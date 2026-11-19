'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require('typescript');

function harness() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lyricflow-draft-test-'));
  const absoluteTemp = path.resolve(os.tmpdir());
  assert.ok(path.resolve(root).startsWith(absoluteTemp + path.sep));
  const native = p => p === '/sandbox' ? root : path.join(root, p.replace(/^\/sandbox\//, ''));
  const virtual = p => '/sandbox/' + path.relative(root, p).replace(/\\/g, '/');
  const mode = { READ_ONLY: 1, WRITE_ONLY: 2, READ_WRITE: 4, CREATE: 8, EXCL: 16, NOFOLLOW: 32, DIR: 64 };
  let failNextWrite = false;
  let failNextDirectorySync = false;
  let failNextReadback = false;
  let failDraftRead = false;
  let failLockClose = 0;
  const openPaths = new Map();
  let pickerCalls = 0;
  let nextSelection;
  let nextAudio;
  let removed = 0;
  let coverReleases = 0;
  let uuidCounter = 0;
  const stat = s => ({ size: s.size, ino: s.ino, mtimeNs: s.mtimeNs, ctimeNs: s.ctimeNs,
    isFile: () => s.isFile(), isDirectory: () => s.isDirectory() });
  const fileIo = {
    OpenMode: mode,
    openSync(p, flags) {
      if (p === '/sandbox/lyricflow_edit_draft.json' && failDraftRead && !(flags & (mode.WRITE_ONLY | mode.READ_WRITE))) {
        failDraftRead = false;
        throw new Error('injected readback failure');
      }
      const nativePath = native(p);
      let openFlags = flags & mode.READ_WRITE ? fs.constants.O_RDWR : flags & mode.WRITE_ONLY ? fs.constants.O_WRONLY : fs.constants.O_RDONLY;
      if (flags & mode.CREATE) openFlags |= fs.constants.O_CREAT;
      if (flags & mode.EXCL) openFlags |= fs.constants.O_EXCL;
      if ((flags & mode.NOFOLLOW) && fs.constants.O_NOFOLLOW) openFlags |= fs.constants.O_NOFOLLOW;
      const fd = fs.openSync(nativePath, openFlags, 0o600);
      openPaths.set(fd, p);
      return { fd, tryLock() {}, unlock() {} };
    },
    closeSync(fd) {
      const name = openPaths.get(fd); openPaths.delete(fd); fs.closeSync(fd);
      if (name === '/sandbox/lyricflow_edit_draft.lock' && failLockClose > 0) {
        failLockClose--;
        if (failLockClose === 0) throw new Error('injected lock close failure');
      }
    },
    fsyncSync(fd) { if (fs.fstatSync(fd).isDirectory() && failNextDirectorySync) {
      failNextDirectorySync = false;
      throw new Error('injected directory sync failure');
    } },
    lstatSync(p) { try { return stat(fs.lstatSync(native(p), { bigint: true })); }
      catch (e) { if (e.code === 'ENOENT') { const x = new Error('not found'); x.code = 13900002; throw x; } throw e; } },
    statSync(fd) { return stat(fs.fstatSync(fd, { bigint: true })); },
    mkdtempSync(p) { return virtual(fs.mkdtempSync(native(p.replace(/X{6}$/, '')))); },
    readSync(fd, ab, options) { return fs.readSync(fd, new Uint8Array(ab), 0, options.length, null); },
    async read(fd, ab, options) { return this.readSync(fd, ab, options); },
    writeSync(fd, ab) { if (failNextWrite) { failNextWrite = false; throw new Error('injected failure'); }
      return fs.writeSync(fd, new Uint8Array(ab), 0, Math.min(ab.byteLength, 1024), null); },
    renameSync(a, b) { fs.renameSync(native(a), native(b)); if (failNextReadback) {
      failNextReadback = false; failDraftRead = true;
    } },
    unlinkSync(p) { fs.unlinkSync(native(p)); },
    rmdirSync(p) { fs.rmdirSync(native(p)); }
  };
  // Harmony Stat.size is a number, while nanosecond fields and ino may be bigint.
  const lstat = fileIo.lstatSync, fstat = fileIo.statSync;
  fileIo.lstatSync = p => { const s = lstat(p); s.size = Number(s.size); return s; };
  fileIo.statSync = fd => { const s = fstat(fd); s.size = Number(s.size); return s; };
  const util = {
    generateRandomUUID: () => `00000000-0000-4000-8000-${(++uuidCounter).toString(16).padStart(12, '0')}`,
    TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) },
    TextDecoder: { create: (_name, options) => ({ decodeToString: bytes => new TextDecoder('utf-8', options).decode(bytes) }) }
  };
  const cryptoFramework = { createMd() { const hash = crypto.createHash('sha256'); return {
    async update(blob) { hash.update(blob.data); }, async digest() { return { data: new Uint8Array(hash.digest()) }; },
    updateSync(blob) { hash.update(blob.data); }, digestSync() { return { data: new Uint8Array(hash.digest()) }; }
  }; } };
  const AudioMetadataService = {
    async importToSandbox() {
      const name = 'lyricflow_work_restored.mp3';
      fs.writeFileSync(path.join(root, name), nextAudio);
      return { workingPath: '/sandbox/' + name, sourceUri: 'fresh-grant', sourceName: 'same.mp3',
        metadata: { coverImage: { async release() { coverReleases++; } } } };
    },
    async removeWorkingFile(p) { removed++; fs.unlinkSync(native(p)); }
  };
  const FileSelectionService = { async selectOne() { pickerCalls++; return nextSelection; } };
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/services/DraftService.ets'), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const imports = { '@kit.CoreFileKit': { fileIo }, '@kit.ArkTS': { util },
    '@kit.CryptoArchitectureKit': { cryptoFramework }, './AudioMetadataService': { AudioMetadataService },
    './FileSelectionService': { FileSelectionService } };
  const mod = { exports: {} };
  vm.runInNewContext(compiled, { module: mod, exports: mod.exports, Error, require: name => imports[name] || {} });
  const panelSource = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/DraftRecoveryPanel.ets'), 'utf8');
  const marker = 'struct DraftRecoveryPanel {';
  const panelStart = panelSource.indexOf(marker), panelBuild = panelSource.indexOf('\n  build() {', panelStart);
  assert.ok(panelStart >= 0 && panelBuild > panelStart);
  const panelBody = panelSource.slice(panelStart + marker.length, panelBuild).replace(/@(Prop|State|Link)\b/g, '');
  const panelCode = ts.transpileModule('class DraftRecoveryPanel {' + panelBody + '\n}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const Panel = vm.runInNewContext(panelCode + '\nDraftRecoveryPanel', { Error, DraftService: mod.exports.DraftService, AudioMetadataService });
  fs.writeFileSync(path.join(root, 'lyricflow_work_initial.mp3'), Buffer.from('synthetic audio fixture'));
  return {
    DraftService: mod.exports.DraftService, context: { filesDir: '/sandbox' }, root,
    working: '/sandbox/lyricflow_work_initial.mp3',
    select(audio) { nextSelection = { name: 'same.mp3', uri: 'fresh-grant' }; nextAudio = Buffer.from(audio); },
    cancel() { nextSelection = undefined; },
    counts() { return { pickerCalls, removed, coverReleases }; },
    failWrite() { failNextWrite = true; },
    failDirectorySync() { failNextDirectorySync = true; },
    failReadback() { failNextReadback = true; },
    failLockClose() { failLockClose = 1; },
    failLockCloseAfter(count) { failLockClose = count; },
    panel() { const panel = new Panel(); panel.visible = true;
      panel.getUIContext = () => ({ getHostContext: () => ({ filesDir: '/sandbox' }) }); return panel; },
    cleanup() { assert.ok(path.resolve(root).startsWith(absoluteTemp + path.sep)); fs.rmSync(root, { recursive: true, force: true }); }
  };
}

