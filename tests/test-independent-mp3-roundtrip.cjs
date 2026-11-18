'use strict';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('typescript');
const root=require('node:path').resolve(__dirname,'../entry/src/main/ets/services');
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'lyricflow-id3-roundtrip-'));
const resolve=p=>{if(!p.startsWith('/private/'))throw Error('invalid path');return path.join(tmp,p.slice(9));};
const h=new Map();let rejectSystem=false,failFsync=false,systemChecks=0;
const io={OpenMode:{READ_ONLY:0,READ_WRITE:2,CREATE:64},WhenceType:{SEEK_SET:0},openSync:(p,m)=>{let fd=fs.openSync(resolve(p),m&64?'w+':'r');h.set(fd,0);return{fd}},open:async(p,m)=>io.openSync(p,m),closeSync:fd=>{h.delete(fd);fs.closeSync(fd)},statSync:fd=>{let s=typeof fd==='string'?fs.statSync(resolve(fd)):fs.fstatSync(fd);return{size:s.size,ino:s.ino,isFile:()=>s.isFile()}},lseek:(fd,pos)=>{h.set(fd,pos);return pos},read:async(fd,b,o)=>{let n=fs.readSync(fd,Buffer.from(b),0,Math.min(o.length,37),h.get(fd));h.set(fd,h.get(fd)+n);return n},write:async(fd,b,o)=>{let n=fs.writeSync(fd,Buffer.from(b),0,Math.min(o.length,37),h.get(fd));h.set(fd,h.get(fd)+n);return n},fsyncSync:fd=>{if(failFsync)throw Error('injected fsync failure');fs.fsyncSync(fd)},mkdtempSync:p=>'/private/'+path.basename(fs.mkdtempSync(resolve(p.replace(/XXXXXX$/,'')))),unlinkSync:p=>fs.unlinkSync(resolve(p)),rmdirSync:p=>fs.rmdirSync(resolve(p))};
const png=fs.readFileSync('' + __dirname.replace(/\\/g,'/') + '/fixtures/synthetic-new-cover.png');
const makePixel=()=>({getImageInfo:async()=>({isHdr:false,pixelFormat:1,size:{width:96,height:96}}),getBytesNumberPerRow:()=>384,getPixelBytesNumber:()=>36864,readAllPixelsToBuffer:async b=>new Uint8Array(b).fill(33),release:async()=>{}});
const image={PixelMapFormat:{RGBA_8888:1,BGRA_8888:2,ARGB_8888:3,RGB_565:4,RGB_888:5},createImagePacker:()=>({packToData:async()=>png.buffer.slice(png.byteOffset,png.byteOffset+png.byteLength),release:async()=>{}}),createImageSource:()=>({getImageInfo:async()=>({size:{width:96,height:96}}),createPixelMap:async()=>makePixel(),release:async()=>{}})};
const cache={};
function load(file){if(cache[file])return cache[file];const src=fs.readFileSync(root+'/'+file+'.ets','utf8');const js=ts.transpileModule(src,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;let m={exports:{}};cache[file]=m.exports;vm.runInNewContext(js,{module:m,exports:m.exports,require:n=>n==='@kit.CoreFileKit'?{fileIo:io}:n==='@kit.ImageKit'?{image}:n==='./SystemAudioProperties'?{fillAudioProperties:async(_p,_m,strict)=>{systemChecks++;assert.equal(strict,true);if(rejectSystem)throw Error('injected system codec rejection');}}:n.startsWith('./')&&n!=='./AudioMetadataTypes'?load(n.slice(2)):{},Number,String,ArrayBuffer,Uint8Array,Math,Error});return m.exports;}
const reader=load('Mp3MetadataReader').readMp3Metadata, writer=load('Mp3DirectWriter').writeMp3MetadataCopy, integrity=load('Id3Integrity').verifyId3Integrity, verifier=load('MetadataVerification');
function syn(n){return Buffer.from([(n>>>21)&127,(n>>>14)&127,(n>>>7)&127,n&127])}
function frame(id,data,ver){const h=Buffer.alloc(10);h.write(id);if(ver===3)h.writeUInt32BE(data.length,4);else syn(data.length).copy(h,4);return Buffer.concat([h,data])}
function t(s){return Buffer.concat([Buffer.from([0]),Buffer.from(s,'latin1')])}
function tag(ver){const real=fs.readFileSync('' + __dirname.replace(/\\/g,'/') + '/fixtures/synthetic-no-cover.mp3');const n=real[6]*2097152+real[7]*16384+real[8]*128+real[9];const audio=real.subarray(10+n);const frames=[frame('TIT2',t('old'),ver),frame('TRCK',t('3/12'),ver),frame('TPOS',t('1/2'),ver),frame('PRIV',Buffer.from([0,1,2,3,4]),ver)];const data=Buffer.concat([...frames,Buffer.alloc(40)]);return Buffer.concat([Buffer.from('ID3'),Buffer.from([ver,0,0]),syn(data.length),data,audio])}
(async()=>{
const realFixture=fs.readFileSync('' + __dirname.replace(/\\/g,'/') + '/fixtures/synthetic-no-cover.mp3');
const oldTagLength=realFixture[6]*2097152+realFixture[7]*16384+realFixture[8]*128+realFixture[9];
const bare=realFixture.subarray(10+oldTagLength);fs.writeFileSync(resolve('/private/no-id3.mp3'),bare);
const originalMetadata=await reader('/private/no-id3.mp3');assert.equal(originalMetadata.title,'');assert.equal(originalMetadata.track,0);
const changesBare={title:'无标签 测试🌸',lyrics:'[00:01]合成歌词',track:2,trackTotal:9,coverImage:makePixel()};
const newPath=await writer('/private','/private/no-id3.mp3',changesBare);assert.ok(systemChecks>0,'system codec verification invoked');
const written=fs.readFileSync(resolve(newPath)),newLength=written[6]*2097152+written[7]*16384+written[8]*128+written[9];assert.equal(written.subarray(0,3).toString(),'ID3');assert.equal(written[3],4);assert.deepEqual(written.subarray(10+newLength),bare,'all original audio bytes retained');
const decoded=await reader(newPath);await verifier.verifyWrittenMetadata(changesBare,decoded);await verifier.verifyPreservedMetadata(changesBare,originalMetadata,decoded);await integrity('/private/no-id3.mp3',newPath,changesBare);assert.deepEqual(fs.readFileSync(resolve('/private/no-id3.mp3')),bare);
const corrupted=Buffer.from(written);corrupted[corrupted.length-25]^=1;fs.writeFileSync(resolve('/private/corrupt.mp3'),corrupted);await assert.rejects(integrity('/private/no-id3.mp3','/private/corrupt.mp3',changesBare));
let tag1=Buffer.alloc(128);tag1.write('TAG');let ape=Buffer.alloc(32);ape.write('APETAGEX');let lyrics=Buffer.from('LYRICS200');let footer=Buffer.alloc(10);footer.write('3DI');
const badCases=[Buffer.concat([bare,tag1]),Buffer.concat([bare,ape]),Buffer.concat([bare,lyrics]),Buffer.concat([bare,footer]),Buffer.concat([bare,Buffer.from('junk')]),bare.subarray(0,bare.length-1),Buffer.concat([Buffer.from('ID3badheader'),bare]),Buffer.from(bare)];badCases[badCases.length-1][0]=0;
for(const data of badCases){fs.writeFileSync(resolve('/private/bad.mp3'),data);await assert.rejects(reader('/private/bad.mp3'));await assert.rejects(writer('/private','/private/bad.mp3',{title:'new'}));assert.deepEqual(fs.readFileSync(resolve('/private/bad.mp3')),data);}
rejectSystem=true;await assert.rejects(writer('/private','/private/no-id3.mp3',{title:'new'}),/system codec rejection/);rejectSystem=false;failFsync=true;await assert.rejects(writer('/private','/private/no-id3.mp3',{title:'new'}),/injected fsync failure/);failFsync=false;assert.deepEqual(fs.readFileSync(resolve('/private/no-id3.mp3')),bare);
console.log('PASS real bare MP3: full audio preservation, metadata and integrity checks, tail/malformed rejection, system codec and fsync failures (system and image mocks)');
for(const version of [3,4]){
const source='/private/input.mp3',input=tag(version);fs.writeFileSync(resolve(source),input);
const old=await reader(source),changes={title:'新标题 🌸',artist:'歌手',album:'专辑',genre:'流派',comment:'备注',lyrics:'[00:01]歌词 🌸',albumArtist:'群星',composer:'作曲家',grouping:'分组',isrc:'USABC1234567',copyright:'© 2026',year:2026,track:8,disc:2,bpm:128,coverImage:makePixel()};
const out=await writer('/private',source,changes);const after=await reader(out);await verifier.verifyWrittenMetadata(changes,after);await verifier.verifyPreservedMetadata(changes,old,after);await integrity(source,out,changes);assert.deepEqual(fs.readFileSync(resolve(source)),input);
assert.equal(after.trackTotal,12);assert.equal(after.discTotal,2);assert.ok(after.coverImage);
const cleared={title:'',lyrics:'',comment:'',track:0,trackTotal:0,disc:0,discTotal:0,bpm:0,year:0};const out2=await writer('/private',out,cleared);const end=await reader(out2);await verifier.verifyWrittenMetadata(cleared,end);await verifier.verifyPreservedMetadata(cleared,after,end);await integrity(out,out2,cleared);
console.log('PASS v'+version+' full write/read/field verification/integrity/clear roundtrip, including mocked cover and short I/O');
}
})().catch(e=>{console.error(e.stack||e);process.exitCode=1}).finally(()=>(()=>{const base=path.resolve(os.tmpdir()),target=path.resolve(tmp),rel=path.relative(base,target);if(!rel||rel.startsWith('..')||path.isAbsolute(rel)||!path.basename(target).startsWith('lyricflow-id3-roundtrip-'))throw Error('refusing unsafe temp cleanup');fs.rmSync(target,{recursive:true,force:true})})());
