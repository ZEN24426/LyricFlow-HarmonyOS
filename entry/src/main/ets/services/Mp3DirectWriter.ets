import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AudioMetadata, AudioMetadataWriter } from './AudioMetadataTypes';
import { readMp3Metadata } from './Mp3MetadataReader';
import { fillAudioProperties } from './SystemAudioProperties';
import { assertBareMp3Frames } from './BareMp3';

// Experimental only: creates a new private staging file, never changes input.
// Only simple ID3v2.3/2.4 without tag-level transformation is supported.
export type Id3NumberChanges = AudioMetadataWriter;
interface Frame { id: string; start: number; size: number; dataSize: number; flags: number; }
interface NumberText { first: string; total: string; hasTotal: boolean; encoding: number; little: boolean; terminated: boolean; }
interface Edit { id: string; replacement: Uint8Array | undefined; original: Frame | undefined; }
interface TextField { id: string; value: string | undefined; }
export interface Mp3Numbers { track: number; trackTotal: number; disc: number; discTotal: number; }

const BLOCK: number = 256 * 1024;
const MAX_TAG: number = 16 * 1024 * 1024;
const MAX_FRAMES: number = 4096;

async function readAt(fd: number, offset: number, length: number): Promise<Uint8Array> {
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(length) || length < 0 || length > BLOCK) {
    throw new Error('ID3 读取范围无效。');
  }
  const result: Uint8Array = new Uint8Array(length);
  let done: number = 0;
  while (done < length) {
    if (fileIo.lseek(fd, offset + done, fileIo.WhenceType.SEEK_SET) !== offset + done) throw new Error('ID3 工作文件无法定位。');
    const part: ArrayBuffer = new ArrayBuffer(length - done);
    const count: number = await fileIo.read(fd, part, { length: length - done });
    if (count <= 0 || count > length - done) throw new Error('ID3 工作文件读取不完整。');
    result.set(new Uint8Array(part, 0, count), done); done += count;
  }
  return result;
}

async function writeAll(fd: number, data: Uint8Array): Promise<void> {
  let done: number = 0;
  while (done < data.length) {
    const part: ArrayBuffer = data.buffer.slice(data.byteOffset + done, data.byteOffset + data.length) as ArrayBuffer;
    const count: number = await fileIo.write(fd, part, { length: part.byteLength });
    if (count <= 0 || count > part.byteLength) throw new Error('ID3 临时副本写入不完整。');
    done += count;
  }
}

async function copyRegion(source: number, target: number, start: number, length: number): Promise<void> {
  for (let done: number = 0; done < length;) {
    const n: number = Math.min(BLOCK, length - done);
    await writeAll(target, await readAt(source, start + done, n)); done += n;
  }
}

function getSize(bytes: Uint8Array, at: number, safe: boolean): number {
  let out: number = 0;
  for (let i: number = 0; i < 4; i++) {
    if (safe && bytes[at + i] > 127) throw new Error('ID3 synchsafe 长度无效。');
    out = out * (safe ? 128 : 256) + bytes[at + i];
  }
  return out;
}

function putSize(bytes: Uint8Array, at: number, value: number, safe: boolean): void {
  const base: number = safe ? 128 : 256;
  for (let i: number = 3; i >= 0; i--) {
    bytes[at + i] = value % base; value = Math.floor(value / base);
  }
  if (value !== 0) throw new Error('ID3 元数据长度超限。');
}

async function checkPadding(fd: number, start: number, length: number): Promise<void> {
  for (let done: number = 0; done < length;) {
    const n: number = Math.min(BLOCK, length - done);
    const bytes: Uint8Array = await readAt(fd, start + done, n);
    for (let i: number = 0; i < n; i++) if (bytes[i] !== 0) throw new Error('ID3 填充区含非零数据。');
    done += n;
  }
}

function checkPrivatePath(root: string, file: string): string {
  const base: string = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  if (!base.startsWith('/') || !file.startsWith(base + '/') || base.indexOf('\\') >= 0 || file.indexOf('\\') >= 0 ||
      base.indexOf('\u0000') >= 0 || file.indexOf('\u0000') >= 0) throw new Error('仅允许应用私有目录内的工作副本。');
  const parts: string[] = file.split('/');
  for (let i: number = 1; i < parts.length; i++) {
    if (parts[i] === '' || parts[i] === '.' || parts[i] === '..') throw new Error('工作副本路径无效。');
  }
  return base;
}

