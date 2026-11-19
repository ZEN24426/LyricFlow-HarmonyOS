'use strict';

// Execute the real non-rendering component methods with platform/network stubs.
// ArkUI rendering, @Watch propagation and system dialog dispatch require device tests.
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

const matcherSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/services/CloudSongMatcher.ets'), 'utf8');
const matcherModule = { exports: {} };
vm.runInNewContext(transpile(matcherSource), { module: matcherModule, exports: matcherModule.exports });
const protocolSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/services/CloudLyricsProtocol.ets'), 'utf8');
const protocolModule = { exports: {} };
vm.runInNewContext(transpile(protocolSource), { module: protocolModule, exports: protocolModule.exports, Error });
const { CloudLyricsError, parseCloudLyrics } = protocolModule.exports;
const bilingualSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/services/CloudBilingualLyrics.ets'), 'utf8');
const bilingualModule = { exports: {} };
vm.runInNewContext(transpile(bilingualSource), { module: bilingualModule, exports: bilingualModule.exports, Error });

class FakeCloudService {
  constructor() {
    this.cancelCount = 0;
    this.searchResult = { songs: [], incomplete: false };
    this.lyricsResult = { text: '[00:00.00]original', translation: '', translationWarning: '', source: 'netease', songId: '1' };
  }
  cancel() { this.cancelCount++; }
  async searchDetailed() { return this.searchResult; }
  async lyrics() { return this.lyricsResult; }
}

