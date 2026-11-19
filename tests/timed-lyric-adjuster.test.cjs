'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript');
const file=path.join(__dirname,'../entry/src/main/ets/services/TimedLyricAdjuster.ets');
const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
const mod={exports:{}};vm.runInNewContext(js,{module:mod,exports:mod.exports,Set,Number,String,Math,RegExp,Error});
const T=mod.exports.TimedLyricAdjuster;

test('whole shift preserves BOM, metadata, ordering, newlines and changes inline markers too',()=>{
 const src='\uFEFF[ti:测试]\r\n[offset:+120]\r\n[custom:data]\n\n[00:01.50]A<00:01.65>好<00:01.999>呀\r[00:02]B';
 const expected='\uFEFF[ti:测试]\r\n[offset:+120]\r\n[custom:data]\n\n[00:01.75]A<00:01.90>好<00:02.249>呀\r[00:02.250]B';
 assert.equal(T.shiftAll(src,250),expected);assert.equal(T.shiftAll(src,0),src);
});
test('single row and inclusive range move all matching timestamp rows, including translations',()=>{
 const src='[00:01.00]first\n[00:02.00]original\n[00:03.00]other\n[00:02.00]translation\n[00:04.00]last';
 assert.equal(T.shiftRows(src,1,1,500),'[00:01.00]first\n[00:02.50]original\n[00:03.00]other\n[00:02.50]translation\n[00:04.00]last');
 assert.equal(T.shiftRows(src,1,2,-500),'[00:01.00]first\n[00:01.50]original\n[00:02.50]other\n[00:01.50]translation\n[00:04.00]last');
 assert.throws(()=>T.shiftRows(src,1,2,-1000),/重合/);
});
test('inline times and different fraction syntax retain their precision when possible',()=>{
 assert.equal(T.shiftAll('[01:02:3]x<01:02.45>y<01:02.456>z',100),'[01:02:4]x<01:02.55>y<01:02.556>z');
 assert.equal(T.shiftAll('[01:02:3]x',1),'[01:02:301]x');
});
test('two raw timeline anchors linearly correct drift and word timing',()=>{
 const s='[offset:-50]\n[00:01.000]a<00:01.500>word\n[00:02.000]b\n[00:03.000]c';
 assert.equal(T.correctDrift(s,{sourceRawMs:1000,targetRawMs:1200},{sourceRawMs:3000,targetRawMs:3400}),'[offset:-50]\n[00:01.200]a<00:01.750>word\n[00:02.300]b\n[00:03.400]c');
 assert.throws(()=>T.correctDriftFromPlayback(s,{sourceRawMs:1000,playbackMs:1200},{sourceRawMs:3000,playbackMs:3400}),/offset/);
 assert.equal(T.correctDriftFromPlayback('[offset:+0]\n[00:01]a\n[00:03]b',{sourceRawMs:1000,playbackMs:1200},{sourceRawMs:3000,playbackMs:3400}),'[offset:+0]\n[00:01.200]a\n[00:03.400]b');
 assert.throws(()=>T.correctDriftFromPlayback('[offset:0]\n[offset:0]\n[00:01]a',{sourceRawMs:1000,playbackMs:1200},{sourceRawMs:3000,playbackMs:3400}),/offset/);
});
test('physical rows include blank and metadata lines; unknown tags are retained',()=>{
 const s='[ti:x]\n\n[00:01.00]<custom>hello\n[xx:unknown]\r\n[00:02.00]world';
 const rows=T.inspect(s); assert.equal(rows.length,2);assert.equal(rows[0].rowIndex,2);assert.equal(rows[1].rowIndex,4);
 assert.equal(T.shiftRows(s,2,2,10),'[ti:x]\n\n[00:01.01]<custom>hello\n[xx:unknown]\r\n[00:02.00]world');
});
test('unsafe timing, ambiguous rows, unsupported formats and invalid arguments are rejected',()=>{
 for(const src of ['[00:01.00][00:02.00]same','[00:61.00]bad','[00:01.00]a<00:99.00>b','[00:01.00]a<00:01.00','[00:01]a< 00:01.5>b','[00:01]a<123,456>b','[123,456]karaoke','[00:01.00]a[00:02.00]b','plain lyric','[00:01.00]ok\n<00:01.20>dangling','[00:01]a\n00:03.00 --> 00:04.00']) assert.throws(()=>T.shiftAll(src,5),undefined,src);
 assert.throws(()=>T.shiftAll('[00:00.00]a',-1));
 assert.throws(()=>T.shiftAll('[999:59.999]a',1));
 assert.throws(()=>T.shiftAll('[00:01]a',Infinity));
 assert.throws(()=>T.shiftRows('[ti:x]\n[00:01]a',0,0,1));
 assert.throws(()=>T.shiftRows('[00:01]a',1,0,1));
 assert.throws(()=>T.correctDrift('[00:01]a',{sourceRawMs:1000,targetRawMs:1000},{sourceRawMs:1000,targetRawMs:2000}));
 assert.throws(()=>T.correctDrift('[00:01]a',{sourceRawMs:1000,targetRawMs:1000},{sourceRawMs:2000,targetRawMs:1000}));
 assert.throws(()=>T.shiftAll('[00:01]'+String.fromCharCode(0xd800),1));
});
test('calibration refuses negative extrapolation without producing a partial result',()=>{
 const original='[00:00.01]a\n[00:01.00]b';
 assert.throws(()=>T.correctDrift(original,{sourceRawMs:1000,targetRawMs:10},{sourceRawMs:2000,targetRawMs:2010}));
 assert.equal(original,'[00:00.01]a\n[00:01.00]b');
});
test('playback calibration rejects hidden, repeated or malformed offset tags',()=>{
 const a={sourceRawMs:1000,playbackMs:1000},b={sourceRawMs:2000,playbackMs:2000};
 for(const header of ['[ti:x][offset:500]','[ti:x][offset:0]','[offset:0][offset:0]','[offset :0]','text [offset:500]']) {
  assert.throws(()=>T.correctDriftFromPlayback(header+'\n[00:01]one\n[00:02]two',a,b),/offset/,header);
 }
});
test('rejects timestamps hidden after metadata or embedded and malformed in lyric text',()=>{
 for(const row of ['[ti:x][00:01]hidden','[00:01]one[00:02.1234]two','[00:01]one[00:02','[00:01]one[ 00:02]two','[ti:x][00:61]hidden']) {
  assert.throws(()=>T.shiftAll(row+'\n[00:03]other',100),/时间/,row);
 }
});
test('drift rejects distinct inline times compressed onto one millisecond',()=>{
 const src='[00:01.000]a<00:01.001>b<00:01.002>c\n[00:02.000]end';
 assert.throws(()=>T.correctDrift(src,{sourceRawMs:1000,targetRawMs:1000},{sourceRawMs:2000,targetRawMs:1001}),/重合/);
 assert.equal(T.shiftAll('[00:01.000]a<00:01.000>b',100),'[00:01.100]a<00:01.100>b');
});
