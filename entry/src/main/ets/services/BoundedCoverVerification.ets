// SPDX-License-Identifier: GPL-3.0-only
/* Bounded ImageKit cover verification. GPL-3.0-only. */
import { image } from '@kit.ImageKit';

class OpenedCover {
  source: image.ImageSource;
  pixelMap: image.PixelMap;
  width: number;
  height: number;
  constructor(source: image.ImageSource, pixelMap: image.PixelMap, width: number, height: number) {
    this.source = source; this.pixelMap = pixelMap; this.width = width; this.height = height;
  }
}

/**
 * Restrictive experimental verifier. Full image decode and every-pixel readback.
 * These limits bound caller-provided data and PixelMap dimensions, not internal
 * native codec scratch space. Decoding must be tested on supported devices.
 */
export class BoundedCoverVerification {
  static readonly MAX_ENCODED: number = 2 * 1024 * 1024;
  static readonly MAX_EDGE: number = 1024;
  static readonly MAX_PIXELS: number = 1024 * 1024;
  static readonly MAX_PIXEL_BYTES: number = 8 * 1024 * 1024;
  static readonly BLOCK_ROWS: number = 16;

  private static require(condition: boolean, message: string): void {
    if (!condition) { throw new Error(message); }
  }
  private static validSize(info: image.ImageInfo): void {
    const width: number = info.size.width; const height: number = info.size.height;
    BoundedCoverVerification.require(Number.isInteger(width) && Number.isInteger(height) && width > 0 && height > 0 &&
      width <= BoundedCoverVerification.MAX_EDGE && height <= BoundedCoverVerification.MAX_EDGE &&
      width * height <= BoundedCoverVerification.MAX_PIXELS && !info.isHdr, 'unsupported or oversized cover');
  }
  private static async open(bytes: Uint8Array, mime: string): Promise<OpenedCover> {
    BoundedCoverVerification.require((mime === 'image/jpeg' || mime === 'image/png') && bytes.length > 0 &&
      bytes.length <= BoundedCoverVerification.MAX_ENCODED, 'invalid cover input');
    const copy: ArrayBuffer = new ArrayBuffer(bytes.length); new Uint8Array(copy).set(bytes);
    let source: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      source = image.createImageSource(copy);
      const sourceInfo: image.ImageInfo = await source.getImageInfo();
      BoundedCoverVerification.validSize(sourceInfo);
      BoundedCoverVerification.require(sourceInfo.mimeType === mime, 'cover MIME mismatch');
      const opts: image.DecodingOptions = { desiredPixelFormat: image.PixelMapFormat.BGRA_8888 };
      pixelMap = await source.createPixelMap(opts);
      const decoded: image.ImageInfo = await pixelMap.getImageInfo();
      BoundedCoverVerification.validSize(decoded);
      BoundedCoverVerification.require(decoded.size.width === sourceInfo.size.width &&
        decoded.size.height === sourceInfo.size.height && decoded.pixelFormat === image.PixelMapFormat.BGRA_8888,
        'cover decode differs from source dimensions or format');
      const stride: number = pixelMap.getBytesNumberPerRow(); const total: number = pixelMap.getPixelBytesNumber();
      BoundedCoverVerification.require(Number.isInteger(stride) && Number.isInteger(total) &&
        stride >= decoded.size.width * 4 && total >= stride * decoded.size.height &&
        total <= BoundedCoverVerification.MAX_PIXEL_BYTES, 'unsupported pixel buffer');
      return new OpenedCover(source, pixelMap, decoded.size.width, decoded.size.height);
    } catch (error) {
      if (pixelMap !== undefined) { try { await pixelMap.release(); } catch (_e) {} }
      if (source !== undefined) { try { await source.release(); } catch (_e) {} }
      throw new Error('cover decode failed: ' + String(error));
    }
  }
  private static async close(opened: OpenedCover): Promise<void> {
    let releaseFailed: boolean = false;
    try { await opened.pixelMap.release(); } catch (_e) { releaseFailed = true; }
    try { await opened.source.release(); } catch (_e) { releaseFailed = true; }
    if (releaseFailed) { throw new Error('cover resource release failed'); }
  }
  private static area(width: number, y: number, height: number, buffer: ArrayBuffer): image.PositionArea {
    return { pixels: buffer, offset: 0, stride: width * 4,
      region: { x: 0, y: y, size: { width: width, height: height } } };
  }
  /** Decode and read every pixel; must finish before using encoded bytes. */
  static async validateCover(encoded: Uint8Array, mime: string): Promise<Uint8Array> {
    BoundedCoverVerification.require(encoded.length > 0 && encoded.length <= BoundedCoverVerification.MAX_ENCODED, 'invalid cover input');
    const checked: Uint8Array = encoded.slice();
    const cover: OpenedCover = await BoundedCoverVerification.open(checked, mime);
    try {
      for (let y: number = 0; y < cover.height; y += BoundedCoverVerification.BLOCK_ROWS) {
        const rows: number = Math.min(BoundedCoverVerification.BLOCK_ROWS, cover.height - y);
        const buffer: ArrayBuffer = new ArrayBuffer(cover.width * rows * 4);
        await cover.pixelMap.readPixels(BoundedCoverVerification.area(cover.width, y, rows, buffer));
      }
      return checked;
    } finally { await BoundedCoverVerification.close(cover); }
  }
  /** Decode expected image and the bytes read back from the staged file, then compare every pixel. */
  static async assertCoverRoundTrip(expected: Uint8Array, written: Uint8Array, mime: string): Promise<void> {
    BoundedCoverVerification.require(expected.length > 0 && expected.length <= BoundedCoverVerification.MAX_ENCODED &&
      written.length > 0 && written.length <= BoundedCoverVerification.MAX_ENCODED, 'invalid cover input');
    const expectedCopy: Uint8Array = expected.slice(); const writtenCopy: Uint8Array = written.slice();
    const a: OpenedCover = await BoundedCoverVerification.open(expectedCopy, mime);
    let b: OpenedCover | undefined = undefined;
    try {
      b = await BoundedCoverVerification.open(writtenCopy, mime);
      BoundedCoverVerification.require(a.width === b.width && a.height === b.height, 'cover dimensions changed');
      for (let y: number = 0; y < a.height; y += BoundedCoverVerification.BLOCK_ROWS) {
        const rows: number = Math.min(BoundedCoverVerification.BLOCK_ROWS, a.height - y);
        const left: ArrayBuffer = new ArrayBuffer(a.width * rows * 4);
        const right: ArrayBuffer = new ArrayBuffer(a.width * rows * 4);
        await a.pixelMap.readPixels(BoundedCoverVerification.area(a.width, y, rows, left));
        await b.pixelMap.readPixels(BoundedCoverVerification.area(b.width, y, rows, right));
        const x: Uint8Array = new Uint8Array(left); const z: Uint8Array = new Uint8Array(right);
        for (let i: number = 0; i < x.length; i++) {
          BoundedCoverVerification.require(x[i] === z[i], 'cover pixels changed');
        }
      }
      BoundedCoverVerification.require(expectedCopy.length === writtenCopy.length, 'encoded cover length changed');
      for (let i: number = 0; i < expectedCopy.length; i++) {
        BoundedCoverVerification.require(expectedCopy[i] === writtenCopy[i], 'encoded cover changed');
      }
    } finally {
      try { if (b !== undefined) { await BoundedCoverVerification.close(b); } }
      finally { await BoundedCoverVerification.close(a); }
    }
  }
}

