// Mock ImageKit follows SDK rule: readPixels(area) emits BGRA even for RGBA inputs.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require('typescript');
const js=ts.transpileModule(fs.readFileSync(__dirname+'/../../entry/src/main/ets/services/AsfPixelMapEncoder.ets','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
const F={RGBA_8888:3,BGRA_8888:4,RGB_565:2},A={UNKNOWN:0,OPAQUE:1,PREMUL:2,UNPREMUL:3},C={UNKNOWN:0,DISPLAY_P3:3,SRGB:4,CUSTOM:5};
const state={input:null,packed:null,outAlpha:2,outColor:4,decodedChange:false,packError:false,releaseError:false,releaseCount:0};
class FakeMap {constructor(raw,format=F.RGBA_8888,alpha=A.PREMUL,color=C.SRGB){this.raw=Buffer.from(raw);this.format=format;this.alpha=alpha;this.color=color;this.width=2;this.height=1;this.hdr=false;this.stride=8;this.total=8;this.reads=0;this.changeOnSecond=false;this.colorThrow=false}async getImageInfo(){return {size:{width:this.width,height:this.height},pixelFormat:this.format,alphaType:this.alpha,isHdr:this.hdr}}getBytesNumberPerRow(){return this.stride}getPixelBytesNumber(){return this.total}getColorSpace(){if(this.colorThrow)throw Error('private data');return{getColorSpaceName:()=>this.color}}async readPixels(area){this.reads++;if(this.changeOnSecond&&this.reads===2)this.raw[0]^=1;let out=new Uint8Array(area.pixels);for(let i=0;i<this.raw.length;i+=4){if(this.format===F.RGBA_8888){out[i]=this.raw[i+2];out[i+1]=this.raw[i+1];out[i+2]=this.raw[i];out[i+3]=this.raw[i+3]}else{out.set(this.raw.subarray(i,i+4),i)}}}async release(){state.releaseCount++;if(state.releaseError)throw Error('release error')}}
const image={PixelMapFormat:F,AlphaType:A,createImagePacker(){return{async packToData(input,opts){assert.equal(opts.format,'image/png');if(state.packError)throw Error('pack failed');let buf=new ArrayBuffer(8);await input.readPixels({pixels:buf,offset:0,stride:8,region:{x:0,y:0,size:{width:2,height:1}}});state.packed=Buffer.from(buf);return Uint8Array.from([1,2,3]).buffer},async release(){state.releaseCount++;if(state.releaseError)throw Error('release error')}}},createImageSource(){return{async createPixelMap(){let b=Buffer.from(state.packed);if(state.decodedChange)b[0]^=1;return new FakeMap(b,F.BGRA_8888,state.outAlpha,state.outColor)},async release(){state.releaseCount++;if(state.releaseError)throw Error('release error')}}}};
const bounded={async validateCover(b,mime){assert.equal(mime,'image/png');return new Uint8Array(b)}};
const deps={'@kit.ImageKit':{image},'@kit.ArkGraphics2D':{colorSpaceManager:{ColorSpace:C}},'./BoundedCoverVerification':{BoundedCoverVerification:bounded}};const m={exports:{}};vm.runInThisContext('(function(exports,module,require){'+js+'\n})')(m.exports,m,id=>deps[id]||{});const E=m.exports.AsfPixelMapEncoder;
(async()=>{

 class TallMap extends FakeMap {
  constructor(format, mutateThird=false) { super(Buffer.alloc(2*33*4),format); this.height=33; this.stride=12; this.total=this.stride*this.height; this.mutateThird=mutateThird;
   for(let y=0;y<33;y++) for(let x=0;x<2;x++){let i=(y*2+x)*4,r=(y*7+x)%256,g=(y*3+x)%256,b=(y*11+x)%256; this.raw.set(format===F.RGBA_8888?[r,g,b,255]:[b,g,r,255],i)}
  }
  async readPixels(area) { this.reads++; if(this.mutateThird&&this.reads===3)this.raw[(32*2)*4]^=1; const out=new Uint8Array(area.pixels); const y0=area.region.y, h=area.region.size.height;
   for(let y=0;y<h;y++)for(let x=0;x<2;x++){let src=((y+y0)*2+x)*4,dst=area.offset+y*area.stride+x*4;if(this.format===F.RGBA_8888){out[dst]=this.raw[src+2];out[dst+1]=this.raw[src+1];out[dst+2]=this.raw[src];out[dst+3]=this.raw[src+3]}else out.set(this.raw.subarray(src,src+4),dst)}
  }
 }
 let tallLeft=new TallMap(F.RGBA_8888), tallRight=new TallMap(F.BGRA_8888);assert(await E.samePixels(tallLeft,tallRight));assert.equal(tallLeft.reads,3);assert.equal(tallRight.reads,3);
 tallLeft=new TallMap(F.RGBA_8888);tallRight=new TallMap(F.BGRA_8888,true);assert.equal(await E.samePixels(tallLeft,tallRight),false);
 const rgba=Buffer.from([230,20,3,255,10,40,200,255]),bgra=Buffer.from([3,20,230,255,200,40,10,255]);
 let input=new FakeMap(rgba),out=await E.encode(input);assert.deepEqual(Buffer.from(out),Buffer.from([1,2,3]));assert.equal(state.releaseCount,3);
 assert(await E.samePixels(new FakeMap(rgba),new FakeMap(bgra,F.BGRA_8888)));
 let swapped=new FakeMap(Buffer.from([230,20,3,255,200,40,10,255]),F.BGRA_8888);await assert.rejects(()=>E.comparePixels(new FakeMap(rgba),swapped),/pixels or color semantics differ/);
 assert(await E.samePixels(new FakeMap(rgba,F.RGBA_8888,A.OPAQUE),new FakeMap(bgra,F.BGRA_8888,A.PREMUL)));
 let transparent=Buffer.from([10,20,30,128,0,0,0,0]),transBgra=Buffer.from([30,20,10,128,0,0,0,0]);assert.equal(await E.samePixels(new FakeMap(transparent,F.RGBA_8888,A.PREMUL),new FakeMap(transBgra,F.BGRA_8888,A.UNPREMUL)),false);
 state.outAlpha=A.UNPREMUL;await assert.rejects(()=>E.encode(new FakeMap(transparent,F.RGBA_8888,A.PREMUL)),/alpha semantics changed/);state.outAlpha=A.PREMUL;
 let bad=new FakeMap(rgba);bad.alpha=A.UNKNOWN;await assert.rejects(()=>E.encode(bad),/alpha=0/);bad=new FakeMap(rgba);bad.hdr=undefined;await assert.rejects(()=>E.encode(bad),/hdr=undefined/);bad=new FakeMap(rgba);bad.hdr=true;await assert.rejects(()=>E.encode(bad),/hdr=true/);
 for(const space of [C.UNKNOWN,undefined]){bad=new FakeMap(rgba);bad.color=space;await assert.rejects(()=>E.encode(bad),/unsupported cover color space/)}
 bad=new FakeMap(rgba);bad.color=C.CUSTOM;await assert.rejects(()=>E.encode(bad),/unsupported custom cover color space \[input\]/);
 await assert.rejects(()=>E.samePixels(new FakeMap(rgba,F.RGBA_8888,A.PREMUL,C.CUSTOM),new FakeMap(bgra,F.BGRA_8888,A.PREMUL,C.CUSTOM)),/unsupported custom cover color space \[left\]/);
 bad=new FakeMap(rgba);bad.colorThrow=true;await assert.rejects(()=>E.encode(bad),e=>String(e).includes('cover color space unavailable')&&!String(e).includes('private data'));
 assert.equal(await E.samePixels(new FakeMap(rgba,F.RGBA_8888,A.PREMUL,C.SRGB),new FakeMap(bgra,F.BGRA_8888,A.PREMUL,C.DISPLAY_P3)),false);
 state.outColor=C.DISPLAY_P3;await assert.rejects(()=>E.encode(new FakeMap(rgba)),/color space changed/);await E.encode(new FakeMap(rgba,F.RGBA_8888,A.PREMUL,C.DISPLAY_P3));state.outColor=C.SRGB;
 bad=new FakeMap(rgba,F.RGB_565);await assert.rejects(()=>E.encode(bad),/format=2/);bad=new FakeMap(rgba);bad.width=1025;await assert.rejects(()=>E.encode(bad),/width=1025/);bad=new FakeMap(rgba);bad.stride=7;await assert.rejects(()=>E.encode(bad),/unsupported cover buffer/);
 bad=new FakeMap(transparent,F.RGBA_8888,A.OPAQUE);await assert.rejects(()=>E.encode(bad),/opaque cover reports nonopaque/);
 let changing=new FakeMap(rgba);changing.changeOnSecond=true;await assert.rejects(()=>E.encode(changing),/cover changed during encoding or lost pixels/);
 state.decodedChange=true;await assert.rejects(()=>E.encode(new FakeMap(rgba)),/lost pixels/);state.decodedChange=false;
 state.packError=true;let before=state.releaseCount;await assert.rejects(()=>E.encode(new FakeMap(rgba)),/pack failed/);assert.equal(state.releaseCount,before+1);state.packError=false;
 state.releaseError=true;await assert.rejects(()=>E.encode(new FakeMap(rgba)),/resource release failed/);state.releaseError=false;
 console.log('PASS mocked ImageKit: RGBA/BGRA, 33-row chunks and padding, alpha/color guards, bounds, mutation and resource failures');
})().catch(e=>{console.error(e);process.exitCode=1});
