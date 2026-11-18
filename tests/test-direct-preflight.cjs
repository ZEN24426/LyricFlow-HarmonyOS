'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require('typescript');
const root=path.resolve(__dirname,'../entry/src/main/ets/services');
let current=Buffer.alloc(0),position=0;
const io={WhenceType:{SEEK_SET:0},statSync:()=>({size:current.length,isFile:()=>true}),lseek:(_fd,p)=>{position=p;return p},read:async(_fd,b,opt)=>{const n=Math.min(opt.length,37,current.length-position);new Uint8Array(b).set(current.subarray(position,position+n));position+=n;return n}};
function load(file){let src=fs.readFileSync(path.join(root,file+'.ets'),'utf8');if(file==='DirectAudioWriteService')src+='\nexport { assertFormatSignature };\n';const compiled=ts.transpileModule(src,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;const m={exports:{}};vm.runInNewContext(compiled,{module:m,exports:m.exports,require:n=>n==='@kit.CoreFileKit'?{fileIo:io}:n==='./BareMp3'?load('BareMp3'):{},Number,String,ArrayBuffer,Uint8Array,Math,Error});return m.exports}
const preflight=load('DirectAudioWriteService').assertFormatSignature;
const tagged=fs.readFileSync(path.join(__dirname,'fixtures/synthetic-no-cover.mp3'));
const size=tagged[6]*2097152+tagged[7]*16384+tagged[8]*128+tagged[9];const bare=tagged.subarray(10+size);
async function check(b,ext,valid){current=Buffer.from(b);position=0;const before=Buffer.from(current);if(valid)await preflight(1,ext);else await assert.rejects(preflight(1,ext));assert.deepEqual(current,before)}
(async()=>{await check(tagged,'.mp3',true);await check(bare,'.mp3',true);await check(bare.subarray(0,-1),'.mp3',false);await check(Buffer.concat([bare,Buffer.from('TAG'),Buffer.alloc(125)]),'.mp3',false);await check(Buffer.from('ID3\x02\0\0\0\0\0\0'),'.mp3',false);await check(Buffer.from('fLaC'),'.flac',true);await check(Buffer.from('not flac'),'.flac',false);console.log('PASS direct-write preflight accepts valid bare/tagged MP3 and FLAC, rejects truncated/tail-tag/unsupported signatures; no mutation');})().catch(e=>{console.error(e);process.exitCode=1});
