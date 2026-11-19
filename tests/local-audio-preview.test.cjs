'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript');
const file=path.join(__dirname,'../entry/src/main/ets/services/LocalAudioPreview.ets');
const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
const tick=()=>new Promise(r=>setImmediate(r));

function harness(shortTimeout=false,manualTimers=false){
 const events=[],players=[];let nextFd=11,createImpl,closeFailure=false;
 const timers=new Map();let nextTimer=1;
 const schedule=manualTimers?(fn)=>{const id=nextTimer++;timers.set(id,fn);return id}:
  (shortTimeout?(fn,ms)=>setTimeout(fn,Math.min(ms,10)):setTimeout);
 const cancelTimer=manualTimers?id=>timers.delete(id):clearTimeout;
 const io={OpenMode:{READ_ONLY:0,NOFOLLOW:0x20000},openSync:(p,flags)=>{events.push(['open',p,flags]);return {fd:nextFd++}},statSync:()=>({isFile:()=>true,size:100,ino:1n}),lstatSync:()=>({isFile:()=>true,size:100,ino:1n}),closeSync:fd=>{events.push(['close',fd]);if(closeFailure){closeFailure=false;throw Error('close failed')}}};
 class FakePlayer{
  constructor(autoInit=true){this.state='idle';this.currentTime=0;this.duration=10000;this.listeners={};this.autoInit=autoInit;this.releases=0;players.push(this)}
  on(t,cb){this.listeners[t]=cb} off(t){delete this.listeners[t]}
  set fdSrc(v){this.source=v;events.push(['source',v.fd]);if(this.autoInit){this.state='initialized';this.listeners.stateChange?.('initialized',0)}}
  async prepare(){events.push(['prepare']);if(this.prepareFailure)throw Error('prepare error');this.state='prepared';this.listeners.stateChange?.('prepared',0)}
  async play(){this.state='playing';events.push(['play']);this.listeners.stateChange?.('playing',0)}
  async pause(){this.state='paused';events.push(['pause']);this.listeners.stateChange?.('paused',0)}
  seek(pos,mode){events.push(['seek',pos,mode]);if(!this.manualSeek){this.currentTime=pos;this.listeners.seekDone?.(pos)}}
  async release(){this.releases++;events.push(['release']);if(this.releaseFailure){this.releaseFailure=false;throw Error('release error')}this.state='released'}
 }
 const media={createAVPlayer:()=>createImpl?createImpl():Promise.resolve(new FakePlayer()),SeekMode:{SEEK_CLOSEST:3}};
 const m={exports:{}};vm.runInNewContext(js,{module:m,exports:m.exports,require:n=>n==='@kit.CoreFileKit'?{fileIo:io}:n==='@kit.MediaKit'?{media}:{},setTimeout:schedule,clearTimeout:cancelTimer,Number,String,Math,Promise,Error});
 return {Preview:m.exports.LocalAudioPreview,events,players,FakePlayer,io,setCreate:f=>{createImpl=f},failClose:()=>{closeFailure=true},
  fireTimer:()=>{assert.equal(timers.size,1,'expected one pending timer');const [id,fn]=timers.entries().next().value;timers.delete(id);fn()}};
}

test('independent read-only fd, state guards, seek and release order',async()=>{
 const h=harness(),p=new h.Preview(),states=[];p.setStateCallback(x=>states.push(x));
 await p.open('/private/lyricflow_work_1_aaa.mp3','/private');assert.equal(p.snapshot().state,'prepared');assert.deepEqual(h.events[0],['open','/private/lyricflow_work_1_aaa.mp3',0x20000]);
 await p.play();assert.equal(p.snapshot().state,'playing');await p.seek(2500);assert.equal(p.snapshot().positionMs,2500);await p.pause();assert.equal(p.snapshot().state,'paused');
 await assert.rejects(p.seek(10001));await assert.rejects(p.seek(-1));await assert.rejects(p.pause());
 await p.close();assert.equal(p.snapshot().state,'idle');assert.ok(states.includes('prepared'));assert.ok(h.events.findIndex(x=>x[0]==='release')<h.events.findIndex(x=>x[0]==='close'));
 await p.open('/private/lyricflow_work_2_bbb.flac','/private');await p.close();assert.notEqual(h.players[0].source.fd,h.players[1].source.fd);
});

