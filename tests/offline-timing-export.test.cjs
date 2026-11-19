'use strict';
// Desktop integration: actual component/service methods and UTF-8 files with
// a stub for HarmonyOS's download picker, file I/O and AVPlayer. It does not
// claim device behavior. Optional ffprobe independently checks LRC timestamps.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const ts = require('typescript');
const root = path.resolve(__dirname, '..');
const compile = source => ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
function moduleAt(relative) {
  const module = { exports: {} };
  vm.runInNewContext(compile(fs.readFileSync(path.join(root, relative), 'utf8')),
    { module, exports: module.exports, Error, Number, String, Math, RegExp, Set });
  return module.exports;
}
const { TimedLyricAdjuster } = moduleAt('entry/src/main/ets/services/TimedLyricAdjuster.ets');
const { LyricEngine } = moduleAt('entry/src/main/ets/services/LyricEngine.ets');
const { hasInlineLrcTiming, plainLrcFromEnhanced } = moduleAt('entry/src/main/ets/services/LrcPreservingExport.ets');
class FakePlayer {
  setStateCallback() {}
  setCleanupErrorCallback() {}
  async close() {}
}
function componentAt(relative, marker, bindings) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  const start = source.indexOf(marker), end = source.indexOf('\n  build() {', start);
  assert.ok(start >= 0 && end > start, 'component methods must be available');
  const body = source.slice(start + marker.length, end)
    .replace(/@Watch\('[^']+'\)/g, '').replace(/@(Prop|State|Link)\b/g, '');
  return vm.runInNewContext(compile('class Component {' + body + '\n}') + '\nComponent', bindings);
}
const TimingPage = componentAt('entry/src/main/ets/components/LyricTimingPage.ets', 'struct LyricTimingPage {',
  { LocalAudioPreview: FakePlayer, TimedLyricAdjuster, MAX_VISIBLE_ROWS: 1000, Error, Number, String,
    Scroller: class { scrollToIndex() {} }, ScrollAlign: { CENTER: 1 } });
const original = '[ti:Fixture]\r\n[00:01.000]<00:01.000>你<00:01.500>好\r\n' +
  '[00:01.000]Translation\r\n[00:02.000]Middle\r\n[00:03.000]End\r\n';
const adjusted = '[ti:Fixture]\r\n[00:01.200]<00:01.200>你<00:01.750>好\r\n' +
  '[00:01.200]Translation\r\n[00:02.300]Middle\r\n[00:03.400]End\r\n';
const ordinary = '[ti:Fixture]\r\n[00:01.200]你好\r\n' +
  '[00:01.200]Translation\r\n[00:02.300]Middle\r\n[00:03.400]End\r\n';

test('two confirmed calibration points flow through preview and both UTF-8 exports', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lyricflow-offline-lrc-'));
  const outputs = [];
  try {
    const Index = componentAt('entry/src/main/ets/pages/Index.ets', 'struct Index {', {
      Error, parseLyricAsync: async (text, name) => LyricEngine.parse(text, name),
      convertToLrcAsync: async doc => LyricEngine.toLrc(doc), hasInlineLrcTiming, plainLrcFromEnhanced,
      ExportService: { saveTextToDownload: async (_ctx, name, text) => {
        const output = path.join(dir, outputs.length === 0 ? 'preserved.lrc' : 'ordinary.lrc');
        fs.writeFileSync(output, text, 'utf8'); outputs.push(output);
        return { name, uri: output };
      } }
    });
    const index = new Index(); let dialog;
    index.page = 'lyrics'; index.audioUri = 'synthetic'; index.audioWorkingPath = 'private';
    index.songTitle = 'fixture'; index.lyricText = original; index.lyricSourceName = '';
    index.ctx = () => ({}); index.notify = () => {}; index.showExportSuccess = () => {};
    index.getUIContext = () => ({ showAlertDialog: d => { dialog = d; } });

    const page = new TimingPage();
    page.targetKey = 'fixture'; page.originalText = original; page.workingPath = '/private/work.mp3';
    page.filesDir = '/private'; page.getUIContext = () => ({ showAlertDialog: d => { page.dialog = d; } });
    page.onApply = result => { assert.equal(result.originalText, original); index.lyricText = result.adjustedText; };
    page.aboutToAppear();
    page.selectRow(page.rows[0]); page.anchorInput = '1200'; page.recordAnchor(true);
    assert.equal(page.anchorOne, undefined, 'first point is not accepted without confirmation');
    page.dialog.secondaryButton.action();
    page.selectRow(page.rows[3]); page.anchorInput = '3400'; page.recordAnchor(false);
    assert.equal(page.anchorTwo, undefined, 'second point is not accepted without confirmation');
    page.dialog.secondaryButton.action();
    page.makePreview('drift');
    assert.equal(index.lyricText, original, 'preview must not mutate the editor');
    assert.equal(page.previewText, adjusted);
    await page.leave(true);
    assert.equal(index.lyricText, adjusted);

    await index.requestLyricsExport();
    dialog.primaryButton.action();
    await new Promise(resolve => setImmediate(resolve));
    await index.requestLyricsExport();
    dialog.secondaryButton.action();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(outputs.length, 2);
    assert.equal(fs.readFileSync(outputs[0], 'utf8'), adjusted);
    assert.equal(fs.readFileSync(outputs[1], 'utf8'), ordinary);
    assert.equal(index.lyricText, adjusted, 'export must not mutate editor text');
    for (let i = 0; i < outputs.length; i++) {
      const file = outputs[i];
      const parsed = LyricEngine.parse(fs.readFileSync(file, 'utf8'), path.basename(file));
      assert.equal(parsed.format, i === 0 ? 'enhanced-lrc' : 'lrc');
      assert.deepEqual(Array.from(parsed.lines, line => line.startMs), [1200, 1200, 2300, 3400]);
    }
    // ffprobe's independent LRC demuxer validates line timestamps/order in both
    // files, not the semantics of enhanced-LRC word timing or player display.
    await t.test('FFprobe independently verifies LRC line timing', { skip: !process.env.LYRICFLOW_FFPROBE }, () => {
      for (const file of outputs) {
        const probe = JSON.parse(execFileSync(process.env.LYRICFLOW_FFPROBE,
          ['-v', 'error', '-show_packets', '-show_entries', 'packet=pts_time', '-of', 'json', file],
          { encoding: 'utf8' }));
        assert.deepEqual(probe.packets.map(packet => Number(packet.pts_time)), [1.2, 1.2, 2.3, 3.4]);
      }
    });
  } finally {
    for (const file of outputs) fs.unlinkSync(file);
    fs.rmdirSync(dir);
  }
});
