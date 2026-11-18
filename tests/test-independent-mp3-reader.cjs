'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('typescript');
const root=require('node:path').resolve(__dirname,'..');
const fixtures='' + __dirname.replace(/\\/g,'/') + '/fixtures';
const io={OpenMode:{READ_ONLY:0},WhenceType:{SEEK_SET:0},open:async(p)=>({fd:fs.openSync(p,'r')}),closeSync:fs.closeSync,statSync:fd=>{const s=fs.fstatSync(fd);return {size:s.size,isFile:()=>s.isFile()}},lseek:(fd,pos)=>{offsets.set(fd,pos);return pos},read:async(fd,b,opt)=>{let n=fs.readSync(fd,Buffer.from(b),0,Math.min(4096,opt.length),offsets.get(fd));offsets.set(fd,offsets.get(fd)+n);return n}};
const offsets=new Map();
const image={createImageSource:()=>({getImageInfo:async()=>({size:{width:96,height:96}}),createPixelMap:async()=>({cover:true,getImageInfo:async()=>({size:{width:96,height:96},isHdr:false}),release:async()=>{}}),release:async()=>{}})};
const source=fs.readFileSync(root+'/entry/src/main/ets/services/Mp3MetadataReader.ets','utf8');
const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
const bare={exports:{}};const bareJs=ts.transpileModule(fs.readFileSync(root+'/entry/src/main/ets/services/BareMp3.ets','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;vm.runInNewContext(bareJs,{module:bare,exports:bare.exports,require:n=>n==='@kit.CoreFileKit'?{fileIo:io}:{},ArrayBuffer,Uint8Array,Number,String,Math,Error});
const m={exports:{}};vm.runInNewContext(js,{module:m,exports:m.exports,require:n=>n==='@kit.CoreFileKit'?{fileIo:io}:n==='@kit.ImageKit'?{image}:n==='./BareMp3'?bare.exports:{},ArrayBuffer,Uint8Array,Number,String,Math,Error});
const reader=m.exports.readMp3Metadata;
function sync(n){return Buffer.from([(n>>>21)&127,(n>>>14)&127,(n>>>7)&127,n&127]);}
function frame(id,bytes,v=4,flags=0){const h=Buffer.alloc(10);h.write(id);if(v===4)sync(bytes.length).copy(h,4);else h.writeUInt32BE(bytes.length,4);h.writeUInt16BE(flags,8);return Buffer.concat([h,bytes]);}
function tag(frames,v=4,flags=0){let b=Buffer.concat([...frames,Buffer.alloc(8)]);return Buffer.concat([Buffer.from('ID3'),Buffer.from([v,0,flags]),sync(b.length),b,Buffer.from('mp3 synthetic audio')]);}
function t(s){return Buffer.concat([Buffer.from([3]),Buffer.from(s)])}
const tmpDir=fs.mkdtempSync(require('node:path').join(require('node:os').tmpdir(),'lyricflow-reader-'));
const tmp=require('node:path').join(tmpDir,'fixture.mp3');
async function check(bytes){fs.writeFileSync(tmp,bytes);const before=fs.readFileSync(tmp);let result;try{result=await reader(tmp)}finally{assert.deepEqual(fs.readFileSync(tmp),before)}return result;}
(async()=>{
 const base=tag([frame('TIT2',t('歌名🌸')),frame('TRCK',t('3/12')),frame('USLT',Buffer.concat([Buffer.from([3,101,110,103,0]),Buffer.from('歌词 🌸')])),frame('TDRC',t('2026-11-18'))]);
 const v=await check(base);assert.equal(v.title,'歌名🌸');assert.equal(v.track,3);assert.equal(v.trackTotal,12);assert.equal(v.lyrics,'歌词 🌸');assert.equal(v.year,2026);
 const utf16=Buffer.concat([Buffer.from([1,255,254]),Buffer.from('封面 🌸','utf16le')]);
 assert.equal((await check(tag([frame('TIT2',utf16,3)],3))).title,'封面 🌸');
 const described=Buffer.concat([Buffer.from([1,101,110,103,255,254,0,0,255,254]),Buffer.from('歌词 🌸','utf16le')]);
 assert.equal((await check(tag([frame('USLT',described,3)],3))).lyrics,'歌词 🌸');
 const pic=Buffer.concat([Buffer.from('\0image/png\0\x03\0','binary'),Buffer.from('fakepng')]);assert.ok((await check(tag([frame('APIC',pic)]))).coverImage);
 for(const b of [tag([frame('TIT2',t('x')),frame('TIT2',t('y'))]),tag([frame('TIT2',Buffer.from([3,0xc0,0x80]))]),tag([frame('TIT2',t('x'),4,1)]),tag([frame('TIT2',t('x'))],4,0x80),tag([frame('TIT2',t('x'))],4,0x40),tag([frame('TIT2',Buffer.from([1,255,254,0,0xd8]))],3),tag([frame('TIT2',t('x\0y'))]),tag([frame('TRCK',t('3/4/5'))])])await assert.rejects(check(b));
 for(const kind of [0,4]) { const nonFront=Buffer.concat([Buffer.from([0]),Buffer.from('image/png\0','binary'),Buffer.from([kind,0]),Buffer.from('fakepng')]);await assert.rejects(check(tag([frame('APIC',nonFront)])),/不是前封面/); }
 const maxCover=Buffer.concat([Buffer.from([0,105,109,97,103,101,47,112,110,103,0,3,0]),Buffer.alloc(8*1024*1024,1)]);assert.ok((await check(tag([frame('APIC',maxCover)]))).coverImage);
 await assert.rejects(check(tag([frame('APIC',Buffer.concat([maxCover,Buffer.from([1])]))])));
 const fixture=fixtures+'/synthetic-unicode.mp3';const real=await reader(fixture);assert.equal(real.track,3);assert.equal(real.trackTotal,12);assert.equal(real.disc,1);assert.equal(real.discTotal,2);
 console.log('PASS synthetic ID3v2.3/2.4, UTF-8/16, lyrics, cover, numbers, unsafe data rejection, short reads, original preservation and real synthetic MP3');
})().catch(e=>{console.error(e);process.exitCode=1}).finally(()=>{try{fs.unlinkSync(tmp)}catch{}try{fs.rmdirSync(tmpDir)}catch{}});
