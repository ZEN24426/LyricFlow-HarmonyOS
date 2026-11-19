'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require('typescript');
const root = path.resolve(__dirname, '..');
const transpile = text => ts.transpileModule(text, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;

function load(relative, requireFn = () => ({})) {
  const mod = { exports: {} };
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  vm.runInNewContext(transpile(source), { module: mod, exports: mod.exports, require: requireFn, Error });
  return mod.exports;
}
const matcher = load('entry/src/main/ets/services/CloudSongMatcher.ets');
const bilingual = load('entry/src/main/ets/services/CloudBilingualLyrics.ets');
let cloudInstances = 0;
let networkRequests = 0;
class FakeCloudService {
  constructor() { cloudInstances++; this.cache = new Map(); }
  cancel() {}
  async searchDetailed(query) {
    if (!this.cache.has(query)) { networkRequests++; this.cache.set(query, { songs: [song()], incomplete: false }); }
    return this.cache.get(query);
  }
  async lyrics(selected) { return cloudLyrics(selected.id); }
}
const defaultAudio = { async readForMatching() { return { metadata: metadata(), usedSandboxCopy: false }; },
  canReadDirectly() { return true; } };
class WorkingFileCleanupError extends Error { constructor() { super('临时音频副本未能清理'); } }
class MetadataExtractorCleanupError extends Error { constructor() { super('音频检查资源未能安全释放'); } }
const defaultScanner = { MAX_SANDBOX_COPIES: 300,
  async scan() { return { audioFiles: [audio()], lyricFiles: [], imageFiles: [], warnings: [], visitedFiles: 1 }; } };
const imports = {
  './FolderScanner': { FolderScanner: defaultScanner },
  './AudioMetadataService': { AudioMetadataService: defaultAudio, WorkingFileCleanupError },
  './FileSelectionService': { FileSelectionService: { async readUtf8Text() { throw Error('unexpected read'); } } },
  './CloudLyricsService': { CloudLyricsService: FakeCloudService },
  './CloudSongMatcher': matcher,
  './CloudBilingualLyrics': bilingual,
  './MissingLyricsMp3Evidence': { MetadataExtractorCleanupError, async beginMp3SourceObservation() { throw Error('unavailable'); } }
};
const queueModule = load('entry/src/main/ets/services/MissingLyricsQueue.ets', name => {
  if (imports[name] !== undefined) return imports[name];
  throw Error('Unexpected import: ' + name);
});
const { MissingLyricsQueue, classifyKnownLyricText, classifyEmbeddedEvidence } = queueModule;

test('strict cleanup failure is reported even after cancellation and does not assert absence', async () => {
  let rejectRead, startedRead;
  const started = new Promise(resolve => { startedRead = resolve; });
  const p = port({ async readMetadata() { startedRead(); return new Promise((_, reject) => { rejectRead = reject; }); } });
  const queue = new MissingLyricsQueue(p.impl); const warnings = [];
  queue.setCleanupErrorCallback(message => warnings.push(message));
  const scan = queue.scan('file://folder', '/private'); const cancelled = assert.rejects(scan, /取消/);
  await started; queue.cancel(); rejectRead(new WorkingFileCleanupError()); await cancelled;
  assert.equal(warnings.length, 1); assert.match(warnings[0], /未能清理/);
  assert.equal(queue.snapshot().rows.length, 0);
});
test('extractor cleanup failure is reported and the song remains unknown', async () => {
  const p = port({ async inspectEmbedded() { throw new MetadataExtractorCleanupError(); } });
  const queue = new MissingLyricsQueue(p.impl), warnings = [];
  queue.setCleanupErrorCallback(message => warnings.push(message));
  await queue.scan('file://folder', '/private');
  assert.equal(warnings.length, 1); assert.match(warnings[0], /未能安全释放/);
  assert.equal(queue.snapshot().rows[0].embedded, 'unknown');
});
test('default adapter propagates observation cleanup failure and releases an acquired cover', async () => {
  for (const stage of ['begin', 'end']) {
    let releases = 0; const warnings = [];
    const adapter = { ...imports, './MissingLyricsMp3Evidence': {
      MetadataExtractorCleanupError,
      async beginMp3SourceObservation() { if (stage === 'begin') throw new MetadataExtractorCleanupError(); return {}; },
      async endMp3SourceObservation() { throw new MetadataExtractorCleanupError(); }
    }, './AudioMetadataService': { WorkingFileCleanupError, AudioMetadataService: {
      canReadDirectly() { return true; }, async readForMatching() { return { usedSandboxCopy: false,
        metadata: metadata({ coverImage: { async release() { releases++; } } }) }; }
    } } };
    const { MissingLyricsQueue: Queue } = load('entry/src/main/ets/services/MissingLyricsQueue.ets', name => adapter[name] || {});
    const queue = new Queue(); queue.setCleanupErrorCallback(message => warnings.push(message));
    await queue.scan('file://folder', '/private');
    assert.equal(warnings.length, 1); assert.equal(queue.snapshot().rows[0].embedded, 'unknown');
    assert.equal(releases, stage === 'end' ? 1 : 0);
  }
});

function song(id = '1') {
  return { source: 'netease', id, title: 'Song', artists: ['Singer'], album: 'Album', durationMs: 100000 };
}
function audio(name = 'song.mp3', id = 'a') { return { id, name, uri: 'file://folder/' + name }; }
function metadata(extra = {}) {
  return { title: 'Song', artist: 'Singer', album: 'Album', durationMs: 100000, lyrics: '',
    coverImage: undefined, ...extra };
}
function cloudLyrics(id = '1') {
  return { source: 'netease', songId: id, text: '[00:01.00]original',
    translation: '[00:01.00]译文', translationWarning: '' };
}
function port(overrides = {}) {
  const state = { searches: 0, previews: 0, cancelled: 0, releases: 0, sidecarReads: 0 };
  const impl = {
    async scan(_uri, _max, _progress, _cancel) {
      return { audioFiles: [audio()], lyricFiles: [], imageFiles: [], warnings: [], visitedFiles: 1 };
    },
    canReadDirectly() { return true; },
    async readMetadata() { return metadata({ coverImage: { async release() { state.releases++; } } }); },
    async inspectEmbedded(_audio, meta) { return { coverage: 'unknown', presence: 'unknown', text: meta.lyrics }; },
    async readSidecar() { state.sidecarReads++; return '[00:01.00]lyric'; },
    async search() { state.searches++; return { songs: [song()], incomplete: false }; },
    async lyrics(selected) { state.previews++; return cloudLyrics(selected.id); },
    cancelCloud() { state.cancelled++; },
    ...overrides
  };
  return { state, impl };
}

test('translation-only queue preview remains manual and cannot select empty alternatives', async () => {
  const p = port({ async lyrics(selected) { return { source: selected.source, songId: selected.id,
    text: '', translation: '[00:01]译文', translationWarning: '' }; } });
  const q = new MissingLyricsQueue(p.impl); await q.scan('file://folder', '/private'); await q.search('a');
  q.selectCandidate('netease', '1'); await q.previewSelected();
  assert.equal(q.snapshot().previewOriginal, ''); assert.equal(q.snapshot().previewBilingual, '');
  assert.match(q.snapshot().status, /暂无可用原文/);
  assert.throws(() => q.confirmPreview('original'), /不可用/);
  assert.throws(() => q.confirmPreview('bilingual'), /不可用/);
  assert.equal(q.confirmPreview('translation').text, '[00:01]译文');
});

test('text classification is conservative for malformed, mixed, empty and unsupported lyrics', () => {
  assert.equal(classifyKnownLyricText('first line\n第二行'), 'plain');
  assert.equal(classifyKnownLyricText('[offset:+25]\n[00:01.00]first\n[00:02.000]二'), 'timed');
  assert.equal(classifyKnownLyricText('[00:01.00]<00:01.01>每<00:01.10>字'), 'timed');
  for (const value of ['', ' \n', '[00:01.00]', '[00:61.00]bad', '[00:01.00]x\nplain',
    '[00:01.00]<00:70.00>bad', '[00:01.00]<00:01:bad>bad', '[00:01]x<+00:99>b',
    '[00:01]x< 00:99>b', '[00:01]x< -00:01.00>b', '[00:01]x< +00:01',
    '[offset:0]\n[offset:1]\n[00:01]a',
    '[chorus]\nwords', '00:00:01,000 --> 00:00:02,000\ntext', 'a\ufffdb', 'x'.repeat(256 * 1024 + 1)]) {
    assert.equal(classifyKnownLyricText(value), 'unknown', value.slice(0, 80));
  }
});

test('absence requires explicit complete presence evidence; empty, SYLT/alias uncertainty and contradiction stay unknown', () => {
  assert.equal(classifyEmbeddedEvidence('', { coverage: 'unknown', presence: 'unknown', text: '' }), 'unknown');
  assert.equal(classifyEmbeddedEvidence('', { coverage: 'complete', presence: 'unknown', text: '' }), 'unknown');
  assert.equal(classifyEmbeddedEvidence('', { coverage: 'complete', presence: 'present', text: '' }), 'unknown');
  assert.equal(classifyEmbeddedEvidence('', { coverage: 'complete', presence: 'absent', text: '' }), 'missing');
  assert.equal(classifyEmbeddedEvidence('actual', { coverage: 'complete', presence: 'absent', text: '' }), 'unknown');
  assert.equal(classifyEmbeddedEvidence('[00:01]text', { coverage: 'unknown', presence: 'present', text: '[00:01]text' }), 'unknown');
  assert.equal(classifyEmbeddedEvidence('[00:01]text', { coverage: 'complete', presence: 'present', text: '[00:01]text' }), 'timed');
});

test('default adapter never turns an empty reader result into missing and reuses one cloud cache', async () => {
  cloudInstances = 0; networkRequests = 0;
  const q = new MissingLyricsQueue();
  await q.scan('file://folder', '/private');
  assert.equal(q.snapshot().rows[0].embedded, 'unknown');
  assert.equal(q.snapshot().rows[0].sidecar, 'unknown');
  assert.equal(networkRequests, 0);
  await q.search('a');
  await q.search('a');
  assert.equal(cloudInstances, 1);
  assert.equal(networkRequests, 1);
  assert.equal(q.snapshot().selectedKey, '');
});

test('scan separates known sidecar from unverified embedded state and never starts network', async () => {
  const p = port({
    async scan() { return { audioFiles: [audio()], lyricFiles: [{ id: 'l', name: 'song.lrc', uri: 'file://folder/song.lrc' }],
      imageFiles: [], warnings: [], visitedFiles: 2 }; },
    async readMetadata() { return metadata({ lyrics: '[00:01.00]visible', coverImage: { async release() { p.state.releases++; } } }); }
  });
  const q = new MissingLyricsQueue(p.impl);
  await q.scan('file://folder', '/private');
  const row = q.snapshot().rows[0];
  assert.equal(row.embedded, 'unknown');
  assert.equal(row.embeddedHasReadableText, true);
  assert.equal(row.embeddedVisibleText, 'timed');
  assert.equal(row.sidecar, 'timed');
  assert.equal(row.sidecarName, 'song.lrc');
  assert.equal(p.state.releases, 1);
  assert.equal(p.state.sidecarReads, 1);
  assert.equal(p.state.searches + p.state.previews, 0);
  assert.match(q.snapshot().warnings.at(-1), /不等于不存在/);
});

test('read failures, ambiguous sidecars, missing URI and duplicate file identities do not become missing', async () => {
  const p = port({
    async scan() { return { audioFiles: [audio('bad.mp3', 'a'), audio('dup.mp3', 'b'),
      { id: 'c', name: 'missing.mp3' }, audio('bad.mp3', 'alias')],
      lyricFiles: [{ id: 'l1', name: 'bad.lrc', uri: 'file://folder/bad.lrc' },
        { id: 'l2', name: 'bad.txt', uri: 'file://folder/bad.txt' }], imageFiles: [], warnings: [], visitedFiles: 4 }; },
    async readMetadata(uri) { if (uri.endsWith('bad.mp3')) throw Error('failed'); return metadata(); }
  });
  const q = new MissingLyricsQueue(p.impl);
  await q.scan('file://folder', '/private');
  const snapshot = q.snapshot();
  assert.equal(snapshot.rows.length, 3);
  for (const row of snapshot.rows) { assert.equal(row.embedded, 'unknown'); assert.equal(row.sidecar, 'unknown'); }
  assert.match(snapshot.rows[0].note, /多个候选/);
  assert.equal(p.state.sidecarReads, 0);
  assert.ok(snapshot.warnings.some(w => /重复/.test(w)));
});

test('only explicit candidate selection and confirmation produce an in-memory draft', async () => {
  const p = port(); const q = new MissingLyricsQueue(p.impl);
  await q.scan('file://folder', '/private');
  await q.search('a');
  assert.equal(q.snapshot().recommendedId, '1');
  assert.equal(q.snapshot().selectedKey, '');
  await assert.rejects(q.previewSelected(), /先选择/);
  assert.throws(() => q.confirmPreview('original'), /先完成/);
  q.selectCandidate('netease', '1');
  await q.previewSelected();
  const draft = q.confirmPreview('bilingual');
  assert.equal(draft.rowId, 'a');
  assert.equal(draft.text, '[00:01.00]original\n[00:01.00]译文');
  assert.throws(() => q.confirmPreview('invalid'), /版本无效/);
  assert.equal(p.state.searches, 1); assert.equal(p.state.previews, 1);
  assert.equal(typeof q.save, 'undefined');
});

test('incomplete results, modified keywords and filename fallback cannot yield recommendations', async () => {
  const incomplete = port({ async search() { return { songs: [song()], incomplete: true }; } });
  const q = new MissingLyricsQueue(incomplete.impl); await q.scan('file://folder', '/private'); await q.search('a');
  assert.equal(q.snapshot().searchIncomplete, true); assert.equal(q.snapshot().recommendedId, '');
  q.selectCandidate('netease', '1'); await q.previewSelected(); assert.equal(q.confirmPreview('original').songId, '1');
  const changed = port(); const q2 = new MissingLyricsQueue(changed.impl); await q2.scan('file://folder', '/private');
  await q2.search('a', 'different'); assert.equal(q2.snapshot().recommendedId, '');
  const fallback = port({ async readMetadata() { return metadata({ title: '' }); } });
  const q3 = new MissingLyricsQueue(fallback.impl); await q3.scan('file://folder', '/private');
  await q3.search('a'); assert.equal(q3.snapshot().rows[0].titleFromFilename, true); assert.equal(q3.snapshot().recommendedId, '');
});

test('stale response after cancellation is rejected; new work waits for outstanding I/O', async () => {
  let resolve;
  const p = port({ search() { return new Promise(r => { resolve = r; }); } });
  const q = new MissingLyricsQueue(p.impl); await q.scan('file://folder', '/private');
  const pending = q.search('a');
  q.cancel(); assert.equal(q.snapshot().cancelling, true);
  await assert.rejects(q.search('a'), /已有任务/);
  resolve({ songs: [song()], incomplete: false });
  await assert.rejects(pending, /取消/);
  assert.equal(q.snapshot().busy, false); assert.equal(q.snapshot().candidates.length, 0);
  assert.equal(p.state.cancelled, 1);
});

test('metadata and sidecar I/O cancellation releases decoded cover and never commits partial rows', async () => {
  let resolve, markStarted;
  const started = new Promise(r => { markStarted = r; });
  const p = port({ readMetadata() { markStarted(); return new Promise(r => { resolve = r; }); } });
  const q = new MissingLyricsQueue(p.impl); const pending = q.scan('file://folder', '/private');
  await started;
  q.cancel();
  resolve(metadata({ coverImage: { async release() { p.state.releases++; } } }));
  await assert.rejects(pending, /取消/);
  assert.equal(q.snapshot().rows.length, 0); assert.equal(p.state.releases, 1); assert.equal(q.snapshot().busy, false);
});

test('preview checks returned song identity and snapshots cannot mutate internal candidates or rows', async () => {
  const p = port({ async lyrics() { return cloudLyrics('wrong-id'); } });
  const q = new MissingLyricsQueue(p.impl); await q.scan('file://folder', '/private'); await q.search('a');
  const snapshot = q.snapshot(); snapshot.rows[0].identity.title = 'mutated'; snapshot.candidates[0].song.id = 'bad';
  assert.equal(q.snapshot().rows[0].identity.title, 'Song'); assert.equal(q.snapshot().candidates[0].song.id, '1');
  q.selectCandidate('netease', '1'); await assert.rejects(q.previewSelected(), /不一致/);
  assert.throws(() => q.confirmPreview('original'), /先完成/);
});
