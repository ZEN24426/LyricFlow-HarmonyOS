import { image } from '@kit.ImageKit';
import { AudioMetadata, AudioMetadataWriter } from './AudioMetadataTypes';

/** The verified result must contain every field the writer was asked to set. */
function assertText(name: string, expected: string | undefined, actual: string): void {
  if (expected !== undefined && actual !== expected) {
    throw new Error('音频标签回读不一致：' + name);
  }
}

function normalizedNewlines(value: string): string {
  return value.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
}

function assertLyrics(expected: string | undefined, actual: string): void {
  if (expected !== undefined &&
      (actual === undefined || actual === null || normalizedNewlines(actual) !== normalizedNewlines(expected))) {
    throw new Error('音频标签回读不一致：歌词');
  }
}

function assertNumber(name: string, expected: number | undefined, actual: number): void {
  if (expected !== undefined && (!Number.isFinite(expected) || actual !== expected)) {
    throw new Error('音频标签回读不一致：' + name);
  }
}

interface CoverPixels {
  width: number;
  height: number;
  stride: number;
  data: Uint8Array;
}

/**
 * Convert both PixelMaps through lossless PNG to the same 8-bit RGBA layout.
 * Comparing encoded PNG bytes is not valid: metadata and compression may differ.
 * Fail closed for HDR, unsupported formats, unreasonably large images, or errors.
 */
async function coverPixels(input: image.PixelMap): Promise<CoverPixels> {
  const original: image.ImageInfo = await input.getImageInfo();
  const w: number = original.size.width;
  const h: number = original.size.height;
  if (!Number.isInteger(w) || !Number.isInteger(h) || w <= 0 || h <= 0 || w * h > 16777216) {
    throw new Error('封面尺寸无效或过大，无法验证。');
  }
  if (original.isHdr || (original.pixelFormat !== image.PixelMapFormat.RGBA_8888 &&
      original.pixelFormat !== image.PixelMapFormat.BGRA_8888 &&
      original.pixelFormat !== image.PixelMapFormat.ARGB_8888 &&
      original.pixelFormat !== image.PixelMapFormat.RGB_565 &&
      original.pixelFormat !== image.PixelMapFormat.RGB_888)) {
    throw new Error('封面的像素格式或 HDR 类型暂不支持精确验证。');
  }
  const packer: image.ImagePacker = image.createImagePacker();
  let src: image.ImageSource | undefined = undefined;
  let decoded: image.PixelMap | undefined = undefined;
  try {
    const options: image.PackingOption = { format: 'image/png', quality: 100, bufferSize: 134217728 };
    const png: ArrayBuffer = await packer.packToData(input, options);
    if (png.byteLength === 0) throw new Error('封面编码结果为空。');
    src = image.createImageSource(png);
    const decodeOptions: image.DecodingOptions = { desiredPixelFormat: image.PixelMapFormat.RGBA_8888 };
    decoded = await src.createPixelMap(decodeOptions);
    const decodedInfo: image.ImageInfo = await decoded.getImageInfo();
    if (decodedInfo.size.width !== w || decodedInfo.size.height !== h ||
        decodedInfo.pixelFormat !== image.PixelMapFormat.RGBA_8888 || decodedInfo.isHdr) {
      throw new Error('封面解码后的尺寸或像素格式不一致。');
    }
    const stride: number = decoded.getBytesNumberPerRow();
    const length: number = decoded.getPixelBytesNumber();
    if (!Number.isInteger(stride) || !Number.isInteger(length) || stride < w * 4 ||
        length < stride * h || length > 134217728) {
      throw new Error('无法可靠读取封面像素。');
    }
    const data: ArrayBuffer = new ArrayBuffer(length);
    await decoded.readAllPixelsToBuffer(data);
    return { width: w, height: h, stride: stride, data: new Uint8Array(data) };
  } finally {
    if (decoded !== undefined) {
      try { await decoded.release(); } catch (_error) {}
    }
    if (src !== undefined) {
      try { await src.release(); } catch (_error) {}
    }
    try { await packer.release(); } catch (_error) {}
  }
}

async function assertCover(expected: image.PixelMap | undefined, actual: image.PixelMap | undefined): Promise<void> {
  if (expected === undefined) return;
  if (actual === undefined || actual === null) throw new Error('音频标签回读不一致：封面缺失。');
  try {
    const left: CoverPixels = await coverPixels(expected);
    const right: CoverPixels = await coverPixels(actual);
    if (left.width !== right.width || left.height !== right.height) {
      throw new Error('封面尺寸不同。');
    }
    // Ignore row padding, but compare every RGBA component of every pixel.
    const rowBytes: number = left.width * 4;
    for (let y: number = 0; y < left.height; y++) {
      for (let x: number = 0; x < rowBytes; x++) {
        if (left.data[y * left.stride + x] !== right.data[y * right.stride + x]) {
          throw new Error('封面像素不同。');
        }
      }
    }
  } catch (error) {
    throw new Error('音频标签回读无法确认封面：' + String(error));
  }
}

