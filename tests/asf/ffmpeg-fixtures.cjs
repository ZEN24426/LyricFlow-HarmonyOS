// Experimental fixture generator for FFmpeg-produced ASF only; not a general editor.
// The metadata structure was consulted in GPL-2.0-or-later Mutagen asf/_objects.py
// and LGPL-2.1-or-later FFmpeg asf.c; see README.md.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const crypto = require('node:crypto');
const ffmpeg = process.env.ASF_TEST_FFMPEG;
const ffprobe = process.env.ASF_TEST_FFPROBE;
if (!ffmpeg || !ffprobe) throw new Error('Set ASF_TEST_FFMPEG and ASF_TEST_FFPROBE to executables');
const dir = process.env.ASF_FIXTURE_DIR;
fs.mkdirSync(dir, {recursive:true});
function run(bin,args) { const r=spawnSync(bin,args,{encoding:null,maxBuffer:64*1024*1024}); if(r.status!==0) throw new Error(`${bin} exited ${r.status}: ${(r.stderr||'').toString()}`);return r.stdout; }
function u16(n){const b=Buffer.alloc(2);b.writeUInt16LE(n);return b;}
function u32(n){const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;}
function u64(n){const b=Buffer.alloc(8);b.writeBigUInt64LE(BigInt(n));return b;}
function obj(id,payload){return Buffer.concat([Buffer.from(id,'hex'),u64(payload.length+24),payload]);}
function wide(s){return Buffer.from(s+'\0','utf16le');}
function desc(name,type,data){const n=wide(name);return Buffer.concat([u16(n.length),n,u16(type),u16(data.length),data]);}
function crc32(b){let c=0xffffffff;for(const x of b){c^=x;for(let i=0;i<8;i++) c=(c>>>1)^((c&1)?0xedb88320:0);}return (c^0xffffffff)>>>0;}
function pngChunk(type,data){const t=Buffer.from(type);const len=Buffer.alloc(4);len.writeUInt32BE(data.length);const crc=Buffer.alloc(4);crc.writeUInt32BE(crc32(Buffer.concat([t,data])));return Buffer.concat([len,t,data,crc]);}
function png(){let head=Buffer.alloc(13);head.writeUInt32BE(2,0);head.writeUInt32BE(2,4);head[8]=8;head[9]=6;let rows=Buffer.from([0,255,0,0,255,0,255,0,255,0,0,0,255,255,255,255,0,255]);return Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),pngChunk('IHDR',head),pngChunk('IDAT',zlib.deflateSync(rows)),pngChunk('IEND',Buffer.alloc(0))]);}
const ids={file:'a1dcab8c47a9cf118ee400c00c205365',extended:'40a4d0d207e3d21197f000a0c95ea850',padding:'74d40618dfca0945a4ba9aabcb96aae8'};
function walk(b){const h=Number(b.readBigUInt64LE(16)), count=b.readUInt32LE(24);let pos=30,items=[];for(let i=0;i<count;i++){const n=Number(b.readBigUInt64LE(pos+16));assert(n>=24 && pos+n<=h);items.push({id:b.subarray(pos,pos+16).toString('hex'),bytes:b.subarray(pos,pos+n)});pos+=n;}assert.equal(pos,h);return {h,items};}
const base=path.join(dir,'ffmpeg-base.wma'), withCover=path.join(dir,'wmav2-picture-padding.wma'), coverFile=path.join(dir,'cover.png');
run(ffmpeg,['-hide_banner','-loglevel','error','-y','-f','lavfi','-i','sine=frequency=880:sample_rate=44100:duration=1','-c:a','wmav2','-b:a','96k','-metadata','title=Fixture title','-metadata','artist=Fixture artist','-metadata','album=Fixture album','-metadata','comment=Preserved comment','-metadata','WM/TestUnknown=opaque-value','-f','asf',base]);
const source=fs.readFileSync(base), w=walk(source), image=png();fs.writeFileSync(coverFile,image);
const matches=w.items.filter(x=>x.id===ids.extended);assert.equal(matches.length,1,'fixture requires one extended description');
const originalExt=matches[0].bytes.subarray(24);
function makeFixture(description){
 const picture=Buffer.concat([Buffer.from([3]),u32(image.length),wide('image/png'),wide(description),image]);
 const augmented=Buffer.concat([u16(originalExt.readUInt16LE(0)+1),originalExt.subarray(2),desc('WM/Picture',1,picture)]);
 const next=w.items.map(item=>item.id===ids.extended?obj(ids.extended,augmented):Buffer.from(item.bytes));
 next.push(obj(ids.padding,Buffer.alloc(8192)));
 const header=Buffer.concat([source.subarray(0,16),u64(30+next.reduce((a,b)=>a+b.length,0)),u32(next.length),source.subarray(28,30),...next]);
 const result=Buffer.concat([header,source.subarray(w.h)]);assert(walk(result).items.find(x=>x.id===ids.file));
 let off=30;for(const item of walk(result).items){if(item.id===ids.file){result.writeBigUInt64LE(BigInt(result.length),off+24+16);break;}off+=item.bytes.length;} return result;
}
let output=makeFixture('');fs.writeFileSync(withCover,output);
fs.writeFileSync(path.join(dir,'wmav2-described-picture-padding.wma'),makeFixture('front'));
const probe=JSON.parse(run(ffprobe,['-v','error','-show_format','-show_streams','-of','json',withCover]).toString());
const aud=probe.streams.find(s=>s.codec_name==='wmav2');assert(aud,'WMAv2 missing');
const art=probe.streams.find(s=>s.disposition && s.disposition.attached_pic===1);assert(art,'attached picture missing');
const outPng=run(ffmpeg,['-v','error','-i',withCover,'-map','0:v:0','-c','copy','-f','image2pipe','-']);assert.deepEqual(outPng,image);
const decode=file=>run(ffmpeg,['-v','error','-i',file,'-map','0:a:0','-c:a','pcm_s16le','-f','s16le','-']);
const before=decode(base),after=decode(withCover);assert.deepEqual(after,before);
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const originalTail=source.subarray(w.h), nextTail=output.subarray(Number(output.readBigUInt64LE(16)));assert.deepEqual(nextTail,originalTail);
console.log(JSON.stringify({base,withCover,coverFile,ffmpeg:run(ffmpeg,['-version']).toString().split(/\r?\n/)[0],baseSize:source.length,headerBefore:w.h,headerAfter:Number(output.readBigUInt64LE(16)),objects:w.items.map(x=>({id:x.id,size:x.bytes.length})),pictureSize:image.length,pcmBytes:before.length,pcmSha256:hash(before),audioTailSha256:hash(originalTail),tags:probe.format.tags,coverCodec:art.codec_name},null,2));

