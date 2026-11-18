// CoreFileKit API is simulated here: no real HarmonyOS filesystem calls.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('typescript');
function mockFs(fault='',ioLimit=2){
 const nodes=new Map(),fds=new Map();let next=1,fd=10,used=false;
 const node=(type,data=[])=>({type,ino:BigInt(next++),data:Buffer.from(data),mtime:1,ctime:1});
 nodes.set('/private',node('dir'));nodes.set('/audio',node('file',[1,2,3,4,5]));
 const fail=(name)=>{if(fault===name&&!used){used=true;throw Error('injected '+name)}};
 function stat(p){const n=typeof p==='number'?fds.get(p)?.node:nodes.get(p);if(!n)throw Error('ENOENT');return {ino:n.ino,size:n.data.length,mtime:n.mtime,ctime:n.ctime,mtimeNs:BigInt(n.mtime),ctimeNs:BigInt(n.ctime),isFile:()=>n.type==='file',isDirectory:()=>n.type==='dir'};}
 const api={OpenMode:{READ_ONLY:1,CREATE:2,READ_WRITE:4,NOFOLLOW:8,DIR:16},WhenceType:{SEEK_SET:0},
  lstatSync(p){if(p.includes('asf-stage-'))fail('lstat-stage');return stat(p)},statSync:stat,
  mkdtempSync(p){if(!p.endsWith('XXXXXX'))throw Error('Invalid argument');if(fault==='mkdtemp-fail')throw {code:13900020};if(fault==='bad-return')return p.slice(0,-6)+'ab/xyz';const d=p.slice(0,-6)+'abc123';nodes.set(d,node('dir'));return d},
  listFileSync(p){if(p.includes('asf-stage-'))fail('list-stage');const prefix=p+'/';return [...nodes.keys()].filter(x=>x.startsWith(prefix)&&!x.slice(prefix.length).includes('/')).map(x=>x.slice(prefix.length))},
  rmdirSync(p){fail('rmdir');nodes.delete(p)},
  openSync(p,mode){if(p.endsWith('/candidate.wma'))fail('open-stage');let n=nodes.get(p);if(!n&&mode&2){n=node('file');nodes.set(p,n)}if(!n)throw Error('ENOENT');let id=fd++;fds.set(id,{node:n,pos:0});return {fd:id}},
  closeSync(id){fail('close');if(!fds.delete(id))throw Error('bad fd')},
  lseek(id,offset){const f=fds.get(id);if(!f)throw Error('bad fd');f.pos=offset;return offset},
  readSync(id,buf){const f=fds.get(id);let count=Math.min(buf.byteLength,ioLimit,f.node.data.length-f.pos);count=Math.max(0,count);new Uint8Array(buf).set(f.node.data.subarray(f.pos,f.pos+count));f.pos+=count;return count},
  writeSync(id,buf){const f=fds.get(id),n=Math.min(buf.byteLength,ioLimit),end=f.pos+n;if(end>f.node.data.length){const b=Buffer.alloc(end);f.node.data.copy(b);f.node.data=b}Buffer.from(buf).copy(f.node.data,f.pos,0,n);f.pos=end;return n},
  fsyncSync(){fail('sync')},unlinkSync(p){fail('unlink');if(!nodes.delete(p))throw Error('ENOENT')}
 };return {api,nodes};
}
function load(fake){const s=fs.readFileSync(__dirname+'/../../entry/src/main/ets/services/AsfPrivateIO.ets','utf8');const js=ts.transpileModule(s,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;const m={exports:{}};vm.runInThisContext('(function(exports,module,require){'+js+'\n})')(m.exports,m,(name)=>{if(name==='@kit.CoreFileKit')return {fileIo:fake.api};throw Error('unexpected require '+name)});return m.exports;}
{
 let f=mockFs(),{AsfPrivateSource,AsfPrivateStageFactory}=load(f);assert.throws(()=>new AsfPrivateSource('/a\0b'),/local source/);assert.throws(()=>new AsfPrivateStageFactory('/private\0bad'),/filesDir/);
 let src=new AsfPrivateSource('/audio');let token=src.snapshotToken();assert.equal(src.path(),'/audio');assert.deepEqual([...src.readAt(1,4)],[2,3]);assert.equal(src.snapshotToken(),token);f.nodes.get('/audio').mtime=2;assert.notEqual(src.snapshotToken(),token);src.close();src.close();
 let factory=new AsfPrivateStageFactory('/private');assert.equal(factory.recoveryPrivateDir(),'');let stage=factory.createExclusivePrivateStage();assert.equal(factory.recoveryPrivateDir(),'/private/asf-stage-abc123');assert.equal(stage.recoveryPath(),factory.recoveryPrivateDir());assert(stage.stream.path().endsWith('/candidate.wma'));assert.equal(stage.stream.writeAt(0,new Uint8Array([9,8,7])),2);assert.deepEqual([...stage.stream.readAt(0,3)],[9,8]);stage.stream.flush();stage.close();stage.close();stage.finishPrivateStage();assert.equal(factory.readyPrivatePath(),stage.stream.path());
}
{
 let f=mockFs(),{AsfPrivateStageFactory}=load(f),factory=new AsfPrivateStageFactory('/private'),stage=factory.createExclusivePrivateStage(),dir=stage.stream.path().slice(0,-'/candidate.wma'.length);stage.close();stage.discardPrivateStage();assert(!f.nodes.has(dir));assert.equal(factory.recoveryPrivateDir(),'');
}
{
 let f=mockFs(),{AsfPrivateStageFactory}=load(f),factory=new AsfPrivateStageFactory('/private'),stage=factory.createExclusivePrivateStage(),p=stage.stream.path();stage.close();f.nodes.get(p).ino=999n;assert.throws(()=>stage.discardPrivateStage(),/identity changed/);assert(f.nodes.has(p));
}
{
 let f=mockFs();assert.throws(()=>f.api.mkdtempSync('/private/asf-stage-'),/Invalid argument/);
 let rejected=mockFs('mkdtemp-fail'),{AsfPrivateStageFactory}=load(rejected),factory=new AsfPrivateStageFactory('/private');assert.throws(()=>factory.createExclusivePrivateStage(),/ASF_STAGE_CREATE_MKDTEMP failed code=13900020/);
 let invalid=mockFs('bad-return'),api=load(invalid),other=new api.AsfPrivateStageFactory('/private');assert.throws(()=>other.createExclusivePrivateStage(),/unexpected temporary directory/);
}
for(const fault of ['lstat-stage','list-stage','open-stage']){
 let f=mockFs(fault),{AsfPrivateStageFactory}=load(f),factory=new AsfPrivateStageFactory('/private');
 assert.throws(()=>factory.createExclusivePrivateStage(),e=>e.message.includes('/private/asf-stage-abc123'));
 if(fault==='lstat-stage') { assert(f.nodes.has('/private/asf-stage-abc123')); assert.equal(factory.recoveryPrivateDir(),'/private/asf-stage-abc123'); } // ownership never established
 else { assert(!f.nodes.has('/private/asf-stage-abc123')); assert.equal(factory.recoveryPrivateDir(),''); } // transient failure, safe empty cleanup
}
{
 let f=mockFs('rmdir'),{AsfPrivateStageFactory}=load(f),factory=new AsfPrivateStageFactory('/private'),stage=factory.createExclusivePrivateStage();stage.close();assert.throws(()=>stage.discardPrivateStage(),/injected rmdir/);assert(f.nodes.has('/private/asf-stage-abc123'));
}
{
 let f=mockFs(),oldOpen=f.api.openSync;f.api.openSync=(p,m)=>{if(p.endsWith('/candidate.wma'))throw Error('open failure');return oldOpen(p,m)};f.api.rmdirSync=()=>{throw Error('cleanup failure')};
 let {AsfPrivateStageFactory}=load(f),factory=new AsfPrivateStageFactory('/private');assert.throws(()=>factory.createExclusivePrivateStage(),/cleanup failed/);assert.equal(factory.recoveryPrivateDir(),'/private/asf-stage-abc123');
}
for(const scenario of ['renamed','cancel','changed-file','unknown-child','changed-dir']) {
 let f=mockFs(),{AsfPrivateStageFactory}=load(f),factory=new AsfPrivateStageFactory('/private'),stage=factory.createExclusivePrivateStage(),p=stage.stream.path(),dir=p.slice(0,-'/candidate.wma'.length);
 stage.close();stage.finishPrivateStage();
 if(scenario==='renamed')f.nodes.delete(p);
 if(scenario==='changed-file')f.nodes.get(p).ino=999n;
 if(scenario==='unknown-child')f.nodes.set(dir+'/unowned', {type:'file',ino:888n,data:Buffer.from('do not delete'),mtime:1,ctime:1});
 if(scenario==='changed-dir')f.nodes.get(dir).ino=777n;
 if(['changed-file','unknown-child','changed-dir'].includes(scenario)) { assert.throws(()=>factory.cleanupReadyPrivateStage(),/identity changed|unowned entries/);assert(f.nodes.has(dir));if(scenario==='unknown-child')assert(f.nodes.has(dir+'/unowned')); }
 else { factory.cleanupReadyPrivateStage();assert(!f.nodes.has(dir));assert(!f.nodes.has(p)); }
}
console.log('PASS simulated CoreFileKit: NUL rejection, identity and change checks, short IO, private stage close/finish/discard, owned cleanup and reported retained paths');





// Combined engine + CoreFileKit + outer export simulation tests recovery state.
function loadModule(name,deps){const code=fs.readFileSync(require('node:path').join(__dirname,'../../entry/src/main/ets/services',name+'.ets'),'utf8');const js=ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;const m={exports:{}};vm.runInThisContext('(function(exports,module,require){'+js+'\n})')(m.exports,m,id=>deps[id]||{});return m.exports}
async function combined(f){
 f.nodes.get('/audio').data=fs.readFileSync(require('node:path').join(process.env.ASF_FIXTURE_DIR,'wmav2-picture-padding.wma'));
 const H=loadModule('AsfHeaderEditor',{}),io=load(f),S=loadModule('AsfStreamingExport',{'./AsfHeaderEditor':H});
 const M=loadModule('AsfWriterMapping',{}),probe={AsfSystemAudioProbe:class {async inspect(){return new S.AsfAudioInfo(1000,1,44100)}}};
 const P=loadModule('AsfPrivateExport',{'./AsfWriterMapping':M,'./AsfStreamingExport':S,'./AsfPrivateIO':io,'./AsfSystemAudioProbe':probe,'./BoundedCoverVerification':{BoundedCoverVerification:{}},'./AsfPixelMapEncoder':{AsfPixelMapEncoder:{}}});
 return P.AsfPrivateExport.exportWorking('/audio','/private',[new S.AsfTextEdit('Title','new')],null);
}
(async()=>{
 let f=mockFs('',8192);f.api.writeSync=()=>{throw Error('PRIVATE_INJECTED')};await assert.rejects(()=>combined(f),e=>String(e).includes('ASF_STAGE_write_header')&&!String(e).includes('PRIVATE_INJECTED')&&!String(e).includes('recovery directory'));assert(!f.nodes.has('/private/asf-stage-abc123'));
 f=mockFs('',8192);f.api.writeSync=()=>{throw Error('PRIVATE_INJECTED')};f.api.rmdirSync=()=>{throw Error('PRIVATE_CLEANUP')};await assert.rejects(()=>combined(f),e=>String(e).includes('recovery directory: /private/asf-stage-abc123')&&!String(e).includes('PRIVATE_INJECTED')&&!String(e).includes('PRIVATE_CLEANUP'));assert(f.nodes.has('/private/asf-stage-abc123'));
 f=mockFs('lstat-stage',8192);await assert.rejects(()=>combined(f),e=>String(e).includes('recovery directory: /private/asf-stage-abc123')&&!String(e).includes('injected lstat'));assert(f.nodes.has('/private/asf-stage-abc123'));
 console.log('PASS combined private staging: successful cleanup, retained cleanup failure, pre-stage failure recovery and sanitized context');
})().catch(e=>{console.error(e);process.exitCode=1});