function validateChange(value: number | undefined): void {
  if (value !== undefined && (!Number.isInteger(value) || value < 0 || value > 99999)) {
    throw new Error('曲目或碟片数值必须为 0 至 99999 的整数。');
  }
}

function parseNumber(data: Uint8Array, version: number): NumberText {
  if (data.length < 2 || data.length > 128) throw new Error('ID3 曲目或碟片文本为空或过长。');
  const encoding: number = data[0];
  if (encoding > 3 || (version === 3 && encoding > 1)) throw new Error('ID3 曲目或碟片编码不支持。');
  let cursor: number = 1;
  let little: boolean = false;
  let terminated: boolean = false;
  const chars: number[] = [];
  if (encoding === 1) {
    if (data.length < 3) throw new Error('ID3 UTF-16 缺少字节序标记。');
    if (data[1] === 0xff && data[2] === 0xfe) little = true;
    else if (data[1] !== 0xfe || data[2] !== 0xff) throw new Error('ID3 UTF-16 字节序无效。');
    cursor = 3;
  }
  if (encoding === 1 || encoding === 2) {
    if ((data.length - cursor) % 2 !== 0) throw new Error('ID3 UTF-16 文本不完整。');
    while (cursor < data.length) {
      const unit: number = little ? data[cursor] + data[cursor + 1] * 256 : data[cursor] * 256 + data[cursor + 1];
      cursor += 2;
      if (unit === 0) { if (cursor !== data.length) throw new Error('ID3 数字帧含多个值。'); terminated = true; break; }
      chars.push(unit);
    }
  } else {
    while (cursor < data.length) {
      const unit: number = data[cursor++];
      if (unit === 0) { if (cursor !== data.length) throw new Error('ID3 数字帧含多个值。'); terminated = true; break; }
      chars.push(unit);
    }
  }
  let first: string = '';
  let total: string = '';
  let hasTotal: boolean = false;
  for (let i: number = 0; i < chars.length; i++) {
    if (chars[i] === 47 && !hasTotal && first.length > 0) { hasTotal = true; continue; }
    if (chars[i] < 48 || chars[i] > 57) throw new Error('ID3 曲目或碟片格式不明确。');
    if (hasTotal) total += String.fromCharCode(chars[i]); else first += String.fromCharCode(chars[i]);
    if (first.length > 20 || total.length > 20) throw new Error('ID3 曲目或碟片数值过长。');
  }
  if (first.length === 0 || (hasTotal && total.length === 0)) throw new Error('ID3 曲目或碟片格式不完整。');
  return { first, total, hasTotal, encoding, little, terminated };
}

function encodeNumber(text: string, state: NumberText): Uint8Array {
  const wide: boolean = state.encoding === 1 || state.encoding === 2;
  const bom: number = state.encoding === 1 ? 2 : 0;
  const end: number = state.terminated ? (wide ? 2 : 1) : 0;
  const out: Uint8Array = new Uint8Array(1 + bom + text.length * (wide ? 2 : 1) + end);
  out[0] = state.encoding;
  let pos: number = 1;
  if (bom > 0) { out[pos++] = state.little ? 0xff : 0xfe; out[pos++] = state.little ? 0xfe : 0xff; }
  for (let i: number = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (!wide) out[pos++] = code;
    else if (state.little) { out[pos++] = code; out[pos++] = 0; }
    else { out[pos++] = 0; out[pos++] = code; }
  }
  return out;
}