test('invalid paths rejected before opening; prepare failure releases fd',async()=>{
 const h=harness(),p=new h.Preview();assert.throws(()=>p.open('/other/a.mp3','/private'));assert.throws(()=>p.open('/private/../other.mp3','/private'));assert.throws(()=>p.open('file://evil','/private'));assert.equal(h.events.length,0);
 h.setCreate(()=>{const x=new h.FakePlayer();x.prepareFailure=true;return Promise.resolve(x)});
 await assert.rejects(p.open('/private/lyricflow_work_3_ccc.mp3','/private'));assert.ok(h.events.some(x=>x[0]==='release'));assert.ok(h.events.some(x=>x[0]==='close'));assert.equal(p.snapshot().state,'idle');
});

test('only direct generated work files with matching regular-file identity are accepted',async()=>{
 const h=harness(),p=new h.Preview(),name='lyricflow_work_123_abc.mp3';
 assert.throws(()=>p.open('/private/sub/'+name,'/private'));
 assert.throws(()=>p.open('/private/other.mp3','/private'));
 assert.throws(()=>p.open('/private//'+name,'/private'));
 assert.throws(()=>p.open('/private/'+name,'/private/../private'));
 h.io.lstatSync=()=>({isFile:()=>false,size:100,ino:1n});
 await assert.rejects(p.open('/private/'+name,'/private'),/身份无效/);
 assert.equal(h.events.filter(x=>x[0]==='source').length,0);
 h.io.lstatSync=()=>({isFile:()=>true,size:100,ino:2n});
 await assert.rejects(p.open('/private/'+name,'/private'),/身份无效/);
 assert.equal(h.events.filter(x=>x[0]==='source').length,0);
 await p.close();
});

test('closing while initialization waits cancels and releases before closing fd',async()=>{
 const h=harness(),p=new h.Preview();h.setCreate(()=>Promise.resolve(new h.FakePlayer(false)));
 const pending=p.open('/private/lyricflow_work_4_ddd.mp3','/private');const rejected=assert.rejects(pending,/取消/);await tick();await p.close();await rejected;
 assert.ok(h.events.findIndex(x=>x[0]==='release')<h.events.findIndex(x=>x[0]==='close'));
});

test('prepare promise may resolve before prepared state event',async()=>{
 const h=harness(),p=new h.Preview();let notify;
 h.setCreate(()=>{const x=new h.FakePlayer();x.prepare=async()=>{notify=()=>{x.state='prepared';x.listeners.stateChange?.('prepared',0)}};return Promise.resolve(x)});
 let ready=false;const pending=p.open('/private/lyricflow_work_4_ddd.mp3','/private').then(()=>{ready=true});await tick();assert.equal(ready,false);
 notify();await pending;assert.equal(p.snapshot().state,'prepared');await p.close();
});

test('closing while prepare waits cancels the pending session',async()=>{
 const h=harness(),p=new h.Preview();h.setCreate(()=>{const x=new h.FakePlayer();x.prepare=()=>new Promise(()=>{});return Promise.resolve(x)});
 const pending=p.open('/private/lyricflow_work_4_ddd.mp3','/private');const rejected=assert.rejects(pending,/取消/);await tick();await p.close();await rejected;
 assert.equal(h.events.filter(x=>x[0]==='release').length,1);assert.equal(h.events.filter(x=>x[0]==='close').length,1);
});

test('late player creation after close is released and never opens a file',async()=>{
 const h=harness(),p=new h.Preview();let finish;h.setCreate(()=>new Promise(r=>{finish=r}));
 const pending=p.open('/private/lyricflow_work_4_ddd.mp3','/private');const rejected=assert.rejects(pending,/取消/);await tick();await p.close();await rejected;
 const late=new h.FakePlayer();finish(late);await tick();assert.equal(late.releases,1);assert.equal(h.events.filter(x=>x[0]==='open').length,0);
});

test('late player release failure is reported and can be retried on close',async()=>{
 const h=harness(),p=new h.Preview(),states=[];p.setStateCallback(x=>states.push(x));let finish;h.setCreate(()=>new Promise(r=>{finish=r}));
 const pending=p.open('/private/lyricflow_work_4_ddd.mp3','/private');const rejected=assert.rejects(pending,/取消/);await tick();await p.close();await rejected;
 const late=new h.FakePlayer();late.releaseFailure=true;finish(late);await tick();assert.equal(late.releases,1);assert.ok(states.includes('cleanupError'));
 await p.close();assert.equal(late.releases,2);assert.equal(h.events.filter(x=>x[0]==='open').length,0);
});

