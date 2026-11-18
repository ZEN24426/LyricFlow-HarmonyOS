import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AudioMetadata } from './AudioMetadataTypes';
import { assertBareMp3Frames } from './BareMp3';

// ID3v2.3 and v2.4 reader. Deliberately bounded and read-only. Transformed or
// ambiguous tags are rejected so the caller cannot treat an incomplete read as
// a verified basis for writing a user's file.
const MAX_TAG: number = 16 * 1024 * 1024;
const MAX_TEXT: number = 256 * 1024;
const MAX_COVER: number = 8 * 1024 * 1024;
const MAX_FRAMES: number = 4096;

interface FrameView { id: string; bytes: Uint8Array; flags: number; }
interface DecodedText { text: string; end: number; little: boolean; }

async function readExact(fd: number, start: number, length: number): Promise<Uint8Array> {
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(length) || start < 0 || length < 0 || length > MAX_TAG) {
    throw new Error('MP3 读取范围无效。');
  }
  const result: Uint8Array = new Uint8Array(length);
  let done: number = 0;
  while (done < length) {
    if (fileIo.lseek(fd, start + done, fileIo.WhenceType.SEEK_SET) !== start + done) throw new Error('MP3 定位失败。');
    const part: ArrayBuffer = new ArrayBuffer(Math.min(length - done, 256 * 1024));
    const n: number = await fileIo.read(fd, part, { length: part.byteLength });
    if (n <= 0 || n > part.byteLength) throw new Error('MP3 读取不完整。');
    result.set(new Uint8Array(part, 0, n), done);
    done += n;
  }
  return result;
}

function size32(b: Uint8Array, offset: number, syncsafe: boolean): number {
  let value: number = 0;
  for (let i: number = 0; i < 4; i++) {
    const n: number = b[offset + i];
    if (syncsafe && n > 127) throw new Error('ID3 长度编码无效。');
    value = value * (syncsafe ? 128 : 256) + n;
  }
  return value;
}

// Decode with explicit validity checks: malformed Unicode must never be
// silently replaced when these values are later used for write verification.
function decodeUtf8(bytes: Uint8Array, from: number, to: number): string {
  let result: string = '';
  let i: number = from;
  while (i < to) {
    const first: number = bytes[i++];
    let value: number = first;
    let remaining: number = 0;
    let min: number = 0;
    if (first >= 0xc2 && first <= 0xdf) { value = first & 0x1f; remaining = 1; min = 0x80; }
    else if (first >= 0xe0 && first <= 0xef) { value = first & 0x0f; remaining = 2; min = 0x800; }
    else if (first >= 0xf0 && first <= 0xf4) { value = first & 0x07; remaining = 3; min = 0x10000; }
    else if (first >= 0x80) throw new Error('ID3 UTF-8 编码无效。');
    if (i + remaining > to) throw new Error('ID3 UTF-8 内容不完整。');
    for (let j: number = 0; j < remaining; j++) {
      const next: number = bytes[i++];
      if ((next & 0xc0) !== 0x80) throw new Error('ID3 UTF-8 编码无效。');
      value = value * 64 + (next & 0x3f);
    }
    if ((remaining > 0 && value < min) || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) {
      throw new Error('ID3 Unicode 字符无效。');
    }
    if (value < 0x10000) result += String.fromCharCode(value);
    else {
      value -= 0x10000;
      result += String.fromCharCode(0xd800 + Math.floor(value / 1024), 0xdc00 + value % 1024);
    }
  }
  return result;
}

// Read one null-terminated ID3 string, or a final unterminated string.
function decodeText(bytes: Uint8Array, start: number, encoding: number, priorLittle: boolean,
  requireTerminator: boolean): DecodedText {
  if (encoding < 0 || encoding > 3 || start > bytes.length) throw new Error('ID3 文本编码不支持。');
  let cursor: number = start;
  let little: boolean = priorLittle;
  let terminated: boolean = false;
  let value: string = '';
  if (encoding === 1 && cursor + 1 < bytes.length) {
    if (bytes[cursor] === 0xff && bytes[cursor + 1] === 0xfe) { little = true; cursor += 2; }
    else if (bytes[cursor] === 0xfe && bytes[cursor + 1] === 0xff) { little = false; cursor += 2; }
    else if (start === 1) throw new Error('ID3 UTF-16 缺少字节序标记。');
  }
  if (encoding === 1 || encoding === 2) {
    if (encoding === 2) little = false;
    while (cursor + 1 < bytes.length) {
      const unit: number = little ? bytes[cursor] + bytes[cursor + 1] * 256 : bytes[cursor] * 256 + bytes[cursor + 1];
      cursor += 2;
      if (unit === 0) { terminated = true; break; }
      if (unit >= 0xdc00 && unit <= 0xdfff) throw new Error('ID3 UTF-16 代理对无效。');
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (cursor + 1 >= bytes.length) throw new Error('ID3 UTF-16 代理对不完整。');
        const low: number = little ? bytes[cursor] + bytes[cursor + 1] * 256 : bytes[cursor] * 256 + bytes[cursor + 1];
        if (low < 0xdc00 || low > 0xdfff) throw new Error('ID3 UTF-16 代理对无效。');
        cursor += 2;
        value += String.fromCharCode(unit, low);
      } else value += String.fromCharCode(unit);
    }
    if (!terminated && cursor !== bytes.length) throw new Error('ID3 UTF-16 字节不完整。');
  } else {
    let end: number = cursor;
    while (end < bytes.length && bytes[end] !== 0) end++;
    if (encoding === 3) value = decodeUtf8(bytes, cursor, end);
    else for (let i: number = cursor; i < end; i++) value += String.fromCharCode(bytes[i]);
    terminated = end < bytes.length;
    cursor = end + (terminated ? 1 : 0);
  }
  if (requireTerminator && !terminated) throw new Error('ID3 描述字段不完整。');
  return { text: value, end: cursor, little };
}

