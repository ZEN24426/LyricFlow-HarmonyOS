'use strict';
const fs=require('fs'),os=require('os'),path=require('path'),vm=require('vm'),assert=require('assert/strict');
const project=path.resolve(__dirname,'..');
const ts=require('typescript');
const root=project+'/entry/src/main/ets/services';const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'own-aiff-test-'));const resolve=p=>{if(!p.startsWith('/private/'))throw Error('invalid path: '+p);return path.join(tmp,p.slice(9));};
let failWrite=false;const h=new Map();const io={OpenMode:{READ_ONLY:0,READ_WRITE:2,CREATE:64},WhenceType:{SEEK_SET:0},openSync:(p,m)=>{const fd=fs.openSync(resolve(p),m&64?'w+':m&2?'r+':'r');h.set(fd,0);return{fd}},open:async(p,m)=>io.openSync(p,m),closeSync:fd=>{h.delete(fd);fs.closeSync(fd)},statSync:fd=>{let s=fs.fstatSync(fd);return{size:s.size,isFile:()=>s.isFile()}},lseek:(fd,pos)=>{h.set(fd,pos);return pos},read:async(fd,b,o)=>{let n=fs.readSync(fd,Buffer.from(b),0,Math.min(o.length,37),h.get(fd));h.set(fd,h.get(fd)+n);return n},write:async(fd,b,o)=>{if(failWrite)throw Error('simulated IO failure');let n=fs.writeSync(fd,Buffer.from(b),0,Math.min(o.length,37),h.get(fd));h.set(fd,h.get(fd)+n);return n},fsyncSync:fs.fsyncSync,truncateSync:fs.ftruncateSync,mkdtempSync:p=>'/private/'+path.relative(tmp,fs.mkdtempSync(resolve(p.replace(/XXXXXX$/,'')))).replace(/\\/g,'/'),unlinkSync:p=>fs.unlinkSync(resolve(p)),rmdirSync:p=>fs.rmdirSync(resolve(p))};
const image={};let modules={};function load(file){if(modules[file])return modules[file];const src=fs.readFileSync(root+'/'+file+'.ets','utf8');const js=ts.transpileModule(src,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;let m={exports:{}};vm.runInNewContext(js,{module:m,exports:m.exports,require:n=>n==='@kit.CoreFileKit'?{fileIo:io}:n==='@kit.ImageKit'?{image}:n.startsWith('./')?load(n.slice(2)):{},Number,String,ArrayBuffer,Uint8Array,Math,Error,RegExp});return modules[file]=m.exports;}
const aiff=load('OwnAiffMetadata');
function chunk(id,data,pad=42){const h=Buffer.alloc(8);h.write(id,'ascii');h.writeUInt32BE(data.length,4);return Buffer.concat([h,data,Buffer.alloc(data.length%2,pad)])}
function form(cs,kind='AIFF'){const data=Buffer.concat([Buffer.from(kind),...cs]);const h=Buffer.alloc(8);h.write('FORM');h.writeUInt32BE(data.length,4);return Buffer.concat([h,data])}
const comm=Buffer.alloc(18);comm.writeUInt16BE(1);comm.writeUInt32BE(100,2);comm.writeUInt16BE(16,6);Buffer.from('400eac44000000000000','hex').copy(comm,8);
const data=Buffer.from(Array.from({length:200},(_,i)=>i%251));const ssnd=Buffer.concat([Buffer.alloc(8),data]);
const input=form([chunk('COMM',comm),chunk('JUNK',Buffer.from([1,2,3])),chunk('SSND',ssnd)]);
(async()=>{
 const source='/private/song.aiff';fs.writeFileSync(resolve(source),input);
 let before=await aiff.readAiffMetadata(source,'/private');assert.equal(before.title,'');
 let out=await aiff.writeAiffMetadata('/private',source,{title:'晴天🌸',lyrics:'[00:01]测试'});
 assert.deepEqual(fs.readFileSync(resolve(source)),input);
 let actual=await aiff.readAiffMetadata(out,'/private');assert.equal(actual.title,'晴天🌸');assert.equal(actual.lyrics,'[00:01]测试');
 await aiff.verifyAiffIntegrity(source,out);
 let out2=await aiff.writeAiffMetadata('/private',out,{title:'另一个标题'});
 actual=await aiff.readAiffMetadata(out2,'/private');assert.equal(actual.title,'另一个标题');assert.equal(actual.lyrics,'[00:01]测试');await aiff.verifyAiffIntegrity(out,out2);
 const changedId=fs.readFileSync(resolve(out2));const idAt=changedId.indexOf(Buffer.from('ID3 '));assert.ok(idAt>0);changedId[idAt]=105;fs.writeFileSync(resolve('/private/changed-id.aiff'),changedId);await assert.rejects(aiff.verifyAiffIntegrity(out,'/private/changed-id.aiff'));
 const expanded=Buffer.concat([fs.readFileSync(resolve(out2)),Buffer.alloc(2)]);const ep=expanded.indexOf(Buffer.from('ID3 '));const oldTagLength=expanded.readUInt32BE(ep+4);expanded.writeUInt32BE(oldTagLength+2,ep+4);expanded.writeUInt32BE(expanded.length-8,4);let tagSize=oldTagLength-10+2;for(let k=ep+17;k>=ep+14;k--){expanded[k]=tagSize%128;tagSize=Math.floor(tagSize/128)}fs.writeFileSync(resolve('/private/expanded.aiff'),expanded);await assert.rejects(aiff.verifyAiffIntegrity(out,'/private/expanded.aiff'));
 let bad=fs.readFileSync(resolve(out));let pos=bad.indexOf(data);assert.ok(pos>0);bad[pos]^=1;fs.writeFileSync(resolve('/private/bad.aiff'),bad);await assert.rejects(aiff.verifyAiffIntegrity(source,'/private/bad.aiff'));
 const conflict=form([chunk('COMM',comm),chunk('NAME',Buffer.from('Other title')),chunk('SSND',ssnd)]);fs.writeFileSync(resolve('/private/conflict.aiff'),conflict);await assert.rejects(aiff.readAiffMetadata('/private/conflict.aiff','/private'));await assert.rejects(aiff.writeAiffMetadata('/private','/private/conflict.aiff',{title:'x'}));assert.deepEqual(fs.readFileSync(resolve('/private/conflict.aiff')),conflict);
 const aifc=form([chunk('COMM',comm),chunk('SSND',ssnd)],'AIFC');fs.writeFileSync(resolve('/private/aifc.aif'),aifc);await assert.rejects(aiff.readAiffMetadata('/private/aifc.aif','/private'));
 const corrupt=Buffer.from(input);corrupt.writeUInt32BE(4,4);fs.writeFileSync(resolve('/private/corrupt.aiff'),corrupt);await assert.rejects(aiff.readAiffMetadata('/private/corrupt.aiff','/private'));
 const invalidComm=Buffer.from(comm);invalidComm.writeUInt32BE(99,2);fs.writeFileSync(resolve('/private/short.aiff'),form([chunk('COMM',invalidComm),chunk('SSND',ssnd)]));await assert.rejects(aiff.readAiffMetadata('/private/short.aiff','/private'));
 const invalidSsnd=Buffer.from(ssnd);invalidSsnd.writeUInt32BE(1,0);fs.writeFileSync(resolve('/private/offset.aiff'),form([chunk('COMM',comm),chunk('SSND',invalidSsnd)]));await assert.rejects(aiff.readAiffMetadata('/private/offset.aiff','/private'));
 const duplicate=form([chunk('COMM',comm),chunk('COMM',comm),chunk('SSND',ssnd)]);fs.writeFileSync(resolve('/private/dup.aiff'),duplicate);await assert.rejects(aiff.readAiffMetadata('/private/dup.aiff','/private'));
 const origId3=fs.readFileSync(resolve(out));const id=origId3.indexOf(Buffer.from('ID3 '));assert.ok(id>0);const size=origId3.readUInt32BE(id+4);const extra=Buffer.from(origId3.subarray(id,id+8+size+size%2));const dupTag=Buffer.concat([origId3,extra]);dupTag.writeUInt32BE(dupTag.length-8,4);fs.writeFileSync(resolve('/private/duptag.aiff'),dupTag);await assert.rejects(aiff.readAiffMetadata('/private/duptag.aiff','/private'));
 const unknown=fs.readFileSync(resolve(out));const chunkAt=unknown.indexOf(Buffer.from('ID3 '));let cursor=chunkAt+18;
 while(unknown[cursor]!==0){const length=(unknown[cursor+4]*2097152)+(unknown[cursor+5]*16384)+(unknown[cursor+6]*128)+unknown[cursor+7];cursor+=10+length;}
 const payload=Buffer.from([3,...Buffer.from('custom-unedited')]);const frame=Buffer.concat([Buffer.from('TXXX'),Buffer.from([0,0,0,payload.length,0,0]),payload]);frame.copy(unknown,cursor);
 fs.writeFileSync(resolve('/private/unknown.aiff'),unknown);const preserved=await aiff.writeAiffMetadata('/private','/private/unknown.aiff',{lyrics:'updated'});
 const preservedBytes=fs.readFileSync(resolve(preserved));assert.ok(preservedBytes.includes(Buffer.from('custom-unedited')));await aiff.verifyAiffIntegrity('/private/unknown.aiff',preserved);
 const all={title:'标题',artist:'歌手',album:'专辑',genre:'流派',comment:'注释',lyrics:'歌词',albumArtist:'专辑歌手',composer:'作曲',grouping:'分组',isrc:'abc123',copyright:'版权',year:2024,track:2,trackTotal:12,disc:1,discTotal:2,bpm:140};
 const allOut=await aiff.writeAiffMetadata('/private',source,all);const allRead=await aiff.readAiffMetadata(allOut,'/private');for(const [key,value] of Object.entries(all))assert.equal(allRead[key],value,key);await aiff.verifyAiffIntegrity(source,allOut);
 const mixed=form([chunk('COMM',comm),chunk('Id3 ',Buffer.alloc(10)),chunk('SSND',ssnd)]);fs.writeFileSync(resolve('/private/mixed.aiff'),mixed);await assert.rejects(aiff.readAiffMetadata('/private/mixed.aiff','/private'));
 const prior=fs.readdirSync(tmp).sort();failWrite=true;await assert.rejects(aiff.writeAiffMetadata('/private',source,{title:'failure'}));failWrite=false;assert.deepEqual(fs.readdirSync(tmp).sort(),prior);assert.deepEqual(fs.readFileSync(resolve(source)),input);assert.equal(h.size,0);
 await assert.rejects(aiff.writeAiffMetadata('/private','/other/song.aiff',{title:'x'}));
 if(process.env.LYRICFLOW_AIFF_FIXTURE){
  const actualInput=fs.readFileSync(process.env.LYRICFLOW_AIFF_FIXTURE);const live='/private/live.aiff';fs.writeFileSync(resolve(live),actualInput);
  await aiff.readAiffMetadata(live,'/private');const change={title:'Synthetic AIFF',lyrics:'[00:01.00] test lyric'};
  const target=await aiff.writeAiffMetadata('/private',live,change);await aiff.verifyAiffIntegrity(live,target);
  const actual=await aiff.readAiffMetadata(target,'/private');assert.equal(actual.title,change.title);assert.equal(actual.lyrics,change.lyrics);
  assert.deepEqual(fs.readFileSync(resolve(live)),actualInput);
  if(process.env.LYRICFLOW_AIFF_RESULT)fs.writeFileSync(process.env.LYRICFLOW_AIFF_RESULT,fs.readFileSync(resolve(target)),{flag:'wx'});
  console.log('PASS requested AIFF fixture read/write, metadata and chunk integrity with file IO shim');
 }
 console.log('PASS AIFF synthetic add/update ID3, short I/O, PCM and odd-pad preservation, conflicting metadata and malformed layouts rejected');
})().catch(e=>{console.error(e);process.exitCode=1}).finally(()=>{const base=path.resolve(os.tmpdir()),target=path.resolve(tmp),relative=path.relative(base,target);if(!relative||relative.startsWith('..')||path.isAbsolute(relative)||!path.basename(target).startsWith('own-aiff-test-'))throw Error('refusing unsafe temp cleanup');fs.rmSync(target,{recursive:true,force:true});});