test('after UI unmount a late factory release failure reaches independent cleanup callback and retry releases it',async()=>{
 const h=harness(),p=new h.Preview();let finish,reported;
 p.setCleanupErrorCallback((message,retry)=>{reported={message,retry}});
 h.setCreate(()=>new Promise(r=>{finish=r}));
 const pending=p.open('/private/lyricflow_work_4_ddd.mp3','/private');const rejected=assert.rejects(pending,/取消/);
 await tick();p.setStateCallback(undefined);await p.close();await rejected;
 assert.equal(reported,undefined);
 const late=new h.FakePlayer();late.releaseFailure=true;finish(late);await tick();
 assert.match(reported.message,/未能释放/);assert.equal(late.releases,1);
 await reported.retry();assert.equal(late.releases,2);assert.equal(late.state,'released');
 await reported.retry();assert.equal(late.releases,2);
 assert.equal(h.events.filter(x=>x[0]==='open').length,0);
});

test('release failure retains the fd; retry releases before closing',async()=>{
 const h=harness(),p=new h.Preview();await p.open('/private/lyricflow_work_4_ddd.mp3','/private');h.players[0].releaseFailure=true;
 await assert.rejects(p.close());assert.equal(h.events.filter(x=>x[0]==='close').length,0);
 await p.close();assert.equal(h.events.filter(x=>x[0]==='release').length,2);assert.equal(h.events.filter(x=>x[0]==='close').length,1);
});


test('ambiguous close failure never retries a possibly reused fd and blocks reopening',async()=>{
 const h=harness(),p=new h.Preview();await p.open('/private/lyricflow_work_4_ddd.mp3','/private');h.failClose();
 await assert.rejects(p.close(),/状态不明/);await assert.rejects(p.close(),/状态不明/);
 await assert.rejects(p.open('/private/lyricflow_work_5_eee.mp3','/private'),/状态不明/);
 assert.deepEqual(h.events.filter(x=>x[0]==='close'),[['close',11]]);
});

test('duplicate old seekDone can settle next operation but exposes no time as an anchor',async()=>{
 const h=harness(),p=new h.Preview();await p.open('/private/lyricflow_work_4_ddd.mp3','/private');const player=h.players[0];player.manualSeek=true;
 const first=p.seek(2500),second=p.seek(5000);await tick();
 player.listeners.seekDone(2450);assert.equal(await first,undefined);await tick();
 assert.equal(h.events.filter(x=>x[0]==='seek').length,2);
 player.listeners.seekDone(2450);assert.equal(await second,undefined);
 assert.equal(p.snapshot().positionMs,0);await p.close();
});

test('close cancels pending seek and removes listener',async()=>{
 const h=harness(),p=new h.Preview();await p.open('/private/lyricflow_work_4_ddd.mp3','/private');const player=h.players[0];player.manualSeek=true;
 const seek=p.seek(2500);const rejected=assert.rejects(seek,/取消/);await tick();await p.close();await rejected;assert.equal(player.listeners.seekDone,undefined);
});

test('failed seek blocks another seek until session is reopened',async()=>{
 const h=harness(),p=new h.Preview();await p.open('/private/lyricflow_work_4_ddd.mp3','/private');const player=h.players[0];player.manualSeek=true;
 const seek=p.seek(2500);const rejected=assert.rejects(seek,/失败/);await tick();const late=player.listeners.seekDone;player.listeners.error({code:1});await rejected;
 await assert.rejects(p.seek(5000),/重新打开/);late(2500);assert.equal(h.events.filter(x=>x[0]==='seek').length,1);
 await p.open('/private/lyricflow_work_5_eee.mp3','/private');assert.equal(await p.seek(5000),undefined);await p.close();
});


test('timed-out seek refuses later seeks so a late event cannot complete one',async()=>{
 const h=harness(false,true),p=new h.Preview();await p.open('/private/lyricflow_work_4_ddd.mp3','/private');const player=h.players[0];player.manualSeek=true;
 const first=p.seek(2500);const rejection=assert.rejects(first,/超时/);await tick();const late=player.listeners.seekDone;
 assert.equal(typeof late,'function');h.fireTimer();await rejection;
 await assert.rejects(p.seek(5000),/重新打开/);late(2500);assert.equal(h.events.filter(x=>x[0]==='seek').length,1);await p.close();
});

