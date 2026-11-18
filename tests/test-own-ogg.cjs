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
(async()=>{
 for(const codec of ['vorbis','opus']){
  const test=makeFixture(codec,{padding:codec==='opus'?100:0});const input='/app/source.'+(codec==='opus'?'opus':'ogg');files.set(input,test.buffer);
  const before=await api.readOggMetadata(input);assert.equal(before.codec,codec);assert.equal(before.hasArtwork,true);assert.equal(before.title,'Old');assert.equal(before.artist,'Singer');assert.equal(before.album,'Album');assert.equal(before.lyrics,'Old line');
  const fields={title:codec==='opus'?'New longer Unicode 歌':'New'};const output=await api.writeOggMetadata('/app',input,fields);const result=files.get(output);
  assert.deepEqual(files.get(input),test.buffer,'source must remain unchanged');const after=await api.readOggMetadata(output);assert.equal(after.hasArtwork,true);assert.equal(after.title,fields.title);assert.equal(after.artist,before.artist);assert.equal(after.lyrics,before.lyrics);
  await api.verifyOggIntegrity(input,output,fields);const pages=splitPages(result);assert.deepEqual(pages[0],test.pages[0]);const actualAudio=Buffer.from(pages.at(-1)),expectedAudio=Buffer.from(test.audioPage);actualAudio.fill(0,18,26);expectedAudio.fill(0,18,26);assert.deepEqual(actualAudio,expectedAudio,'audio page content and granule must remain unchanged apart from sequence/CRC');assert.ok(result.includes(Buffer.from('X-UNKNOWN=')));assert.ok(result.includes(Buffer.from(pictureTag)));assert.ok(after.coverImage);assert.ok(result.includes(Buffer.from('fixture-vendor')));
  const longerTitle=codec==='opus'?'Longer than old':'longer';const longerOutput=await api.writeOggMetadata('/app',input,{title:longerTitle});assert.equal((await api.readOggMetadata(longerOutput)).title,longerTitle);await api.verifyOggIntegrity(input,longerOutput,{title:longerTitle});
  await assert.rejects(api.writeOggMetadata('/app',input,{coverImage:{}}));
  const boundary=makeBoundary(codec);files.set('/app/boundary.ogg',boundary);assert.equal((await api.readOggMetadata('/app/boundary.ogg')).title,'Old');const boundaryOut=await api.writeOggMetadata('/app','/app/boundary.ogg',{title:'New'});await api.verifyOggIntegrity('/app/boundary.ogg',boundaryOut,{title:'New'});assert.deepEqual(files.get('/app/boundary.ogg'),boundary);
  const duplicate=makeFixture(codec,{duplicate:true,padding:100}).buffer;files.set('/app/duplicate.ogg',duplicate);await assert.rejects(api.writeOggMetadata('/app','/app/duplicate.ogg',{title:'New'}));assert.deepEqual(files.get('/app/duplicate.ogg'),duplicate);
  const changesWrong={title:codec==='opus'?'New longer Unicode 歌':'New',artist:'other'};await assert.rejects(api.verifyOggIntegrity(input,output,changesWrong));
  const changedAudio=Buffer.from(result),pagesBefore=splitPages(changedAudio),lastOffset=changedAudio.length-pagesBefore.at(-1).length;changedAudio[lastOffset+changedAudio[lastOffset+26]+28]^=1;changedAudio.writeUInt32LE(crc(changedAudio.subarray(lastOffset)),lastOffset+22);files.set('/app/tamper.ogg',changedAudio);await assert.rejects(api.verifyOggIntegrity(input,'/app/tamper.ogg',fields));
  const granuleChanged=Buffer.concat([...pages.slice(0,-1),changedPage(pages.at(-1),6,pages.at(-1)[6]^1)]);files.set('/app/granule.ogg',granuleChanged);await assert.rejects(api.verifyOggIntegrity(input,'/app/granule.ogg',fields));
  console.log('PASS '+codec+' cross-page comments, stable audio page and granule, field checks and conflict rejection (container-only synthetic data)');
 }
 const rich=makeFixture('opus',{padding:300,extra:['GENRE=Rock','DESCRIPTION=Note','ALBUM ARTIST=Band','COMPOSER=Composer','GROUPING=Grp','ISRC=USAAA0000000','COPYRIGHT=Copy','DATE=2026','TRACKNUMBER=3/12','DISCNUMBER=1/2','BPM=120']});
 files.set('/app/rich.opus',rich.buffer);const m=await api.readOggMetadata('/app/rich.opus');
 assert.equal(m.genre,'Rock');assert.equal(m.comment,'Note');assert.equal(m.albumArtist,'Band');assert.equal(m.composer,'Composer');assert.equal(m.grouping,'Grp');assert.equal(m.isrc,'USAAA0000000');assert.equal(m.copyright,'Copy');assert.equal(m.year,2026);assert.equal(m.track,3);assert.equal(m.trackTotal,12);assert.equal(m.disc,1);assert.equal(m.discTotal,2);assert.equal(m.bpm,120);assert.ok(m.coverImage);
 const richFields={genre:'Jazz',comment:'Memo',albumArtist:'Duo!',composer:'Composer',grouping:'New',isrc:'USAAA0000001',copyright:'Copr',year:2025,bpm:121};
 const richOut=await api.writeOggMetadata('/app','/app/rich.opus',richFields);const rm=await api.readOggMetadata(richOut);assert.equal(rm.genre,'Jazz');assert.equal(rm.comment,'Memo');assert.equal(rm.albumArtist,'Duo!');assert.equal(rm.year,2025);assert.equal(rm.bpm,121);await api.verifyOggIntegrity('/app/rich.opus',richOut,richFields);
 await assert.rejects(api.writeOggMetadata('/app','/app/rich.opus',{track:4}));await assert.rejects(api.writeOggMetadata('/app','/app/rich.opus',{discTotal:8}));
 for(const extra of [['COMMENT=a','DESCRIPTION=b'],['DATE=2026','YEAR=2026'],['TRACKNUMBER=3','TRACKNUM=3'],['TRACKTOTAL=12','TOTALTRACKS=12'],['TRACKNUMBER=3/12','TRACKTOTAL='],['BPM=-5'],['DATE=bad'],['METADATA_BLOCK_PICTURE=bad!']]){
   const b=makeFixture('opus',{padding:300,extra}).buffer;files.set('/app/reject.opus',b);await assert.rejects(api.readOggMetadata('/app/reject.opus'));assert.deepEqual(files.get('/app/reject.opus'),b);
 }
 const fullDate=makeFixture('opus',{padding:300,extra:['DATE=2026-11-18']}).buffer;files.set('/app/date.opus',fullDate);assert.equal((await api.readOggMetadata('/app/date.opus')).year,2026);await assert.rejects(api.writeOggMetadata('/app','/app/date.opus',{year:2025}));
 const opus=makeFixture('opus',{padding:30});const invalidPreSkip=Buffer.concat([...opus.pages.slice(0,-1),withGranule(opus.pages.at(-1),10)]);const negative=Buffer.concat([...opus.pages.slice(0,-1),withGranule(opus.pages.at(-1),-2)]);
 const body=Buffer.from([0xf8,0xff,0xfe]);const audioA=page(3,0,1000,packLaces(body.length),body);const audioB=page(4,4,500,packLaces(body.length),body);const backwards=Buffer.concat([...opus.pages.slice(0,-1),audioA,audioB]);
 for(const b of [invalidPreSkip,negative,backwards]){files.set('/app/granule-bad.opus',b);await assert.rejects(api.readOggMetadata('/app/granule-bad.opus'));await assert.rejects(api.writeOggMetadata('/app','/app/granule-bad.opus',{title:'New'}));}
 const legacy=makeFixture('opus',{art:null,padding:100,extra:['COVERART=YWJj','COVERARTMIME=image/png']}).buffer;files.set('/app/legacy.opus',legacy);const legacyMeta=await api.readOggMetadata('/app/legacy.opus');assert.ok(legacyMeta.hasArtwork&&legacyMeta.coverImage);
 const onlyBack=Buffer.from(pictureBlock);onlyBack.writeUInt32BE(4,0);const backTag='METADATA_BLOCK_PICTURE='+onlyBack.toString('base64');
 const backOnly=makeFixture('opus',{art:backTag,padding:100}).buffer;files.set('/app/back.opus',backOnly);const backMeta=await api.readOggMetadata('/app/back.opus');assert.equal(backMeta.hasArtwork,true);assert.equal(backMeta.coverImage,undefined);
 const wrongSize=Buffer.from(pictureBlock);wrongSize.writeUInt32BE(1,21);const invalidPictures=[{art:pictureTag,extra:[pictureTag]},{art:'METADATA_BLOCK_PICTURE='+wrongSize.toString('base64'),extra:[]},{art:'METADATA_BLOCK_PICTURE='+Buffer.from('not a picture block').toString('base64'),extra:[]},{art:null,extra:['COVERART=YWJj','COVERARTMIME=']},{art:null,extra:['COVERARTMIME=image/png']}];
 for(const opt of invalidPictures){const b=makeFixture('opus',{padding:100,...opt}).buffer;files.set('/app/invalid-picture.opus',b);await assert.rejects(api.readOggMetadata('/app/invalid-picture.opus'));await assert.rejects(api.writeOggMetadata('/app','/app/invalid-picture.opus',{title:'New'}));assert.deepEqual(files.get('/app/invalid-picture.opus'),b);}
 const noPicture=makeFixture('opus',{art:null,padding:60,extra:['COVERART=YWJj','COVERARTMIME=','COVERARTMIME=image/png']}).buffer;
 files.set('/app/duplicate-mime.opus',noPicture);await assert.rejects(api.readOggMetadata('/app/duplicate-mime.opus'));await assert.rejects(api.writeOggMetadata('/app','/app/duplicate-mime.opus',{title:'New'}));
 const smallFirstAudio=Buffer.concat([...opus.pages.slice(0,-1),page(3,0,1,packLaces(body.length),body),page(4,4,960,packLaces(body.length),body)]);
 files.set('/app/small-first.opus',smallFirstAudio);await assert.rejects(api.readOggMetadata('/app/small-first.opus'));await assert.rejects(api.writeOggMetadata('/app','/app/small-first.opus',{title:'New'}));
 for(const payload of [Buffer.from([0xf9,0]),Buffer.from([0xfa,5]),Buffer.from([0xfb,0]),Buffer.from([0xfb,63]),Buffer.from([0xfb,0x42,255])]){
   const b=Buffer.concat([...opus.pages.slice(0,-1),page(3,4,960,packLaces(payload.length),payload)]);files.set('/app/bad-frame.opus',b);await assert.rejects(api.readOggMetadata('/app/bad-frame.opus'));
 }
 const codeCases=[Buffer.from([0xf8,1]),Buffer.from([0xf9,1,2]),Buffer.from([0xfa,1,2,3]),Buffer.from([0xfb,2,1,2]),Buffer.from([0xfb,0x82,1,2,3]),Buffer.from([0xfb,0x42,1,1,2,0])];
 for(const data of codeCases){const samples=(data[0]&3)===0?960:1920;const b=Buffer.concat([...opus.pages.slice(0,-1),page(3,4,samples,packLaces(data.length),data)]);files.set('/app/valid-frame.opus',b);assert.equal((await api.readOggMetadata('/app/valid-frame.opus')).codec,'opus');}
 const partialPacket=Buffer.concat([Buffer.from([0xf8]),Buffer.alloc(255,1)]);const crossAudio=Buffer.concat([...opus.pages.slice(0,-1),page(3,0,-1,[255],partialPacket.subarray(0,255)),page(4,5,960,[1],partialPacket.subarray(255))]);files.set('/app/cross-audio.opus',crossAudio);assert.equal((await api.readOggMetadata('/app/cross-audio.opus')).codec,'opus');
 const validTiming=Buffer.concat([...opus.pages.slice(0,-1),page(3,0,960,packLaces(body.length),body),page(4,0,1920,packLaces(body.length),body),page(5,4,2500,packLaces(body.length),body)]);files.set('/app/timing.opus',validTiming);assert.equal((await api.readOggMetadata('/app/timing.opus')).codec,'opus');
 const tooLate=Buffer.concat([...opus.pages.slice(0,-1),page(3,0,960,packLaces(body.length),body),page(4,4,1921,packLaces(body.length),body)]);files.set('/app/late.opus',tooLate);await assert.rejects(api.readOggMetadata('/app/late.opus'));
 console.log('PASS metadata fields, number/alias/date ambiguity, cover parsing mock, and Opus granule rejection');
 const x=makeFixture('vorbis'), badCRC=Buffer.from(x.buffer);badCRC[badCRC.length-1]^=1;
 const variants=[badCRC,Buffer.concat([x.pages[0],changedPage(x.pages[1],18,9),...x.pages.slice(2)]),Buffer.concat([x.pages[0],x.pages[1],changedPage(x.pages[2],5,0),x.pages[3]]),Buffer.concat([x.pages[0],x.pages[1],changedPage(x.pages[2],14,99),x.pages[3]]),Buffer.concat([x.buffer,Buffer.from('JUNK')]),Buffer.concat([x.buffer,x.buffer]),x.buffer.subarray(0,x.buffer.length-1)];
 for(const b of variants){files.set('/app/bad.ogg',b);await assert.rejects(api.readOggMetadata('/app/bad.ogg'));assert.deepEqual(files.get('/app/bad.ogg'),b)}
 files.set('/app/fail.ogg',x.buffer);const original=Buffer.from(x.buffer);const priorEncoding=encodeCalls;await assert.rejects(api.writeOggMetadata('/app','/app/fail.ogg',{lyrics:'x'.repeat(4*1024*1024+1)}));assert.equal(encodeCalls,priorEncoding,'reject oversized strings before allocating an encoded copy');assert.deepEqual(files.get('/app/fail.ogg'),original);let d=deleted;failWrite=true;await assert.rejects(api.writeOggMetadata('/app','/app/fail.ogg',{title:'New'}),/injected write failure/);failWrite=false;assert.ok(deleted>d);assert.deepEqual(files.get('/app/fail.ogg'),original);
 failSync=true;await assert.rejects(api.writeOggMetadata('/app','/app/fail.ogg',{title:'New'}),/injected fsync failure/);failSync=false;assert.deepEqual(files.get('/app/fail.ogg'),original);
 assert.equal(fds.size,0);console.log('PASS Ogg CRC, sequence, continuation, chained/multi serial streams, trailing bytes, truncation and I/O failure rejection');
})().catch(e=>{console.error(e.stack||e);process.exitCode=1});