function content(lyric = 'draft lyrics') {
  return { title: 'song', artist: 'artist', album: '', composer: '', genre: '', year: '', albumArtist: '', track: '',
    disc: '', discTotal: '', trackTotal: '', bpm: '', grouping: '', isrc: '', copyright: '', comment: '',
    lyricText: lyric, lyricSourceName: '', lyricSummary: '', coverNeedsReselection: true };
}

test('draft restore reauthorizes and hashes the complete imported working copy; covers require reselection', async () => {
  const h = harness();
  try {
    const session = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    const input = content('first');
    const pending = h.DraftService.save(h.context, session, input);
    input.lyricText = 'changed after enqueue';
    const saved = await pending;
    const persisted = fs.readFileSync(path.join(h.root, 'lyricflow_edit_draft.json'), 'utf8');
    assert.equal(persisted.includes('fresh-grant'), false);
    assert.equal(persisted.includes('lyricflow_work_'), false);
    const summary = await h.DraftService.inspect(h.context);
    assert.equal(summary.revision, saved.revision);
    assert.equal('lyricText' in summary, false);
    h.select('wrong audio fixture');
    await assert.rejects(h.DraftService.restore(h.context, summary.revision), /内容与草稿来源不同/);
    assert.deepEqual(h.counts(), { pickerCalls: 1, removed: 1, coverReleases: 1 });
    assert.equal((await h.DraftService.inspect(h.context)).revision, summary.revision);
    h.select('synthetic audio fixture');
    const restored = await h.DraftService.restore(h.context, summary.revision);
    assert.equal(restored.content.lyricText, 'first');
    assert.equal(restored.content.coverNeedsReselection, true);
    assert.equal('coverImage' in restored.content, false);
    assert.equal(h.counts().pickerCalls, 2);
  } finally { h.cleanup(); }
});

