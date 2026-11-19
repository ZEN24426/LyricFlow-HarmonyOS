'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

// Exercise the real page controller methods without pretending to render ArkUI.
const file = path.resolve(__dirname, '../entry/src/main/ets/components/MissingLyricsPage.ets');
let source = fs.readFileSync(file, 'utf8').split('  build() {')[0] + '\n}\n';
source = source.replace(/@Component\s+export struct/, 'export class')
  .replace(/@Prop\s+@Watch\('[^']+'\)\s+/g, '')
  .replace(/@State\s+/g, '');
const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
  target: ts.ScriptTarget.ES2020 } }).outputText;
const item = { id: '1', uri: 'file://music/one.mp3', name: 'one.mp3', identity: { title: 'song', artist: 'singer', album: '', durationMs: 1000 },
  titleFromFilename: false, embedded: 'unknown', embeddedHasReadableText: false, embeddedVisibleText: 'unknown',
  sidecar: 'unknown', sidecarName: '', note: 'unknown' };
const song = { source: 'netease', id: '42', title: 'song', artists: ['singer'], album: '', durationMs: 1000 };
const candidate = { song, score: 90, evidence: [], warnings: [] };
class Queue {
  constructor() { this.s = { rows: [], warnings: [], busy: false, cancelling: false, operation: '', searchRowId: '',
    candidates: [], selectedKey: '', recommendedId: '', previewOriginal: '', previewTranslation: '', previewTranslationWarning: '',
    previewBilingual: '', previewBilingualWarning: '', previewBilingualError: '', status: '' }; this.cancelCount = 0; }
  snapshot() { return { ...this.s }; }
  setCleanupErrorCallback(cb) { this.cleanupCb = cb; }
  cancel() { this.cancelCount++; if (this.s.busy) this.s.cancelling = true; }
  async scan() { this.s.busy = true; this.s.operation = 'scan'; await new Promise(r => { this.finishScan = r; });
    this.s.rows = [item]; this.s.busy = false; this.s.operation = ''; this.s.status = 'done'; }
  async search(id) { this.s.searchRowId = id; this.s.candidates = [candidate]; this.s.status = 'search done'; }
  selectCandidate(source, id) { this.s.selectedKey = JSON.stringify([source, id]); }
  async previewSelected() { this.s.previewOriginal = '[00:01]original'; this.s.previewTranslation = '[00:01]译文';
    this.s.previewBilingual = '[00:01]original\n[00:01]译文'; this.s.status = 'preview done'; }
  confirmPreview(kind) { return { rowId: this.s.searchRowId, source: 'netease', songId: '42', kind,
    text: kind === 'bilingual' ? this.s.previewBilingual : kind === 'translation' ? this.s.previewTranslation : this.s.previewOriginal }; }
}
const m = { exports: {} };
vm.runInNewContext(code, { module: m, exports: m.exports, Error, Number, String, Math, JSON,
  require: name => name.endsWith('MissingLyricsQueue') ? { MissingLyricsQueue: Queue } :
    { CloudSongMatcher: { buildKeyword: i => i.title + ' ' + i.artist } } });
const Page = m.exports.MissingLyricsPage;
function page() { const p = new Page(); p.folderUri = 'file://music'; p.filesDir = '/private'; p.aboutToAppear(); return p; }

test('cleanup failure from the old scan is forwarded after the page disappears', () => {
  const p = new Page(), notices = [];
  p.folderUri = 'file://music'; p.filesDir = '/private'; p.onCleanupError = message => notices.push(message);
  p.aboutToAppear(); const previousQueue = p.queue; p.aboutToDisappear();
  previousQueue.cleanupCb('临时音频副本未能清理');
  assert.deepEqual(notices, ['临时音频副本未能清理']);
});

test('manual confirmation requires preview and acknowledgement, then delivers only one in-memory handoff', async () => {
  const p = page(); const selected = []; p.onConfirm = value => selected.push(value);
  const pending = p.scan(); p.queue.finishScan(); await pending;
  p.chooseRow(p.rows[0]); await p.search(); await p.preview(candidate);
  p.confirm(); assert.equal(selected.length, 0);
  p.acknowledged = true; p.kind = 'bilingual'; p.confirm(); p.confirm();
  assert.equal(selected.length, 1); assert.equal(selected[0].audioUri, item.uri);
  assert.equal(selected[0].audioName, item.name); assert.equal(selected[0].text, '[00:01]original\n[00:01]译文');
});

test('translation-only preview defaults to translation and requires acknowledgement before handoff', async () => {
  const p = page(); const chosen = []; p.onConfirm = value => chosen.push(value);
  const pending = p.scan(); p.queue.finishScan(); await pending;
  p.chooseRow(p.rows[0]); await p.search();
  p.queue.previewSelected = async function() { this.s.previewOriginal = ''; this.s.previewTranslation = '[00:01]译文';
    this.s.previewBilingual = ''; this.s.status = '仅有译文'; };
  await p.preview(candidate); assert.equal(p.kind, 'translation'); assert.equal(p.currentText(), '[00:01]译文');
  p.confirm(); assert.equal(chosen.length, 0); p.acknowledged = true; p.confirm();
  assert.equal(chosen.length, 1); assert.equal(chosen[0].kind, 'translation'); assert.equal(chosen[0].text, '[00:01]译文');
});

test('directory change and leaving page invalidate late operations and prevent handoff', async () => {
  const p = page(); const first = p.queue, pending = p.scan();
  p.folderUri = 'file://new'; p.onFolderChanged(); assert.notEqual(p.queue, first);
  first.finishScan(); await pending; assert.equal(p.rows.length, 0); assert.equal(p.busy, false);
  const second = p.queue, late = p.scan(); p.aboutToDisappear(); second.finishScan(); await late;
  assert.equal(p.rows.length, 0); let delivered = false; p.onConfirm = () => { delivered = true; };
  p.acknowledged = true; p.confirm(); assert.equal(delivered, false);
});

test('cancelling a delayed preview cannot make an obsolete result confirmable', async () => {
  const p = page(); const pending = p.scan(); p.queue.finishScan(); await pending;
  p.chooseRow(p.rows[0]); await p.search();
  let release; p.queue.previewSelected = async function() { this.s.busy = true;
    await new Promise(r => { release = r; }); this.s.previewOriginal = 'stale'; this.s.busy = false; };
  const preview = p.preview(candidate); p.cancel(); release(); await preview;
  assert.equal(p.previewReady, false); assert.equal(p.currentText(), '');
  let delivered = false; p.onConfirm = () => { delivered = true; }; p.acknowledged = true; p.confirm();
  assert.equal(delivered, false);
});

test('a cancelled scan cannot show late rows even if underlying I/O finishes', async () => {
  const p = page(), pending = p.scan(); p.cancel(); p.queue.finishScan(); await pending;
  assert.equal(p.rows.length, 0); assert.equal(p.busy, false); assert.match(p.status, /取消/);
});
