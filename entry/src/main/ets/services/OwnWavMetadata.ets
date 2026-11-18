import { fileIo } from '@kit.CoreFileKit';
import { AudioMetadata, AudioMetadataWriter } from './AudioMetadataTypes';
import { readMp3Metadata } from './Mp3MetadataReader';
import { writeMp3MetadataCopy } from './Mp3DirectWriter';
import { verifyId3Integrity } from './Id3Integrity';

// Conservative RIFF/WAVE subset: one fmt, one data and at most one ID3 chunk.
// LIST/INFO and other known competing tag carriers are rejected, rather than
// rewriting just one of multiple metadata copies. RF64/RIFX are not accepted.
const CHUNK: number = 256 * 1024;
const MAX_ID3: number = 16 * 1024 * 1024 + 10;
const MAX_CHUNKS: number = 4096;
interface WavChunk { id: string; start: number; length: number; total: number; }
interface WavLayout { size: number; chunks: WavChunk[]; id3?: WavChunk; }

function four(b: Uint8Array, p: number): string {
  return String.fromCharCode(b[p], b[p + 1], b[p + 2], b[p + 3]);
}
function le32(b: Uint8Array, p: number): number {
  return b[p] + b[p + 1] * 256 + b[p + 2] * 65536 + b[p + 3] * 16777216;
}
function put32(n: number): Uint8Array {
  return new Uint8Array([n & 255, Math.floor(n / 256) & 255, Math.floor(n / 65536) & 255, Math.floor(n / 16777216) & 255]);
}
function checkedRoot(root: string): string {
  const value: string = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  if (!value.startsWith('/') || value.indexOf('\\') >= 0 || value.indexOf('\u0000') >= 0) {
    throw new Error('WAV 临时目录无效。');
  }
  const parts: string[] = value.split('/');
  for (let i: number = 1; i < parts.length; i++) {
    if (parts[i] === '' || parts[i] === '.' || parts[i] === '..') throw new Error('WAV 临时目录无效。');
  }
  return value;
}
async function readAt(fd: number, pos: number, length: number): Promise<Uint8Array> {
  if (!Number.isSafeInteger(pos) || pos < 0 || !Number.isInteger(length) || length < 0 || length > CHUNK) {
    throw new Error('WAV 读取范围无效。');
  }
  const out: Uint8Array = new Uint8Array(length);
  let done: number = 0;
  while (done < length) {
    if (fileIo.lseek(fd, pos + done, fileIo.WhenceType.SEEK_SET) !== pos + done) throw new Error('WAV 定位失败。');
    const part: ArrayBuffer = new ArrayBuffer(length - done);
    const n: number = await fileIo.read(fd, part, { length: part.byteLength });
    if (n <= 0 || n > part.byteLength) throw new Error('WAV 内容不完整。');
    out.set(new Uint8Array(part, 0, n), done); done += n;
  }
  return out;
}
async function writeAll(fd: number, bytes: Uint8Array): Promise<void> {
  let done: number = 0;
  while (done < bytes.length) {
    const part: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset + done, bytes.byteOffset + bytes.length) as ArrayBuffer;
    const n: number = await fileIo.write(fd, part, { length: part.byteLength });
    if (n <= 0 || n > part.byteLength) throw new Error('WAV 副本写入不完整。');
    done += n;
  }
}
async function copyRange(source: number, destination: number, start: number, length: number): Promise<void> {
  let done: number = 0;
  while (done < length) {
    const n: number = Math.min(CHUNK, length - done);
    await writeAll(destination, await readAt(source, start + done, n)); done += n;
  }
}
async function parse(fd: number): Promise<WavLayout> {
  const stat: fileIo.Stat = fileIo.statSync(fd);
  if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size < 12 || stat.size > 4294967303) {
    throw new Error('WAV 大小无效或超出 RIFF 范围。');
  }
  const header: Uint8Array = await readAt(fd, 0, 12);
  if (four(header, 0) !== 'RIFF' || four(header, 8) !== 'WAVE' || le32(header, 4) !== stat.size - 8) {
    throw new Error('仅支持长度准确的标准 RIFF/WAVE 文件。');
  }
  const chunks: WavChunk[] = [];
  let id3: WavChunk | undefined = undefined;
  let formats: number = 0;
  let audio: number = 0;
  let pos: number = 12;
  while (pos < stat.size) {
    if (chunks.length >= MAX_CHUNKS || stat.size - pos < 8) throw new Error('WAV 数据块不完整或过多。');
    const h: Uint8Array = await readAt(fd, pos, 8);
    const id: string = four(h, 0);
    const length: number = le32(h, 4);
    const total: number = 8 + length + (length % 2);
    if (total > stat.size - pos) throw new Error('WAV 数据块长度无效。');
    const c: WavChunk = { id, start: pos, length, total };
    if (id === 'fmt ') {
      if (++formats > 1 || length < 16) throw new Error('WAV 格式块缺失或重复。');
    } else if (id === 'data') {
      if (++audio > 1 || length === 0) throw new Error('WAV 音频数据为空或重复。');
    } else if (id === 'id3 ' || id === 'ID3 ') {
      if (id3 !== undefined || length < 10 || length > MAX_ID3) throw new Error('WAV ID3 标签重复或超限。');
      const tag: Uint8Array = await readAt(fd, pos + 8, 10);
      if (four(tag, 0).substring(0, 3) !== 'ID3' || (tag[3] !== 3 && tag[3] !== 4) || tag[4] !== 0 || tag[5] !== 0 ||
          tag[6] > 127 || tag[7] > 127 || tag[8] > 127 || tag[9] > 127 ||
          10 + tag[6] * 2097152 + tag[7] * 16384 + tag[8] * 128 + tag[9] !== length) {
        throw new Error('WAV ID3 标签结构不受支持。');
      }
      id3 = c;
    } else if (id === 'LIST') {
      if (length < 4) throw new Error('WAV LIST 数据块不完整。');
      if (four(await readAt(fd, pos + 8, 4), 0) === 'INFO') throw new Error('WAV 含 LIST/INFO 标签，不能安全合并。');
    } else if (id === 'bext' || id === 'iXML' || id === 'axml' || id === 'cart' || id === 'ID3\u0000') {
      throw new Error('WAV 含其他元数据块，无法确认是否有冲突。');
    }
    chunks.push(c); pos += total;
  }
  if (pos !== stat.size || formats !== 1 || audio !== 1) throw new Error('WAV 缺少必要的数据块。');
  return { size: stat.size, chunks, id3 };
}
async function makeId3(fd: number, layout: WavLayout, output: string): Promise<void> {
  const f: fileIo.File = fileIo.openSync(output, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
  try {
    if (layout.id3 !== undefined) await copyRange(fd, f.fd, layout.id3.start + 8, layout.id3.length);
    else await writeAll(f.fd, new Uint8Array([73, 68, 51, 4, 0, 0, 0, 0, 0, 0]));
    // A private sentinel supplies the payload expected by the ID3-only parser.
    await writeAll(f.fd, new Uint8Array([0]));
    fileIo.fsyncSync(f.fd);
  } finally { fileIo.closeSync(f.fd); }
}
// The MP3 writer preserves existing padding. Remove only validated trailing
// zero padding from this private temporary tag, so its new frames can reuse the
// fixed-size ID3 chunk without moving any unrelated RIFF chunks.
async function compactId3File(path: string): Promise<void> {
  const f: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE);
  try {
    const size: number = fileIo.statSync(f.fd).size;
    if (size < 11 || size > MAX_ID3 + 1) throw new Error('WAV 临时标签长度无效。');
    const tag: Uint8Array = new Uint8Array(size - 1);
    let copied: number = 0;
    while (copied < tag.length) {
      const n: number = Math.min(CHUNK, tag.length - copied);
      tag.set(await readAt(f.fd, copied, n), copied); copied += n;
    }
    const version: number = tag[3];
    let pos: number = 10;
    while (pos < tag.length && tag[pos] !== 0) {
      if (tag.length - pos < 10) throw new Error('WAV ID3 帧不完整。');
      let length: number = 0;
      for (let i: number = 0; i < 4; i++) {
        const b: number = tag[pos + 4 + i];
        if (version === 4 && b > 127) throw new Error('WAV ID3 帧长度无效。');
        length = length * (version === 4 ? 128 : 256) + b;
      }
      if (length <= 0 || length > tag.length - pos - 10) throw new Error('WAV ID3 帧长度无效。');
      pos += 10 + length;
    }
    for (let i: number = pos; i < tag.length; i++) if (tag[i] !== 0) throw new Error('WAV ID3 填充区无效。');
    let n: number = pos - 10;
    for (let i: number = 9; i >= 6; i--) { tag[i] = n % 128; n = Math.floor(n / 128); }
    if (n !== 0 || fileIo.lseek(f.fd, 0, fileIo.WhenceType.SEEK_SET) !== 0) throw new Error('WAV 标签整理失败。');
    fileIo.truncateSync(f.fd, 0);
    await writeAll(f.fd, tag.slice(0, pos));
    await writeAll(f.fd, new Uint8Array([0]));
    fileIo.fsyncSync(f.fd);
  } finally { fileIo.closeSync(f.fd); }
}
function cleanupFile(path: string): void { try { fileIo.unlinkSync(path); } catch (_error) {} }
function cleanupDir(path: string): void { try { fileIo.rmdirSync(path); } catch (_error) {} }