test('canceling file selection leaves draft untouched and produces no restored content', async () => {
  const h = harness();
  try {
    const session = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    const saved = await h.DraftService.save(h.context, session, content());
    h.cancel();
    assert.equal(await h.DraftService.restore(h.context, saved.revision), undefined);
    assert.equal((await h.DraftService.inspect(h.context)).revision, saved.revision);
    assert.equal(h.counts().removed, 0);
    const savedAfterCancel = await h.DraftService.save(h.context, session, content('continue editing'));
    h.select('synthetic audio fixture');
    const restored = await h.DraftService.restore(h.context, savedAfterCancel.revision);
    assert.equal(restored.content.lyricText, 'continue editing');
  } finally { h.cleanup(); }
});

test('preparing, abandoning or rejecting recovery keeps the original session saving', async () => {
  const h = harness();
  try {
    const original = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    let saved = await h.DraftService.save(h.context, original, content('original'));
    h.select('synthetic audio fixture');
    let prepared = await h.DraftService.restore(h.context, saved.revision);
    await assert.rejects(h.DraftService.save(h.context, prepared.session, content('not committed')), /会话已失效/);
    h.DraftService.abandonRestore(prepared.session);
    saved = await h.DraftService.save(h.context, original, content('after cancel'));
    h.select('synthetic audio fixture');
    prepared = await h.DraftService.restore(h.context, saved.revision);
    assert.equal((await h.DraftService.commitRestore(h.context, prepared.session, () => false)).state, 'rejected');
    saved = await h.DraftService.save(h.context, original, content('after rejection'));
    h.select('synthetic audio fixture');
    prepared = await h.DraftService.restore(h.context, saved.revision);
    assert.equal((await h.DraftService.commitRestore(h.context, prepared.session, () => { throw new Error('parent refused'); })).state, 'uncertain');
    await h.DraftService.save(h.context, original, content('after callback error'));
  } finally { h.cleanup(); }
});

test('commit checks draft revision before callback and only successful acceptance switches session', async () => {
  const h = harness();
  try {
    const original = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    let saved = await h.DraftService.save(h.context, original, content('one'));
    h.select('synthetic audio fixture');
    let prepared = await h.DraftService.restore(h.context, saved.revision);
    saved = await h.DraftService.save(h.context, original, content('newer edit'));
    let invoked = 0;
    await assert.rejects(h.DraftService.commitRestore(h.context, prepared.session, () => { invoked++; return true; }), /草稿已变化/);
    assert.equal(invoked, 0);
    saved = await h.DraftService.save(h.context, original, content('original still works'));
    h.select('synthetic audio fixture');
    prepared = await h.DraftService.restore(h.context, saved.revision);
    assert.equal((await h.DraftService.commitRestore(h.context, prepared.session, claim => {
      claim(); invoked++; return true;
    })).state, 'committed');
    assert.equal(invoked, 1);
    await assert.rejects(h.DraftService.save(h.context, original, content('old')), /会话已失效/);
    const accepted = await h.DraftService.save(h.context, prepared.session, content('accepted'));
    assert.ok(accepted.revision);
  } finally { h.cleanup(); }
});