test('a new instance waits for a closing player before it can create another',async()=>{
 const h=harness(),first=new h.Preview(),second=new h.Preview();
 await first.open('/private/lyricflow_work_1_aaa.mp3','/private');
 let finishRelease;h.players[0].release=()=>new Promise(resolve=>{finishRelease=resolve});
 const closing=first.close();const opening=second.open('/private/lyricflow_work_2_bbb.mp3','/private');
 await tick();assert.equal(h.players.length,1);finishRelease();await closing;await opening;
 assert.equal(h.players.length,2);await second.close();
});

test('another instance cannot interrupt a session that has not requested close',async()=>{
 const h=harness(),first=new h.Preview(),second=new h.Preview();
 await first.open('/private/lyricflow_work_1_aaa.mp3','/private');
 await assert.rejects(second.open('/private/lyricflow_work_2_bbb.mp3','/private'),/仍在使用/);
 assert.equal(h.players[0].releases,0);assert.equal(h.players.length,1);await first.close();
 await second.open('/private/lyricflow_work_2_bbb.mp3','/private');await second.close();
});

test('release timeout keeps the gate until the original release really finishes',async()=>{
 const h=harness(true),first=new h.Preview(),second=new h.Preview();
 await first.open('/private/lyricflow_work_1_aaa.mp3','/private');let finishRelease;
 h.players[0].release=()=>new Promise(resolve=>{finishRelease=resolve});
 await assert.rejects(first.close(),/超时/);
 await assert.rejects(second.open('/private/lyricflow_work_2_bbb.mp3','/private'),/超时/);
 assert.equal(h.players.length,1);finishRelease();
 await second.open('/private/lyricflow_work_2_bbb.mp3','/private');assert.equal(h.players.length,2);await second.close();
});

test('a failed release is safely retried by the next instance before opening',async()=>{
 const h=harness(),first=new h.Preview(),second=new h.Preview();
 await first.open('/private/lyricflow_work_1_aaa.mp3','/private');h.players[0].releaseFailure=true;
 await assert.rejects(first.close());await second.open('/private/lyricflow_work_2_bbb.mp3','/private');
 assert.equal(h.players[0].releases,2);assert.equal(h.players.length,2);await second.close();
});

test('a platform release error containing timeout is not mistaken for the local timer',async()=>{
 const h=harness(),first=new h.Preview(),second=new h.Preview();
 await first.open('/private/lyricflow_work_1_aaa.mp3','/private');const player=h.players[0];let calls=0;
 player.release=async()=>{calls++;if(calls===1)throw Error('媒体服务超时');player.state='released'};
 await assert.rejects(first.close(),/媒体服务超时/);
 await second.open('/private/lyricflow_work_2_bbb.mp3','/private');assert.equal(calls,2);await second.close();
});

test('failed release cannot leave the old player available for new playback or seek',async()=>{
 const h=harness(),p=new h.Preview();await p.open('/private/lyricflow_work_1_aaa.mp3','/private');
 h.players[0].releaseFailure=true;await assert.rejects(p.close());
 await assert.rejects(p.play(),/关闭/);await assert.rejects(p.seek(1000),/关闭/);
 assert.equal(h.events.filter(x=>x[0]==='play'||x[0]==='seek').length,0);await p.close();
});

test('an ambiguous fd close blocks all new instances without re-closing the descriptor',async()=>{
 const h=harness(),first=new h.Preview(),second=new h.Preview();
 await first.open('/private/lyricflow_work_1_aaa.mp3','/private');h.failClose();await assert.rejects(first.close(),/状态不明/);
 await assert.rejects(second.open('/private/lyricflow_work_2_bbb.mp3','/private'),/重启/);
 assert.equal(h.players.length,1);assert.deepEqual(h.events.filter(x=>x[0]==='close'),[['close',11]]);
});

test('cancelled factory owns the gate until its late player is released',async()=>{
 const h=harness(),first=new h.Preview(),second=new h.Preview();let finish;
 h.setCreate(()=>new Promise(resolve=>{finish=resolve}));
 const pending=first.open('/private/lyricflow_work_1_aaa.mp3','/private'),rejected=assert.rejects(pending,/取消/);
 await tick();await first.close();await rejected;
 await assert.rejects(second.open('/private/lyricflow_work_2_bbb.mp3','/private'),/释放中/);
 const late=new h.FakePlayer();finish(late);await tick();assert.equal(late.releases,1);
 h.setCreate(()=>Promise.resolve(new h.FakePlayer()));await second.open('/private/lyricflow_work_2_bbb.mp3','/private');await second.close();
});
