// Node-only mock of @kit.ImageKit: exercises orchestration, not actual decoding.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require('typescript');
const p=require('node:path').join(__dirname,'../../entry/src/main/ets/services/BoundedCoverVerification.ets');
const js=ts.transpileModule(fs.readFileSync(p,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
const state={created:0,sourceReleased:0,mapReleased:0,reads:0,failRead:false,failRelease:false};
const FMT=3;
const image={PixelMapFormat:{BGRA_8888:FMT},createImageSource(buffer){
 state.created++;const bytes=new Uint8Array(buffer);const width=bytes[0]+256*bytes[1],height=bytes[2]+256*bytes[3];
 const info={size:{width,height},mimeType:'image/png',isHdr:false,pixelFormat:FMT};
 return {async getImageInfo(){return info},async release(){state.sourceReleased++},async createPixelMap(){
   if(bytes.length<4+width*height*4)throw Error('fake truncated');
   return {async getImageInfo(){return info},getBytesNumberPerRow(){return width*4},getPixelBytesNumber(){return width*height*4},
     async readPixels(area){state.reads++;if(state.failRead)throw Error('fake read failure');const dst=new Uint8Array(area.pixels);for(let y=0;y<area.region.size.height;y++){const offset=4+(area.region.y+y)*width*4;dst.set(bytes.subarray(offset,offset+width*4),y*area.stride)}},
     async release(){state.mapReleased++;if(state.failRelease)throw Error('fake release failure')}};
 }}
}};
const m={exports:{}};vm.runInThisContext('(function(exports,module,require){'+js+'\n})')(m.exports,m,(id)=>{assert.equal(id,'@kit.ImageKit');return {image}});const C=m.exports.BoundedCoverVerification;
function fake(w,h){const b=new Uint8Array(4+w*h*4);b[0]=w&255;b[1]=w>>>8;b[2]=h&255;b[3]=h>>>8;for(let i=4;i<b.length;i++)b[i]=i%251;return b}
(async()=>{
 const a=fake(3,20);const snapshot=await C.validateCover(a,'image/png');assert.notEqual(snapshot,a);assert.deepEqual(snapshot,a);assert.equal(state.reads,2);assert.equal(state.sourceReleased,1);assert.equal(state.mapReleased,1);
 await C.assertCoverRoundTrip(a,a.slice(),'image/png');assert.equal(state.reads,6);assert.equal(state.sourceReleased,3);assert.equal(state.mapReleased,3);
 let b=a.slice();b[10]^=1;await assert.rejects(()=>C.assertCoverRoundTrip(a,b,'image/png'),/pixels changed/);
 await assert.rejects(()=>C.validateCover(a,'image/jpeg'),/MIME mismatch/);
 await assert.rejects(()=>C.validateCover(new Uint8Array([0xff,0xff,1,0]),'image/png'),/oversized/);
 await assert.rejects(()=>C.validateCover(a.slice(0,-1),'image/png'),/fake truncated/);
 state.failRead=true;await assert.rejects(()=>C.validateCover(a,'image/png'),/fake read failure/);state.failRead=false;
 state.failRelease=true;await assert.rejects(()=>C.validateCover(a,'image/png'),/resource release failed/);state.failRelease=false;
 assert.equal(state.created,state.sourceReleased);console.log('PASS mocked ImageKit: bounds, full region iteration, pixel mismatch, MIME/truncation, read failure and resource cleanup');
})().catch(e=>{console.error(e);process.exitCode=1});