async function planEdit(fd: number, frames: Frame[], id: string, version: number,
  firstChange: number | undefined, totalChange: number | undefined): Promise<Edit | undefined> {
  if (firstChange === undefined && totalChange === undefined) return undefined;
  let original: Frame | undefined = undefined;
  for (let i: number = 0; i < frames.length; i++) {
    if (frames[i].id !== id) continue;
    if (original !== undefined) throw new Error('ID3 曲目或碟片帧重复，无法确定要修改的值。');
    original = frames[i];
  }
  if (original !== undefined && original.flags !== 0) throw new Error('待修改的 ID3 数字帧含特殊标志。');
  let old: NumberText = { first: '', total: '', hasTotal: false, encoding: 0, little: false, terminated: false };
  if (original !== undefined) {
    if (original.dataSize > 128) throw new Error('ID3 数字帧过大。');
    old = parseNumber(await readAt(fd, original.start + 10, original.dataSize), version);
  }
  const first: string = firstChange === undefined ? old.first : (firstChange === 0 ? '' : firstChange.toString());
  const total: string = totalChange === undefined ? (old.hasTotal ? old.total : '') :
    (totalChange === 0 ? '' : totalChange.toString());
  if (first.length === 0 && total.length > 0) throw new Error('不能仅保留总数而清除曲目或碟片序号。');
  if (first.length === 0) return { id, replacement: undefined, original };
  const body: Uint8Array = encodeNumber(first + (total.length > 0 ? '/' + total : ''), old);
  const replacement: Uint8Array = new Uint8Array(10 + body.length);
  for (let i: number = 0; i < 4; i++) replacement[i] = id.charCodeAt(i);
  putSize(replacement, 4, body.length, version === 4);
  replacement.set(body, 10);
  return { id, replacement, original };
}

function uniqueFrame(frames: Frame[], id: string): Frame | undefined {
  let found: Frame | undefined = undefined;
  for (let i: number = 0; i < frames.length; i++) {
    if (frames[i].id !== id) continue;
    if (found !== undefined) throw new Error('待修改的 ID3 字段存在多个帧：' + id);
    found = frames[i];
  }
  if (found !== undefined && found.flags !== 0) throw new Error('待修改的 ID3 帧包含不支持的标志：' + id);
  return found;
}

function singleText(data: Uint8Array, version: number): string {
  if (data.length === 0 || data.length > BLOCK) throw new Error('ID3 文本为空或过长。');
  const enc: number = data[0];
  if (enc > 3 || (version === 3 && enc > 1)) throw new Error('ID3 文本编码不支持。');
  let pos: number = 1;
  let little: boolean = false;
  let result: string = '';
  if (enc === 1) {
    if (data.length < 3) throw new Error('ID3 文本缺少字节序标记。');
    if (data[1] === 255 && data[2] === 254) little = true;
    else if (data[1] !== 254 || data[2] !== 255) throw new Error('ID3 字节序标记无效。');
    pos = 3;
  }
  if (enc === 1 || enc === 2) {
    if ((data.length - pos) % 2 !== 0) throw new Error('ID3 UTF-16 不完整。');
    while (pos < data.length) {
      const unit: number = little ? data[pos] + data[pos + 1] * 256 : data[pos] * 256 + data[pos + 1];
      pos += 2;
      if (unit === 0) { if (pos !== data.length) throw new Error('待修改的 ID3 文本包含多个值。'); break; }
      if (unit >= 0xdc00 && unit <= 0xdfff) throw new Error('ID3 UTF-16 代理对无效。');
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (pos + 2 > data.length) throw new Error('ID3 UTF-16 代理对不完整。');
        const low: number = little ? data[pos] + data[pos + 1] * 256 : data[pos] * 256 + data[pos + 1];
        if (low < 0xdc00 || low > 0xdfff) throw new Error('ID3 UTF-16 代理对无效。');
        result += String.fromCharCode(unit, low); pos += 2;
      } else result += String.fromCharCode(unit);
    }
  } else {
    // We only need ASCII semantics here (year and separators); validate UTF-8
    // separately in the independent integrity checker before source commit.
    for (; pos < data.length; pos++) {
      const unit: number = data[pos];
      if (unit === 0) { if (pos !== data.length - 1) throw new Error('待修改的 ID3 文本包含多个值。'); break; }
      result += String.fromCharCode(unit);
    }
  }
  return result;
}

function utf16Body(text: string): Uint8Array {
  if (text.length > 120000 || text.indexOf('\u0000') >= 0) throw new Error('ID3 文本过长或含空字符。');
  const data: Uint8Array = new Uint8Array(3 + text.length * 2);
  data[0] = 1; data[1] = 255; data[2] = 254;
  for (let i: number = 0; i < text.length; i++) {
    const unit: number = text.charCodeAt(i);
    if (unit >= 0xdc00 && unit <= 0xdfff && (i === 0 || text.charCodeAt(i - 1) < 0xd800 || text.charCodeAt(i - 1) > 0xdbff)) {
      throw new Error('文本包含无效的 Unicode 代理对。');
    }
    if (unit >= 0xd800 && unit <= 0xdbff && (i + 1 >= text.length || text.charCodeAt(i + 1) < 0xdc00 || text.charCodeAt(i + 1) > 0xdfff)) {
      throw new Error('文本包含无效的 Unicode 代理对。');
    }
    data[3 + i * 2] = unit & 255; data[4 + i * 2] = unit >> 8;
  }
  return data;
}

