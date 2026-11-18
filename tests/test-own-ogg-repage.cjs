'use strict';
// Ogg container structural tests only. The synthetic audio packets and Vorbis
// setup bytes are not a decodable stream and are not evidence of playback.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('typescript');
const files=new Map(),fds=new Map();let fdNext=10,dirs=0,failWrite=false,failSync=false,deleted=0;
const io={OpenMode:{READ_ONLY:1,CREATE:2,READ_WRITE:4},WhenceType:{SEEK_SET:0},
 openSync(p,m){if(!files.has(p)){if(!(m&2))throw Error('missing '+p);files.set(p,Buffer.alloc(0))}const fd=fdNext++;fds.set(fd,{path:p,pos:0});return{fd}},
 async open(p,m){return this.openSync(p,m)}, closeSync(fd){fds.delete(fd)},
 statSync(fd){const p=typeof fd==='string'?fd:fds.get(fd).path,b=files.get(p);if(!b)throw Error('missing '+p);return{size:b.length,ino:123,isFile:()=>true}},
 lseek(fd,p){fds.get(fd).pos=p;return p},
 async read(fd,arr,{length}){const o=fds.get(fd),b=files.get(o.path),n=Math.min(length,37,b.length-o.pos);new Uint8Array(arr).set(b.subarray(o.pos,o.pos+n));o.pos+=n;return n},
 async write(fd,arr,{length}){if(failWrite)throw Error('injected write failure');const o=fds.get(fd);let b=files.get(o.path),n=Math.min(length,41),d=Buffer.from(arr,0,n);if(o.pos+n>b.length){let x=Buffer.alloc(o.pos+n);b.copy(x);b=x;files.set(o.path,b)}d.copy(b,o.pos);o.pos+=n;return n},
 mkdtempSync(p){return p.replace('XXXXXX',String(++dirs))},fsyncSync(){if(failSync)throw Error('injected fsync failure')},unlinkSync(p){deleted++;files.delete(p)},rmdirSync(){}};