test('ownership cannot be claimed after the synchronous callback returns', async () => {
  const h = harness();
  try {
    const original = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    const saved = await h.DraftService.save(h.context, original, content('original'));
    h.select('synthetic audio fixture');
    const prepared = await h.DraftService.restore(h.context, saved.revision);
    let lateClaim;
    const decision = await h.DraftService.commitRestore(h.context, prepared.session, claim => {
      lateClaim = claim; return false;
    });
    assert.equal(decision.state, 'rejected');
    assert.throws(() => lateClaim(), /确认已结束/);
    assert.ok((await h.DraftService.save(h.context, original, content('still active'))).revision);
  } finally { h.cleanup(); }
});

test('claimed restore with callback and lock-close failures preserves copy and never starts autosave', async () => {
  const h = harness();
  try {
    const original = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    await h.DraftService.save(h.context, original, content('original'));
    const panel = h.panel();
    await panel.refresh();
    h.select('synthetic audio fixture');
    await panel.beginRestore();
    let handedOff;
    let issue;
    panel.onRestore = (result, _generation, claim) => {
      claim(); handedOff = result; h.failLockClose(); throw new Error('parent failed after taking ownership');
    };
    let onCommittedCalls = 0;
    panel.onCommitted = () => { onCommittedCalls++; };
    panel.onRecoveryIssue = (result, state, warning) => { issue = { result, state, warning }; };
    await panel.confirmRestore();
    assert.ok(handedOff);
    assert.equal(h.counts().removed, 0);
    assert.equal(h.counts().coverReleases, 0);
    assert.equal(fs.existsSync(path.join(h.root, 'lyricflow_work_restored.mp3')), true);
    assert.equal(issue.state, 'committed');
    assert.match(issue.warning, /锁失败/);
    assert.match(issue.warning, /自动保存已暂停/);
    assert.equal(onCommittedCalls, 0);
    assert.equal(panel.mode, 'notice');
    assert.match(panel.status, /自动保存已暂停/);
    await assert.rejects(h.DraftService.save(h.context, handedOff.session, content('must not overwrite')), /会话已失效/);
    await assert.rejects(h.DraftService.save(h.context, original, content('old')), /会话已失效/);
  } finally { h.cleanup(); }
});

test('successful claim with lock-close and committed-notification failures preserves copy and exposes both failures', async () => {
  const h = harness();
  try {
    const original = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    await h.DraftService.save(h.context, original, content('original'));
    const panel = h.panel(); await panel.refresh(); h.select('synthetic audio fixture'); await panel.beginRestore();
    let result;
    panel.onRestore = (value, _generation, claim) => { claim(); result = value; h.failLockClose(); return true; };
    panel.onCommitted = () => { throw new Error('notification failure'); };
    let issue;
    panel.onRecoveryIssue = (value, state, warning) => { issue = { value, state, warning }; };
    await panel.confirmRestore();
    assert.equal(issue.state, 'committed');
    assert.match(issue.warning, /锁失败/);
    assert.match(issue.warning, /通知失败/);
    assert.equal(h.counts().removed, 0);
    assert.ok((await h.DraftService.save(h.context, result.session, content('accepted'))).revision);
  } finally { h.cleanup(); }
});

test('claim followed by false never notifies a committed editor or starts autosave', async () => {
  const h = harness();
  try {
    const original = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    await h.DraftService.save(h.context, original, content('original'));
    const panel = h.panel(); await panel.refresh(); h.select('synthetic audio fixture'); await panel.beginRestore();
    let committed = 0;
    panel.onRestore = (_result, _generation, claim) => { claim(); return false; };
    panel.onCommitted = () => { committed++; };
    await panel.confirmRestore();
    assert.equal(committed, 0);
    assert.equal(h.counts().removed, 0);
    assert.match(panel.status, /自动保存已暂停/);
  } finally { h.cleanup(); }
});

