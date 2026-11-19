'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require('typescript');
const file = path.join(__dirname, '../entry/src/main/ets/pages/Index.ets');

function makeIndex(service) {
  const source = fs.readFileSync(file, 'utf8');
  const marker = 'struct Index {';
  const start = source.indexOf(marker), end = source.indexOf('\n  build() {', start);
  assert.ok(start >= 0 && end > start);
  const body = source.slice(start + marker.length, end).replace(/@Watch\('[^']+'\)/g, '').replace(/@(Prop|State|Link)\b/g, '');
  const js = ts.transpileModule('class Index {' + body + '\n}', { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
  const wrappedService = { ...service, removeWorkingFileChecked: service.removeWorkingFileChecked || service.removeWorkingFile };
  return vm.runInNewContext(js + '\nIndex', { AudioMetadataService: wrappedService, Error, Promise });
}
function fixture() {
  return { sourceUri: 'folder/song.mp3', sourceName: 'song.mp3', workingPath: '/private/new.mp3', metadata: {
    title: 'Fixture', artist: 'Singer', album: '', genre: '', year: 0, track: 0, disc: 0, discTotal: 0,
    trackTotal: 0, bpm: 0, albumArtist: '', composer: '', grouping: '', isrc: '', copyright: '', comment: '',
    lyrics: 'existing lyric', duration: 1, durationMs: 1000, bitrate: 128, sampleRate: 44100, channels: 2, fileSize: 42
  } };
}
const selection = { audioUri: 'folder/song.mp3', audioName: 'song.mp3', rowId: 'r', source: 'netease', songId: '1', kind: 'original', text: '[00:01]new',
  expectedTitleFromFilename: false, expectedIdentity: { title: 'Fixture', artist: 'Singer', album: '', durationMs: 1000 } };
async function flush() { for (let i = 0; i < 15; i++) await Promise.resolve(); }

test('queue handoff rereads and asks again before replacing the current edit', async () => {
  const removed = [], dialogs = [], working = fixture();
  const service = { importToSandbox: async () => working, removeWorkingFile: async p => { removed.push(p); } };
  const Index = makeIndex(service), index = new Index();
  index.getUIContext = () => ({ showAlertDialog: d => dialogs.push(d) });
  index.ctx = () => ({ filesDir: '/private' }); index.notify = () => {};
  index.page = 'missingLyrics'; index.folderUri = 'folder'; index.audioUri = 'old'; index.audioWorkingPath = '/private/old';
  index.lyricText = 'old unsaved edit';
  index.confirmMissingSelection(selection);
  assert.equal(dialogs.length, 1);
  assert.equal(index.lyricText, 'old unsaved edit');
  dialogs[0].secondaryButton.action();
  await flush();
  assert.equal(dialogs.length, 2);
  assert.match(dialogs[1].message, /已有可见歌词/);
  assert.equal(index.lyricText, 'old unsaved edit');
  dialogs[1].secondaryButton.action();
  assert.equal(index.lyricText, selection.text);
  assert.equal(index.audioUri, selection.audioUri);
  assert.equal(index.editBaseline.lyrics, 'existing lyric');
  assert.equal(index.page, 'lyrics');
  await flush();
  assert.deepEqual(removed, ['/private/old']);
});

test('a late queue import is discarded if the user leaves before it finishes', async () => {
  let finish; const removed = [], dialogs = [];
  const service = { importToSandbox: () => new Promise(resolve => { finish = resolve; }),
    removeWorkingFile: async p => { removed.push(p); } };
  const Index = makeIndex(service), index = new Index();
  index.getUIContext = () => ({ showAlertDialog: d => dialogs.push(d) });
  index.ctx = () => ({ filesDir: '/private' }); index.notify = () => {};
  index.page = 'missingLyrics'; index.folderUri = 'folder'; index.audioUri = 'old'; index.audioWorkingPath = '/private/old';
  index.lyricText = 'old unsaved edit';
  index.confirmMissingSelection(selection);
  dialogs[0].secondaryButton.action();
  await flush();
  index.invalidateMissingSelection(); index.page = 'folder';
  finish(fixture());
  await flush();
  assert.equal(index.lyricText, 'old unsaved edit');
  assert.equal(index.audioUri, 'old');
  assert.deepEqual(removed, ['/private/new.mp3']);
});

test('changed prior tags or a different re-read song cannot be silently replaced', async () => {
  const removed = [], dialogs = [], working = fixture();
  const service = { importToSandbox: async () => working, removeWorkingFile: async p => { removed.push(p); } };
  const Index = makeIndex(service), index = new Index();
  index.getUIContext = () => ({ showAlertDialog: d => dialogs.push(d) });
  index.ctx = () => ({ filesDir: '/private' }); index.notify = () => {};
  index.page = 'missingLyrics'; index.folderUri = 'folder'; index.audioUri = 'old'; index.audioWorkingPath = '/private/old';
  index.lyricText = 'old'; index.songTitle = 'before';
  index.confirmMissingSelection(selection); dialogs[0].secondaryButton.action(); await flush();
  index.songTitle = 'later unsaved title'; dialogs[1].secondaryButton.action(); dialogs[1].onDidDisappear(); await flush();
  assert.equal(index.songTitle, 'later unsaved title'); assert.equal(index.audioUri, 'old');
  assert.deepEqual(removed, ['/private/new.mp3']);

  dialogs.length = 0; removed.length = 0; index.page = 'missingLyrics'; working.metadata.artist = 'Different';
  index.confirmMissingSelection(selection); dialogs[0].secondaryButton.action(); await flush();
  assert.equal(dialogs.length, 1); assert.equal(index.audioUri, 'old');
  assert.deepEqual(removed, ['/private/new.mp3']);
});

test('adopting a new song releases old distinct covers once but retains the new cover', async () => {
  const counts = { old: 0, pending: 0, next: 0 };
  const old = { release: async () => { counts.old++; } };
  const pending = { release: async () => { counts.pending++; } };
  const next = { release: async () => { counts.next++; } };
  const service = { removeWorkingFile: async () => {} }, Index = makeIndex(service), index = new Index();
  index.notify = () => {}; index.coverPixelMap = old; index.pendingCoverImage = pending;
  const working = fixture(); working.metadata.coverImage = next;
  index.adoptWorkingAudio(working); await flush();
  assert.deepEqual(counts, { old: 1, pending: 1, next: 0 });
});

test('re-reading uses the same title whitespace rule as the queue', () => {
  const Index = makeIndex({}), index = new Index(), working = fixture();
  working.metadata.title = '  Fixture  ';
  assert.equal(index.missingIdentityMatches(selection, working), true);
});

test('synchronous old-resource cleanup failures do not interrupt handoff', async () => {
  const dialogs = [], working = fixture();
  const service = { importToSandbox: async () => working, removeWorkingFile: () => { throw Error('cleanup'); } };
  const Index = makeIndex(service), index = new Index();
  index.getUIContext = () => ({ showAlertDialog: d => dialogs.push(d) });
  index.ctx = () => ({ filesDir: '/private' }); index.notify = () => {};
  index.page = 'missingLyrics'; index.folderUri = 'folder'; index.audioUri = 'old'; index.audioWorkingPath = '/private/old';
  index.lyricText = 'old'; index.coverPixelMap = { release() { throw Error('release'); } };
  index.confirmMissingSelection(selection); dialogs[0].secondaryButton.action(); await flush();
  dialogs[1].secondaryButton.action();
  assert.equal(index.audioUri, selection.audioUri); assert.equal(index.lyricText, selection.text); assert.equal(index.page, 'lyrics');
});