let encodeCalls=0;const util={TextEncoder:{create:()=>({encodeInto:s=>{encodeCalls++;return new Uint8Array(Buffer.from(s,'utf8'))}})},TextDecoder:{create:(_,o)=>({decodeToString:b=>new TextDecoder('utf-8',o).decode(b)})}};
const pixel=()=>({getImageInfo:async()=>({size:{width:2,height:3},isHdr:false}),release:async()=>{}});
const image={createImageSource:()=>({getImageInfo:async()=>({size:{width:2,height:3},isHdr:false}),createPixelMap:async()=>pixel(),release:async()=>{}})};
function load(file){const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,m={exports:{}};vm.runInNewContext(js,{module:m,exports:m.exports,require:n=>n==='@kit.CoreFileKit'?{fileIo:io}:n==='@kit.ArkTS'?{util}:n==='@kit.ImageKit'?{image}:{},Number,String,ArrayBuffer,Uint8Array,Math,Error});return m.exports}
const api=load(path.resolve(__dirname,'../entry/src/main/ets/services/OwnOggMetadata.ets'));
// Independently implemented non-reflected Ogg CRC with the page CRC field zeroed.
function crc(page){let c=0;for(let i=0;i<page.length;i++){let v=i>=22&&i<26?0:page[i];c=(c^(v<<24))>>>0;for(let j=0;j<8;j++)c=((c<<1)^((c&0x80000000)?0x04c11db7:0))>>>0}return c>>>0}
const le=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b};
const be=n=>{const b=Buffer.alloc(4);b.writeUInt32BE(n);return b};
const pngFixture=Buffer.from('synthetic-image-stub');
const pictureBlock=Buffer.concat([be(3),be(9),Buffer.from('image/png'),be(0),be(2),be(3),be(32),be(0),be(pngFixture.length),pngFixture]);
const pictureTag='METADATA_BLOCK_PICTURE='+pictureBlock.toString('base64');
function page(seq,flags,granule,laces,body,serial=0x12345678){if(laces.reduce((a,b)=>a+b,0)!==body.length)throw Error('bad test page');const h=Buffer.alloc(27+laces.length);h.write('OggS');h[4]=0;h[5]=flags;h.writeBigInt64LE(BigInt(granule),6);h.writeUInt32LE(serial,14);h.writeUInt32LE(seq,18);h[26]=laces.length;Buffer.from(laces).copy(h,27);const p=Buffer.concat([h,body]);p.writeUInt32LE(crc(p),22);return p}
function packLaces(size){const l=[];while(size>=255){l.push(255);size-=255}l.push(size);return l}
function vorbisID(){const b=Buffer.alloc(30);b[0]=1;b.write('vorbis',1);b.writeUInt32LE(0,7);b[11]=2;b.writeUInt32LE(44100,12);b[28]=0xb8;b[29]=1;return b}
function opusID(){const b=Buffer.alloc(19);b.write('OpusHead');b[8]=1;b[9]=2;b.writeUInt16LE(312,10);b.writeUInt32LE(48000,12);b[18]=0;return b}
function comment(codec,values,padding=0){const vendor=Buffer.from('fixture-vendor'),entries=values.map(v=>Buffer.from(v));const fields=Buffer.concat([le(vendor.length),vendor,le(entries.length),...entries.map(x=>Buffer.concat([le(x.length),x]))]);return codec==='opus'?Buffer.concat([Buffer.from('OpusTags'),fields,Buffer.alloc(padding)]):Buffer.concat([Buffer.from([3]),Buffer.from('vorbis'),fields,Buffer.from([1])])}
function makeFixture(codec,{title='Old',duplicate=false,padding=0,extra=[],art=pictureTag}={}){
 const ident=codec==='opus'?opusID():vorbisID();
 const entries=['TITLE='+title,'ARTIST=Singer','ALBUM=Album','LYRICS=Old line','X-UNKNOWN='+('z'.repeat(600))];
 if(art!==null) entries.push(art);
 entries.push(...extra);
 if(duplicate)entries.push('title=duplicate');
 const tags=comment(codec,entries,padding),prefix=510,part1=tags.subarray(0,prefix),part2=tags.subarray(prefix);
 if(part1.length!==prefix)throw Error('fixture must cross page');
 const begin=page(0,2,0,packLaces(ident.length),ident);
 const partial=page(1,0,-1,[255,255],part1);
 let completion;
 if(codec==='vorbis'){const setup=Buffer.concat([Buffer.from([5]),Buffer.from('vorbis'),Buffer.from([1,2,3,4])]);completion=page(2,1,0,[...packLaces(part2.length),...packLaces(setup.length)],Buffer.concat([part2,setup]));}
 else completion=page(2,1,0,packLaces(part2.length),part2);
 const audio=codec==='vorbis'?Buffer.from([0,12,34,56,78]):Buffer.from([0xf8,0xff,0xfe]);
 const audioPage=page(3,4,codec==='opus'?960:1024,packLaces(audio.length),audio);
 return{buffer:Buffer.concat([begin,partial,completion,audioPage]),pages:[begin,partial,completion,audioPage],tags,audioPage};
}
function makeBoundary(codec){
 const ident=codec==='opus'?opusID():vorbisID(),small=['TITLE=Old','ARTIST=Singer','ALBUM=Album','LYRICS=Old line'];let tags;
 if(codec==='opus'){const base=comment(codec,small);tags=comment(codec,small,510-base.length)}
 else {const base=comment(codec,[...small,'X=']);tags=comment(codec,[...small,'X='+('z'.repeat(510-base.length))])}
 assert.equal(tags.length,510);const first=page(0,2,0,packLaces(ident.length),ident),partial=page(1,0,-1,[255,255],tags);
 const setup=Buffer.concat([Buffer.from([5]),Buffer.from('vorbis'),Buffer.from([1,2,3])]);
 const end=codec==='vorbis'?page(2,1,0,[0,...packLaces(setup.length)],setup):page(2,1,0,[0],Buffer.alloc(0));
 const audio=codec==='opus'?Buffer.from([0xf8,0xff,0xfe]):Buffer.from([0,12,34]);const last=page(3,4,960,packLaces(audio.length),audio);
 return Buffer.concat([first,partial,end,last]);
}
function splitPages(b){const pages=[];for(let p=0;p<b.length;){assert.equal(b.subarray(p,p+4).toString(),'OggS');const n=b[p+26],header=27+n;let len=header;for(let i=0;i<n;i++)len+=b[p+27+i];assert.ok(p+len<=b.length);const pg=b.subarray(p,p+len);assert.equal(pg.readUInt32LE(22),crc(pg));pages.push(pg);p+=len;}return pages}
function changedPage(pageBuf,offset,val){const p=Buffer.from(pageBuf);p[offset]=val;p.writeUInt32LE(crc(p),22);return p}
function findPage(bytes,index){return splitPages(bytes)[index]}
function withGranule(p,n){const out=Buffer.from(p);out.writeBigInt64LE(BigInt(n),6);out.writeUInt32LE(crc(out),22);return out}