/** Throws on mismatched or unverifiable fields; never silently skips zero/empty. */
export async function verifyWrittenMetadata(expected: AudioMetadataWriter, actual: AudioMetadata, verifyCover: boolean = true): Promise<void> {
  assertText('标题', expected.title, actual.title);
  assertText('歌手', expected.artist, actual.artist);
  assertText('专辑', expected.album, actual.album);
  assertText('流派', expected.genre, actual.genre);
  assertText('备注', expected.comment, actual.comment);
  assertLyrics(expected.lyrics, actual.lyrics);
  assertText('专辑艺术家', expected.albumArtist, actual.albumArtist);
  assertText('作曲者', expected.composer, actual.composer);
  assertText('分组', expected.grouping, actual.grouping);
  assertText('ISRC', expected.isrc, actual.isrc);
  assertText('版权信息', expected.copyright, actual.copyright);
  assertNumber('年份', expected.year, actual.year);
  assertNumber('曲目序号', expected.track, actual.track);
  assertNumber('碟片序号', expected.disc, actual.disc);
  assertNumber('碟片总数', expected.discTotal, actual.discTotal);
  assertNumber('曲目总数', expected.trackTotal, actual.trackTotal);
  assertNumber('BPM', expected.bpm, actual.bpm);
  if (verifyCover) await assertCover(expected.coverImage, actual.coverImage);
}

function assertPreservedText(name: string, before: string, after: string): void {
  if (typeof before !== 'string' || typeof after !== 'string' || before !== after) {
    throw new Error('未修改的音频标签发生变化或无法读取：' + name);
  }
}

function assertPreservedNumber(name: string, before: number, after: number): void {
  if (typeof before !== 'number' || typeof after !== 'number' ||
      !Number.isFinite(before) || !Number.isFinite(after) || before !== after) {
    throw new Error('音频属性发生变化或无法读取：' + name);
  }
}

/**
 * Confirm values that were not explicitly edited are still present after the
 * staged write. This verifies the fields exposed by AudioMetadata; TagLib's
 * API does not expose every possible vendor tag or multiple embedded pictures.
 */
export async function verifyPreservedMetadata(
  expected: AudioMetadataWriter,
  before: AudioMetadata,
  after: AudioMetadata,
  verifyDuration: boolean = true,
  verifyCover: boolean = true
): Promise<void> {
  if (expected.title === undefined) assertPreservedText('标题', before.title, after.title);
  if (expected.artist === undefined) assertPreservedText('歌手', before.artist, after.artist);
  if (expected.album === undefined) assertPreservedText('专辑', before.album, after.album);
  if (expected.genre === undefined) assertPreservedText('流派', before.genre, after.genre);
  if (expected.comment === undefined) assertPreservedText('备注', before.comment, after.comment);
  if (expected.lyrics === undefined) assertPreservedText('歌词', before.lyrics, after.lyrics);
  if (expected.albumArtist === undefined) assertPreservedText('专辑艺术家', before.albumArtist, after.albumArtist);
  if (expected.composer === undefined) assertPreservedText('作曲者', before.composer, after.composer);
  if (expected.grouping === undefined) assertPreservedText('分组', before.grouping, after.grouping);
  if (expected.isrc === undefined) assertPreservedText('ISRC', before.isrc, after.isrc);
  if (expected.copyright === undefined) assertPreservedText('版权信息', before.copyright, after.copyright);
  if (expected.year === undefined) assertPreservedNumber('年份', before.year, after.year);
  if (expected.track === undefined) assertPreservedNumber('曲目序号', before.track, after.track);
  if (expected.disc === undefined) assertPreservedNumber('碟片序号', before.disc, after.disc);
  if (expected.discTotal === undefined) assertPreservedNumber('碟片总数', before.discTotal, after.discTotal);
  if (expected.trackTotal === undefined) assertPreservedNumber('曲目总数', before.trackTotal, after.trackTotal);
  if (expected.bpm === undefined) assertPreservedNumber('BPM', before.bpm, after.bpm);
  if (verifyCover && expected.coverImage === undefined) {
    const beforeHasCover: boolean = before.coverImage !== undefined && before.coverImage !== null;
    const afterHasCover: boolean = after.coverImage !== undefined && after.coverImage !== null;
    if (!beforeHasCover && afterHasCover) {
      throw new Error('未修改的封面被意外新增。');
    }
    if (beforeHasCover && !afterHasCover) throw new Error('未修改的封面被意外删除。');
    if (before.coverImage !== undefined && before.coverImage !== null) {
      await assertCover(before.coverImage, after.coverImage);
    }
  }
  // ADTS callers can skip extractor-derived duration only when a separate
  // format verifier checks the complete audio stream byte for byte.
  if (verifyDuration) {
    assertPreservedNumber('时长', before.duration, after.duration);
    assertPreservedNumber('精确时长', before.durationMs, after.durationMs);
  }
  assertPreservedNumber('采样率', before.sampleRate, after.sampleRate);
  assertPreservedNumber('声道数', before.channels, after.channels);
  assertPreservedText('文件类型', before.fileType, after.fileType);
}