function componentClass(relativePath, className) {
  const source = fs.readFileSync(path.join(root, relativePath), 'utf8');
  const marker = 'struct ' + className + ' {';
  const start = source.indexOf(marker);
  const build = source.indexOf('\n  build() {', start);
  assert.ok(start >= 0 && build > start, 'component method section exists');
  const body = source.slice(start + marker.length, build)
    .replace(/@Watch\('[^']+'\)/g, '')
    .replace(/@(Prop|State|Link)\b/g, '');
  const helperStart = source.indexOf('function songKey(');
  const helperEnd = helperStart < 0 ? -1 : source.indexOf('@Component', helperStart);
  const helpers = helperStart >= 0 && helperEnd >= 0 && helperEnd < start ? source.slice(helperStart, helperEnd) : '';
  const code = transpile(helpers + '\nclass ' + className + ' {' + body + '\n}\n');
  return vm.runInNewContext(code + '\n' + className, {
    CloudLyricsService: FakeCloudService,
    CloudLyricsError,
    Error,
    combineCloudLyrics: bilingualModule.exports.combineCloudLyrics,
    CloudSongMatcher: matcherModule.exports.CloudSongMatcher
  });
}

const CloudLyricsPage = componentClass('entry/src/main/ets/components/CloudLyricsPage.ets', 'CloudLyricsPage');
const Index = componentClass('entry/src/main/ets/pages/Index.ets', 'Index');
const song = { source: 'netease', id: '1', title: '晴天', artists: ['周杰伦'], album: '叶惠美', durationMs: 269000 };

function pageForSearch() {
  const page = new CloudLyricsPage();
  page.songTitle = '晴天'; page.artist = '周杰伦'; page.album = '叶惠美'; page.durationMs = 269000;
  page.audioKey = 'source|working'; page.previewVisible = false;
  page.getUIContext = () => ({ getFocusController: () => ({ clearFocus() {} }) });
  page.service.searchResult = { songs: [song], incomplete: false };
  page.aboutToAppear();
  return page;
}

test('filename fallback remains searchable but cannot yield a recommendation', async () => {
  const page = pageForSearch();
  page.titleFromFilename = true;
  await page.search();
  assert.equal(page.keyword, '晴天 周杰伦');
  assert.equal(page.candidates[0].score, 100);
  assert.equal(page.recommendedKey, '');
  assert.match(page.status, /暂无可靠推荐/);
  page.titleFromFilename = false;
  await page.search();
  assert.equal(page.recommendedKey, 'netease:1');
});

test('incomplete search never highlights a recommendation', async () => {
  const page = pageForSearch();
  page.service.searchResult = { songs: [song], incomplete: true };
  await page.search();
  assert.equal(page.recommendedKey, '');
  assert.match(page.status, /部分结果异常或不完整，已停止推荐/);
  assert.equal(page.candidates.length, 1);
});

test('invalid translation warns without preventing original selection', async () => {
  const page = pageForSearch();
  await page.search();
  page.service.lyricsResult.translationWarning = '云端译文数据异常，暂时只能使用原文。';
  await page.previewCandidate(0);
  assert.equal(page.translationWarning, '云端译文数据异常，暂时只能使用原文。');
  assert.equal(page.originalText, '[00:00.00]original');
  let selected;
  page.onApply = value => { selected = value; };
  page.applySelection();
  assert.equal(selected.kind, 'original');
  assert.equal(selected.text, '[00:00.00]original');
  page.textKind = 'translation';
  assert.equal(page.canApply(), false);
});

test('translation is explicitly identified on selection', async () => {
  const page = pageForSearch();
  await page.search();
  page.service.lyricsResult.translation = '[00:00.00]translation';
  await page.previewCandidate(0);
  page.textKind = 'translation';
  let selected;
  page.onApply = value => { selected = value; };
  page.applySelection();
  assert.equal(selected.kind, 'translation');
  assert.equal(selected.text, '[00:00.00]translation');
});

test('translation-only preview defaults to translation and never applies empty original or bilingual text', async () => {
  const page = pageForSearch(); await page.search();
  page.service.lyricsResult.text = ''; page.service.lyricsResult.translation = '[00:00.00]译文';
  await page.previewCandidate(0);
  assert.equal(page.textKind, 'translation'); assert.equal(page.originalText, ''); assert.equal(page.bilingualText, '');
  assert.match(page.status, /暂无可用原文/);
  let chosen; page.onApply = value => { chosen = value; }; page.applySelection();
  assert.equal(chosen.kind, 'translation'); assert.equal(chosen.text, '[00:00.00]译文');
  page.textKind = 'original'; assert.equal(page.canApply(), false);
  page.textKind = 'bilingual'; assert.equal(page.canApply(), false);
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/CloudLyricsPage.ets'), 'utf8');
  assert.match(source, /enabled\(this\.originalText\.trim\(\)\.length > 0\)/);
  assert.match(source, /this\.originalText\.trim\(\)\.length > 0 \|\| this\.translatedText\.trim\(\)\.length > 0/);
});

test('bilingual choice is previewed and applied without changing the individual choices', async () => {
  const page = pageForSearch();
  await page.search();
  page.service.lyricsResult.translation = '[00:00.00]translation';
  await page.previewCandidate(0);
  assert.equal(page.bilingualText, '[00:00.00]original\n[00:00.00]translation');
  assert.match(page.bilingualWarning, /同一时间/);
  page.textKind = 'bilingual';
  let selected;
  page.onApply = value => { selected = value; };
  page.applySelection();
  assert.equal(selected.kind, 'bilingual');
  assert.equal(selected.targetKey, 'source|working');
  assert.equal(selected.text, page.bilingualText);
  page.textKind = 'original';
  assert.equal(page.previewText(), '[00:00.00]original');
  page.textKind = 'translation';
  assert.equal(page.previewText(), '[00:00.00]translation');
  page.audioKey = 'changed|working';
  page.textKind = 'bilingual';
  assert.equal(page.canApply(), false);
});

test('unsafe merge leaves original and translation available and clears on new preview', async () => {
  const page = pageForSearch();
  await page.search();
  page.service.lyricsResult.translation = 'untimed translation';
  await page.previewCandidate(0);
  assert.equal(page.bilingualText, '');
  assert.match(page.bilingualError, /无法安全合并/);
  page.textKind = 'bilingual';
  assert.equal(page.canApply(), false);
  page.textKind = 'translation';
  assert.equal(page.canApply(), true);
  page.backToCandidates();
  assert.equal(page.bilingualError, '');
  assert.equal(page.bilingualText, '');
});

test('pure music and missing lyrics are unavailable states, not retryable failures', async () => {
  for (const [payload, message] of [
    [{ code: 200, nolyric: true }, '这首歌被平台标记为纯音乐。'],
    [{ code: 200, uncollected: true }, '平台暂未收录这首歌的歌词。']
  ]) {
    const page = pageForSearch();
    await page.search();
    page.service.lyrics = async () => parseCloudLyrics(JSON.stringify(payload), song.id);
    await page.previewCandidate(0);
    assert.equal(page.lyricsUnavailable, true);
    assert.equal(page.hasError, false);
    assert.equal(page.status, message);
    assert.equal(page.canApply(), false);
    assert.equal(page.previewVisible, true);
    page.backToCandidates();
    assert.equal(page.lyricsUnavailable, false);
    assert.equal(page.previewVisible, false);
    assert.equal(page.candidates.length, 1);
  }
});

test('network and format errors remain retryable failures', async () => {
  for (const kind of ['NETWORK', 'RATE_LIMIT', 'FORMAT_CHANGED']) {
    const page = pageForSearch();
    await page.search();
    page.service.lyrics = async () => { throw new CloudLyricsError(kind, '请求失败'); };
    await page.previewCandidate(0);
    assert.equal(page.lyricsUnavailable, false);
    assert.equal(page.hasError, true);
    assert.match(page.status, /^歌词获取失败：/);
    assert.equal(page.canApply(), false);
  }
});

test('returning to candidates cancels and ignores an earlier lyric response', async () => {
  const page = pageForSearch();
  await page.search();
  let resolveLyrics;
  page.service.lyrics = () => new Promise(resolve => { resolveLyrics = resolve; });
  const pending = page.previewCandidate(0);
  assert.equal(page.previewVisible, true);
  page.onBackRequested();
  assert.equal(page.previewVisible, false);
  assert.equal(page.selectedIndex, -1);
  resolveLyrics({ text: 'stale', translation: '', translationWarning: '', source: 'netease', songId: '1' });
  await pending;
  assert.equal(page.originalText, '');
  assert.equal(page.canApply(), false);
});

test('component disappearance invalidates responses without mutating linked parent state', async () => {
  const page = pageForSearch();
  await page.search();
  let resolveLyrics;
  page.service.lyrics = () => new Promise(resolve => { resolveLyrics = resolve; });
  const pending = page.previewCandidate(0);
  assert.equal(page.previewVisible, true);
  page.aboutToDisappear();
  assert.equal(page.previewVisible, true);
  resolveLyrics({ text: 'stale', translation: '', translationWarning: '', source: 'netease', songId: '1' });
  await pending;
  assert.equal(page.originalText, '');

  const index = new Index();
  index.page = 'cloudLyrics'; index.cloudPreviewVisible = true; index.audioWorkingPath = 'working';
  index.switchMainTab(1);
  assert.equal(index.onBackPress(), false);
  index.switchMainTab(0);
  index.openCloudLyrics('editor');
  assert.equal(index.cloudPreviewVisible, false);
});

test('parent back navigation respects preview and an active replacement dialog', () => {
  const index = new Index();
  index.page = 'cloudLyrics'; index.cloudReturnPage = 'lyrics'; index.cloudPreviewVisible = true;
  assert.equal(index.onBackPress(), true);
  assert.equal(index.page, 'cloudLyrics');
  assert.equal(index.cloudBackRequest, 1);
  index.audioUri = 'source'; index.audioWorkingPath = 'working'; index.lyricText = 'existing';
  let dialog;
  index.getUIContext = () => ({ showAlertDialog: options => { dialog = options; } });
  const selection = { targetKey: 'source|working', song, text: 'new translation', kind: 'translation' };
  index.confirmCloudLyrics(selection);
  assert.equal(index.onBackPress(), false);
  assert.equal(index.cloudBackRequest, 1);
  assert.equal(index.lyricText, 'existing');
  dialog.onDidDisappear();
  assert.equal(index.onBackPress(), true);
  assert.equal(index.cloudBackRequest, 2);
  index.cloudPreviewVisible = false;
  assert.equal(index.onBackPress(), true);
  assert.equal(index.page, 'lyrics');
});

test('replacement confirmation preserves filename and records translation provenance', () => {
  const index = new Index();
  index.page = 'cloudLyrics'; index.audioUri = 'source'; index.audioWorkingPath = 'working'; index.lyricText = 'existing';
  let dialog;
  index.getUIContext = () => ({ showAlertDialog: options => { dialog = options; } });
  index.confirmCloudLyrics({ targetKey: 'source|working', song, text: 'new translation', kind: 'translation' });
  dialog.primaryButton.action(); dialog.onDidDisappear();
  assert.equal(index.lyricText, 'existing');
  index.confirmCloudLyrics({ targetKey: 'source|working', song, text: 'new translation', kind: 'translation' });
  dialog.secondaryButton.action(); dialog.onDidDisappear();
  assert.equal(index.lyricText, 'new translation');
  assert.equal(index.lyricSourceName, '晴天.lrc');
  assert.match(index.lyricSummary, /^云端译文 ·/);
  assert.equal(index.page, 'lyrics');
});

test('bilingual selection retains replacement confirmation and provenance', () => {
  const index = new Index();
  index.page = 'cloudLyrics'; index.audioUri = 'source'; index.audioWorkingPath = 'working'; index.lyricText = 'existing';
  let dialog;
  index.getUIContext = () => ({ showAlertDialog: options => { dialog = options; } });
  const selection = { targetKey: 'source|working', song, text: '[00:01]original\n[00:01]translation', kind: 'bilingual' };
  index.confirmCloudLyrics(selection);
  dialog.primaryButton.action(); dialog.onDidDisappear();
  assert.equal(index.lyricText, 'existing');
  index.confirmCloudLyrics(selection);
  dialog.secondaryButton.action(); dialog.onDidDisappear();
  assert.equal(index.lyricText, selection.text);
  assert.match(index.lyricSummary, /^云端原文\+译文 ·/);
});

test('a dismissed old confirmation cannot overwrite new edits after returning to the same song', () => {
  const index = new Index();
  index.page = 'cloudLyrics'; index.audioUri = 'source'; index.audioWorkingPath = 'working'; index.lyricText = 'old';
  let dialog;
  index.getUIContext = () => ({ showAlertDialog: options => { dialog = options; } });
  index.confirmCloudLyrics({ targetKey: 'source|working', song, text: 'stale', kind: 'original' });
  const oldDialog = dialog;
  oldDialog.onDidDisappear();
  index.switchMainTab(0);
  index.lyricText = 'newly-edited';
  index.openCloudLyrics('lyrics');
  oldDialog.secondaryButton.action();
  assert.equal(index.lyricText, 'newly-edited');
  assert.equal(index.page, 'cloudLyrics');
});

test('pending confirmation checks the lyrics snapshot and current task state', () => {
  for (const mutate of [
    index => { index.lyricText = 'changed'; },
    index => { index.lyricUri = 'another-uri'; },
    index => { index.lyricSourceName = 'another.lrc'; },
    index => { index.lyricSummary = 'changed source'; },
    index => { index.audioWorkingPath = 'another-working'; },
    index => { index.busy = true; }
  ]) {
    const index = new Index();
    index.page = 'cloudLyrics'; index.audioUri = 'source'; index.audioWorkingPath = 'working'; index.lyricText = 'old';
    let dialog;
    index.getUIContext = () => ({ showAlertDialog: options => { dialog = options; } });
    index.confirmCloudLyrics({ targetKey: 'source|working', song, text: 'stale', kind: 'bilingual' });
    mutate(index);
    const expected = index.lyricText;
    dialog.secondaryButton.action();
    assert.equal(index.lyricText, expected);
    assert.equal(index.page, 'cloudLyrics');
    dialog.onDidDisappear();
    assert.equal(index.cloudDialogOpen, false);
  }
});

test('old dismissal or action cannot dismiss or replace a newer confirmation', () => {
  const index = new Index();
  index.page = 'cloudLyrics'; index.audioUri = 'source'; index.audioWorkingPath = 'working'; index.lyricText = 'old';
  let dialog;
  index.getUIContext = () => ({ showAlertDialog: options => { dialog = options; } });
  index.confirmCloudLyrics({ targetKey: 'source|working', song, text: 'stale', kind: 'original' });
  const oldDialog = dialog;
  oldDialog.primaryButton.action();
  index.confirmCloudLyrics({ targetKey: 'source|working', song, text: 'fresh', kind: 'translation' });
  const newDialog = dialog;
  oldDialog.onDidDisappear();
  oldDialog.secondaryButton.action();
  assert.equal(index.cloudDialogOpen, true);
  assert.equal(index.lyricText, 'old');
  newDialog.secondaryButton.action();
  newDialog.onDidDisappear();
  assert.equal(index.lyricText, 'fresh');
  assert.equal(index.cloudDialogOpen, false);
});

test('closing or hiding a ready preview immediately disables apply and queued actions', async () => {
  for (const hide of ['close', 'aboutToDisappear']) {
    const page = pageForSearch(); await page.search(); await page.previewCandidate(0);
    let applied = 0; let closed = 0; let requests = 0;
    page.onApply = () => applied++; page.onClose = () => closed++;
    page.service.searchDetailed = async () => { requests++; return { songs: [song], incomplete: false }; };
    page.service.lyrics = async () => { requests++; return page.service.lyricsResult; };
    assert.equal(page.canApply(), true);
    page[hide]();
    assert.equal(page.canApply(), false);
    page.applySelection(); await page.search(); await page.previewCandidate(0);
    assert.equal(applied, 0); assert.equal(requests, 0);
    page.close();
    assert.equal(closed, hide === 'close' ? 1 : 0);
  }
});

test('changing keyword or cancelling search ignores both late success and late failure', async () => {
  for (const action of ['changeKeyword', 'cancelOperation', 'close', 'aboutToDisappear', 'onAudioChanged']) {
    for (const fail of [false, true]) {
      const page = pageForSearch(); let settle;
      page.service.searchDetailed = () => new Promise((resolve, reject) => {
        settle = () => fail ? reject(new Error('stale failure')) : resolve({ songs: [song], incomplete: false });
      });
      const pending = page.search();
      if (action === 'changeKeyword') page.changeKeyword('different');
      else if (action === 'onAudioChanged') { page.audioKey = 'another|working'; page.onAudioChanged(); }
      else page[action]();
      const status = page.status;
      settle(); await pending;
      assert.equal(page.candidates.length, 0); assert.equal(page.status, status);
      assert.equal(page.canApply(), false);
    }
  }
});