function withoutSeqAndCrc(page){let b=Buffer.from(page);b.fill(0,18,26);return b}
(async()=>{
 for(const codec of ['vorbis','opus'])for(const len of [0,5,254,255,256,65024,65025,65026,131000]){
  const x=makeFixture(codec,{padding:codec==='opus'?40:0});const input='/app/src.'+(codec==='opus'?'opus':'ogg');files.set(input,x.buffer);
  const lyric='L'.repeat(len),fields={lyrics:lyric};const out=await api.writeOggMetadata('/app',input,fields);const output=files.get(out);
  assert.deepEqual(files.get(input),x.buffer);await api.verifyOggIntegrity(input,out,fields);
  assert.equal((await api.readOggMetadata(out)).lyrics,lyric);
  const p=splitPages(output);assert.deepEqual(withoutSeqAndCrc(p.at(-1)),withoutSeqAndCrc(x.audioPage));
  assert.ok(output.includes(Buffer.from('X-UNKNOWN=')));assert.ok(output.includes(Buffer.from(pictureTag)));
  for(let i=0;i<p.length;i++)assert.equal(p[i].readUInt32LE(18),i);
 }
 for(const codec of ['vorbis','opus']){
  const x=makeFixture(codec,{padding:20}),source='/app/source.ogg';files.set(source,x.buffer);
  const out=await api.writeOggMetadata('/app',source,{lyrics:'Y'.repeat(70000)}),o=files.get(out),pages=splitPages(o);
  const bad=Buffer.from(o),last=pages.at(-1),pos=bad.length-last.length;bad[pos+28+bad[pos+26]]^=1;bad.writeUInt32LE(crc(bad.subarray(pos)),pos+22);files.set('/app/bad-audio.ogg',bad);
  await assert.rejects(api.verifyOggIntegrity(source,'/app/bad-audio.ogg',{lyrics:'Y'.repeat(70000)}));
  const wrong=Buffer.from(o);wrong.writeUInt32LE(777,18);wrong.writeUInt32LE(crc(wrong.subarray(0,pages[0].length)),22);files.set('/app/bad-seq.ogg',wrong);await assert.rejects(api.readOggMetadata('/app/bad-seq.ogg'));
  failWrite=true;await assert.rejects(api.writeOggMetadata('/app',source,{lyrics:'fail'}));failWrite=false;
  failSync=true;await assert.rejects(api.writeOggMetadata('/app',source,{lyrics:'fail'}));failSync=false;assert.deepEqual(files.get(source),x.buffer);
 }

 for(const codec of ['vorbis','opus']){
  const fixture=makeFixture(codec,{padding:20}),head=fixture.pages.slice(0,-1),payload=Buffer.concat([Buffer.from([codec==='opus'?0xf8:0]),Buffer.alloc(255,1)]);
  const first=page(3,0,-1,[255],payload.subarray(0,255)),last=page(4,5,960,[1],payload.subarray(255));
  const input=Buffer.concat([...head,first,last]);files.set('/app/cross-audio.ogg',input);
  const fields={lyrics:'cross page '+('x'.repeat(70000))},out=await api.writeOggMetadata('/app','/app/cross-audio.ogg',fields);
  await api.verifyOggIntegrity('/app/cross-audio.ogg',out,fields);const pages=splitPages(files.get(out));
  assert.deepEqual(withoutSeqAndCrc(pages.at(-2)),withoutSeqAndCrc(first));assert.deepEqual(withoutSeqAndCrc(pages.at(-1)),withoutSeqAndCrc(last));assert.deepEqual(files.get('/app/cross-audio.ogg'),input);
  const tamper=Buffer.from(files.get(out)),where=tamper.indexOf(Buffer.from('X-UNKNOWN='));assert.ok(where>=0);tamper[where+10]^=1;
  let cursor=0;while(cursor<tamper.length){const n=tamper[cursor+26];let size=27+n;for(let i=0;i<n;i++)size+=tamper[cursor+27+i];if(where>=cursor&&where<cursor+size){tamper.writeUInt32LE(crc(tamper.subarray(cursor,cursor+size)),cursor+22);break}cursor+=size;}
  files.set('/app/changed-comment.ogg',tamper);await assert.rejects(api.verifyOggIntegrity('/app/cross-audio.ogg','/app/changed-comment.ogg',fields));
  if(codec==='vorbis'){
   const setup=Buffer.from(files.get(out)),where=setup.indexOf(Buffer.from([5,118,111,114,98,105,115]));assert.ok(where>=0);setup[where+7]^=1;
   let offset=0;while(offset<setup.length){const n=setup[offset+26];let size=27+n;for(let i=0;i<n;i++)size+=setup[offset+27+i];if(where>=offset&&where<offset+size){setup.writeUInt32LE(crc(setup.subarray(offset,offset+size)),offset+22);break}offset+=size;}
   files.set('/app/changed-setup.ogg',setup);await assert.rejects(api.verifyOggIntegrity('/app/cross-audio.ogg','/app/changed-setup.ogg',fields));
  }
 }
 assert.equal(fds.size,0);console.log('PASS experimental Vorbis/Opus variable-length repagination, cross-page/zero-lace boundaries, audio page/CRC/sequence, failures and source preservation (synthetic container only)');
})().catch(e=>{console.error(e.stack||e);process.exitCode=1});
