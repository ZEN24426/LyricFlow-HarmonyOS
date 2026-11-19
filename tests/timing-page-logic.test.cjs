'use strict';
// Exercises component methods with stubs; ArkUI rendering and platform behavior
// still require a real ArkTS build and device validation.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), ts = require('typescript');
const root = path.resolve(__dirname, '..');
const compile = s => ts.transpileModule(s, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const serviceModule = { exports: {} };
vm.runInNewContext(compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/services/TimedLyricAdjuster.ets'), 'utf8')),
  { module: serviceModule, exports: serviceModule.exports, Error });
class FakePlayer {
  setStateCallback(cb) { this.cb = cb; }
  setCleanupErrorCallback(cb) { this.cleanupCb = cb; }
  async open() {}
  async close() { this.closeCount = (this.closeCount || 0) + 1; if (this.closeError) throw Error('close failed'); }
  async seek() {}
  async play() {}
  async pause() {}
  snapshot() { return { positionMs: 1234 }; }
}
const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/LyricTimingPage.ets'), 'utf8');
const marker = 'struct LyricTimingPage {';
const start = src.indexOf(marker), end = src.indexOf('\n  build() {', start);
assert.ok(start >= 0 && end > start);
const body = src.slice(start + marker.length, end).replace(/@Watch\('[^']+'\)/g, '').replace(/@(Prop|State)\b/g, '');
const Page = vm.runInNewContext(compile('class Page {' + body + '\n}') + '\nPage', {
  LocalAudioPreview: FakePlayer, TimedLyricAdjuster: serviceModule.exports.TimedLyricAdjuster,
  MAX_VISIBLE_ROWS: 1000, Error, Number, String, Math,
  Scroller: class { scrollToIndex(index) { this.last = index; this.count = (this.count || 0) + 1; } },
  SliderChangeMode: { Begin: 0, Moving: 1, End: 2, Click: 3 }, ScrollAlign: { CENTER: 1 }, setInterval: () => 7, clearInterval: () => {}
});
function make(text = '[00:01]one\n[00:03]two') {
  const p = new Page();
  p.targetKey = 'audio-key'; p.originalText = text; p.workingPath = '/private/file.mp3'; p.filesDir = '/private';
  p.getUIContext = () => ({ showAlertDialog: d => { p.dialog = d; } });
  p.aboutToAppear();
  return p;
}
test('adjustment requires full preview and explicit apply and returns source identity', async () => {
  const p = make(); let applied; p.onApply = x => { applied = x; };
  p.shiftInput = '250'; p.makePreview('all');
  assert.equal(applied, undefined);
  assert.equal(p.previewText, '[00:01.250]one\n[00:03.250]two');
  await p.leave(true);
  assert.equal(applied.targetKey, 'audio-key'); assert.equal(applied.originalText, p.originalText);
  assert.equal(applied.adjustedText, p.previewText); assert.equal(p.player.closeCount, 1);
});
test('changed source invalidates pending preview and callbacks', async () => {
  const p = make(); let applied = false; p.onApply = () => { applied = true; };
  p.shiftInput = '100'; p.makePreview('all'); p.originalText = '[00:02]changed'; p.sourceChanged();
  await p.leave(true);
  assert.equal(applied, false); assert.equal(p.previewText, ''); assert.equal(p.sourceValid, false);
});
test('player position never implicitly becomes an anchor and dialog must be confirmed', async () => {
  const p = make(); p.ready = true; p.selectRow(p.rows[0]);
  await new Promise(resolve => setImmediate(resolve));
  p.recordAnchor(true); assert.equal(p.anchorOne, undefined);
  p.anchorInput = '1250'; p.recordAnchor(true); assert.equal(p.anchorOne, undefined);
  p.dialog.secondaryButton.action();
  assert.equal(p.anchorOne.sourceRawMs, 1000); assert.equal(p.anchorOne.playbackMs, 1250);
});
test('stale dialog and nonzero or hidden offset cannot create playback anchors', () => {
  const p = make(); p.selectRow(p.rows[0]); p.anchorInput = '1250'; p.recordAnchor(true);
  p.selectRow(p.rows[1]); p.dialog.secondaryButton.action(); assert.equal(p.anchorOne, undefined);
  const q = make('[ti:x][offset:500]\n[00:01]one'); q.selectRow(q.rows[0]); q.anchorInput = '1000'; q.recordAnchor(true);
  assert.equal(q.canUsePlayback, false); assert.equal(q.anchorOne, undefined);
});
test('range preserves same-time translation and manual anchors preview drift', () => {
  const p = make('[00:01]one\n[00:01]译文\n[00:03]two');
  p.selectedRow = 0; p.firstRow = 0; p.lastRow = 0; p.shiftInput = '100'; p.makePreview('range');
  assert.equal(p.previewText, '[00:01.100]one\n[00:01.100]译文\n[00:03]two');
  p.previewText = ''; p.selectRow(p.rows[0]); p.anchorInput = '1200'; p.recordAnchor(true); p.dialog.secondaryButton.action();
  p.selectRow(p.rows[2]); p.anchorInput = '3400'; p.recordAnchor(false); p.dialog.secondaryButton.action();
  p.makePreview('drift');
  assert.equal(p.previewText, '[00:01.200]one\n[00:01.200]译文\n[00:03.400]two');
});
test('close failure prevents apply and unexpected removal reports cleanup failure', async () => {
  const p = make(); let applied = false, cleanup = false;
  p.onApply = () => { applied = true; }; p.onCleanupError = () => { cleanup = true; };
  p.shiftInput = '100'; p.makePreview('all'); p.player.closeError = true; await p.leave(true);
  assert.equal(applied, false); assert.match(p.status, /关闭试听失败/);
  p.aboutToDisappear(); await new Promise(resolve => setImmediate(resolve)); assert.equal(cleanup, true);
});
test('late cleanup error still reaches parent after component disappears', async () => {
  const p = new Page(); let reported;
  p.targetKey = 'audio-key'; p.originalText = '[00:01]one'; p.workingPath = '/private/file.mp3'; p.filesDir = '/private';
  p.onCleanupError = (message, retry) => { reported = { message, retry }; };
  p.aboutToAppear(); p.aboutToDisappear(); await new Promise(resolve => setImmediate(resolve));
  let retried = false; const retry = async () => { retried = true; };
  p.player.cleanupCb('late release failed', retry);
  assert.equal(reported.message, 'late release failed'); assert.equal(retried, false);
  await reported.retry(); assert.equal(retried, true);
});
test('failed reopen clears stale ready state before accepting playback actions', async () => {
  const p = make(); p.ready = true; p.playing = true;
  p.player.open = async () => { throw Error('release failed'); };
  await p.openAudio(); assert.equal(p.ready, false); assert.equal(p.playing, false);
  assert.match(p.status, /release failed/);
});


test('playback highlights bilingual group without changing manual selection or anchor input', () => {
 const p=make('[00:01]one\n[00:01]translation\n[00:03]two');p.ready=true;p.selectedRow=2;p.anchorInput='4567';
 p.player.snapshot=()=>({positionMs:1500,durationMs:8000});p.refreshPlayback();
 assert.equal(p.playbackTime,1000);assert.equal(p.selectedRow,2);assert.equal(p.anchorInput,'4567');assert.equal(p.lyricScroller.last,0);
 p.player.snapshot=()=>({positionMs:3500,durationMs:8000});p.refreshPlayback();assert.equal(p.playbackTime,3000);assert.equal(p.lyricScroller.last,2);
});
test('manual editing suspends scrolling until explicit follow; paused seek refreshes highlight',async()=>{
 const p=make();p.ready=true;p.player.snapshot=()=>({positionMs:3500,durationMs:8000});p.editingInput=true;p.suspendFollowing();p.refreshPlayback();
 assert.equal(p.lyricScroller.count,undefined);assert.equal(p.playbackTime,3000);
 p.resumeFollowing();assert.equal(p.lyricScroller.count,undefined);p.editingInput=false;p.refreshPlayback(true);assert.equal(p.lyricScroller.last,1);
 p.player.snapshot=()=>({positionMs:1500,durationMs:8000});await p.seekTo(1500);assert.equal(p.playbackTime,1000);assert.equal(p.lyricScroller.last,0);
});
test('one play tap prepares and starts; repeated pending tap cannot double open',async()=>{
 const p=make();let finish,opens=0,plays=0;p.player.open=()=>{opens++;return new Promise(r=>finish=r);};p.player.play=async()=>{plays++;p.player.cb('playing');};
 const first=p.togglePlayback();await p.togglePlayback();assert.equal(opens,1);finish();await first;assert.equal(plays,1);assert.equal(p.playing,true);
 p.player.pause=async()=>p.player.cb('paused');await p.togglePlayback();assert.equal(p.playing,false);
});
test('unsafe or absent timeline never selects an arbitrary line; removal stops polling',()=>{
 const p=make('[offset:500]\n[00:01]one');p.ready=true;p.player.snapshot=()=>({positionMs:1500,durationMs:8000});p.startPlaybackTracking();
 assert.equal(p.playbackTime,-1);assert.equal(p.lyricScroller.count,undefined);assert.equal(p.playbackTimer,7);p.aboutToDisappear();assert.equal(p.playbackTimer,-1);
 p.rows=[];p.visible=true;p.sourceValid=true;p.ready=true;p.canUsePlayback=true;p.refreshPlayback();assert.equal(p.playbackTime,-1);
});

test('plain lyrics can still play without a fabricated highlight or selection',async()=>{const p=make('plain lyric text');assert.equal(p.sourceValid,true);assert.equal(p.canUsePlayback,false);p.player.play=async()=>p.player.cb('playing');await p.togglePlayback();assert.equal(p.playing,true);assert.equal(p.playbackTime,-1);assert.equal(p.selectedRow,-1);});

test('confirmed backward and forward seeks update bilingual guidance without moving the edit selection', async () => {
  const p = make('[00:01]one\n[00:01]translation one\n[00:03]two\n[00:03]translation two');
  p.ready = true;
  let confirmedPosition = 3500, confirm;
  p.player.snapshot = () => ({ positionMs: confirmedPosition, durationMs: 8000 });
  p.player.seek = () => new Promise(resolve => { confirm = resolve; });
  p.refreshPlayback();
  assert.equal(p.playbackTime, 3000);
  const back = p.seekTo(1500);
  p.refreshPlayback();
  assert.equal(p.playbackTime, 3000);
  confirmedPosition = 1500;
  confirm();
  await back;
  assert.equal(p.playbackTime, 1000);
  assert.equal(p.lyricScroller.last, 0);
  p.selectedRow = 1;
  p.anchorInput = '1120';
  p.editingInput = true;
  p.suspendFollowing();
  const count = p.lyricScroller.count;
  const forward = p.seekTo(3500);
  p.refreshPlayback();
  assert.equal(p.playbackTime, 1000);
  confirmedPosition = 3500;
  confirm();
  await forward;
  assert.equal(p.playbackTime, 3000);
  assert.equal(p.rows.filter(row => row.startMs === p.playbackTime).length, 2);
  assert.equal(p.lyricScroller.count, count);
  assert.equal(p.editingInput, true);
  assert.equal(p.selectedRow, 1);
  assert.equal(p.anchorInput, '1120');
  p.editingInput = false;
  p.resumeFollowing();
  assert.equal(p.lyricScroller.last, 2);
});

test('slider previews without seek, commits once, clamps and preserves editing',async()=>{
 const p=make();p.ready=true;p.playbackDuration=8000;p.selectedRow=1;p.anchorInput='314';p.editingInput=true;
 let requests=[],resolve;p.player.seek=v=>{requests.push(v);return new Promise(r=>resolve=r);};
 p.player.snapshot=()=>({positionMs:1250,durationMs:8000});
 p.sliderChanged(2400,0);p.sliderChanged(3500,1);p.refreshPlayback();
 assert.equal(p.scrubPosition,3500);assert.equal(p.scrubbing,true);assert.equal(requests.length,0);
 p.sliderChanged(9000,2);p.sliderChanged(9000,3);assert.deepEqual(requests,[8000]);
 assert.equal(p.followPlayback,false);assert.equal(p.selectedRow,1);assert.equal(p.anchorInput,'314');
 resolve();await new Promise(r=>setImmediate(r));assert.equal(p.scrubbing,false);assert.equal(p.playbackPosition,1250);
 assert.equal(p.editingInput,true);assert.equal(p.lyricScroller.count,undefined);
});
test('slider cancellation, failures and invalid source leave no stuck thumb or busy gate',async()=>{
 const p=make();p.ready=true;p.playbackDuration=8000;p.player.snapshot=()=>({positionMs:1200,durationMs:8000});
 let seeks=0;p.player.seek=async()=>{seeks++;throw Error('seek failure');};
 p.sliderChanged(5000,1);p.cancelScrub();assert.equal(p.scrubbing,false);assert.equal(seeks,0);
 p.sliderChanged(NaN,3);assert.equal(seeks,0);p.sliderChanged(5000,3);
 await new Promise(r=>setImmediate(r));assert.equal(p.busy,false);assert.equal(p.scrubbing,false);assert.match(p.status,/seek failure/);
 p.sliderChanged(1000,1);p.sourceChanged();assert.equal(p.scrubbing,false);p.sliderChanged(1000,2);assert.equal(seeks,1);
});
test('slider has stable id, accessible label and commits only through model callback',()=>{
 assert.match(src,/Slider\(\{/);assert.match(src,/id\('timing-progress'\)/);assert.match(src,/accessibilityText/);
 assert.match(src,/TouchType.Cancel/);
});
