// Only mock orchestration; no actual CoreFileKit/MediaKit behavior is exercised.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('typescript');
const js=ts.transpileModule(fs.readFileSync(__dirname+'/../../entry/src/main/ets/services/AsfSystemAudioProbe.ets','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
const state={bytes:Buffer.alloc(200,7),version:1n,nextFd:1,files:new Map(),released:0,metadata:null,mutate:false,short:true,symlink:false,readFail:false,metadataFail:false,releaseFail:false};
const descKeys={MD_KEY_TRACK_TYPE:'track_type',MD_KEY_DURATION:'duration',MD_KEY_AUD_CHANNEL_COUNT:'channel_count',MD_KEY_AUD_SAMPLE_RATE:'sample_rate'};
function stat(isDir=false){const version=state.version;return {ino:isDir?3n:99n,size:state.bytes.length,mtimeNs:version,ctimeNs:version,isFile:()=>!isDir,isDirectory:()=>isDir,isSymbolicLink:()=>state.symlink};}
const fileIo={OpenMode:{READ_ONLY:0,NOFOLLOW:1},lstatSync(p){if(p==='/safe')return stat(true);if(p==='/safe/file.wma')return stat();throw Error('missing')},openSync(p,mode){assert.equal(p,'/safe/file.wma');assert.equal(mode,1);let fd=state.nextFd++;state.files.set(fd,{pos:0});return{fd}},statSync(fd){assert(state.files.has(fd));return stat()},closeSync(fd){assert(state.files.delete(fd))},readSync(fd,array,options){const f=state.files.get(fd);assert(f);if(state.readFail)throw Error('fake read failure');let n=Math.min(options.length,state.bytes.length-f.pos,state.short?37:options.length);new Uint8Array(array).set(state.bytes.subarray(f.pos,f.pos+n));f.pos+=n;return n}};
const media={MediaDescriptionKey:descKeys,MediaType:{MEDIA_TYPE_AUD:0},async createAVMetadataExtractor(){return{fdSrc:null,async fetchMetadata(){if(state.metadataFail)throw Error('fake metadata failure');if(state.mutate){state.bytes[3]^=1;state.version++}return state.metadata},async release(){state.released++;if(state.releaseFail)throw Error('fake release failure')}}}};
class AsfAudioInfo{constructor(durationMs,channels,sampleRate){Object.assign(this,{durationMs,channels,sampleRate})}}
const m={exports:{}};vm.runInThisContext('(function(exports,module,require){'+js+'\n})')(m.exports,m,(id)=>id==='@kit.CoreFileKit'?{fileIo}:id==='@kit.MediaKit'?{media}:id==='./AsfStreamingExport'?{AsfAudioInfo}:undefined);
const Probe=m.exports.AsfSystemAudioProbe;
const stream={path:()=>'/safe/file.wma',size:()=>state.bytes.length,snapshotToken:()=>String(state.version),readAt:(pos,n)=>Uint8Array.from(state.bytes.subarray(pos,pos+Math.min(n,19)))};
const valid={track_type:0,channel_count:2,sample_rate:44100};
const top={duration:'1000',sampleRate:'44100'};
(async()=>{
 state.metadata={...top,tracks:[valid]};let info=await new Probe().inspect(stream);assert.deepEqual([info.durationMs,info.channels,info.sampleRate],[1000,2,44100]);assert.equal(state.files.size,0);assert.equal(state.released,1);
 // The documented track description does not promise duration or sample_rate.
 state.metadata={duration:'1000',sampleRate:'44100',tracks:[{track_type:0,channel_count:2}]};info=await new Probe().inspect(stream);assert.deepEqual([info.durationMs,info.channels,info.sampleRate],[1000,2,44100]);
 state.metadata={duration:1000,tracks:[{track_type:0,channel_count:'2',sample_rate:'44100'}]};info=await new Probe().inspect(stream);assert.deepEqual([info.durationMs,info.channels,info.sampleRate],[1000,2,44100]);
 state.metadata={duration:'1000',sampleRate:'44100',tracks:[{...valid,duration:0}]};info=await new Probe().inspect(stream);assert.equal(info.durationMs,1000);
 for(const bad of [0,undefined,-1,1.5,NaN,Infinity,'',' 1000','1.5','1e3','0','10000000000000000']) {
  state.metadata={duration:bad,sampleRate:'44100',tracks:[valid]};await assert.rejects(()=>new Probe().inspect(stream),/duration/);assert.equal(state.files.size,0);
 }
 for(const bad of [0,undefined,-1,1.5,NaN,'',' 2','2.0','9']) {
  state.metadata={...top,tracks:[{...valid,channel_count:bad}]};await assert.rejects(()=>new Probe().inspect(stream),/channel_count/);assert.equal(state.files.size,0);
 }
 for(const bad of [0,-1,1.5,NaN,Infinity,'',' 44100','4e4','384001']) {
  state.metadata={duration:'1000',sampleRate:bad,tracks:[valid]};await assert.rejects(()=>new Probe().inspect(stream),/sampleRate/);
  state.metadata={...top,tracks:[{...valid,sample_rate:bad}]};await assert.rejects(()=>new Probe().inspect(stream),/track sample_rate/);
 }
 state.metadata={duration:'1000',tracks:[{track_type:0,channel_count:2}]};await assert.rejects(()=>new Probe().inspect(stream),/sample_rate/);
 state.metadata={duration:'1000',sampleRate:'48000',tracks:[valid]};await assert.rejects(()=>new Probe().inspect(stream),/sample rates disagree/);
 const tinyStream={...stream,readAt:(pos,n)=>Uint8Array.from(state.bytes.subarray(pos,pos+Math.min(n,1)))};await assert.rejects(()=>new Probe().inspect(tinyStream),/retry budget exceeded/);assert.equal(state.files.size,0);
 state.metadata={...top,tracks:[valid]};state.readFail=true;await assert.rejects(()=>new Probe().inspect(stream),/fake read failure/);state.readFail=false;assert.equal(state.files.size,0);
 state.metadataFail=true;await assert.rejects(()=>new Probe().inspect(stream),/fake metadata failure/);state.metadataFail=false;assert.equal(state.files.size,0);
 state.releaseFail=true;await assert.rejects(()=>new Probe().inspect(stream),/fake release failure/);state.releaseFail=false;assert.equal(state.files.size,0);
 for(const type of [NaN,1.5,999,-1,'0',undefined]) { state.metadata={...top,tracks:[valid,{track_type:type}]};await assert.rejects(()=>new Probe().inspect(stream),/track type unavailable or unsupported/); }
 state.metadata={...top,tracks:[valid,{track_type:1}]};info=await new Probe().inspect(stream);assert.equal(info.channels,2);
 state.metadata={...top,tracks:[valid,valid]};await assert.rejects(()=>new Probe().inspect(stream),/multiple audio/);assert.equal(state.files.size,0);
 state.metadata={...top,tracks:[valid]};state.mutate=true;await assert.rejects(()=>new Probe().inspect(stream),/identity changed/);state.mutate=false;assert.equal(state.files.size,0);
 const nulStream={...stream,path:()=>'/safe/file'+String.fromCharCode(0)+'.wma'};await assert.rejects(()=>new Probe().inspect(nulStream),/unsupported path/);assert.equal(state.files.size,0);
 state.symlink=true;await assert.rejects(()=>new Probe().inspect(stream),/symlink/);state.symlink=false;assert.equal(state.files.size,0);
 console.log('PASS mocked media probe: short reads, complete properties, missing/invalid fields, duplicates, mutation and symlink refusal');
})().catch(e=>{console.error(e);process.exitCode=1});





