import { fileIo } from '@kit.CoreFileKit';
import { AudioMetadata, AudioMetadataWriter } from './AudioMetadataTypes';
import { readMp3Metadata } from './Mp3MetadataReader';
import { writeMp3MetadataCopy } from './Mp3DirectWriter';
import { verifyId3Integrity } from './Id3Integrity';
import { verifyWrittenMetadata, verifyPreservedMetadata } from './MetadataVerification';

// Experimental copy-only support for strictly framed MPEG-4 AAC-LC/ADTS.
// Frame boundaries do not prove AAC payloads decode, or universal ID3 support.
const BLOCK: number = 256 * 1024;
const MAX_TAG: number = 16 * 1024 * 1024;
const MAX_FRAMES: number = 10000000;
const RATES: number[] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];
interface AdtsLayout { size: number; audioStart: number; frames: number; rate: number; channels: number; hasTag: boolean; }
function rootPath(root: string): string {
  const base: string = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  if (!base.startsWith('/') || base.indexOf('\\') >= 0 || base.indexOf('\u0000') >= 0) throw new Error('AAC 私有目录无效。');
  const segments: string[] = base.split('/');
  for (let i: number = 1; i < segments.length; i++) if (segments[i] === '' || segments[i] === '.' || segments[i] === '..') throw new Error('AAC 私有目录无效。');
  return base;
}
function privatePath(root: string, path: string): void {
  if (!path.startsWith(root + '/') || path.indexOf('\\') >= 0 || path.indexOf('\u0000') >= 0) throw new Error('仅允许处理应用私有目录中的 AAC 副本。');
  const segments: string[] = path.split('/');
  for (let i: number = 1; i < segments.length; i++) if (segments[i] === '' || segments[i] === '.' || segments[i] === '..') throw new Error('AAC 私有文件路径无效。');
}
async function readAt(fd: number, pos: number, size: number): Promise<Uint8Array> {
  if (!Number.isSafeInteger(pos) || pos < 0 || !Number.isInteger(size) || size < 0 || size > BLOCK) throw new Error('AAC 读取范围无效。');
  const out: Uint8Array = new Uint8Array(size); let done: number = 0;
  const scratch: ArrayBuffer = new ArrayBuffer(Math.min(16384, size));
  while (done < size) {
    if (fileIo.lseek(fd, pos + done, fileIo.WhenceType.SEEK_SET) !== pos + done) throw new Error('AAC 工作文件无法定位。');
    const want: number = Math.min(scratch.byteLength, size - done);
    const n: number = await fileIo.read(fd, scratch, { length: want });
    if (n <= 0 || n > want) throw new Error('AAC 数据不完整。');
    out.set(new Uint8Array(scratch, 0, n), done); done += n;
  }
  return out;
}
async function writeAll(fd: number, bytes: Uint8Array): Promise<void> {
  let done: number = 0;
  const scratch: Uint8Array = new Uint8Array(Math.min(16384, bytes.length));
  while (done < bytes.length) {
    const want: number = Math.min(scratch.length, bytes.length - done);
    scratch.set(bytes.subarray(done, done + want));
    const n: number = await fileIo.write(fd, scratch.buffer as ArrayBuffer, { length: want });
    if (n <= 0 || n > want) throw new Error('AAC 副本写入不完整。');
    done += n;
  }
}
async function copyRange(src: number, dst: number, start: number, length: number): Promise<void> {
  for (let p: number = 0; p < length;) { const n: number = Math.min(BLOCK, length - p); await writeAll(dst, await readAt(src, start + p, n)); p += n; }
}
async function inspect(fd: number): Promise<AdtsLayout> {
  const st: fileIo.Stat = fileIo.statSync(fd);
  if (!st.isFile() || !Number.isSafeInteger(st.size) || st.size < 16) throw new Error('AAC 文件无效或过小。');
  const first: Uint8Array = await readAt(fd, 0, 10);
  const hasTag: boolean = first[0] === 73 && first[1] === 68 && first[2] === 51;
  let start: number = 0;
  if (hasTag) {
    if ((first[3] !== 3 && first[3] !== 4) || first[4] !== 0 || first[5] !== 0) throw new Error('AAC ID3 版本或特殊标志不受支持。');
    let n: number = 0;
    for (let i: number = 6; i < 10; i++) { if (first[i] > 127) throw new Error('AAC ID3 长度无效。'); n = n * 128 + first[i]; }
    if (n > MAX_TAG || n > st.size - 10) throw new Error('AAC ID3 标签不完整或超限。');
    start = 10 + n;
  }
  let p: number = start; let frames: number = 0; let rateIndex: number = -1; let channels: number = 0;
  let cached: Uint8Array = new Uint8Array(0); let cachedAt: number = -1;
  while (p < st.size) {
    if (frames >= MAX_FRAMES || st.size - p < 7) throw new Error('AAC 帧数量过多或结尾不完整。');
    if (cachedAt < 0 || p < cachedAt || p + 7 > cachedAt + cached.length) {
      cachedAt = p; cached = await readAt(fd, p, Math.min(BLOCK, st.size - p));
    }
    const at: number = p - cachedAt;
    if (cached[at] !== 255 || cached[at + 1] !== 0xf1 || (cached[at + 2] >> 6) !== 1 || (cached[at + 6] & 3) !== 0) {
      throw new Error('仅支持无 CRC、单数据块的 MPEG-4 AAC-LC ADTS 帧。');
    }
    const rate: number = (cached[at + 2] >> 2) & 15;
    const channel: number = ((cached[at + 2] & 1) << 2) | (cached[at + 3] >> 6);
    if (rate >= RATES.length || (channel !== 1 && channel !== 2)) throw new Error('AAC 采样率或声道配置不受支持。');
    if (rateIndex < 0) { rateIndex = rate; channels = channel; }
    else if (rate !== rateIndex || channel !== channels) throw new Error('AAC 流中途变更采样率或声道，无法安全处理。');
    const length: number = (cached[at + 3] & 3) * 2048 + cached[at + 4] * 8 + (cached[at + 5] >> 5);
    if (length <= 7 || length > st.size - p) throw new Error('AAC 帧长度无效或数据不完整。');
    p += length; frames++;
  }
  if (p !== st.size || frames < 2 || rateIndex < 0) throw new Error('AAC 帧过少、文件尾部不受支持或不完整。');
  if (fileIo.statSync(fd).size !== st.size) throw new Error('读取期间 AAC 文件大小发生变化。');
  return { size: st.size, audioStart: start, frames, rate: RATES[rateIndex], channels, hasTag };
}
function empty(size: number): AudioMetadata {
  return { title: '', artist: '', album: '', year: 0, track: 0, genre: '', comment: '', lyrics: '',
    albumArtist: '', composer: '', disc: 0, discTotal: 0, trackTotal: 0, bpm: 0, grouping: '', isrc: '', copyright: '',
    duration: 0, durationMs: 0, bitrate: 0, sampleRate: 0, channels: 0, coverImage: undefined,
    fileType: 'audio/aac', fileSize: size, creationTime: 0, modifyTime: 0 };
}
/** The caller may use a system extractor for technical properties and playback validation. */
export async function readAdtsMetadata(path: string): Promise<AudioMetadata> {
  const f: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY); let result: AudioMetadata | undefined = undefined;
  try {
    const x: AdtsLayout = await inspect(f.fd);
    result = x.hasTag ? await readMp3Metadata(path) : empty(x.size);
    if (fileIo.statSync(f.fd).size !== x.size) throw new Error('读取期间 AAC 文件大小发生变化。');
    result.fileType = 'audio/aac'; result.fileSize = x.size;
    return result;
  } catch (error) {
    if (result !== undefined && result.coverImage !== undefined) { try { await result.coverImage.release(); } catch (_e) {} }
    throw error as Error;
  } finally { try { fileIo.closeSync(f.fd); } catch (_e) {} }
}
async function normalizedBare(root: string, original: string): Promise<string> {
  const source: fileIo.File = fileIo.openSync(original, fileIo.OpenMode.READ_ONLY);
  let dst: fileIo.File | undefined = undefined; let dir: string = ''; let path: string = ''; let done: boolean = false;
  try {
    const x: AdtsLayout = await inspect(source.fd); if (x.hasTag) throw new Error('AAC 已带标签，不应重新创建标签。');
    dir = fileIo.mkdtempSync(root + '/lyricflow_adts_base_XXXXXX'); path = dir + '/base.aac';
    dst = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    await writeAll(dst.fd, new Uint8Array([73, 68, 51, 4, 0, 0, 0, 0, 0, 0]));
    await copyRange(source.fd, dst.fd, 0, x.size);
    if (fileIo.statSync(source.fd).size !== x.size || fileIo.statSync(dst.fd).size !== x.size + 10) throw new Error('AAC 标签临时副本大小不一致。');
    fileIo.fsyncSync(dst.fd); done = true; return path;
  } finally {
    if (dst !== undefined) { try { fileIo.closeSync(dst.fd); } catch (_e) {} }
    try { fileIo.closeSync(source.fd); } catch (_e) {}
    if (!done && path.length > 0) { try { fileIo.unlinkSync(path); } catch (_e) {} }
    if (!done && dir.length > 0) { try { fileIo.rmdirSync(dir); } catch (_e) {} }
  }
}
function removeTemporary(path: string): void {
  if (path.length === 0) return;
  try { fileIo.unlinkSync(path); } catch (_e) {}
  try { fileIo.rmdirSync(path.substring(0, path.lastIndexOf('/'))); } catch (_e) {}
}
async function compareAudio(a: number, ax: AdtsLayout, b: number, bx: AdtsLayout): Promise<void> {
  const length: number = ax.size - ax.audioStart;
  if (length !== bx.size - bx.audioStart || ax.frames !== bx.frames || ax.rate !== bx.rate || ax.channels !== bx.channels) throw new Error('AAC 音频长度或帧参数发生变化。');
  for (let p: number = 0; p < length;) {
    const n: number = Math.min(BLOCK, length - p);
    const l: Uint8Array = await readAt(a, ax.audioStart + p, n); const r: Uint8Array = await readAt(b, bx.audioStart + p, n);
    for (let i: number = 0; i < n; i++) if (l[i] !== r[i]) throw new Error('AAC 音频帧字节发生变化。');
    p += n;
  }
}
async function verifyCore(root: string, original: string, edited: string, fields: AudioMetadataWriter, preparedBaseline: string = ''): Promise<void> {
  const a: fileIo.File = fileIo.openSync(original, fileIo.OpenMode.READ_ONLY); let b: fileIo.File | undefined = undefined; let temporary: string = '';
  let before: AudioMetadata | undefined = undefined; let after: AudioMetadata | undefined = undefined;
  try {
    b = fileIo.openSync(edited, fileIo.OpenMode.READ_ONLY);
    const ax: AdtsLayout = await inspect(a.fd); const bx: AdtsLayout = await inspect(b.fd);
    if (!bx.hasTag) throw new Error('AAC 输出标签缺失。');
    await compareAudio(a.fd, ax, b.fd, bx);
    let tagSource: string = original;
    if (!ax.hasTag) { tagSource = preparedBaseline; if (tagSource.length === 0) { temporary = await normalizedBare(root, original); tagSource = temporary; } }
    await verifyId3Integrity(tagSource, edited, fields);
    before = await readAdtsMetadata(original); after = await readAdtsMetadata(edited);
    await verifyWrittenMetadata(fields, after); await verifyPreservedMetadata(fields, before, after);
    if (fileIo.statSync(a.fd).size !== ax.size || fileIo.statSync(b.fd).size !== bx.size) throw new Error('校验时 AAC 文件大小发生变化。');
  } finally {
    if (before !== undefined && before.coverImage !== undefined) { try { await before.coverImage.release(); } catch (_e) {} }
    if (after !== undefined && after.coverImage !== undefined) { try { await after.coverImage.release(); } catch (_e) {} }
    if (b !== undefined) { try { fileIo.closeSync(b.fd); } catch (_e) {} }
    try { fileIo.closeSync(a.fd); } catch (_e) {}
    removeTemporary(temporary);
  }
}
/** Verify tag edits and every ADTS byte; no claim about AAC payload decodability. */
export async function verifyAdtsIntegrity(filesDir: string, beforePath: string, afterPath: string, fields: AudioMetadataWriter): Promise<void> {
  const root: string = rootPath(filesDir); privatePath(root, beforePath); privatePath(root, afterPath);
  await verifyCore(root, beforePath, afterPath, fields);
}
/** Returns a private, independently verified AAC copy; never writes source. */
export async function writeAdtsMetadata(filesDir: string, inputPath: string, fields: AudioMetadataWriter): Promise<string> {
  const root: string = rootPath(filesDir); privatePath(root, inputPath);
  const f: fileIo.File = fileIo.openSync(inputPath, fileIo.OpenMode.READ_ONLY);
  let normalized: string = ''; let edited: string = ''; let output: string = ''; let complete: boolean = false;
  try {
    const x: AdtsLayout = await inspect(f.fd);
    if (!x.hasTag) normalized = await normalizedBare(root, inputPath);
    edited = await writeMp3MetadataCopy(root, x.hasTag ? inputPath : normalized, fields);
    output = edited.substring(0, edited.lastIndexOf('/')) + '/edited.aac';
    fileIo.renameSync(edited, output); edited = '';
    await verifyCore(root, inputPath, output, fields, normalized);
    complete = true; return output;
  } finally {
    try { fileIo.closeSync(f.fd); } catch (_e) {}
    removeTemporary(normalized);
    if (!complete) { removeTemporary(output); removeTemporary(edited); }
  }
}
