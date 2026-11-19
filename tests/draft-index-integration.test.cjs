'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require('typescript');

function metadata(overrides = {}) {
  return { title: 'Original', artist: 'Artist', album: '', composer: '', genre: '', year: 0, albumArtist: '',
    track: 0, disc: 0, discTotal: 0, trackTotal: 0, bpm: 0, grouping: '', isrc: '', copyright: '',
    comment: '', lyrics: 'old lyrics', duration: 10, durationMs: 10000, bitrate: 128, sampleRate: 44100,
    channels: 2, fileSize: 100, ...overrides };
}
function content(overrides = {}) {
  return { title: 'Draft', artist: 'Artist', album: '', composer: '', genre: '', year: '', albumArtist: '',
    track: '', disc: '', discTotal: '', trackTotal: '', bpm: '', grouping: '', isrc: '', copyright: '',
    comment: '', lyricText: 'draft lyrics', lyricSourceName: '', lyricSummary: '', coverNeedsReselection: true, ...overrides };
}
function harness() {
  const calls = [], messages = [];
  const service = {
    async begin(_ctx, p) { calls.push(['begin', p]); return { token: 'new-session' }; },
    async save(_ctx, session, value) { calls.push(['save', session.token, value]); return { revision: 'rev-current' }; },
    async inspect() { return undefined; },
    async discardIf(_ctx, revision, check) { calls.push(['discard', revision]); return check(); }
  };
  const audio = {
    async importToSandbox(uri, name) { calls.push(['import', uri]); return { sourceUri: uri, sourceName: name,
      workingPath: '/private/refreshed.mp3', metadata: metadata() }; },
    async removeWorkingFile(p) { calls.push(['remove', p]); },
    async removeWorkingFileChecked(p) { calls.push(['checked-remove', p]); }
  };
  const save = { async save(mode) { calls.push(['audio-save', mode]); return { externalBackupName: 'backup.mp3' }; } };
  const picker = { async selectOne() { calls.push(['select']); return undefined; } };
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
  const marker = 'struct Index {';
  const start = source.indexOf(marker), end = source.indexOf('\n  build() {', start);
  const body = source.slice(start + marker.length, end).replace(/@Watch\('[^']+'\)/g, '').replace(/@(Prop|State|Link)\b/g, '');
  const js = ts.transpileModule('class Index {' + body + '\n}', { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2020 } }).outputText;
  const Index = vm.runInNewContext(js + '\nIndex', { Error, Promise, DraftService: service, AudioMetadataService: audio,
    AudioSaveService: save, FileSelectionService: picker, setTimeout: () => 1, clearTimeout: () => {},
    parseLyricAsync: async () => ({ format: 'lrc' }) });
  const index = new Index();
  index.ctx = () => ({ filesDir: '/private' });
  index.notify = message => { messages.push(message); };
  index.showExportSuccess = message => { messages.push(message); };
  index.audioUri = 'source'; index.audioName = 'song.mp3'; index.audioWorkingPath = '/private/old.mp3';
  index.songTitle = 'Original'; index.artist = 'Artist'; index.lyricText = 'old lyrics';
  index.captureEditBaseline();
  index.draftSession = { token: 'session' };
  return { index, calls, messages, service, audio, save, picker };
}

test('current edits are flushed before asking to switch audio', async () => {
  const h = harness();
  h.index.songTitle = 'Changed'; h.index.draftChanged();
  await h.index.importAudio();
  assert.deepEqual(h.calls.slice(0, 2).map(x => x[0]), ['save', 'select']);
  assert.equal(h.calls[0][2].title, 'Changed');
  assert.equal(h.index.audioWorkingPath, '/private/old.mp3');
  assert.equal(h.index.draftDirty, false);
});

test('exit waits for a successful draft flush before clearing the editor and private copy', async () => {
  const h = harness();
  let complete;
  h.service.save = () => new Promise(resolve => { complete = resolve; });
  h.index.songTitle = 'Unsaved'; h.index.draftChanged();
  h.index.aboutToDisappear();
  for (let i = 0; i < 20 && complete === undefined; i++) await Promise.resolve();
  assert.equal(typeof complete, 'function');
  assert.equal(h.index.songTitle, 'Unsaved');
  assert.equal(h.calls.some(x => x[0] === 'remove'), false);
  complete({ revision: 'rev-saved' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.index.audioWorkingPath, '');
  assert.ok(h.calls.some(x => x[0] === 'remove' && x[1] === '/private/old.mp3'));
});

test('failed exit flush preserves edits and working copy and does not claim durable recovery', async () => {
  const h = harness();
  h.service.save = async () => { throw new Error('injected disk failure'); };
  h.index.songTitle = 'Unsaved'; h.index.lyricText = 'private unsaved lyrics'; h.index.draftChanged();
  h.index.aboutToDisappear();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.index.songTitle, 'Unsaved');
  assert.equal(h.index.lyricText, 'private unsaved lyrics');
  assert.equal(h.index.audioWorkingPath, '/private/old.mp3');
  assert.equal(h.calls.some(x => x[0] === 'remove'), false);
  assert.match(h.index.draftStatus, /跨进程恢复未确认/);
});