test('parent failure before claim combined with lock-close failure preserves both copy and original session', async () => {
  const h = harness();
  try {
    const original = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    await h.DraftService.save(h.context, original, content('original'));
    const panel = h.panel();
    await panel.refresh();
    h.select('synthetic audio fixture');
    await panel.beginRestore();
    let issue;
    panel.onRestore = () => { h.failLockClose(); throw new Error('ambiguous handoff'); };
    panel.onRecoveryIssue = (result, state, warning) => { issue = { result, state, warning }; };
    await panel.confirmRestore();
    assert.equal(issue.state, 'uncertain');
    assert.match(issue.warning, /状态不确定/);
    assert.equal(h.counts().removed, 0);
    assert.equal(fs.existsSync(path.join(h.root, 'lyricflow_work_restored.mp3')), true);
    assert.equal(panel.mode, 'notice');
    assert.ok((await h.DraftService.save(h.context, original, content('original still active'))).revision);
  } finally { h.cleanup(); }
});

test('post-rename sync/readback failures reconcile the exact attempted revision before retry', async () => {
  const h = harness();
  try {
    const session = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    await h.DraftService.save(h.context, session, content('original'));
    h.failDirectorySync();
    await assert.rejects(h.DraftService.save(h.context, session, content('attempt one')), /directory sync failure/);
    const uncertain = await h.DraftService.inspect(h.context);
    h.failDirectorySync();
    await assert.rejects(h.DraftService.save(h.context, session, content('must wait')), /directory sync failure/);
    assert.equal((await h.DraftService.inspect(h.context)).revision, uncertain.revision);
    await h.DraftService.save(h.context, session, content('recovered'));
    h.failReadback();
    await assert.rejects(h.DraftService.save(h.context, session, content('attempt two')), /readback failure/);
    const saved = await h.DraftService.save(h.context, session, content('final'));
    h.select('synthetic audio fixture');
    assert.equal((await h.DraftService.restore(h.context, saved.revision)).content.lyricText, 'final');
  } finally { h.cleanup(); }
});

test('corrupt draft disposal requires explicit exact snapshot and never deletes a valid replacement', async () => {
  const h = harness();
  try {
    const session = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    await h.DraftService.save(h.context, session, content('keep'));
    const file = path.join(h.root, 'lyricflow_edit_draft.json');
    const valid = fs.readFileSync(file);
    await assert.rejects(h.DraftService.inspectCorrupt(h.context), /草稿有效/);
    fs.writeFileSync(file, '{bad one');
    const first = await h.DraftService.inspectCorrupt(h.context);
    fs.writeFileSync(file, '{another corrupt record');
    await assert.rejects(h.DraftService.discardCorrupt(h.context, first.token), /草稿已变化/);
    const second = await h.DraftService.inspectCorrupt(h.context);
    fs.writeFileSync(file, valid);
    await assert.rejects(h.DraftService.discardCorrupt(h.context, second.token), /草稿有效/);
    assert.deepEqual(fs.readFileSync(file), valid);
    fs.writeFileSync(file, '{bad again');
    const third = await h.DraftService.inspectCorrupt(h.context);
    await h.DraftService.discardCorrupt(h.context, third.token);
    assert.equal(await h.DraftService.inspect(h.context), undefined);
  } finally { h.cleanup(); }
});

test('serialized saves preserve call order and discard uses an exact revision', async () => {
  const h = harness();
  try {
    const session = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    const first = h.DraftService.save(h.context, session, content('one'));
    const second = h.DraftService.save(h.context, session, content('two'));
    const [a, b] = await Promise.all([first, second]);
    await assert.rejects(h.DraftService.discard(h.context, a.revision), /草稿已变化/);
    h.select('synthetic audio fixture');
    const restored = await h.DraftService.restore(h.context, b.revision);
    assert.equal(restored.content.lyricText, 'two');
    await h.DraftService.discard(h.context, b.revision);
    assert.equal(await h.DraftService.inspect(h.context), undefined);
    await assert.rejects(h.DraftService.save(h.context, restored.session, content()), /会话已失效/);
  } finally { h.cleanup(); }
});

