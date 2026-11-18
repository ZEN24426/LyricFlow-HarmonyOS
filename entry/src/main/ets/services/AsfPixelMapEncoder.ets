// SPDX-License-Identifier: GPL-3.0-only
/* Bounded PixelMap -> PNG experiment. Caller retains ownership of input. */
import { image } from '@kit.ImageKit';
import { colorSpaceManager } from '@kit.ArkGraphics2D';
import { BoundedCoverVerification } from './BoundedCoverVerification';
export class AsfPixelMapEncoder {
  static readonly MAX_EDGE: number=1024;
  static readonly MAX_PIXELS: number=1024*1024;
  static readonly MAX_ENCODED: number=128*1024;
  static readonly BLOCK_ROWS: number=16;
  private static ok(x: boolean, message: string): void { if(!x) { throw new Error(message); } }
  private static area(width: number, y: number, rows: number, buffer: ArrayBuffer): image.PositionArea {
    return { pixels: buffer, offset: 0, stride: width*4, region: { x: 0, y: y, size: { width: width, height: rows } } };
  }
  private static info(info: image.ImageInfo, stage: string): void {
    const valid: boolean=Number.isInteger(info.size.width) && Number.isInteger(info.size.height) &&
      info.size.width>0 && info.size.height>0 && info.size.width<=AsfPixelMapEncoder.MAX_EDGE &&
      info.size.height<=AsfPixelMapEncoder.MAX_EDGE && info.size.width*info.size.height<=AsfPixelMapEncoder.MAX_PIXELS &&
      info.isHdr===false && (info.pixelFormat===image.PixelMapFormat.BGRA_8888 || info.pixelFormat===image.PixelMapFormat.RGBA_8888) &&
      (info.alphaType===image.AlphaType.OPAQUE || info.alphaType===image.AlphaType.PREMUL || info.alphaType===image.AlphaType.UNPREMUL);
    if(!valid) {
      throw new Error('unsupported cover info ['+stage+'] width='+String(info.size.width)+' height='+String(info.size.height)+
        ' format='+String(info.pixelFormat)+' alpha='+String(info.alphaType)+' hdr='+String(info.isHdr));
    }
  }
  private static space(map: image.PixelMap, stage: string): colorSpaceManager.ColorSpace {
    let value: colorSpaceManager.ColorSpace;
    try { value=map.getColorSpace().getColorSpaceName(); }
    catch (_error) { throw new Error('cover color space unavailable ['+stage+']'); }
    AsfPixelMapEncoder.ok(value!==colorSpaceManager.ColorSpace.CUSTOM,
      'unsupported custom cover color space ['+stage+']: color profile equivalence cannot be verified');
    AsfPixelMapEncoder.ok(value===colorSpaceManager.ColorSpace.SRGB || value===colorSpaceManager.ColorSpace.DISPLAY_P3,
      'unsupported cover color space ['+stage+'] value='+String(value));
    return value;
  }
  private static buffer(map: image.PixelMap, info: image.ImageInfo): void {
    const stride: number=map.getBytesNumberPerRow(); const total: number=map.getPixelBytesNumber();
    AsfPixelMapEncoder.ok(Number.isSafeInteger(stride) && Number.isSafeInteger(total) && stride>=info.size.width*4 &&
      total>=stride*info.size.height && total<=8*1024*1024,'unsupported cover buffer');
  }
  /** readPixels(area) supplies BGRA_8888 bytes for either supported input format. */
  static async samePixels(left: image.PixelMap, right: image.PixelMap): Promise<boolean> {
    const a: image.ImageInfo=await left.getImageInfo(); const b: image.ImageInfo=await right.getImageInfo();
    AsfPixelMapEncoder.info(a,'left'); AsfPixelMapEncoder.info(b,'right');
    const leftSpace: colorSpaceManager.ColorSpace=AsfPixelMapEncoder.space(left,'left');
    const rightSpace: colorSpaceManager.ColorSpace=AsfPixelMapEncoder.space(right,'right');
    if(a.size.width!==b.size.width || a.size.height!==b.size.height || leftSpace!==rightSpace) return false;
    AsfPixelMapEncoder.buffer(left,a); AsfPixelMapEncoder.buffer(right,b);
    const width: number=a.size.width; const height: number=a.size.height; let opaque: boolean=true;
    for(let y: number=0;y<height;y+=AsfPixelMapEncoder.BLOCK_ROWS) {
      const rows: number=Math.min(AsfPixelMapEncoder.BLOCK_ROWS,height-y); const n: number=width*rows*4;
      const aa: ArrayBuffer=new ArrayBuffer(n); const bb: ArrayBuffer=new ArrayBuffer(n);
      await left.readPixels(AsfPixelMapEncoder.area(width,y,rows,aa)); await right.readPixels(AsfPixelMapEncoder.area(width,y,rows,bb));
      const x: Uint8Array=new Uint8Array(aa); const z: Uint8Array=new Uint8Array(bb);
      for(let i: number=0;i<n;i++) { if(x[i]!==z[i]) return false; if(i%4===3 && x[i]!==255) opaque=false; }
    }
    AsfPixelMapEncoder.ok((a.alphaType!==image.AlphaType.OPAQUE && b.alphaType!==image.AlphaType.OPAQUE) || opaque,
      'opaque cover reports nonopaque pixels');
    return a.alphaType===b.alphaType || opaque;
  }
  static async comparePixels(left: image.PixelMap, right: image.PixelMap): Promise<void> {
    AsfPixelMapEncoder.ok(await AsfPixelMapEncoder.samePixels(left,right),'cover pixels or color semantics differ');
  }
  static async encode(input: image.PixelMap): Promise<Uint8Array> {
    const info: image.ImageInfo=await input.getImageInfo(); AsfPixelMapEncoder.info(info,'input');
    const sourceSpace: colorSpaceManager.ColorSpace=AsfPixelMapEncoder.space(input,'input'); AsfPixelMapEncoder.buffer(input,info);
    const width: number=info.size.width; const height: number=info.size.height;
    const initial: Uint8Array=new Uint8Array(width*height*4); let opaque: boolean=true;
    for(let y: number=0;y<height;y+=AsfPixelMapEncoder.BLOCK_ROWS) {
      const rows: number=Math.min(AsfPixelMapEncoder.BLOCK_ROWS,height-y); const area: ArrayBuffer=new ArrayBuffer(width*rows*4);
      await input.readPixels(AsfPixelMapEncoder.area(width,y,rows,area)); const pixels: Uint8Array=new Uint8Array(area);
      for(let i: number=3;i<pixels.length;i+=4) if(pixels[i]!==255) opaque=false;
      initial.set(pixels,y*width*4);
    }
    AsfPixelMapEncoder.ok(info.alphaType!==image.AlphaType.OPAQUE || opaque,'opaque cover reports nonopaque pixels');
    const packer: image.ImagePacker=image.createImagePacker(); let source: image.ImageSource|undefined=undefined; let decoded: image.PixelMap|undefined=undefined;
    try {
      const options: image.PackingOption={ format: 'image/png', quality: 100, bufferSize: AsfPixelMapEncoder.MAX_ENCODED };
      const raw: ArrayBuffer=await packer.packToData(input,options);
      AsfPixelMapEncoder.ok(raw.byteLength>0 && raw.byteLength<=AsfPixelMapEncoder.MAX_ENCODED,'encoded cover too large');
      const checked: Uint8Array=await BoundedCoverVerification.validateCover(new Uint8Array(raw),'image/png');
      const copy: ArrayBuffer=new ArrayBuffer(checked.length); new Uint8Array(copy).set(checked); source=image.createImageSource(copy);
      const opts: image.DecodingOptions={ desiredPixelFormat: image.PixelMapFormat.BGRA_8888 }; decoded=await source.createPixelMap(opts);
      const outputInfo: image.ImageInfo=await decoded.getImageInfo(); AsfPixelMapEncoder.info(outputInfo,'decoded'); AsfPixelMapEncoder.buffer(decoded,outputInfo);
      AsfPixelMapEncoder.ok(outputInfo.size.width===width && outputInfo.size.height===height,'encoded cover dimensions changed');
      AsfPixelMapEncoder.ok(AsfPixelMapEncoder.space(decoded,'decoded')===sourceSpace,'cover color space changed');
      AsfPixelMapEncoder.ok(info.alphaType===outputInfo.alphaType || opaque,'cover alpha semantics changed');
      const currentInfo: image.ImageInfo=await input.getImageInfo(); AsfPixelMapEncoder.info(currentInfo,'input_recheck');
      AsfPixelMapEncoder.ok(currentInfo.size.width===width && currentInfo.size.height===height && currentInfo.pixelFormat===info.pixelFormat &&
        currentInfo.alphaType===info.alphaType && AsfPixelMapEncoder.space(input,'input_recheck')===sourceSpace,'cover changed during encoding');
      for(let y: number=0;y<height;y+=AsfPixelMapEncoder.BLOCK_ROWS) {
        const rows: number=Math.min(AsfPixelMapEncoder.BLOCK_ROWS,height-y); const n: number=width*rows*4;
        const expectedAgain: ArrayBuffer=new ArrayBuffer(n); const actual: ArrayBuffer=new ArrayBuffer(n);
        await input.readPixels(AsfPixelMapEncoder.area(width,y,rows,expectedAgain));
        await decoded.readPixels(AsfPixelMapEncoder.area(width,y,rows,actual));
        const current: Uint8Array=new Uint8Array(expectedAgain); const result: Uint8Array=new Uint8Array(actual);
        for(let i: number=0;i<n;i++) {
          const first: number=initial[y*width*4+i];
          AsfPixelMapEncoder.ok(current[i]===first && result[i]===first,'cover changed during encoding or lost pixels');
        }
      }
      return checked;
    } finally {
      let failed: boolean=false;
      if(decoded!==undefined) { try { await decoded.release(); } catch (_error) { failed=true; } }
      if(source!==undefined) { try { await source.release(); } catch (_error) { failed=true; } }
      try { await packer.release(); } catch (_error) { failed=true; }
      if(failed) { throw new Error('cover encoder resource release failed'); }
    }
  }
}
