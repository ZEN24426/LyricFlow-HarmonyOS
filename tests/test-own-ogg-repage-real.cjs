'use strict';
// Real codec interoperability regression. Uses a user-provided FFmpeg executable
// and a synthetic WAV; it does not claim to replace HarmonyOS device testing.
// FFMPEG_PATH may be an absolute path or executable discoverable on PATH.
// OGG_TEST_WAV may point to a different explicitly supplied synthetic WAV.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),vm=require('node:vm');
const crypto=require('node:crypto'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const ts=require('typescript');
const executable=process.env.FFMPEG_PATH||'ffmpeg';
const inputWav=process.env.OGG_TEST_WAV||path.join(__dirname,'fixtures','synthetic-input.wav');
if(!fs.existsSync(inputWav))throw new Error('Missing synthetic WAV; set OGG_TEST_WAV to an existing test-only WAV file.');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'lyricflow-ogg-real-'));
const files=new Map(),fds=new Map();let next=10,dirs=0;
const io={OpenMode:{READ_ONLY:1,CREATE:2,READ_WRITE:4},WhenceType:{SEEK_SET:0},
 openSync(p,m){if(!files.has(p)){if(!(m&2))throw Error('missing '+p);files.set(p,Buffer.alloc(0))}const fd=next++;fds.set(fd,{path:p,pos:0});return{fd}},async open(p,m){return this.openSync(p,m)},
 closeSync(fd){fds.delete(fd)},statSync(fd){const p=typeof fd==='string'?fd:fds.get(fd).path,b=files.get(p);if(!b)throw Error('missing '+p);return{size:b.length,ino:123,isFile:()=>true}},
 lseek(fd,p){fds.get(fd).pos=p;return p},async read(fd,arr,{length}){const o=fds.get(fd),b=files.get(o.path),n=Math.min(length,137,b.length-o.pos);new Uint8Array(arr).set(b.subarray(o.pos,o.pos+n));o.pos+=n;return n},
 async write(fd,arr,{length}){const o=fds.get(fd);let b=files.get(o.path),n=Math.min(length,139),d=Buffer.from(arr,0,n);if(o.pos+n>b.length){const x=Buffer.alloc(o.pos+n);b.copy(x);b=x;files.set(o.path,b)}d.copy(b,o.pos);o.pos+=n;return n},
 mkdtempSync(p){return p.replace('XXXXXX',String(++dirs))},fsyncSync(){},unlinkSync(p){files.delete(p)},rmdirSync(){}};