test('changes during exit flush prevent cleanup even if both snapshots save', async () => {
  const h = harness();
  let complete, n = 0;
  h.service.save = async () => { if (++n === 1) await new Promise(resolve => { complete = resolve; }); return { revision: 'rev-' + n }; };
  h.index.songTitle = 'First'; h.index.draftChanged(); h.index.aboutToDisappear();
  for (let i = 0; i < 20 && complete === undefined; i++) await Promise.resolve();
  h.index.songTitle = 'Later'; h.index.draftChanged(); complete();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.index.songTitle, 'Later');
  assert.equal(h.index.audioWorkingPath, '/private/old.mp3');
  assert.equal(h.calls.some(x => x[0] === 'remove'), false);
  assert.match(h.index.draftStatus, /编辑发生变化/);
});

test('a resumed component invalidates the old disappearing callback', async () => {
  const h = harness();
  let complete;
  h.service.save = () => new Promise(resolve => { complete = resolve; });
  h.index.songTitle = 'Unsaved'; h.index.draftChanged(); h.index.aboutToDisappear();
  for (let i = 0; i < 20 && complete === undefined; i++) await Promise.resolve();
  h.index.restoreSavedFolder = () => {};
  h.index.loadFirstUseGuides = () => {};
  h.index.checkInterruptedDirectWrite = () => {};
  h.index.refreshDraftStatus = () => {};
  h.index.aboutToAppear();
  complete({ revision: 'rev-saved' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.index.songTitle, 'Unsaved');
  assert.equal(h.index.audioWorkingPath, '/private/old.mp3');
  assert.equal(h.calls.some(x => x[0] === 'remove'), false);
});

test('switch waits for edits that arrive while an earlier draft save is in flight', async () => {
  const h = harness();
  let finishFirst;
  let count = 0;
  h.service.save = async (_ctx, session, value) => {
    h.calls.push(['save', session.token, value]);
    if (++count === 1) await new Promise(resolve => { finishFirst = resolve; });
    return { revision: 'rev-' + count };
  };
  h.index.songTitle = 'First'; h.index.draftChanged();
  const switching = h.index.importAudio();
  for (let i = 0; i < 15 && finishFirst === undefined; i++) await Promise.resolve();
  assert.equal(typeof finishFirst, 'function');
  h.index.songTitle = 'Second'; h.index.draftChanged();
  finishFirst();
  await switching;
  assert.deepEqual(h.calls.filter(x => x[0] === 'save').map(x => x[2].title), ['First', 'Second']);
  assert.equal(h.calls.at(-1)[0], 'select');
});

test('untracked dirty edits block a switch rather than overwrite an existing draft', async () => {
  const h = harness();
  h.index.draftSession = undefined;
  h.index.songTitle = 'Unsaved'; h.index.draftChanged();
  await h.index.importAudio();
  assert.equal(h.calls.some(x => x[0] === 'select'), false);
  assert.equal(h.index.songTitle, 'Unsaved');
  assert.match(h.messages.at(-1), /未自动保存/);
});

test('editing while picker is open prevents the selection from replacing current work', async () => {
  const h = harness();
  let choose;
  h.picker.selectOne = () => new Promise(resolve => { choose = resolve; });
  const pending = h.index.importAudio();
  for (let i = 0; i < 20 && choose === undefined; i++) await Promise.resolve();
  h.index.songTitle = 'Later edit'; h.index.draftChanged();
  choose({ uri: 'selected', name: 'selected.mp3' });
  await pending;
  assert.equal(h.calls.some(x => x[0] === 'import'), false);
  assert.equal(h.index.audioWorkingPath, '/private/old.mp3');
  assert.equal(h.index.songTitle, 'Later edit');
});

test('editing while new audio imports retains current editor and cleans only the unused copy', async () => {
  const h = harness();
  let complete;
  h.picker.selectOne = async () => ({ uri: 'selected', name: 'selected.mp3' });
  h.audio.importToSandbox = () => new Promise(resolve => { complete = resolve; });
  const pending = h.index.importAudio();
  for (let i = 0; i < 20 && complete === undefined; i++) await Promise.resolve();
  h.index.lyricText = 'Later lyrics'; h.index.draftChanged();
  complete({ sourceUri: 'selected', sourceName: 'selected.mp3', workingPath: '/private/new.mp3', metadata: metadata() });
  await pending;
  assert.equal(h.index.audioWorkingPath, '/private/old.mp3');
  assert.equal(h.index.lyricText, 'Later lyrics');
  assert.ok(h.calls.some(x => x[0] === 'checked-remove' && x[1] === '/private/new.mp3'));
});

test('restoring a draft requires a current editor snapshot and keeps unconfirmed cover unselected', () => {
  const h = harness();
  h.index.page = 'draftRecovery'; h.index.draftOpenSnapshot = h.index.editorSnapshot();
  const result = { revision: 'rev-restored', session: { token: 'restored' }, content: content(),
    audio: { sourceUri: 'new', sourceName: 'song.mp3', workingPath: '/private/restored.mp3', metadata: metadata() } };
  let claims = 0;
  assert.equal(h.index.acceptDraft(result, h.index.draftEditGeneration, () => { claims++; }), true);
  h.index.draftCommitted(result.session);
  assert.equal(claims, 1);
  assert.equal(h.index.lyricText, 'draft lyrics');
  assert.equal(h.index.pendingCoverImage, undefined);
  assert.equal(h.index.coverChanged, false);
  assert.equal(h.index.draftCoverNeedsReselection, true);
  assert.equal(h.index.draftRevision, 'rev-restored');
  assert.equal(h.index.draftSession.token, 'restored');
});

test('changed editor prevents claiming or replacing its content', () => {
  const h = harness();
  h.index.page = 'draftRecovery'; h.index.draftOpenSnapshot = h.index.editorSnapshot();
  h.index.lyricText = 'newer';
  let claims = 0;
  assert.equal(h.index.acceptDraft({}, h.index.draftEditGeneration, () => { claims++; }), false);
  assert.equal(claims, 0);
  assert.equal(h.index.lyricText, 'newer');
});

test('verified direct write clears only the matching saved draft and starts a new identity', async () => {
  const h = harness();
  h.index.songTitle = 'Changed'; h.index.draftChanged();
  await h.index.writeOriginalAudioMetadata(h.index.editorSnapshot(), h.index.draftEditGeneration);
  assert.deepEqual(h.calls.filter(x => ['save', 'audio-save', 'import', 'discard'].includes(x[0])).map(x => x[0]),
    ['save', 'audio-save', 'import', 'discard']);
  assert.equal(h.calls.find(x => x[0] === 'discard')[1], 'rev-current');
  assert.equal(h.index.audioWorkingPath, '/private/refreshed.mp3');
  assert.equal(h.index.draftDirty, false);
  assert.ok(h.calls.some(x => x[0] === 'begin'));
});

test('new edits while old audio cleanup is pending remain dirty and save under the refreshed identity', async () => {
  const h = harness();
  h.index.songTitle = 'Changed'; h.index.draftChanged();
  let finishCleanup;
  h.audio.removeWorkingFile = p => { h.calls.push(['remove', p]); return new Promise(resolve => { finishCleanup = resolve; }); };
  const pending = h.index.writeOriginalAudioMetadata(h.index.editorSnapshot(), h.index.draftEditGeneration);
  for (let i = 0; i < 40 && finishCleanup === undefined; i++) await Promise.resolve();
  assert.equal(typeof finishCleanup, 'function');
  assert.equal(h.index.audioWorkingPath, '/private/refreshed.mp3');
  h.index.lyricText = 'New after save'; h.index.draftChanged();
  finishCleanup(); await pending;
  assert.equal(h.index.lyricText, 'New after save');
  assert.equal(h.index.draftDirty, true);
  await h.index.flushDraft();
  assert.equal(h.index.draftDirty, false);
  assert.equal(h.calls.filter(x => x[0] === 'save').at(-1)[2].lyricText, 'New after save');
  assert.equal(h.calls.filter(x => x[0] === 'save').at(-1)[1], 'new-session');
});

test('new edits while refreshed cover release is pending remain dirty and save', async () => {
  const h = harness();
  h.index.songTitle = 'Changed'; h.index.draftChanged();
  let finishCover;
  const cover = { release: () => new Promise(resolve => { finishCover = resolve; }) };
  h.audio.importToSandbox = async (uri, name) => ({ sourceUri: uri, sourceName: name,
    workingPath: '/private/refreshed.mp3', metadata: metadata({ coverImage: cover }) });
  const pending = h.index.writeOriginalAudioMetadata(h.index.editorSnapshot(), h.index.draftEditGeneration);
  for (let i = 0; i < 40 && finishCover === undefined; i++) await Promise.resolve();
  assert.equal(typeof finishCover, 'function');
  h.index.songTitle = 'New after write'; h.index.draftChanged();
  finishCover(); await pending;
  assert.equal(h.index.songTitle, 'New after write');
  assert.equal(h.index.draftDirty, true);
  await h.index.flushDraft();
  assert.equal(h.calls.filter(x => x[0] === 'save').at(-1)[2].title, 'New after write');
});

test('cleanup failure after direct write never disables tracking or discards newer edits', async () => {
  const h = harness();
  h.index.songTitle = 'Changed'; h.index.draftChanged();
  let failCleanup;
  h.audio.removeWorkingFile = () => new Promise((_resolve, reject) => { failCleanup = reject; });
  const pending = h.index.writeOriginalAudioMetadata(h.index.editorSnapshot(), h.index.draftEditGeneration);
  for (let i = 0; i < 40 && failCleanup === undefined; i++) await Promise.resolve();
  h.index.lyricText = 'Later edit'; h.index.draftChanged();
  failCleanup(new Error('cleanup failed')); await pending;
  assert.equal(h.index.lyricText, 'Later edit');
  assert.equal(h.index.draftDirty, true);
  await h.index.flushDraft();
  assert.equal(h.calls.filter(x => x[0] === 'save').at(-1)[2].lyricText, 'Later edit');
});

test('edit changed during direct write retains draft and does not replace newer editor state', async () => {
  const h = harness();
  h.index.songTitle = 'Changed'; h.index.draftChanged();
  let finish;
  h.save.save = () => new Promise(resolve => { finish = resolve; });
  const pending = h.index.writeOriginalAudioMetadata(h.index.editorSnapshot(), h.index.draftEditGeneration);
  for (let i = 0; i < 15 && finish === undefined; i++) await Promise.resolve();
  assert.equal(typeof finish, 'function');
  h.index.songTitle = 'Later edit'; h.index.draftChanged();
  finish({ externalBackupName: 'backup.mp3' });
  await pending;
  assert.equal(h.calls.some(x => x[0] === 'discard'), false);
  assert.equal(h.index.songTitle, 'Later edit');
  assert.equal(h.index.audioWorkingPath, '/private/old.mp3');
  assert.match(h.index.draftStatus, /草稿仍保留/);
});

test('direct write confirmation refuses a stale snapshot before starting', () => {
  const h = harness();
  let dialog;
  h.index.getUIContext = () => ({ showAlertDialog: value => { dialog = value; } });
  h.index.confirmOriginalAudioWrite();
  h.index.audioUri = 'different target';
  dialog.secondaryButton.action();
  assert.equal(h.calls.some(x => x[0] === 'audio-save'), false);
  assert.match(h.messages.at(-1), /重新确认/);
});

test('direct write refuses target change while async metadata preparation is pending', async () => {
  const h = harness();
  let prepare;
  h.index.prepareAudioMetadata = () => new Promise(resolve => { prepare = resolve; });
  const pending = h.index.writeOriginalAudioMetadata(h.index.editorSnapshot(), h.index.draftEditGeneration);
  for (let i = 0; i < 20 && prepare === undefined; i++) await Promise.resolve();
  h.index.audioUri = 'different target';
  prepare({ fields: { title: 'prepared' }, warning: '' });
  await pending;
  assert.equal(h.calls.some(x => x[0] === 'audio-save'), false);
  assert.match(h.messages.at(-1), /准备直写期间变化/);
});

test('edits while conditional draft cleanup is pending are not overwritten after direct write', async () => {
  const h = harness();
  h.index.lyricText = 'Prepared lyric'; h.index.draftChanged();
  let finishDiscard;
  h.service.discardIf = async (_ctx, revision, check) => {
    h.calls.push(['discard', revision]);
    await new Promise(resolve => { finishDiscard = resolve; });
    return check();
  };
  const pending = h.index.writeOriginalAudioMetadata(h.index.editorSnapshot(), h.index.draftEditGeneration);
  for (let i = 0; i < 40 && finishDiscard === undefined; i++) await Promise.resolve();
  assert.equal(typeof finishDiscard, 'function');
  h.index.lyricText = 'Later lyric'; h.index.draftChanged();
  finishDiscard(); await pending;
  assert.equal(h.index.lyricText, 'Later lyric');
  assert.equal(h.index.audioWorkingPath, '/private/old.mp3');
  assert.ok(h.calls.some(x => x[0] === 'checked-remove' && x[1] === '/private/refreshed.mp3'));
  assert.match(h.index.draftStatus, /编辑发生变化/);
});
