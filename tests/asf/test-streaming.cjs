const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('typescript');
function load(name,deps={}){const src=fs.readFileSync(path.join(__dirname,'../../entry/src/main/ets/services',name+'.ets'),'utf8');const js=ts.transpileModule(src,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;const m={exports:{}};vm.runInThisContext('(function(exports,module,require){'+js+'\n})')(m.exports,m,id=>{if(deps[id])return deps[id];throw Error('unknown dependency '+id)});return m.exports}
const h=load('AsfHeaderEditor'), core=load('AsfStreamingExport',{'./AsfHeaderEditor':h});const H=h.AsfHeaderEditor,E=core.AsfStreamingExport;
const input=fs.readFileSync(path.join(process.env.ASF_FIXTURE_DIR,'wmav2-picture-padding.wma'));let hs=Number(input.readBigUInt64LE(16));let header=input.subarray(0,hs),data=input.subarray(hs,hs+50);const scan=H.scan(header,input.length,data);assert.equal(scan.headerSize,hs);
let target=H.replaceText(header,'Title','Stream title 曲',input.length,data);let updated=H.scan(target,input.length,data);assert(updated.entries.filter(e=>e.name.toLowerCase()==='title').every(e=>H.textValue(e)==='Stream title 曲'));
class Source {constructor(bytes){this.bytes=Buffer.from(bytes);this.token='v1';this.reads=0;this.max=0;this.failAt=0;this.maxReturn=137;}size(){return this.bytes.length}snapshotToken(){return this.token}readAt(offset,n){this.reads++;this.max=Math.max(this.max,n);if(this.failAt===this.reads)throw Error('read fault');return new Uint8Array(this.bytes.subarray(offset,offset+Math.min(n,this.maxReturn)))}}
class StageStream extends Source{constructor(config){super(Buffer.alloc(0));this.c=config;this.writes=0;this.maxReturn=config.shortRead||137}writeAt(offset,data){this.writes++;if(this.c.codeWrite===this.writes)throw {code:13900020,message:'PRIVATE_TEST_CONTENT'};if(this.c.zeroWrite===this.writes)return 0;if(this.c.failWrite===this.writes)throw Error('write fault');let n=Math.min(data.length,this.c.shortWrite||257);if(offset+n>this.bytes.length){let out=Buffer.alloc(offset+n);this.bytes.copy(out);this.bytes=out}Buffer.from(data.subarray(0,n)).copy(this.bytes,offset);return n}flush(){if(this.c.flush)throw Error('flush fault')}readAt(offset,n){if(this.c.readFault)throw Error('staged read fault');let b=super.readAt(offset,n);if(this.c.corrupt&&offset>=hs&&b.length){b[0]^=1}return b}}
class Factory{constructor(c={}){this.c=c;this.stage=null;this.discarded=false;this.closed=false;this.finished=false}createExclusivePrivateStage(){if(this.c.create)throw Error('create unavailable');let parent=this;this.stage=new StageStream(this.c);return {stream:this.stage,recoveryPath(){return '/mock-stage'},finishPrivateStage(){if(parent.c.finish)throw Error('finish fault');parent.finished=true},discardPrivateStage(){parent.discarded=true;if(parent.c.cleanup)throw Error('cleanup fault')},close(){parent.closed=true;if(parent.c.close)throw Error('close fault')}}}}
const probe={async inspect(s){if(s.badProbe)throw Error('probe fault');return new core.AsfAudioInfo(1000,1,44100)}};const verifier={async validateCover(bytes){return new Uint8Array(bytes)},async assertCoverRoundTrip(a,b){assert.deepEqual(Buffer.from(a),Buffer.from(b))}};
async function run(c={},source=new Source(input),p=probe,v=verifier){let f=new Factory(c);let err;try{await E.exportCopy(source,f,p,v,[new core.AsfTextEdit('Title','Stream title 曲')],null)}catch(e){err=e}return {source,f,err}}
(async()=>{
 let {source,f,err}=await run();assert.ifError(err);assert(f.finished&&f.closed&&!f.discarded);assert.deepEqual(f.stage.bytes.subarray(hs),input.subarray(hs));assert.equal(H.textValue(H.scan(f.stage.bytes.subarray(0,hs),input.length,f.stage.bytes.subarray(hs,hs+50)).entries.find(e=>e.name==='Title')),'Stream title 曲');assert(source.max<=Math.max(H.MAX_HEADER,E.CHUNK));
 for(const config of [{zeroWrite:1},{failWrite:3},{flush:true},{readFault:true},{corrupt:true},{finish:true}]){let r=await run(config);assert(r.err,JSON.stringify(config));assert(r.f.discarded&&r.f.closed&&!r.f.finished,JSON.stringify(config));assert.deepEqual(r.source.bytes,input)}
 // Two unknown library records have the same name/value/type but distinct stream ids.
 let local=H.scan(input.subarray(0,hs),input.length,input.subarray(hs,hs+50)),extension=local.objects.find(o=>o.id===H.EXTENSION),pad=local.padding;
 const key=Buffer.from('WM/Scoped\0','utf16le'),value=Buffer.from('same\0','utf16le');function record(stream){let pre=Buffer.alloc(12);pre.writeUInt16LE(stream,2);pre.writeUInt16LE(key.length,4);pre.writeUInt32LE(value.length,8);return Buffer.concat([pre,key,value])}
 let recs=Buffer.concat([Buffer.from([2,0]),record(1),record(2)]),child=Buffer.concat([Buffer.from(H.LIBRARY,'hex'),Buffer.alloc(8),recs]);child.writeBigUInt64LE(BigInt(child.length),16);
 let newExt=Buffer.concat([input.subarray(extension.start,extension.start+extension.size),child]);newExt.writeBigUInt64LE(BigInt(newExt.length),16);newExt.writeUInt32LE(child.length,42);
 let newPad=Buffer.alloc(pad.size-child.length);input.copy(newPad,0,pad.start,pad.start+16);newPad.writeBigUInt64LE(BigInt(newPad.length),16);
 let objects=local.objects.map(o=>o.start===extension.start?newExt:o.start===pad.start?newPad:input.subarray(o.start,o.start+o.size));let scoped=Buffer.concat([input.subarray(0,30),...objects,input.subarray(hs)]);assert.equal(scoped.length,input.length);
 let scopeSrc=H.scan(scoped.subarray(0,hs),scoped.length,scoped.subarray(hs,hs+50)).entries.filter(x=>x.name==='WM/Scoped');assert.equal(scopeSrc.length,2);assert(scopeSrc.every(x=>x.scoped));assert.notDeepEqual(Buffer.from(scopeSrc[0].raw),Buffer.from(scopeSrc[1].raw));
 let scopeResult=await run({},new Source(scoped));assert.ifError(scopeResult.err);let scopeDst=H.scan(scopeResult.f.stage.bytes.subarray(0,hs),scoped.length,scopeResult.f.stage.bytes.subarray(hs,hs+50)).entries.filter(x=>x.name==='WM/Scoped');assert.deepEqual(scopeDst.map(x=>Buffer.from(x.raw)),scopeSrc.map(x=>Buffer.from(x.raw)));
 let aliasFactory=new Factory();await assert.rejects(()=>E.exportCopy(new Source(input),aliasFactory,probe,verifier,[new core.AsfTextEdit('Title','x')],null,['WM/AlbumTitle']),/conflicting alternate metadata/);assert(!aliasFactory.stage);
 let coded=await run({codeWrite:1});assert.match(String(coded.err),/ASF_STAGE_write_header failed code=13900020/);assert(!String(coded.err).includes('PRIVATE_TEST_CONTENT'));assert(coded.f.discarded);
 let tinyRead=new Source(input);tinyRead.maxReturn=1;let tiny=await run({},tinyRead);assert.match(String(tiny.err),/retry budget exceeded/);assert(!tiny.f.stage);
 let tinyWrite=await run({shortWrite:1});assert.match(String(tinyWrite.err),/ASF_STAGE_write_header/);assert(tinyWrite.f.discarded);
 let failSource=new Source(input);failSource.failAt=80;let r=await run({},failSource);assert(r.err);assert(r.f.discarded&&r.f.closed);
 r=await run({create:true});assert(r.err);assert(!r.f.stage);
 r=await run({zeroWrite:1,cleanup:true});assert.match(String(r.err),/cleanup incomplete/);
 let changed=new Source(input);let changedProbe={async inspect(stream){if(stream===changed)changed.token='v2';return new core.AsfAudioInfo(1000,1,44100)}};r=await run({},changed,changedProbe);assert.match(String(r.err),/changed before staging/);assert(!r.f.stage);
 let mismatchedProbe={async inspect(){return new core.AsfAudioInfo(1000,2,44100)}};r=await run({},new Source(input),mismatchedProbe);assert.match(String(r.err),/invalid source audio info/);assert(!r.f.stage);
 let badProbe={async inspect(){return new core.AsfAudioInfo(0,1,44100)}};r=await run({},new Source(input),badProbe);assert.match(String(r.err),/invalid source audio info/);assert(!r.f.stage);
 let falseProbe={async inspect(s){return s instanceof StageStream?new core.AsfAudioInfo(999,1,44100):new core.AsfAudioInfo(1000,1,44100)}};r=await run({},new Source(input),falseProbe);assert.match(String(r.err),/ASF_STAGE_probe_output/);assert(r.f.discarded);
 const cover=fs.readFileSync(path.join(process.env.ASF_FIXTURE_DIR,'cover.png'));let verified=0,compared=0;
 let coverVerifier={async validateCover(b){verified++;return new Uint8Array(b)},async assertCoverRoundTrip(a,b){compared++;assert.deepEqual(Buffer.from(a),Buffer.from(b))}};
 let cf=new Factory(),cs=new Source(input);await E.exportCopy(cs,cf,probe,coverVerifier,[],new core.AsfCoverEdit(cover,'image/png'));assert.equal(verified,1);assert.equal(compared,1);assert(cf.finished);
 let rejectingVerifier={async validateCover(b){return new Uint8Array(b)},async assertCoverRoundTrip(){throw Error('pixel mismatch')}};cf=new Factory();await assert.rejects(()=>E.exportCopy(new Source(input),cf,probe,rejectingVerifier,[],new core.AsfCoverEdit(cover,'image/png')),/ASF_STAGE_verify_cover/);assert(cf.discarded&&!cf.finished);
 let large=Buffer.concat([input,Buffer.alloc(300000,42)]);large.writeBigUInt64LE(BigInt(large.length),30+24+16);large.writeBigUInt64LE(BigInt(large.length-hs),hs+16);let largeSrc=new Source(large);largeSrc.maxReturn=8192;let largeResult=await run({shortRead:8192,shortWrite:8192},largeSrc);assert.ifError(largeResult.err);assert.equal(largeSrc.max,65536);assert.deepEqual(largeResult.f.stage.bytes.subarray(hs),large.subarray(hs));
 console.log('PASS bounded header + streaming: partial reads/writes, full data comparison, source checks, invalid probe, failures and cleanup (mock I/O and probe)');
})().catch(e=>{console.error(e);process.exitCode=1});