/** Reads only unambiguous ID3 metadata; caller supplies its private filesDir. */
export async function readWavMetadata(path: string, filesDir: string): Promise<AudioMetadata> {
  const root: string = checkedRoot(filesDir);
  const source: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  let dir: string = '';
  try {
    const wav: WavLayout = await parse(source.fd);
    dir = fileIo.mkdtempSync(root + '/lyricflow_wav_read_XXXXXX');
    const tag: string = dir + '/tag.mp3';
    await makeId3(source.fd, wav, tag);
    const result: AudioMetadata = await readMp3Metadata(tag);
    result.fileType = 'audio/wav'; result.fileSize = wav.size;
    return result;
  } finally {
    if (dir.length > 0) { cleanupFile(dir + '/tag.mp3'); cleanupDir(dir); }
    try { fileIo.closeSync(source.fd); } catch (_error) {}
  }
}

/** Compare every unmodified WAV chunk, including padding and all audio bytes. */
export async function verifyWavIntegrity(beforePath: string, afterPath: string): Promise<void> {
  const before: fileIo.File = await fileIo.open(beforePath, fileIo.OpenMode.READ_ONLY);
  let after: fileIo.File | undefined = undefined;
  try {
    after = await fileIo.open(afterPath, fileIo.OpenMode.READ_ONLY);
    const a: WavLayout = await parse(before.fd);
    const b: WavLayout = await parse(after.fd);
    const left: WavChunk[] = a.chunks.filter((c: WavChunk): boolean => c.id !== 'id3 ' && c.id !== 'ID3 ');
    const right: WavChunk[] = b.chunks.filter((c: WavChunk): boolean => c.id !== 'id3 ' && c.id !== 'ID3 ');
    if (left.length !== right.length || b.id3 === undefined) throw new Error('WAV 副本数据块发生变化。');
    for (let i: number = 0; i < left.length; i++) {
      if (left[i].id !== right[i].id || left[i].total !== right[i].total || left[i].start !== right[i].start) {
        throw new Error('WAV 副本数据块或位置发生变化。');
      }
      let done: number = 0;
      while (done < left[i].total) {
        const n: number = Math.min(CHUNK, left[i].total - done);
        const x: Uint8Array = await readAt(before.fd, left[i].start + done, n);
        const y: Uint8Array = await readAt(after.fd, right[i].start + done, n);
        for (let j: number = 0; j < n; j++) if (x[j] !== y[j]) throw new Error('WAV 音频或未修改的数据块发生变化。');
        done += n;
      }
    }
  } finally {
    if (after !== undefined) try { fileIo.closeSync(after.fd); } catch (_error) {}
    try { fileIo.closeSync(before.fd); } catch (_error) {}
  }
}