function plainText(frame: FrameView, version: number): string {
  if (frame.bytes.length < 1 || frame.bytes.length > MAX_TEXT) throw new Error('ID3 文本字段长度无效。');
  const encoding: number = frame.bytes[0];
  if (version === 3 && encoding > 1) throw new Error('ID3v2.3 文本编码不支持。');
  const out: DecodedText = decodeText(frame.bytes, 1, encoding, false, false);
  if (out.end !== frame.bytes.length) throw new Error('ID3 字段包含多个文本值。');
  return out.text;
}

function describedText(frame: FrameView, version: number): string {
  if (frame.bytes.length < 5 || frame.bytes.length > MAX_TEXT) throw new Error('ID3 歌词或备注长度无效。');
  const encoding: number = frame.bytes[0];
  if (version === 3 && encoding > 1) throw new Error('ID3v2.3 文本编码不支持。');
  const description: DecodedText = decodeText(frame.bytes, 4, encoding, false, true);
  const value: DecodedText = decodeText(frame.bytes, description.end, encoding, description.little, false);
  if (value.end !== frame.bytes.length) throw new Error('ID3 歌词或备注包含多个文本值。');
  return value.text;
}

function numericPair(value: string): number[] {
  if (value.length === 0) return [0, 0];
  if (!/^[0-9]+(\/[0-9]+)?$/.test(value)) throw new Error('ID3 数字字段格式不支持。');
  const parts: string[] = value.split('/');
  const first: number = Number(parts[0]);
  const total: number = parts.length > 1 ? Number(parts[1]) : 0;
  if (!Number.isSafeInteger(first) || !Number.isSafeInteger(total) || first > 99999 || total > 99999) {
    throw new Error('ID3 数字字段超出范围。');
  }
  return [first, total];
}

async function decodeCover(frame: FrameView, version: number): Promise<image.PixelMap> {
  const b: Uint8Array = frame.bytes;
  if (b.length < 5 || b.length > MAX_COVER + 1024) throw new Error('ID3 封面长度无效或过大。');
  const encoding: number = b[0];
  if (version === 3 && encoding > 1) throw new Error('ID3v2.3 封面描述编码不支持。');
  let pos: number = 1;
  while (pos < b.length && b[pos] !== 0) pos++;
  if (pos + 2 >= b.length) throw new Error('ID3 封面格式不完整。');
  if (b[pos + 1] !== 3) throw new Error('ID3 图片不是前封面，暂无法可靠显示。');
  const description: DecodedText = decodeText(b, pos + 2, encoding, false, true);
  if (description.end >= b.length || b.length - description.end > MAX_COVER) {
    throw new Error('ID3 封面图片为空或过大。');
  }
  const encoded: Uint8Array = b.slice(description.end);
  const source: image.ImageSource = image.createImageSource(encoded.buffer as ArrayBuffer);
  try {
    const info: image.ImageInfo = await source.getImageInfo();
    const width: number = info.size.width;
    const height: number = info.size.height;
    if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0 ||
        width > 16384 || height > 16384 || width * height > 16777216 || info.isHdr) {
      throw new Error('ID3 封面尺寸或 HDR 格式不支持。');
    }
    const decoded: image.PixelMap = await source.createPixelMap();
    try {
      const actual: image.ImageInfo = await decoded.getImageInfo();
      if (actual.size.width !== width || actual.size.height !== height || actual.isHdr) {
        throw new Error('ID3 封面解码尺寸不一致。');
      }
      return decoded;
    } catch (error) {
      try { await decoded.release(); } catch (_releaseError) {}
      throw error as Error;
    }
  } finally { try { await source.release(); } catch (_error) {} }
}

function emptyMetadata(size: number): AudioMetadata {
  return {
      title: '', artist: '', album: '', year: 0, track: 0, genre: '', comment: '', lyrics: '',
      albumArtist: '', composer: '', disc: 0, discTotal: 0, trackTotal: 0, bpm: 0,
      grouping: '', isrc: '', copyright: '', duration: 0, durationMs: 0, bitrate: 0,
      sampleRate: 0, channels: 0, coverImage: undefined, fileType: 'audio/mpeg', fileSize: size,
      creationTime: 0, modifyTime: 0
  };
}