function makeFrame(id: string, data: Uint8Array, version: number): Uint8Array {
  const result: Uint8Array = new Uint8Array(10 + data.length);
  for (let i: number = 0; i < 4; i++) result[i] = id.charCodeAt(i);
  putSize(result, 4, data.length, version === 4);
  result.set(data, 10);
  return result;
}

async function planText(fd: number, frames: Frame[], id: string, version: number, value: string | undefined): Promise<Edit | undefined> {
  if (value === undefined) return undefined;
  const original: Frame | undefined = uniqueFrame(frames, id);
  if (original !== undefined) {
    if (original.dataSize > BLOCK) throw new Error('待修改的 ID3 文本帧过大。');
    const old: string = singleText(await readAt(fd, original.start + 10, original.dataSize), version);
    if ((id === 'TPE1' || id === 'TPE2' || id === 'TCOM' || id === 'TCON') && old.indexOf('/') >= 0) throw new Error('标签可能包含多个值。');
    if ((id === 'TYER' || id === 'TDRC') && !/^[0-9]{4}$/.test(old)) throw new Error('原始日期含月日或不明确，无法仅修改年份。');
  }
  if ((id === 'TPE1' || id === 'TPE2' || id === 'TCOM' || id === 'TCON') && value.indexOf('/') >= 0) throw new Error('标签包含有歧义的分隔符。');
  return { id, original, replacement: value.length === 0 ? undefined : makeFrame(id, utf16Body(value), version) };
}

async function planDescribedText(fd: number, frames: Frame[], id: string, version: number, value: string | undefined): Promise<Edit | undefined> {
  if (value === undefined) return undefined;
  const original: Frame | undefined = uniqueFrame(frames, id);
  let language: Uint8Array = new Uint8Array([101, 110, 103]);
  if (original !== undefined) {
    if (original.dataSize > BLOCK || original.dataSize < 5) throw new Error('歌词或备注帧无效或过大。');
    const old: Uint8Array = await readAt(fd, original.start + 10, original.dataSize);
    if (old[0] > 3 || (version === 3 && old[0] > 1)) throw new Error('歌词或备注编码不支持。');
    for (let i: number = 1; i <= 3; i++) if (old[i] < 97 || old[i] > 122) throw new Error('歌词或备注语言代码无效。');
    language = old.slice(1, 4);
    let pos: number = 4;
    if (old[0] === 1) {
      if (old.length < pos + 2) throw new Error('歌词或备注描述不完整。');
      if ((old[pos] === 255 && old[pos + 1] === 254) || (old[pos] === 254 && old[pos + 1] === 255)) pos += 2;
    }
    if (old[0] === 1 || old[0] === 2) {
      if (old.length < pos + 2 || old[pos] !== 0 || old[pos + 1] !== 0) throw new Error('歌词或备注有非空描述，无法安全替换。');
    } else if (old[pos] !== 0) throw new Error('歌词或备注有非空描述，无法安全替换。');
  }
  if (value.length === 0) return { id, original, replacement: undefined };
  const text: Uint8Array = utf16Body(value);
  const body: Uint8Array = new Uint8Array(1 + 3 + 2 + 2 + 2 + text.length - 3);
  body[0] = 1; body.set(language, 1); body[4] = 255; body[5] = 254; // empty UTF-16 description
  body[8] = 255; body[9] = 254;
  body.set(text.slice(3), 10);
  return { id, original, replacement: makeFrame(id, body, version) };
}

