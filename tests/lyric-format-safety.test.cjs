'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require('typescript');
const root = path.resolve(__dirname, '..');
const transpile = source => ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;

function moduleAt(relative) {
  const mod = { exports: {} };
  vm.runInNewContext(transpile(fs.readFileSync(path.join(root, relative), 'utf8')),
    { module: mod, exports: mod.exports, Error });
  return mod.exports;
}
const { LyricEngine } = moduleAt('entry/src/main/ets/services/LyricEngine.ets');
const { combineCloudLyrics } = moduleAt('entry/src/main/ets/services/CloudBilingualLyrics.ets');
const { hasInlineLrcTiming, plainLrcFromEnhanced } = moduleAt('entry/src/main/ets/services/LrcPreservingExport.ets');

function indexClass(saveText, extras = {}) {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
  const marker = 'struct Index {';
  const start = source.indexOf(marker);
  const end = source.indexOf('\n  build() {', start);
  assert.ok(start >= 0 && end > start);
  const body = source.slice(start + marker.length, end)
    .replace(/@Watch\('[^']+'\)/g, '').replace(/@(Prop|State|Link)\b/g, '');
  const code = transpile('class Index {' + body + '\n}');
  return vm.runInNewContext(code + '\nIndex', {
    Error,
    parseLyricAsync: async (text, name) => LyricEngine.parse(text, name),
    convertToLrcAsync: async doc => LyricEngine.toLrc(doc),
    hasInlineLrcTiming,
    plainLrcFromEnhanced,
    ExportService: { saveTextToDownload: saveText },
    ...extras
  });
}

test('enhanced lyric export offers preservation and ordinary conversion without changing the editor', async () => {
  const written = [];
  const Index = indexClass(async (_ctx, name, text) => { written.push({ name, text }); return { name, uri: 'saved' }; });
  const index = new Index();
  let dialog;
  index.ctx = () => ({}); index.notify = () => {}; index.showExportSuccess = () => {};
  index.getUIContext = () => ({ showAlertDialog: value => { dialog = value; } });
  index.page = 'lyrics'; index.audioUri = 'selected'; index.audioWorkingPath = 'private';
  index.songTitle = 'fixture'; index.lyricSourceName = '';
  index.lyricText = '[offset:5]\n[00:01.00]<00:01.00>hello<00:01.50>world\n';
  const initial = index.lyricText;
  await index.requestLyricsExport();
  assert.ok(dialog);
  dialog.secondaryButton.action();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(written[0].text, '[offset:5]\n[00:01.00]helloworld\n');
  assert.equal(index.lyricText, initial);
  await index.requestLyricsExport();
  dialog.primaryButton.action();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(written[1].text, initial);
});

test('an obsolete export-choice dialog cannot export later edits', async () => {
  const written = [];
  const Index = indexClass(async (_ctx, name, text) => { written.push({ name, text }); return { name, uri: 'saved' }; });
  const index = new Index(); let dialog;
  index.ctx = () => ({}); index.notify = () => {}; index.showExportSuccess = () => {};
  index.getUIContext = () => ({ showAlertDialog: value => { dialog = value; } });
  index.page = 'lyrics'; index.audioUri = 'selected'; index.audioWorkingPath = 'private';
  index.lyricText = '[00:01.00]<00:01.00>old'; index.lyricSourceName = '';
  await index.requestLyricsExport();
  index.lyricText = '[00:01.00]<00:01.00>new';
  dialog.secondaryButton.action();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(written.length, 0);
});

test('subtitle text with inline-looking markup does not promise raw LRC preservation', async () => {
  const written = [];
  const Index = indexClass(async (_ctx, name, text) => { written.push({ name, text }); return { name, uri: 'saved' }; });
  const index = new Index(); let shown = false;
  index.ctx = () => ({}); index.notify = () => {}; index.showExportSuccess = () => {};
  index.getUIContext = () => ({ showAlertDialog: () => { shown = true; } });
  index.page = 'lyrics'; index.audioUri = 'selected'; index.audioWorkingPath = 'private';
  index.songTitle = 'fixture'; index.lyricSourceName = '';
  index.lyricText = '1\n00:00:01,000 --> 00:00:02,000\ntext <00:01.00>inside';
  await index.requestLyricsExport();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(shown, false);
  assert.equal(written.length, 0);
});

test('bilingual LRC with a lyric arrow stays LRC in the audio and lyric export paths', async () => {
  const combined = combineCloudLyrics('[00:01.00]left --> right', '[00:01.00]翻译');
  assert.equal(combined.error, '');
  const parsed = LyricEngine.parse(combined.text, '');
  assert.equal(parsed.format, 'lrc');
  assert.deepEqual(Array.from(parsed.lines, line => line.text), ['left --> right', '翻译']);
  let saved;
  const Index = indexClass(async (_ctx, name, text) => { saved = { name, text }; return { name, uri: 'saved' }; });
  const index = new Index();
  index.ctx = () => ({});
  index.notify = () => {};
  index.showExportSuccess = () => {};
  index.lyricText = combined.text;
  index.songTitle = 'fixture';
  const prepared = await index.prepareAudioMetadata(false);
  assert.equal(prepared.fields.lyrics, combined.text);
  await index.exportLyrics();
  assert.equal(saved.name, 'fixture.lrc');
  assert.equal(saved.text, combined.text);
});

test('literal arrows remain text and malformed subtitle-like cues are blocked', () => {
  assert.equal(LyricEngine.parse('from --> to', '').format, 'txt');
  for (const text of ['00:99:00,000 --> 00:99:02,000\ninvalid', '00:00:02,000 --> 00:00:01,000\ninvalid']) {
    const invalid = LyricEngine.parse(text, '');
    assert.equal(invalid.format, 'srt');
    assert.equal(invalid.conversionBlocked, true);
    assert.throws(() => LyricEngine.toLrc(invalid), /停止转换/);
  }
  const srt = LyricEngine.parse('1\n00:00:01,000 --> 00:00:02,000\nleft --> right\n', '');
  assert.equal(srt.format, 'srt');
  assert.equal(srt.lines.length, 1);
  assert.equal(srt.lines[0].text, 'left --> right');
  const subtitleWithLrcText = '1\n00:00:01,000 --> 00:00:02,000\n[00:01.00]subtitle text\n';
  assert.equal(LyricEngine.parse(subtitleWithLrcText, '').format, 'srt');
  assert.equal(LyricEngine.parse(subtitleWithLrcText, 'fixture.srt').format, 'srt');
  assert.equal(LyricEngine.parse(subtitleWithLrcText, 'fixture.srt').lines[0].text, '[00:01.00]subtitle text');
  const vtt = LyricEngine.parse('WEBVTT\n\n00:01.000 --> 00:02.000 align:start\nline\n', '');
  assert.equal(vtt.format, 'vtt');
  assert.equal(vtt.lines[0].startMs, 1000);
  assert.equal(vtt.lines[0].endMs, 2000);
});

test('mixed valid and invalid SRT, VTT, SBV and ASS events fail closed', () => {
  const mixed = [
    ['srt', '1\n00:00:01,000 --> 00:00:02,000\nFIRST\n\n2\n00:00:04,000 --> 00:00:03,000\nSECOND'],
    ['srt', '1\n00:00:01,000 --> 00:00:02,000\nFIRST\n\n2\ngarbled --> invalid\nSECOND'],
    ['vtt', 'WEBVTT\n\n00:01.000 --> 00:02.000\nFIRST\n\n00:04.000 --> 00:03.000\nSECOND'],
    ['sbv', '0:00:01.000,0:00:02.000\nFIRST\n\n0:00:04.000,0:00:03.000\nSECOND'],
    ['sbv', '0:00:01.000,0:00:02.000\nFIRST\n\n0:00:04.000,bad\nSECOND'],
    ['ass', '[Script Info]\n[Events]\nFormat: Start, End, Text\nDialogue: 0:00:01.00,0:00:02.00,FIRST\nDialogue: 0:00:04.00,0:00:03.00,SECOND']
  ];
  for (const [format, text] of mixed) {
    const document = LyricEngine.parse(text, 'fixture.' + format);
    assert.equal(document.format, format);
    assert.equal(document.conversionBlocked, true, format);
    assert.match(document.warnings.join(' '), /禁止转换/);
    assert.throws(() => LyricEngine.toLrc(document), /停止转换/);
  }
});

test('mixed standalone LRC and ASS dialogue cannot silently discard the LRC line', () => {
  const text = '[00:01.00]keep me\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,other';
  const document = LyricEngine.parse(text, '');
  assert.equal(document.format, 'ass');
  assert.equal(document.conversionBlocked, true);
  assert.throws(() => LyricEngine.toLrc(document), /停止转换/);
});

test('standalone LRC or free text outside subtitle blocks cannot disappear during conversion', () => {
  const fixtures = [
    ['srt', '1\n00:00:01,000 --> 00:00:02,000\nFIRST\n\n[00:03.00]KEEP'],
    ['srt', '1\n00:00:01,000 --> 00:00:02,000\nFIRST\n\nKEEP THIS BLOCK'],
    ['vtt', 'WEBVTT\n\n00:01.000 --> 00:02.000\nFIRST\n\n[00:03.00]KEEP'],
    ['vtt', 'WEBVTT\n\n00:01.000 --> 00:02.000\nFIRST\n\nKEEP THIS BLOCK'],
    ['sbv', '0:00:01.000,0:00:02.000\nFIRST\n\n[00:03.00]KEEP'],
    ['sbv', '0:00:01.000,0:00:02.000\nFIRST\n\nKEEP THIS BLOCK']
  ];
  for (const [format, text] of fixtures) {
    for (const name of ['', 'fixture.' + format]) {
      const document = LyricEngine.parse(text, name);
      assert.equal(document.format, format, format + ' / ' + name);
      assert.equal(document.conversionBlocked, true, format + ' / ' + name);
      assert.match(document.warnings.join(' '), /未识别内容或无效时间/);
      assert.throws(() => LyricEngine.toLrc(document), /未识别内容或无效时间.*停止转换/);
    }
  }
});

test('time-like subtitle body text remains content, while cue identifiers are not lyrics', () => {
  const fixtures = [
    ['srt', '1\n00:00:01,000 --> 00:00:02,000\n[00:01.00]subtitle text\nAt 12:34 we meet\n\n2\n00:00:03,000 --> 00:00:04,000\nSECOND'],
    ['vtt', 'WEBVTT\n\nfirst-id\n00:01.000 --> 00:02.000\n[00:01.00]subtitle text\nAt 12:34 we meet\n\nsecond-id\n00:03.000 --> 00:04.000\nSECOND'],
    ['sbv', '0:00:01.000,0:00:02.000\n[00:01.00]subtitle text\n12:34,000 people\n\n0:00:03.000,0:00:04.000\nSECOND']
  ];
  for (const [format, text] of fixtures) {
    const document = LyricEngine.parse(text, 'fixture.' + format);
    assert.notEqual(document.conversionBlocked, true, format);
    const output = LyricEngine.toLrc(document).text;
    assert.match(output, /\[00:01\.00\]subtitle text/, format);
    assert.match(output, /SECOND/, format);
    assert.doesNotMatch(output, /first-id|second-id/, format);
  }
});

test('valid SRT, VTT, SBV and ASS still convert with their text', () => {
  const fixtures = [
    ['srt', '1\n00:00:01,000 --> 00:00:02,000\nFIRST'],
    ['vtt', 'WEBVTT\n\n00:01.000 --> 00:02.000\nFIRST'],
    ['sbv', '0:00:01.000,0:00:02.000\nFIRST'],
    ['ass', '[Script Info]\n[Events]\nFormat: Start, End, Text\nDialogue: 0:00:01.00,0:00:02.00,FIRST']
  ];
  for (const [format, text] of fixtures) {
    const document = LyricEngine.parse(text, 'fixture.' + format);
    assert.notEqual(document.conversionBlocked, true, format);
    assert.match(LyricEngine.toLrc(document).text, /FIRST/);
  }
});

test('three-digit-minute bilingual LRC remains timed LRC for preview and export', async () => {
  const combined = combineCloudLyrics('[123:01.10]original', '[123:01.100]译文');
  assert.equal(combined.error, '');
  const parsed = LyricEngine.parse(combined.text, '');
  assert.equal(parsed.format, 'lrc');
  assert.deepEqual(Array.from(parsed.lines, line => line.startMs), [7381100, 7381100]);
  let saved;
  const Index = indexClass(async (_ctx, name, text) => { saved = { name, text }; return { name, uri: 'saved' }; });
  const index = new Index();
  index.ctx = () => ({}); index.notify = () => {}; index.showExportSuccess = () => {};
  index.lyricText = combined.text; index.songTitle = 'long-song';
  await index.exportLyrics();
  assert.equal(saved.name, 'long-song.lrc');
  assert.equal(saved.text, combined.text);
});

test('empty subtitle conversion fails closed before saving lyrics or audio metadata', async () => {
  let saves = 0;
  const Index = indexClass(async () => { saves++; return { name: 'bad.lrc', uri: 'saved' }; });
  const index = new Index();
  const messages = [];
  index.ctx = () => ({});
  index.notify = message => messages.push(message);
  index.showExportSuccess = () => { throw new Error('must not report success'); };
  index.lyricText = '[Script Info]\nTitle: broken\n[Events]\nFormat: Start, End, Text';
  index.songTitle = 'fixture';
  await assert.rejects(index.prepareAudioMetadata(false), /转换结果为空/);
  await index.exportLyrics();
  assert.equal(saves, 0);
  assert.match(messages.at(-1), /转换结果为空/);
});

test('batch copy export rejects both empty and partially invalid conversions before writing', async () => {
  const inputs = {
    empty: '[Script Info]\n[Events]\nFormat: Start, End, Text',
    mixed: '1\n00:00:01,000 --> 00:00:02,000\nFIRST\n\n2\n00:00:04,000 --> 00:00:03,000\nSECOND',
    valid: '1\n00:00:01,000 --> 00:00:02,000\nFIRST'
  };
  const written = [];
  const saved = [];
  const extras = {
    FileSelectionService: { readUtf8Text: async uri => inputs[uri] },
    AudioMetadataService: {
      importToSandbox: async uri => ({ workingPath: uri + '-working', metadata: {} }),
      makeWorkingCopy: async working => working + '-copy',
      write: async (working, fields) => { written.push({ working, lyrics: fields.lyrics }); },
      safeOutputName: name => name,
      removeWorkingFile: async () => {}
    },
    ExportService: { saveAudioToDownload: async (_ctx, name) => { saved.push(name); return { uri: name }; } }
  };
  const Index = indexClass(async () => {}, extras);
  const index = new Index();
  const notices = [];
  index.ctx = () => ({ filesDir: '/sandbox' });
  index.notify = message => notices.push(message);
  index.confirmedCandidates = () => [
    { audioUri: 'audio-empty', lyricUri: 'empty', audioName: 'empty.mp3', lyricName: 'empty.ass' },
    { audioUri: 'audio-mixed', lyricUri: 'mixed', audioName: 'mixed.mp3', lyricName: 'mixed.srt' },
    { audioUri: 'audio-valid', lyricUri: 'valid', audioName: 'valid.mp3', lyricName: 'valid.srt' }
  ];
  await index.exportConfirmedMatches();
  assert.equal(written.length, 1);
  assert.match(written[0].lyrics, /FIRST/);
  assert.deepEqual(saved, ['valid.mp3']);
  assert.match(notices.at(-1), /成功 1 项，失败 2 项/);
  assert.match(notices.at(-1), /转换结果为空/);
  assert.match(notices.at(-1), /停止转换/);
});

test('batch direct-write service does not write mixed invalid subtitles', async () => {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/services/BatchDirectWriteService.ets'), 'utf8');
  const mixed = '1\n00:00:01,000 --> 00:00:02,000\nFIRST\n\n2\n00:00:04,000 --> 00:00:03,000\nSECOND';
  let writes = 0;
  const imports = {
    '@kit.CoreFileKit': { fileIo: { stat: async () => ({ ino: 123, isFile: () => true }) } },
    './DirectAudioWriteService': { DirectAudioWriteService: {
      probe: async () => {}, writeMetadataInPlace: async () => { writes++; }
    } },
    './FileSelectionService': { FileSelectionService: { readUtf8Text: async () => mixed } },
    './AudioMetadataService': { AudioMetadataService: { importToSandbox: async () => { throw new Error('must not import'); } } },
    './BackgroundTasks': {
      parseLyricAsync: async (text, name) => LyricEngine.parse(text, name),
      convertToLrcAsync: async doc => LyricEngine.toLrc(doc)
    }
  };
  const mod = { exports: {} };
  vm.runInNewContext(transpile(source), { module: mod, exports: mod.exports, Error, require: name => imports[name] || {} });
  const result = await mod.exports.BatchDirectWriteService.run({ filesDir: '/sandbox' }, [
    { key: 'k', state: 'confirmed', audioUri: 'audio', lyricUri: 'lyric', audioName: 'song.mp3', lyricName: 'song.srt' }
  ], () => {}, () => false);
  assert.equal(result.succeeded, 0);
  assert.equal(result.failed, 1);
  assert.match(result.details.join(' '), /停止转换/);
  assert.equal(writes, 0);
});

test('single lyric export and audio preparation reject mixed invalid subtitles', async () => {
  let saves = 0;
  const Index = indexClass(async () => { saves++; return { name: 'bad.lrc', uri: 'saved' }; });
  const index = new Index();
  const messages = [];
  index.ctx = () => ({});
  index.notify = message => messages.push(message);
  index.lyricText = '1\n00:00:01,000 --> 00:00:02,000\nFIRST\n\n2\n00:00:04,000 --> 00:00:03,000\nSECOND';
  index.songTitle = 'fixture';
  await assert.rejects(index.prepareAudioMetadata(false), /停止转换/);
  await index.exportLyrics();
  assert.equal(saves, 0);
  assert.match(messages.at(-1), /停止转换/);
});

test('subtitle plus separate LRC is refused before lyric export or audio preparation', async () => {
  let saves = 0;
  const Index = indexClass(async () => { saves++; return { name: 'bad.lrc', uri: 'saved' }; });
  const cases = [
    '1\n00:00:01,000 --> 00:00:02,000\nFIRST\n\n[00:03.00]KEEP',
    'WEBVTT\n\n00:01.000 --> 00:02.000\nFIRST\n\n[00:03.00]KEEP',
    '0:00:01.000,0:00:02.000\nFIRST\n\n[00:03.00]KEEP'
  ];
  for (const text of cases) {
    const index = new Index(); const messages = [];
    index.ctx = () => ({}); index.notify = message => messages.push(message);
    index.lyricText = text; index.songTitle = 'fixture';
    await assert.rejects(index.prepareAudioMetadata(false), /停止转换/);
    await index.exportLyrics();
    assert.equal(saves, 0);
    assert.equal(index.lyricText, text);
    assert.match(messages.at(-1), /停止转换/);
  }
});

test('single direct-write preparation rejects mixed invalid subtitles before any write', async () => {
  let writes = 0;
  const Index = indexClass(async () => {}, {
    AudioSaveService: { save: async () => { writes++; throw new Error('must not write'); } }
  });
  const index = new Index();
  const messages = [];
  index.ctx = () => ({ filesDir: '/sandbox' });
  index.notify = message => messages.push(message);
  index.audioUri = 'audio';
  index.audioName = 'song.mp3';
  index.audioWorkingPath = 'working';
  index.editBaseline = { lyrics: 'previous' };
  index.lyricText = '1\n00:00:01,000 --> 00:00:02,000\nFIRST\n\n2\n00:00:04,000 --> 00:00:03,000\nSECOND';
  await assert.rejects(index.prepareAudioMetadata(true), /停止转换/);
  await index.writeOriginalAudioMetadata(index.editorSnapshot(), index.draftEditGeneration);
  assert.equal(writes, 0);
  assert.match(messages.at(-1), /停止转换/);
  assert.equal(index.busy, false);
});