let expectedCover;
const util={TextEncoder:{create:()=>({encodeInto:s=>new Uint8Array(Buffer.from(s,'utf8'))})},TextDecoder:{create:(_,o)=>({decodeToString:b=>new TextDecoder('utf-8',o).decode(b)})}};
const image={createImageSource:buf=>{assert.ok(expectedCover);assert.deepEqual(Buffer.from(buf),expectedCover);const width=expectedCover.readUInt32BE(16),height=expectedCover.readUInt32BE(20);return{getImageInfo:async()=>({size:{width,height},isHdr:false}),createPixelMap:async()=>({getImageInfo:async()=>({size:{width,height},isHdr:false}),release:async()=>{}}),release:async()=>{}}}};
function load(file){const compiled=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,m={exports:{}};vm.runInNewContext(compiled,{module:m,exports:m.exports,require:n=>n==='@kit.CoreFileKit'?{fileIo:io}:n==='@kit.ArkTS'?{util}:n==='@kit.ImageKit'?{image}:{},Number,String,ArrayBuffer,Uint8Array,Math,Error});return m.exports;}
const api=load(path.resolve(__dirname,'../entry/src/main/ets/services/OwnOggMetadata.ets'));
function ff(args){return execFileSync(executable,['-hide_banner','-v','error',...args],{encoding:null,maxBuffer:32*1024*1024})}
function metadata(p){return ff(['-i',p,'-map_metadata','0:s:a:0','-f','ffmetadata','-']).toString('utf8')}
function pcmHash(p){return crypto.createHash('sha256').update(ff(['-i',p,'-map','0:a:0','-c:a','pcm_s16le','-f','s16le','-'])).digest('hex')}
function crc(page){let c=0;for(let i=0;i<page.length;i++){const b=i>=22&&i<26?0:page[i];c=(c^(b<<24))>>>0;for(let j=0;j<8;j++)c=((c<<1)^((c&0x80000000)?0x04c11db7:0))>>>0}return c}
function audioPages(bytes){let pos=0,offsets=[];while(pos<bytes.length){assert.equal(bytes.subarray(pos,pos+4).toString(),'OggS');const n=bytes[pos+26];let len=27+n;for(let i=0;i<n;i++)len+=bytes[pos+27+i];offsets.push({pos,len,flags:bytes[pos+5]});pos+=len}assert.equal(pos,bytes.length);return offsets}
(async()=>{
 for(const codec of ['vorbis','opus']){
  const enc=codec==='vorbis'?'libvorbis':'libopus',ext=codec==='vorbis'?'ogg':'opus';
  const source=path.join(temp,'source.'+ext),edited=path.join(temp,'edited.'+ext);
  ff(['-i',inputWav,'-map','0:a:0','-c:a',enc,'-metadata','title=Old','-y',source]);
  const original=fs.readFileSync(source),beforeMeta=metadata(source),beforePCM=pcmHash(source);
  assert.match(beforeMeta,/^title=Old$/mi,'FFmpeg must see the original title');
  const virtual='/app/source.'+ext;files.set(virtual,Buffer.from(original));
  const before=await api.readOggMetadata(virtual);assert.equal(before.codec,codec);assert.equal(before.title,'Old');
  const changes={title:'New',lyrics:'[00:01]'+('歌词 test '.repeat(12000))},out=await api.writeOggMetadata('/app',virtual,changes);
  assert.deepEqual(files.get(virtual),original,'the original virtual file was modified');
  await api.verifyOggIntegrity(virtual,out,changes);
  const after=await api.readOggMetadata(out);assert.equal(after.title,'New');assert.equal(after.lyrics,changes.lyrics);
  fs.writeFileSync(edited,files.get(out));assert.deepEqual(fs.readFileSync(source),original,'the source file was modified');
  const outMeta=metadata(edited);assert.match(outMeta,/^title=New$/mi,'FFmpeg must see the edited title');const line=outMeta.split(/\r?\n/).find(x=>/^lyrics=/i.test(x));assert.ok(line,'FFmpeg missing lyric');assert.equal(line.slice(line.indexOf('=')+1),changes.lyrics,'FFmpeg lyric differs');
  const afterPCM=pcmHash(edited);assert.equal(afterPCM,beforePCM,'decoded PCM differs after metadata edit');
  if(codec==='opus'){
   const pages=audioPages(original),index=pages.findIndex((p,i)=>i>=2&&(p.flags&4)===0);assert.ok(index>=2,'fixture should contain a non-EOS audio page');
   const target=pages[index],broken=Buffer.from(original);broken.writeBigInt64LE(1n,target.pos+6);broken.writeUInt32LE(crc(broken.subarray(target.pos,target.pos+target.len)),target.pos+22);
   files.set('/app/bad-granule.opus',broken);await assert.rejects(api.readOggMetadata('/app/bad-granule.opus'));await assert.rejects(api.writeOggMetadata('/app','/app/bad-granule.opus',{title:'New'}));
   await assert.rejects(api.verifyOggIntegrity('/app/bad-granule.opus',out,{title:'New'}));assert.deepEqual(files.get('/app/bad-granule.opus'),broken);
  }
  console.log(`PASS ${codec} real FFmpeg encode, metadata readback and decoded PCM SHA-256 ${beforePCM}`);
 }
 const coverPath=process.env.OGG_TEST_PNG||path.join(__dirname,'fixtures','synthetic-new-cover.png');
 if(!fs.existsSync(coverPath))throw Error('Missing synthetic PNG; set OGG_TEST_PNG to a test-only PNG.');
 expectedCover=fs.readFileSync(coverPath);assert.equal(expectedCover.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
 const be=n=>{const b=Buffer.alloc(4);b.writeUInt32BE(n);return b};const w=expectedCover.readUInt32BE(16),h=expectedCover.readUInt32BE(20);
 const picture=Buffer.concat([be(3),be(9),Buffer.from('image/png'),be(0),be(w),be(h),be(32),be(0),be(expectedCover.length),expectedCover]);
 const pictureTag=picture.toString('base64');
 // FFmpeg checks the PNG can actually be decoded; ImageKit remains mocked.
 const coverPcm=crypto.createHash('sha256').update(ff(['-i',coverPath,'-frames:v','1','-f','rawvideo','-pix_fmt','rgba','-'])).digest('hex');
 for(const codec of ['vorbis','opus']){
  const enc=codec==='vorbis'?'libvorbis':'libopus',ext=codec==='vorbis'?'ogg':'opus';
  const src=path.join(temp,'picture-source.'+ext),dst=path.join(temp,'picture-edited.'+ext);
  ff(['-i',inputWav,'-map','0:a:0','-c:a',enc,'-metadata','title=Old','-metadata','METADATA_BLOCK_PICTURE='+pictureTag,'-y',src]);
  const original=fs.readFileSync(src),virtual='/app/picture.'+ext;files.set(virtual,Buffer.from(original));
  const before=await api.readOggMetadata(virtual);assert.ok(before.hasArtwork&&before.coverImage);await before.coverImage.release();
  const out=await api.writeOggMetadata('/app',virtual,{title:'New',lyrics:'Lyric '.repeat(12000)});await api.verifyOggIntegrity(virtual,out,{title:'New',lyrics:'Lyric '.repeat(12000)});
  const after=await api.readOggMetadata(out);assert.ok(after.hasArtwork&&after.coverImage);await after.coverImage.release();
  fs.writeFileSync(dst,files.get(out));assert.equal(pcmHash(dst),pcmHash(src));assert.deepEqual(files.get(virtual),original);
  assert.ok(files.get(out).includes(Buffer.from('METADATA_BLOCK_PICTURE=')));
  console.log('PASS '+codec+' real encoded audio with PNG cover preserved; PNG RGBA SHA-256 '+coverPcm+' (ImageKit stub)');
 }
 assert.equal(fds.size,0,'virtual file handles must be closed');
})().catch(e=>{console.error(e.stack||e);process.exitCode=1}).finally(()=>{(()=>{const base=path.resolve(os.tmpdir()),target=path.resolve(temp),rel=path.relative(base,target);if(!rel||rel.startsWith('..')||path.isAbsolute(rel)||!path.basename(target).startsWith('lyricflow-ogg-real-'))throw Error('refusing unsafe temp cleanup');fs.rmSync(target,{recursive:true,force:true})})()});