test('conditional cleanup never deletes a changed draft or changed editor', async () => {
  const h = harness();
  try {
    const session = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    const first = await h.DraftService.save(h.context, session, content('one'));
    assert.equal(await h.DraftService.discardIf(h.context, first.revision, () => false), false);
    const second = await h.DraftService.save(h.context, session, content('two'));
    assert.equal(await h.DraftService.discardIf(h.context, first.revision, () => true), false);
    assert.equal((await h.DraftService.inspect(h.context)).revision, second.revision);
    assert.equal(await h.DraftService.discardIf(h.context, second.revision, () => true), true);
    assert.equal(await h.DraftService.inspect(h.context), undefined);
  } finally { h.cleanup(); }
});

test('pending autosave snapshots are bounded and can be retried', async () => {
  const h = harness();
  try {
    const session = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    const first = h.DraftService.save(h.context, session, content('one'));
    const second = h.DraftService.save(h.context, session, content('two'));
    assert.throws(() => h.DraftService.save(h.context, session, content('three')), /尚未完成/);
    await Promise.all([first, second]);
    const third = await h.DraftService.save(h.context, session, content('three'));
    h.select('synthetic audio fixture');
    assert.equal((await h.DraftService.restore(h.context, third.revision)).content.lyricText, 'three');
  } finally { h.cleanup(); }
});

test('failed new begin keeps queued and subsequent original-session saves valid', async () => {
  const h = harness();
  try {
    const session = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    const oldSave = h.DraftService.save(h.context, session, content('kept'));
    const newer = h.DraftService.begin(h.context, h.working, 'same.mp3');
    await oldSave;
    await assert.rejects(newer, /已有未处理草稿/);
    await h.DraftService.save(h.context, session, content('fresh'));
    assert.ok(await h.DraftService.inspect(h.context));
  } finally { h.cleanup(); }
});

test('begin lock-close failure after validation leaves prior session valid', async () => {
  const h = harness();
  try {
    const original = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    h.failLockCloseAfter(2);
    await assert.rejects(h.DraftService.begin(h.context, h.working, 'same.mp3'), /lock close failure/);
    assert.ok((await h.DraftService.save(h.context, original, content('still valid'))).revision);
  } finally { h.cleanup(); }
});

test('corrupt drafts are refused without deletion; failed temp writes preserve previous draft', async () => {
  const h = harness();
  try {
    const session = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    const saved = await h.DraftService.save(h.context, session, content('kept'));
    const file = path.join(h.root, 'lyricflow_edit_draft.json');
    const previous = fs.readFileSync(file);
    h.failWrite();
    await assert.rejects(h.DraftService.save(h.context, session, content('new')), /injected failure/);
    assert.deepEqual(fs.readFileSync(file), previous);
    assert.equal((await h.DraftService.inspect(h.context)).revision, saved.revision);
    fs.writeFileSync(file, previous.toString('utf8').replace('kept', 'lost'));
    await assert.rejects(h.DraftService.inspect(h.context), /草稿校验失败/);
    fs.writeFileSync(file, previous);
    fs.writeFileSync(file, '{broken');
    await assert.rejects(h.DraftService.inspect(h.context), /草稿数据损坏/);
    assert.equal(fs.readFileSync(file, 'utf8'), '{broken');
  } finally { h.cleanup(); }
});

test('oversize, unknown fields and invalid Unicode are rejected without writing', async () => {
  const h = harness();
  try {
    const session = await h.DraftService.begin(h.context, h.working, 'same.mp3');
    assert.throws(() => h.DraftService.save(h.context, session, { ...content(), coverImage: 'untrusted' }), /草稿字段/);
    assert.throws(() => h.DraftService.save(h.context, session, content('x'.repeat(1024 * 1024 + 1))), /大小限制/);
    assert.throws(() => h.DraftService.save(h.context, session, content('\ud800')), /草稿文本无效/);
    assert.equal(await h.DraftService.inspect(h.context), undefined);
  } finally { h.cleanup(); }
});