async function planCover(fd: number, frames: Frame[], version: number, cover: image.PixelMap | undefined): Promise<Edit | undefined> {
  if (cover === undefined) return undefined;
  const original: Frame | undefined = uniqueFrame(frames, 'APIC');
  if (original !== undefined) {
    const old: Uint8Array = await readAt(fd, original.start + 10, Math.min(original.dataSize, 1024));
    if (old.length < 5 || old[0] > 3 || (version === 3 && old[0] > 1)) throw new Error('原封面描述编码不支持。');
    let pos: number = 1;
    while (pos < old.length && old[pos] !== 0) pos++;
    if (pos + 2 >= old.length || old[pos + 1] !== 3) throw new Error('原封面不是唯一的前封面。');
    let description: number = pos + 2;
    if (old[0] === 1) {
      if (description + 1 >= old.length) throw new Error('原封面描述不完整。');
      if ((old[description] === 255 && old[description + 1] === 254) ||
          (old[description] === 254 && old[description + 1] === 255)) description += 2;
    }
    if (old[0] === 1 || old[0] === 2) {
      if (description + 2 >= old.length || old[description] !== 0 || old[description + 1] !== 0) {
        throw new Error('原封面包含非空描述，无法安全替换。');
      }
    } else if (old[description] !== 0 || description + 1 >= old.length) {
      throw new Error('原封面包含非空描述，无法安全替换。');
    }
  }
  const info: image.ImageInfo = await cover.getImageInfo();
  if (info.isHdr || info.size.width <= 0 || info.size.height <= 0 || info.size.width * info.size.height > 16777216) throw new Error('封面尺寸或格式不支持。');
  const packer: image.ImagePacker = image.createImagePacker();
  try {
    const data: ArrayBuffer = await packer.packToData(cover, { format: 'image/png', quality: 100, bufferSize: 8388608 });
    if (data.byteLength <= 0 || data.byteLength > 8388608) throw new Error('封面编码失败或文件过大。');
    const prefix: Uint8Array = new Uint8Array([0, 105, 109, 97, 103, 101, 47, 112, 110, 103, 0, 3, 0]);
    const body: Uint8Array = new Uint8Array(prefix.length + data.byteLength);
    body.set(prefix, 0); body.set(new Uint8Array(data), prefix.length);
    return { id: 'APIC', original, replacement: makeFrame('APIC', body, version) };
  } finally { try { await packer.release(); } catch (_error) {} }
}

/** Read ID3v2 number/total pairs from the app-private imported snapshot. */
export async function readMp3Numbers(privateRoot: string, sourcePath: string): Promise<Mp3Numbers> {
  checkPrivatePath(privateRoot, sourcePath);
  const source: fileIo.File = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
  try {
    const st: fileIo.Stat = fileIo.statSync(source.fd);
    if (!st.isFile() || !Number.isSafeInteger(st.size) || st.size < 11) throw new Error('MP3 工作副本无效。');
    const head: Uint8Array = await readAt(source.fd, 0, 10);
    const version: number = head[3];
    if (head[0] !== 73 || head[1] !== 68 || head[2] !== 51 || (version !== 3 && version !== 4) || head[4] !== 0 || head[5] !== 0) {
      throw new Error('仅支持无特殊标志的 ID3v2.3/2.4。');
    }
    const tagSize: number = getSize(head, 6, true);
    if (tagSize > MAX_TAG || tagSize > st.size - 11) throw new Error('ID3 标签过大或不完整。');
    const end: number = 10 + tagSize;
    const frames: Frame[] = [];
    let pos: number = 10;
    while (pos < end) {
      if ((await readAt(source.fd, pos, 1))[0] === 0) { await checkPadding(source.fd, pos, end - pos); break; }
      if (frames.length >= MAX_FRAMES || end - pos < 10) throw new Error('ID3 帧头不完整或帧数过多。');
      const frame: Uint8Array = await readAt(source.fd, pos, 10);
      let id: string = '';
      for (let i: number = 0; i < 4; i++) {
        if (!((frame[i] >= 65 && frame[i] <= 90) || (frame[i] >= 48 && frame[i] <= 57))) throw new Error('ID3 帧标识无效。');
        id += String.fromCharCode(frame[i]);
      }
      const length: number = getSize(frame, 4, version === 4);
      if (length <= 0 || length > end - pos - 10) throw new Error('ID3 帧长度无效。');
      frames.push({ id, start: pos, size: 10 + length, dataSize: length, flags: frame[8] * 256 + frame[9] });
      pos += 10 + length;
    }
    const result: Mp3Numbers = { track: 0, trackTotal: 0, disc: 0, discTotal: 0 };
    for (let i: number = 0; i < 2; i++) {
      const id: string = i === 0 ? 'TRCK' : 'TPOS';
      const frame: Frame | undefined = uniqueFrame(frames, id);
      if (frame === undefined) continue;
      if (frame.dataSize > 128) throw new Error('ID3 数字帧过大。');
      const parsed: NumberText = parseNumber(await readAt(source.fd, frame.start + 10, frame.dataSize), version);
      const first: number = Number(parsed.first);
      const total: number = parsed.hasTotal ? Number(parsed.total) : 0;
      if (!Number.isSafeInteger(first) || !Number.isSafeInteger(total) || first > 99999 || total > 99999) {
        throw new Error('ID3 曲目或碟片数值超出支持范围。');
      }
      if (i === 0) { result.track = first; result.trackTotal = total; }
      else { result.disc = first; result.discTotal = total; }
    }
    return result;
  } finally { try { fileIo.closeSync(source.fd); } catch (_error) {} }
}