/** Returns a new app-private staging file; never changes the input. */
export async function writeWavMetadata(filesDir: string, inputPath: string, fields: AudioMetadataWriter): Promise<string> {
  const root: string = checkedRoot(filesDir);
  if (!inputPath.startsWith(root + '/') || inputPath.indexOf('\\') >= 0 || inputPath.indexOf('\u0000') >= 0 ||
      inputPath.split('/').some((p: string): boolean => p === '.' || p === '..')) throw new Error('仅允许编辑私有目录中的 WAV 副本。');
  const source: fileIo.File = await fileIo.open(inputPath, fileIo.OpenMode.READ_ONLY);
  let dir: string = '';
  let edited: string = '';
  let output: fileIo.File | undefined = undefined;
  let result: string = '';
  let complete: boolean = false;
  try {
    const wav: WavLayout = await parse(source.fd);
    dir = fileIo.mkdtempSync(root + '/lyricflow_wav_XXXXXX');
    const tag: string = dir + '/tag.mp3';
    await makeId3(source.fd, wav, tag);
    await compactId3File(tag);
    edited = await writeMp3MetadataCopy(root, tag, fields);
    await verifyId3Integrity(tag, edited, fields);
    const tagged: fileIo.File = await fileIo.open(edited, fileIo.OpenMode.READ_ONLY);
    try {
      const tagLength: number = fileIo.statSync(tagged.fd).size - 1;
      if (tagLength < 10 || tagLength > MAX_ID3) throw new Error('新 WAV 标签大小无效。');
      // Keep all original chunk offsets stable. When an ID3 chunk already
      // exists, only use its existing space and add valid ID3 padding; do not
      // shift opaque chunks that might contain offsets. A new tag is appended.
      const oldTotal: number = wav.id3 === undefined ? 0 : wav.id3.total;
      const storedLength: number = wav.id3 === undefined ? Math.min(MAX_ID3, tagLength + 4096) : wav.id3.length;
      if (tagLength > storedLength) throw new Error('原 WAV 标签空间不足，无法在保持数据块位置不变时安全更新。');
      const newTotal: number = 8 + storedLength + storedLength % 2;
      const newSize: number = wav.size - oldTotal + newTotal;
      if (newSize - 8 > 0xffffffff) throw new Error('更新后的 WAV 超出 RIFF 长度限制。');
      result = dir + '/edited.wav';
      output = fileIo.openSync(result, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      await writeAll(output.fd, new Uint8Array([82, 73, 70, 70]));
      await writeAll(output.fd, put32(newSize - 8));
      await writeAll(output.fd, new Uint8Array([87, 65, 86, 69]));
      const id3Header: Uint8Array = await readAt(tagged.fd, 0, 10);
      let padLength: number = storedLength - 10;
      for (let i: number = 9; i >= 6; i--) { id3Header[i] = padLength % 128; padLength = Math.floor(padLength / 128); }
      if (padLength !== 0) throw new Error('WAV ID3 填充超限。');
      for (let i: number = 0; i < wav.chunks.length; i++) {
        const c: WavChunk = wav.chunks[i];
        if (c.id !== 'id3 ' && c.id !== 'ID3 ') { await copyRange(source.fd, output.fd, c.start, c.total); continue; }
        await copyRange(source.fd, output.fd, c.start, 8);
        await writeAll(output.fd, id3Header);
        await copyRange(tagged.fd, output.fd, 10, tagLength - 10);
        let remaining: number = storedLength - tagLength;
        while (remaining > 0) {
          const n: number = Math.min(CHUNK, remaining);
          await writeAll(output.fd, new Uint8Array(n)); remaining -= n;
        }
        if (storedLength % 2 !== 0) await copyRange(source.fd, output.fd, c.start + 8 + storedLength, 1);
      }
      if (wav.id3 === undefined) {
        await writeAll(output.fd, new Uint8Array([105, 100, 51, 32]));
        await writeAll(output.fd, put32(storedLength));
        await writeAll(output.fd, id3Header);
        await copyRange(tagged.fd, output.fd, 10, tagLength - 10);
        let remaining: number = storedLength - tagLength;
        while (remaining > 0) {
          const n: number = Math.min(CHUNK, remaining);
          await writeAll(output.fd, new Uint8Array(n)); remaining -= n;
        }
        if (storedLength % 2 !== 0) await writeAll(output.fd, new Uint8Array([0]));
      }
      if (fileIo.statSync(source.fd).size !== wav.size || fileIo.statSync(output.fd).size !== newSize) {
        throw new Error('WAV 副本长度发生变化。');
      }
      fileIo.fsyncSync(output.fd);
    } finally { fileIo.closeSync(tagged.fd); }
    fileIo.closeSync(output.fd); output = undefined;
    await verifyWavIntegrity(inputPath, result);
    // Verify the tag actually written into the final RIFF, not merely the
    // intermediate tag that was used to construct it.
    const check: fileIo.File = await fileIo.open(result, fileIo.OpenMode.READ_ONLY);
    const readback: string = dir + '/readback.mp3';
    try { await makeId3(check.fd, await parse(check.fd), readback); }
    finally { fileIo.closeSync(check.fd); }
    await verifyId3Integrity(tag, readback, fields);
    complete = true;
    return result;
  } finally {
    if (output !== undefined) try { fileIo.closeSync(output.fd); } catch (_error) {}
    try { fileIo.closeSync(source.fd); } catch (_error) {}
    if (edited.length > 0) { cleanupFile(edited); cleanupDir(edited.substring(0, edited.lastIndexOf('/'))); }
    if (dir.length > 0) cleanupFile(dir + '/tag.mp3');
    if (dir.length > 0) cleanupFile(dir + '/readback.mp3');
    if (!complete && result.length > 0) cleanupFile(result);
    if (!complete && dir.length > 0) cleanupDir(dir);
  }
}
