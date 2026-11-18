const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const ts=require('typescript');
function load(file,deps={}){const src=fs.readFileSync(path.join(__dirname,'../../entry/src/main/ets/services',file+'.ets'),'utf8');const js=ts.transpileModule(src,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;const m={exports:{}};vm.runInThisContext('(function(exports,module,require){'+js+'\n})')(m.exports,m,id=>deps[id]||{});return m.exports}
const h=load('AsfHeaderEditor'), H=h.AsfHeaderEditor;
const dir=process.env.ASF_FIXTURE_DIR;const original=fs.readFileSync(path.join(dir,'wmav2-picture-padding.wma')), edited=fs.readFileSync(path.join(dir,'editor-output.wma'));const headerSize=Number(original.readBigUInt64LE(16));
class Reader{constructor(buffer,token,limit=997){this.buffer=Buffer.from(buffer);this.token=token;this.limit=limit;this.calls=0;this.max=0;this.closed=false;this.failAt=0}size(){return this.buffer.length}snapshotToken(){return this.token}readAt(offset,n){this.calls++;this.max=Math.max(n,this.max);if(this.failAt===this.calls)throw Error('fake I/O fault');return new Uint8Array(this.buffer.subarray(offset,offset+Math.min(n,this.limit)))}close(){this.closed=true;if(this.closeFail)throw Error('fake close fault')}}
const probe={async inspect(){return {durationMs:1000,channels:1,sampleRate:44100}}};
let openMap={},opened=[];class FakeSource extends Reader{constructor(p){if(!openMap[p])throw Error('open failed');super(openMap[p],p);this.closeFail=p==='close-fail';opened.push(this)}}
class FakeProbe{async inspect(){return {durationMs:1000,channels:1,sampleRate:44100}}}
const S=load('AsfStagedIntegrity',{'./AsfHeaderEditor':h,'./AsfPrivateIO':{AsfPrivateSource:FakeSource},'./AsfSystemAudioProbe':{AsfSystemAudioProbe:FakeProbe}});
const I=S.AsfStagedIntegrity;
(async()=>{
 let a=new Reader(original,'a'),b=new Reader(edited,'b');await I.verifyStreams(a,b,probe,['Title']);assert(a.max<=H.MAX_HEADER&&b.max<=H.MAX_HEADER);
 let parsed=H.scan(original.subarray(0,headerSize),original.length,original.subarray(headerSize,headerSize+50)),ext=parsed.objects.find(o=>o.id===H.EXTENSION),pad=parsed.padding;
 const key=Buffer.from('WM/Scoped\0','utf16le'),v=Buffer.from('same\0','utf16le'),record=Buffer.alloc(12);record.writeUInt16LE(key.length,4);record.writeUInt32LE(v.length,8);
 let child=Buffer.concat([Buffer.from(H.LIBRARY,'hex'),Buffer.alloc(8),Buffer.from([1,0]),record,key,v]);child.writeBigUInt64LE(BigInt(child.length),16);
 let ne=Buffer.concat([original.subarray(ext.start,ext.start+ext.size),child]);ne.writeBigUInt64LE(BigInt(ne.length),16);ne.writeUInt32LE(child.length,42);
 let np=Buffer.alloc(pad.size-child.length);original.copy(np,0,pad.start,pad.start+16);np.writeBigUInt64LE(BigInt(np.length),16);
 let objs=parsed.objects.map(o=>o.start===ext.start?ne:o.start===pad.start?np:original.subarray(o.start,o.start+o.size));let withNested=Buffer.concat([original.subarray(0,30),...objs,original.subarray(headerSize)]);
 let headerNested=H.replaceText(withNested.subarray(0,headerSize),'Title','new nested title',withNested.length,withNested.subarray(headerSize,headerSize+50));let nestedEdited=Buffer.concat([Buffer.from(headerNested),withNested.subarray(headerSize)]);
 await I.verifyStreams(new Reader(withNested,'x'),new Reader(nestedEdited,'y'),probe,['Title']);
 let swapped=Buffer.from(nestedEdited),newScan=H.scan(swapped.subarray(0,headerSize),swapped.length,swapped.subarray(headerSize,headerSize+50)),newExt=newScan.objects.find(o=>o.id===H.EXTENSION);Buffer.from(H.META,'hex').copy(swapped,newExt.start+46);
 await assert.rejects(()=>I.verifyStreams(new Reader(withNested,'x'),new Reader(swapped,'y'),probe,['Title']),/extension object changed/);
 let edScan=H.scan(edited.subarray(0,headerSize),edited.length,edited.subarray(headerSize,headerSize+50));let titleEntry=edScan.entries.find(e=>e.name.toLowerCase()==='title'&&H.isAbsentContent(edited,e)===false&&edScan.objects.find(o=>o.start===e.objectAt)?.id===H.CONTENT);let content=edScan.objects.find(o=>o.start===titleEntry.objectAt),padEd=edScan.padding;
 let titleDropped=Buffer.concat([edited.subarray(content.start,titleEntry.start),edited.subarray(titleEntry.start+titleEntry.size,content.start+content.size)]);titleDropped.writeUInt16LE(0,titleEntry.lengthAt-content.start);titleDropped.writeBigUInt64LE(BigInt(titleDropped.length),16);
 let padded=Buffer.alloc(padEd.size+titleEntry.size);edited.copy(padded,0,padEd.start,padEd.start+16);padded.writeBigUInt64LE(BigInt(padded.length),16);
 let filtered=edScan.objects.map(o=>o.start===content.start?titleDropped:o.start===padEd.start?padded:edited.subarray(o.start,o.start+o.size));let missingTitle=Buffer.concat([edited.subarray(0,30),...filtered,edited.subarray(headerSize)]);
 await assert.rejects(()=>I.verifyStreams(new Reader(original,'a'),new Reader(missingTitle,'b'),probe,['Title']),/edited metadata presence changed/);
 let altered=Buffer.from(edited);let alteredScan=H.scan(altered.subarray(0,headerSize),altered.length,altered.subarray(headerSize,headerSize+50));let unknown=alteredScan.entries.find(e=>e.name==='WM/TestUnknown');altered[unknown.start]^=1;await assert.rejects(()=>I.verifyStreams(new Reader(original,'a'),new Reader(altered,'b'),probe,['Title']),/unedited metadata changed/);
 let bad=Buffer.from(edited);bad[headerSize+60]^=1;await assert.rejects(()=>I.verifyStreams(new Reader(original,'a'),new Reader(bad,'b'),probe,['Title']),/Data object bytes differ/);
 bad=Buffer.from(edited);let s=H.scan(bad.subarray(0,headerSize),bad.length,bad.subarray(headerSize,headerSize+50));let stream=s.objects.find(x=>x.id===H.STREAM);bad[stream.start+24+62]^=1;await assert.rejects(()=>I.verifyStreams(new Reader(original,'a'),new Reader(bad,'b'),probe,['Title']),/nonmetadata header object changed/);
 await assert.rejects(()=>I.verifyStreams(new Reader(original,'same'),new Reader(edited,'same'),probe,['Title']),/identities may alias/);
 await assert.rejects(()=>I.verifyStreams(new Reader(original,'a',1),new Reader(edited,'b'),probe,['Title']),/read retry budget/);
 let fail=new Reader(original,'a');fail.failAt=3;await assert.rejects(()=>I.verifyStreams(fail,new Reader(edited,'b'),probe,['Title']),/fake I\/O/);
 let mixed={async inspect(s){return s.token==='a'?{durationMs:1000,channels:1,sampleRate:44100}:{durationMs:1001,channels:1,sampleRate:44100}}};await assert.rejects(()=>I.verifyStreams(new Reader(original,'a'),new Reader(edited,'b'),mixed,['Title']),/media attributes/);
 let mutated=new Reader(original,'a'),p={async inspect(s){if(s===mutated)s.token='changed';return {durationMs:1000,channels:1,sampleRate:44100}}};await assert.rejects(()=>I.verifyStreams(mutated,new Reader(edited,'b'),p,['Title']),/changed during verification/);
 openMap={source:original,target:edited};opened=[];await S.verifyAsfStagedIntegrity('source','target',['Title']);assert(opened.every(x=>x.closed));
 opened=[];await assert.rejects(()=>S.verifyAsfStagedIntegrity('source','missing'),/open failed/);assert.equal(opened.length,1);assert(opened[0].closed);
 openMap['close-fail']=edited;opened=[];await assert.rejects(()=>S.verifyAsfStagedIntegrity('source','close-fail',['Title']),/staged close failed/);assert(opened.every(x=>x.closed));
 await assert.rejects(()=>S.verifyAsfStagedIntegrity('source','source'),/must differ/);
 console.log('PASS bounded staged verification: real fixture bytes, short reads, aliases, header/audio corruption, media mismatch, mutations and close failure (mock I/O + probe)');
})().catch(e=>{console.error(e);process.exitCode=1});