/** The returned path is a new app-private staging file; input is not modified. */
export async function writeMp3MetadataCopy(privateRoot: string, sourcePath: string, changes: AudioMetadataWriter): Promise<string> {
  const root: string = checkPrivatePath(privateRoot, sourcePath);
  validateChange(changes.track); validateChange(changes.trackTotal); validateChange(changes.disc); validateChange(changes.discTotal);
  validateChange(changes.bpm); validateChange(changes.year);
  if (changes.year !== undefined && changes.year > 9999) throw new Error('年份超出有效范围。');
  const source: fileIo.File = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
  let output: fileIo.File | undefined = undefined;
  let dir: string = '';
  let path: string = '';
  let completed: boolean = false;
  try {
    const stat: fileIo.Stat = fileIo.statSync(source.fd);
    if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size < 11) throw new Error('ID3 工作副本无效。');
    let header: Uint8Array = await readAt(source.fd, 0, 10);
    const bare: boolean = header[0] !== 73 || header[1] !== 68 || header[2] !== 51;
    let version: number = header[3];
    let oldSize: number = 0;
    let end: number = 0;
    let cursor: number = 0;
    if (bare) {
      // No user file is modified. Validate every frame, all the way to EOF,
      // then require the system extractor to confirm an MPEG audio track.
      await assertBareMp3Frames(source.fd, stat.size);
      const metadata: AudioMetadata = await readMp3Metadata(sourcePath);
      await fillAudioProperties(sourcePath, metadata, true);
      const byPath: fileIo.Stat = fileIo.statSync(sourcePath);
      if (!byPath.isFile() || byPath.size !== stat.size || byPath.ino !== stat.ino ||
          fileIo.statSync(source.fd).size !== stat.size) {
        throw new Error('验证期间 MP3 工作副本发生变化。');
      }
      header = new Uint8Array([73, 68, 51, 4, 0, 0, 0, 0, 0, 0]);
      version = 4;
    } else {
      if ((version !== 3 && version !== 4) || header[4] !== 0 || header[5] !== 0) {
        throw new Error('仅支持无特殊标志的 ID3v2.3/2.4 工作副本。');
      }
      oldSize = getSize(header, 6, true);
      if (oldSize > MAX_TAG || oldSize > stat.size - 11) throw new Error('ID3 元数据过大或不完整。');
      end = 10 + oldSize;
      cursor = 10;
    }
    const frames: Frame[] = [];
    while (cursor < end) {
      if ((await readAt(source.fd, cursor, 1))[0] === 0) { await checkPadding(source.fd, cursor, end - cursor); break; }
      if (frames.length >= MAX_FRAMES || end - cursor < 10) throw new Error('ID3 帧头不完整或帧数超限。');
      const raw: Uint8Array = await readAt(source.fd, cursor, 10);
      let id: string = '';
      for (let i: number = 0; i < 4; i++) {
        if (!((raw[i] >= 65 && raw[i] <= 90) || (raw[i] >= 48 && raw[i] <= 57))) throw new Error('ID3 帧标识无效。');
        id += String.fromCharCode(raw[i]);
      }
      const dataSize: number = getSize(raw, 4, version === 4);
      if (dataSize <= 0 || dataSize > end - cursor - 10) throw new Error('ID3 帧长度无效。');
      frames.push({ id, start: cursor, size: 10 + dataSize, dataSize, flags: raw[8] * 256 + raw[9] });
      cursor += 10 + dataSize;
    }
    const paddingStart: number = cursor;
    const edits: Edit[] = [];
    const track: Edit | undefined = await planEdit(source.fd, frames, 'TRCK', version, changes.track, changes.trackTotal);
    const disc: Edit | undefined = await planEdit(source.fd, frames, 'TPOS', version, changes.disc, changes.discTotal);
    if (track !== undefined) edits.push(track);
    if (disc !== undefined) edits.push(disc);
    if (changes.year !== undefined) {
      const alternate: string = version === 3 ? 'TDRC' : 'TYER';
      if (uniqueFrame(frames, alternate) !== undefined) throw new Error('年份存在非标准别名，无法安全修改。');
      const related: string[] = ['TDAT', 'TIME', 'TORY', 'TDOR'];
      for (let i: number = 0; i < related.length; i++) {
        if (uniqueFrame(frames, related[i]) !== undefined) throw new Error('存在额外日期标签，无法仅修改年份。');
      }
    }
    const textFields: TextField[] = [
      { id: 'TIT2', value: changes.title }, { id: 'TPE1', value: changes.artist },
      { id: 'TALB', value: changes.album }, { id: 'TCON', value: changes.genre },
      { id: 'TPE2', value: changes.albumArtist }, { id: 'TCOM', value: changes.composer },
      { id: 'TIT1', value: changes.grouping }, { id: 'TSRC', value: changes.isrc },
      { id: 'TCOP', value: changes.copyright },
      { id: version === 3 ? 'TYER' : 'TDRC', value: changes.year === undefined ? undefined : (changes.year === 0 ? '' : changes.year.toString().padStart(4, '0')) },
      { id: 'TBPM', value: changes.bpm === undefined ? undefined : (changes.bpm === 0 ? '' : changes.bpm.toString()) }
    ];
    for (let i: number = 0; i < textFields.length; i++) {
      const edit: Edit | undefined = await planText(source.fd, frames, textFields[i].id, version, textFields[i].value);
      if (edit !== undefined) edits.push(edit);
    }
    const lyrics: Edit | undefined = await planDescribedText(source.fd, frames, 'USLT', version, changes.lyrics);
    const comment: Edit | undefined = await planDescribedText(source.fd, frames, 'COMM', version, changes.comment);
    const cover: Edit | undefined = await planCover(source.fd, frames, version, changes.coverImage);
    if (lyrics !== undefined) edits.push(lyrics);
    if (comment !== undefined) edits.push(comment);
    if (cover !== undefined) edits.push(cover);
    if (edits.length === 0) throw new Error('没有需要写入的 MP3 标签更改。');
    let newSize: number = oldSize;
    for (let i: number = 0; i < edits.length; i++) {
      if (edits[i].original !== undefined) newSize -= edits[i].original!.size;
      if (edits[i].replacement !== undefined) newSize += edits[i].replacement!.length;
    }
    if (newSize < 0 || newSize > MAX_TAG) throw new Error('更新后的 ID3 元数据超限。');
    putSize(header, 6, newSize, true);
    dir = fileIo.mkdtempSync(root + '/lyricflow_id3_XXXXXX');
    path = dir + '/edited.mp3';
    output = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    await writeAll(output.fd, header);
    for (let i: number = 0; i < frames.length; i++) {
      let matched: Edit | undefined = undefined;
      for (let j: number = 0; j < edits.length; j++) if (edits[j].original === frames[i]) matched = edits[j];
      if (matched === undefined) await copyRegion(source.fd, output.fd, frames[i].start, frames[i].size);
      else if (matched.replacement !== undefined) await writeAll(output.fd, matched.replacement);
    }
    for (let i: number = 0; i < edits.length; i++) {
      if (edits[i].original === undefined && edits[i].replacement !== undefined) await writeAll(output.fd, edits[i].replacement!);
    }
    await copyRegion(source.fd, output.fd, paddingStart, end - paddingStart);
    await copyRegion(source.fd, output.fd, end, stat.size - end);
    if (fileIo.statSync(source.fd).size !== stat.size || fileIo.statSync(output.fd).size !== stat.size + newSize - oldSize + (bare ? 10 : 0)) {
      throw new Error('ID3 副本长度校验失败。');
    }
    fileIo.fsyncSync(output.fd);
    completed = true;
    return path;
  } finally {
    if (output !== undefined) { try { fileIo.closeSync(output.fd); } catch (_error) {} }
    try { fileIo.closeSync(source.fd); } catch (_error) {}
    if (!completed && path.length > 0) { try { fileIo.unlinkSync(path); } catch (_error) {} }
    if (!completed && dir.length > 0) { try { fileIo.rmdirSync(dir); } catch (_error) {} }
  }
}