/** Read a bounded, untransformed ID3v2.3/v2.4 tag without modifying the file. */
export async function readMp3Metadata(path: string): Promise<AudioMetadata> {
  const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  let decodedCover: image.PixelMap | undefined = undefined;
  let completed: boolean = false;
  try {
    const stat: fileIo.Stat = fileIo.statSync(file.fd);
    if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size < 11) throw new Error('MP3 文件无效。');
    const header: Uint8Array = await readExact(file.fd, 0, 10);
    if (header[0] !== 73 || header[1] !== 68 || header[2] !== 51) {
      await assertBareMp3Frames(file.fd, stat.size);
      completed = true;
      return emptyMetadata(stat.size);
    }
    const version: number = header[3];
    if (header[0] !== 73 || header[1] !== 68 || header[2] !== 51 ||
      (version !== 3 && version !== 4) || header[4] !== 0 || header[5] !== 0) {
      throw new Error('仅支持无特殊标志的 ID3v2.3/2.4 MP3 标签。');
    }
    const length: number = size32(header, 6, true);
    if (length > MAX_TAG || length > stat.size - 11) throw new Error('ID3 标签过大或不完整。');
    const data: Uint8Array = await readExact(file.fd, 10, length);
    const frames: FrameView[] = [];
    let pos: number = 0;
    while (pos < data.length) {
      if (data[pos] === 0) {
        for (let i: number = pos; i < data.length; i++) if (data[i] !== 0) throw new Error('ID3 填充区无效。');
        break;
      }
      if (frames.length >= MAX_FRAMES || data.length - pos < 10) throw new Error('ID3 帧过多或不完整。');
      let id: string = '';
      for (let i: number = 0; i < 4; i++) {
        const ch: number = data[pos + i];
        if (!((ch >= 65 && ch <= 90) || (ch >= 48 && ch <= 57))) throw new Error('ID3 帧标识无效。');
        id += String.fromCharCode(ch);
      }
      const n: number = size32(data, pos + 4, version === 4);
      if (n <= 0 || n > data.length - pos - 10) throw new Error('ID3 帧长度无效。');
      const flags: number = data[pos + 8] * 256 + data[pos + 9];
      frames.push({ id, bytes: data.slice(pos + 10, pos + 10 + n), flags });
      pos += 10 + n;
    }
    const result: AudioMetadata = emptyMetadata(stat.size);
    const handled: string[] = [];
    for (let i: number = 0; i < frames.length; i++) {
      const frame: FrameView = frames[i];
      const id: string = frame.id;
      if (['TIT2', 'TPE1', 'TALB', 'TYER', 'TDRC', 'TRCK', 'TCON', 'COMM', 'USLT', 'TPE2',
        'TCOM', 'TPOS', 'TBPM', 'TIT1', 'TSRC', 'TCOP', 'APIC'].indexOf(id) < 0) continue;
      if (frame.flags !== 0) throw new Error('ID3 字段含不支持的帧标志：' + id);
      if (handled.indexOf(id) >= 0 || ((id === 'TYER' || id === 'TDRC') &&
        (handled.indexOf('TYER') >= 0 || handled.indexOf('TDRC') >= 0))) {
        throw new Error('ID3 字段重复，无法可靠读取：' + id);
      }
      handled.push(id);
      if (id === 'APIC') { decodedCover = await decodeCover(frame, version); result.coverImage = decodedCover; continue; }
      const value: string = id === 'COMM' || id === 'USLT' ? describedText(frame, version) : plainText(frame, version);
      if (id === 'TIT2') result.title = value;
      else if (id === 'TPE1') result.artist = value;
      else if (id === 'TALB') result.album = value;
      else if (id === 'TCON') result.genre = value;
      else if (id === 'COMM') result.comment = value;
      else if (id === 'USLT') result.lyrics = value;
      else if (id === 'TPE2') result.albumArtist = value;
      else if (id === 'TCOM') result.composer = value;
      else if (id === 'TIT1') result.grouping = value;
      else if (id === 'TSRC') result.isrc = value;
      else if (id === 'TCOP') result.copyright = value;
      else if (id === 'TRCK') { const numbers: number[] = numericPair(value); result.track = numbers[0]; result.trackTotal = numbers[1]; }
      else if (id === 'TPOS') { const numbers: number[] = numericPair(value); result.disc = numbers[0]; result.discTotal = numbers[1]; }
      else if (id === 'TBPM') result.bpm = numericPair(value)[0];
      else if (id === 'TYER' || id === 'TDRC') {
        if (value.length > 0 && !/^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$/.test(value)) throw new Error('ID3 日期格式不支持。');
        result.year = value.length > 0 ? Number(value.substring(0, 4)) : 0;
      }
    }
    completed = true;
    return result;
  } finally {
    if (!completed && decodedCover !== undefined) { try { await decodedCover.release(); } catch (_error) {} }
    try { fileIo.closeSync(file.fd); } catch (_error) {}
  }
}
