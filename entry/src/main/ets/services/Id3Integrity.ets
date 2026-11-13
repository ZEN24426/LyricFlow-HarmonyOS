import { fileIo } from '@kit.CoreFileKit';
import { AudioMetadataWriter } from '@dabing/taglib_harmony';

// Conservative ID3v2.3 / 2.4 verifier. Unsupported tags are rejected.
const IO_CHUNK: number = 256 * 1024;
const MAX_TAG: number = 16 * 1024 * 1024;
const MAX_TEXT: number = 256 * 1024;
const MAX_FRAMES: number = 4096;

interface Id3Frame { id: string; start: number; length: number; dataStart: number; dataLength: number; }
interface Id3Layout { version: number; tail: number; size: number; frames: Id3Frame[]; }
interface FrameGroup { ids: string[]; before: number; after: number; }
interface NumberParts { first: string; total: string; hasTotal: boolean; }
interface StructuredValue { language: string; value: string; }

async function readAt(fd: number, offset: number, length: number): Promise<Uint8Array> {
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(length) || length < 0 || length > MAX_TEXT) {
    throw new Error('ID3 读取范围无效。');
  }
  const result: Uint8Array = new Uint8Array(length);
  let done: number = 0;
  while (done < length) {
    if (fileIo.lseek(fd, offset + done, fileIo.WhenceType.SEEK_SET) !== offset + done) {
      throw new Error('ID3 无法可靠定位。');
    }
    const buf: ArrayBuffer = new ArrayBuffer(length - done);
    const count: number = await fileIo.read(fd, buf, { length: length - done });
    if (count <= 0 || count > length - done) throw new Error('ID3 读取不完整。');
    result.set(new Uint8Array(buf, 0, count), done);
    done += count;
  }
  return result;
}

function size32(bytes: Uint8Array, start: number, synchsafe: boolean): number {
  let result: number = 0;
  for (let i: number = 0; i < 4; i++) {
    const byte: number = bytes[start + i];
    if (synchsafe && byte >= 128) throw new Error('ID3 synchsafe 长度无效。');
    result = result * (synchsafe ? 128 : 256) + byte;
  }
  return result;
}

async function assertZero(fd: number, offset: number, length: number): Promise<void> {
  for (let done: number = 0; done < length;) {
    const count: number = Math.min(IO_CHUNK, length - done);
    const bytes: Uint8Array = await readAt(fd, offset + done, count);
    for (let i: number = 0; i < count; i++) if (bytes[i] !== 0) throw new Error('ID3 填充区含非零数据。');
    done += count;
  }
}

async function parseId3(fd: number): Promise<Id3Layout> {
  const st: fileIo.Stat = fileIo.statSync(fd);
  if (!st.isFile() || !Number.isSafeInteger(st.size) || st.size < 11) throw new Error('MP3 文件无效或为空。');
  const h: Uint8Array = await readAt(fd, 0, 10);
  if (h[0] !== 0x49 || h[1] !== 0x44 || h[2] !== 0x33 || (h[3] !== 3 && h[3] !== 4) ||
      h[4] !== 0 || h[5] !== 0) {
    throw new Error('仅支持无扩展头、无不同步处理和无特殊标志的 ID3v2.3/2.4。');
  }
  const tagSize: number = size32(h, 6, true);
  if (tagSize > MAX_TAG || tagSize > st.size - 11) throw new Error('ID3 标签过大或不完整。');
  const end: number = 10 + tagSize;
  let offset: number = 10;
  const frames: Id3Frame[] = [];
  while (offset < end) {
    const first: Uint8Array = await readAt(fd, offset, 1);
    if (first[0] === 0) { await assertZero(fd, offset, end - offset); offset = end; break; }
    if (frames.length >= MAX_FRAMES || end - offset < 10) throw new Error('ID3 帧头不完整或帧数过多。');
    const frame: Uint8Array = await readAt(fd, offset, 10);
    let id: string = '';
    for (let i: number = 0; i < 4; i++) {
      if (!((frame[i] >= 0x41 && frame[i] <= 0x5a) || (frame[i] >= 0x30 && frame[i] <= 0x39))) {
        throw new Error('ID3 帧标识无效。');
      }
      id += String.fromCharCode(frame[i]);
    }
    if (frame[8] !== 0 || frame[9] !== 0) throw new Error('ID3 帧含压缩、加密或其他不支持的标志。');
    const length: number = size32(frame, 4, h[3] === 4);
    if (length <= 0 || length > end - offset - 10) throw new Error('ID3 帧长度无效。');
    frames.push({ id, start: offset, length: 10 + length, dataStart: offset + 10, dataLength: length });
    offset += 10 + length;
  }
  return { version: h[3], tail: end, size: st.size, frames };
}

async function equalRegions(a: number, posA: number, b: number, posB: number, length: number): Promise<boolean> {
  for (let done: number = 0; done < length;) {
    const count: number = Math.min(IO_CHUNK, length - done);
    const left: Uint8Array = await readAt(a, posA + done, count);
    const right: Uint8Array = await readAt(b, posB + done, count);
    for (let i: number = 0; i < count; i++) if (left[i] !== right[i]) return false;
    done += count;
  }
  return true;
}

async function hasMagic(fd: number, offset: number, magic: string): Promise<boolean> {
  if (offset < 0) return false;
  const bytes: Uint8Array = await readAt(fd, offset, magic.length);
  for (let i: number = 0; i < magic.length; i++) if (bytes[i] !== magic.charCodeAt(i)) return false;
  return true;
}

/** Do not leave older, contradictory copies of edited metadata at EOF. */
async function refuseCompetingTailTags(fd: number, layout: Id3Layout): Promise<void> {
  const tailLength: number = layout.size - layout.tail;
  if (tailLength >= 10 && await hasMagic(fd, layout.tail, 'ID3')) {
    throw new Error('MP3 包含多个连续 ID3v2 标签，无法安全同步；请先使用副本处理。');
  }
  const hasId3v1: boolean = tailLength >= 128 && await hasMagic(fd, layout.size - 128, 'TAG');
  // Standard APEv2 places its 32-byte footer at EOF or immediately before
  // ID3v1. Reject such dual-tag files before any source modification.
  const apeAtEnd: boolean = tailLength >= 32 && await hasMagic(fd, layout.size - 32, 'APETAGEX');
  const apeBeforeId3: boolean = hasId3v1 && tailLength >= 160 && await hasMagic(fd, layout.size - 160, 'APETAGEX');
  if (apeAtEnd || apeBeforeId3) {
    throw new Error('MP3 包含尾部 APEv2 标签，无法同时安全更新两份标签；请先使用副本处理。');
  }
  const lyricsAtEnd: boolean = tailLength >= 9 && (await hasMagic(fd, layout.size - 9, 'LYRICS200') ||
    await hasMagic(fd, layout.size - 9, 'LYRICSEND'));
  const lyricsBeforeId3: boolean = hasId3v1 && tailLength >= 137 &&
    (await hasMagic(fd, layout.size - 137, 'LYRICS200') || await hasMagic(fd, layout.size - 137, 'LYRICSEND'));
  if (lyricsAtEnd || lyricsBeforeId3) {
    throw new Error('MP3 包含尾部 Lyrics3 标签，无法同时安全更新两份标签；请先使用副本处理。');
  }
  const id3AtEnd: boolean = tailLength >= 10 && await hasMagic(fd, layout.size - 10, '3DI');
  const id3BeforeId3v1: boolean = hasId3v1 && tailLength >= 138 && await hasMagic(fd, layout.size - 138, '3DI');
  if (id3AtEnd || id3BeforeId3v1) {
    throw new Error('MP3 包含尾部 ID3v2 标签，无法同时安全更新两份标签；请先使用副本处理。');
  }
  if (hasId3v1) {
    throw new Error('MP3 包含尾部 ID3v1 标签，无法同时安全更新两份标签；请先使用副本处理。');
  }
}

function addGroup(groups: FrameGroup[], ids: string[]): void { groups.push({ ids, before: 0, after: 0 }); }

function makeGroups(fields: AudioMetadataWriter, version: number): FrameGroup[] {
  const groups: FrameGroup[] = [];
  if (fields.title !== undefined) addGroup(groups, ['TIT2']);
  if (fields.artist !== undefined) addGroup(groups, ['TPE1']);
  if (fields.album !== undefined) addGroup(groups, ['TALB']);
  if (fields.genre !== undefined) addGroup(groups, ['TCON']);
  if (fields.year !== undefined) addGroup(groups, [version === 3 ? 'TYER' : 'TDRC']);
  if (fields.comment !== undefined) addGroup(groups, ['COMM']);
  if (fields.lyrics !== undefined) addGroup(groups, ['USLT']);
  if (fields.coverImage !== undefined) addGroup(groups, ['APIC']);
  if (fields.albumArtist !== undefined) addGroup(groups, ['TPE2']);
  if (fields.composer !== undefined) addGroup(groups, ['TCOM']);
  if (fields.grouping !== undefined) addGroup(groups, ['TIT1']);
  if (fields.isrc !== undefined) addGroup(groups, ['TSRC']);
  if (fields.copyright !== undefined) addGroup(groups, ['TCOP']);
  if (fields.bpm !== undefined) addGroup(groups, ['TBPM']);
  if (fields.track !== undefined || fields.trackTotal !== undefined) addGroup(groups, ['TRCK']);
  if (fields.disc !== undefined || fields.discTotal !== undefined) addGroup(groups, ['TPOS']);
  // v2.3 and v2.4 both have the IDs above; version changes are rejected later.
  if (version !== 3 && version !== 4) throw new Error('不支持的 ID3 版本。');
  return groups;
}

function findGroup(groups: FrameGroup[], id: string): FrameGroup | undefined {
  for (let i: number = 0; i < groups.length; i++) if (groups[i].ids.indexOf(id) >= 0) return groups[i];
  return undefined;
}

function frameById(frames: Id3Frame[], id: string): Id3Frame | undefined {
  for (let i: number = 0; i < frames.length; i++) if (frames[i].id === id) return frames[i];
  return undefined;
}

// Return text code units while rejecting multiple values and malformed UTF-16.
// Encodings 0/3 can contain only one value; encoding 1 must have a BOM.
// Encoding 2 is allowed only by ID3v2.4. Terminators are accepted at the end.
async function textUnits(fd: number, frame: Id3Frame, version: number): Promise<number[]> {
  if (frame.dataLength > MAX_TEXT) throw new Error('待修改 ID3 文本帧过大。');
  const data: Uint8Array = await readAt(fd, frame.dataStart, frame.dataLength);
  return decodeTextUnits(data, version);
}

function decodeTextUnits(data: Uint8Array, version: number): number[] {
  if (data.length === 0) throw new Error('ID3 文本帧缺少编码字节。');
  const encoding: number = data[0];
  if (encoding > 3 || (version === 3 && encoding > 1)) throw new Error('待修改 ID3 文本编码不支持。');
  const result: number[] = [];
  if (encoding === 0 || encoding === 3) {
    for (let i: number = 1; i < data.length; i++) {
      if (data[i] === 0) {
        if (i !== data.length - 1) throw new Error('待修改 ID3 文本含多个值。');
        break;
      }
      result.push(data[i]);
    }
    if (encoding === 3) {
      const decoded: number[] = [];
      for (let i: number = 0; i < result.length;) {
        const lead: number = result[i];
        if (lead < 0x80) { decoded.push(lead); i++; continue; }
        let count: number = 0;
        if (lead >= 0xc2 && lead <= 0xdf) count = 2;
        else if (lead >= 0xe0 && lead <= 0xef) count = 3;
        else if (lead >= 0xf0 && lead <= 0xf4) count = 4;
        if (count === 0 || i + count > result.length) throw new Error('ID3 UTF-8 数据无效。');
        for (let j: number = 1; j < count; j++) {
          if (result[i + j] < 0x80 || result[i + j] > 0xbf) throw new Error('ID3 UTF-8 数据无效。');
        }
        const second: number = result[i + 1];
        if ((lead === 0xe0 && second < 0xa0) || (lead === 0xed && second > 0x9f) ||
            (lead === 0xf0 && second < 0x90) || (lead === 0xf4 && second > 0x8f)) {
          throw new Error('ID3 UTF-8 数据无效。');
        }
        let point: number = lead & (count === 2 ? 0x1f : (count === 3 ? 0x0f : 0x07));
        for (let j: number = 1; j < count; j++) point = point * 64 + (result[i + j] & 0x3f);
        if (point <= 0xffff) decoded.push(point);
        else {
          point -= 0x10000;
          decoded.push(0xd800 + Math.floor(point / 1024), 0xdc00 + point % 1024);
        }
        i += count;
      }
      return decoded;
    }
  } else {
    let index: number = 1;
    let little: boolean = false;
    if (encoding === 1) {
      if (data.length < 3) throw new Error('ID3 UTF-16 缺少字节序标记。');
      if (data[1] === 0xff && data[2] === 0xfe) little = true;
      else if (data[1] !== 0xfe || data[2] !== 0xff) throw new Error('ID3 UTF-16 字节序标记无效。');
      index = 3;
    }
    if ((data.length - index) % 2 !== 0) throw new Error('ID3 UTF-16 数据不完整。');
    while (index < data.length) {
      const unit: number = little ? data[index] + data[index + 1] * 256 : data[index] * 256 + data[index + 1];
      index += 2;
      if (unit === 0) {
        if (index !== data.length) throw new Error('待修改 ID3 文本含多个值。');
        break;
      }
      if (unit >= 0xdc00 && unit <= 0xdfff) throw new Error('ID3 UTF-16 代理对无效。');
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (index + 2 > data.length) throw new Error('ID3 UTF-16 代理对不完整。');
        const low: number = little ? data[index] + data[index + 1] * 256 : data[index] * 256 + data[index + 1];
        if (low < 0xdc00 || low > 0xdfff) throw new Error('ID3 UTF-16 代理对无效。');
        result.push(unit); result.push(low); index += 2;
      } else result.push(unit);
    }
  }
  return result;
}

async function checkExpectedText(fd: number, frames: Id3Frame[], id: string,
  expected: string | undefined, version: number): Promise<void> {
  if (expected === undefined) return;
  const frame: Id3Frame | undefined = frameById(frames, id);
  if (frame === undefined) {
    if (expected.length !== 0) throw new Error('写入后的 ID3 字段缺失：' + id);
    return;
  }
  const units: number[] = await textUnits(fd, frame, version);
  let actual: string = '';
  for (let i: number = 0; i < units.length; i++) actual += String.fromCharCode(units[i]);
  if (actual !== expected) throw new Error('写入后的 ID3 字段回读不一致：' + id);
}

function checkExpectedNumber(actual: string | undefined, expected: number | undefined, id: string): void {
  if (expected === undefined) return;
  if (!Number.isSafeInteger(expected) || expected < 0 || (actual === undefined ? expected !== 0 : Number(actual) !== expected)) {
    throw new Error('写入后的 ID3 数字回读不一致：' + id);
  }
}

async function checkExpectedNumericFrame(fd: number, frames: Id3Frame[], id: string,
  expected: number | undefined, version: number): Promise<void> {
  if (expected === undefined) return;
  const frame: Id3Frame | undefined = frameById(frames, id);
  if (frame === undefined) { checkExpectedNumber(undefined, expected, id); return; }
  const units: number[] = await textUnits(fd, frame, version);
  let digits: string = '';
  for (let i: number = 0; i < units.length; i++) {
    if (units[i] < 0x30 || units[i] > 0x39) throw new Error('写入后的 ID3 数字格式无效：' + id);
    digits += String.fromCharCode(units[i]);
  }
  if (digits.length === 0 || digits.length > 20) throw new Error('写入后的 ID3 数字格式无效：' + id);
  checkExpectedNumber(digits, expected, id);
}

async function numberParts(fd: number, frame: Id3Frame | undefined, version: number): Promise<NumberParts | undefined> {
  if (frame === undefined) return undefined;
  const units: number[] = await textUnits(fd, frame, version);
  let first: string = '';
  let total: string = '';
  let hasTotal: boolean = false;
  for (let i: number = 0; i < units.length; i++) {
    if (units[i] === 0x2f && !hasTotal && first.length > 0) { hasTotal = true; continue; }
    if (units[i] < 0x30 || units[i] > 0x39) throw new Error('ID3 曲目或碟片格式不明确。');
    if (hasTotal) total += String.fromCharCode(units[i]); else first += String.fromCharCode(units[i]);
    if (first.length > 20 || total.length > 20) throw new Error('ID3 曲目或碟片数字过长。');
  }
  if (first.length === 0 || (hasTotal && total.length === 0)) throw new Error('ID3 曲目或碟片格式不完整。');
  return { first, total, hasTotal };
}

function preserveNumberPart(before: NumberParts | undefined, after: NumberParts | undefined,
  firstChanged: boolean, totalChanged: boolean): void {
  if (!firstChanged && (before === undefined ? after !== undefined : after === undefined || before.first !== after.first)) {
    throw new Error('未修改的 ID3 曲目或碟片序号发生变化。');
  }
  if (!totalChanged && (before === undefined ? after !== undefined && after.hasTotal :
      after === undefined ? before.hasTotal : before.hasTotal !== after.hasTotal || before.total !== after.total)) {
    throw new Error('未修改的 ID3 曲目或碟片总数发生变化。');
  }
}

async function verifyEditedFrame(fd: number, frame: Id3Frame, version: number): Promise<void> {
  const text: number[] = await textUnits(fd, frame, version);
  // ID3v2.3 uses slash for multi-value people fields. The bridge does not
  // expose distinct values, so refuse ambiguous edited values in either version.
  if (frame.id === 'TPE1' || frame.id === 'TPE2' || frame.id === 'TCOM' || frame.id === 'TCON') {
    for (let i: number = 0; i < text.length; i++) if (text[i] === 0x2f) throw new Error('待修改的 ID3 人员字段可能包含多个值。');
  }
}

/**
 * A changed lyric/comment may have a language and description. Only a single
 * empty-description frame is editable; preserve its language when replacing it.
 */
async function structuredText(fd: number, frame: Id3Frame, version: number): Promise<StructuredValue> {
  if (frame.dataLength < 5 || frame.dataLength > MAX_TEXT) throw new Error('ID3 歌词或备注帧长度无效。');
  const data: Uint8Array = await readAt(fd, frame.dataStart, frame.dataLength);
  const enc: number = data[0];
  if (enc > 3 || (version === 3 && enc > 1)) throw new Error('ID3 歌词或备注编码不支持。');
  for (let i: number = 1; i <= 3; i++) {
    if (data[i] < 0x20 || data[i] > 0x7e) throw new Error('ID3 歌词或备注语言无效。');
  }
  let p: number = 4;
  if (enc === 1) {
    if (p + 1 >= data.length) throw new Error('ID3 描述不完整。');
    // ID3v2.3/2.4 allow an empty terminated UTF-16 string with or without a
    // BOM. Nonempty descriptions are rejected below in either representation.
    if ((data[p] === 0xff && data[p + 1] === 0xfe) ||
        (data[p] === 0xfe && data[p + 1] === 0xff)) p += 2;
  }
  const term: number = (enc === 1 || enc === 2) ? 2 : 1;
  if (p + term > data.length || data[p] !== 0 || (term === 2 && data[p + 1] !== 0)) {
    throw new Error('带描述的 ID3 歌词或备注不能安全修改。');
  }
  p += term;
  const valueBytes: Uint8Array = new Uint8Array(1 + data.length - p);
  valueBytes[0] = enc;
  valueBytes.set(data.subarray(p), 1);
  const units: number[] = decodeTextUnits(valueBytes, version);
  let value: string = '';
  for (let i: number = 0; i < units.length; i++) value += String.fromCharCode(units[i]);
  return { language: String.fromCharCode(data[1], data[2], data[3]), value };
}

/** Ensure an edited APIC is a single, undescribed, embedded front cover. */
async function checkFrontCover(fd: number, frame: Id3Frame, version: number): Promise<void> {
  if (frame.dataLength < 5) throw new Error('ID3 图片帧不完整。');
  // The picture itself can be large: inspect only the bounded header.
  const data: Uint8Array = await readAt(fd, frame.dataStart, Math.min(frame.dataLength, 1024));
  const enc: number = data[0];
  if (enc > 3 || (version === 3 && enc > 1)) throw new Error('ID3 封面描述编码不支持。');
  let p: number = 1;
  let mime: string = '';
  while (p < data.length && data[p] !== 0) {
    if (data[p] < 0x20 || data[p] > 0x7e || mime.length >= 255) throw new Error('ID3 封面 MIME 无效。');
    mime += String.fromCharCode(data[p++]);
  }
  if (p >= data.length || (mime.toLowerCase() !== 'image/png' && mime.toLowerCase() !== 'image/jpeg')) {
    throw new Error('仅支持内嵌 PNG 或 JPEG 前封面。');
  }
  p++;
  if (p >= data.length || data[p++] !== 3) throw new Error('仅支持修改前封面。');
  if (enc === 1) {
    if (p + 1 >= data.length) throw new Error('ID3 封面描述不完整。');
    if ((data[p] === 0xff && data[p + 1] === 0xfe) ||
        (data[p] === 0xfe && data[p + 1] === 0xff)) p += 2;
  }
  const term: number = (enc === 1 || enc === 2) ? 2 : 1;
  if (p + term >= frame.dataLength || p + term > data.length || data[p] !== 0 ||
      (term === 2 && data[p + 1] !== 0)) throw new Error('带描述或空内容的 ID3 封面不能安全修改。');
}

async function checkPureYear(fd: number, frame: Id3Frame, version: number): Promise<void> {
  const units: number[] = await textUnits(fd, frame, version);
  if (units.length !== 4) throw new Error('完整日期无法只修改年份而保留精度。');
  for (let i: number = 0; i < units.length; i++) {
    if (units[i] < 0x30 || units[i] > 0x39) throw new Error('完整日期无法只修改年份而保留精度。');
  }
}

/** Verify all unedited frames and the entire payload/tail, before any source write. */
export async function verifyId3Integrity(backupPath: string, stagedPath: string, fields: AudioMetadataWriter): Promise<void> {
  const left: fileIo.File = await fileIo.open(backupPath, fileIo.OpenMode.READ_ONLY);
  let right: fileIo.File | undefined = undefined;
  try {
    right = await fileIo.open(stagedPath, fileIo.OpenMode.READ_ONLY);
    const before: Id3Layout = await parseId3(left.fd);
    const after: Id3Layout = await parseId3(right.fd);
    await refuseCompetingTailTags(left.fd, before);
    await refuseCompetingTailTags(right.fd, after);
    if (before.version !== after.version) throw new Error('ID3 版本发生变化。');
    const groups: FrameGroup[] = makeGroups(fields, before.version);
    const oldKept: Id3Frame[] = [];
    const newKept: Id3Frame[] = [];
    for (let side: number = 0; side < 2; side++) {
      const list: Id3Frame[] = side === 0 ? before.frames : after.frames;
      const kept: Id3Frame[] = side === 0 ? oldKept : newKept;
      const fd: number = side === 0 ? left.fd : right.fd;
      for (let i: number = 0; i < list.length; i++) {
        if (fields.year !== undefined &&
            ((before.version === 3 && (list[i].id === 'TDAT' || list[i].id === 'TIME' || list[i].id === 'TDRC')) ||
             (before.version === 4 && (list[i].id === 'TYER' || list[i].id === 'TDAT' || list[i].id === 'TIME')))) {
          throw new Error('ID3 含额外日期字段，无法安全修改年份。');
        }
        const group: FrameGroup | undefined = findGroup(groups, list[i].id);
        if (group === undefined) { kept.push(list[i]); continue; }
        if (side === 0) group.before++; else group.after++;
        if (list[i].id === 'COMM' || list[i].id === 'USLT') {
          await structuredText(fd, list[i], before.version);
        } else if (list[i].id === 'APIC') {
          await checkFrontCover(fd, list[i], before.version);
        } else if (list[i].id === 'TYER' || list[i].id === 'TDRC') {
          await checkPureYear(fd, list[i], before.version);
        } else if (list[i].id !== 'TRCK' && list[i].id !== 'TPOS') {
          await verifyEditedFrame(fd, list[i], before.version);
        }
      }
    }
    for (let i: number = 0; i < groups.length; i++) {
      if (groups[i].before > 1 || groups[i].after > 1) throw new Error('待修改的 ID3 字段存在多个帧。');
    }
    if (fields.coverImage !== undefined && frameById(after.frames, 'APIC') === undefined) {
      throw new Error('写入后没有可验证的 ID3 前封面。');
    }
    for (const id of ['COMM', 'USLT']) {
      const relevant: boolean = id === 'COMM' ? fields.comment !== undefined : fields.lyrics !== undefined;
      const oldFrame: Id3Frame | undefined = frameById(before.frames, id);
      const newFrame: Id3Frame | undefined = frameById(after.frames, id);
      if (relevant && oldFrame !== undefined && newFrame !== undefined &&
          (await structuredText(left.fd, oldFrame, before.version)).language !==
          (await structuredText(right.fd, newFrame, after.version)).language) {
        throw new Error('未修改的 ID3 语言标识发生变化：' + id);
      }
      if (relevant) {
        const expectedText: string | undefined = id === 'COMM' ? fields.comment : fields.lyrics;
        const actualText: string = newFrame === undefined ? '' : (await structuredText(right.fd, newFrame, after.version)).value;
        if (expectedText !== undefined && actualText.replace(/\r\n/g, '\n').replace(/\r/g, '\n') !==
            expectedText.replace(/\r\n/g, '\n').replace(/\r/g, '\n')) {
          throw new Error('写入后的 ID3 字段回读不一致：' + id);
        }
      }
    }
    if (fields.track !== undefined || fields.trackTotal !== undefined) {
      const oldTrack: NumberParts | undefined = await numberParts(left.fd, frameById(before.frames, 'TRCK'), before.version);
      const newTrack: NumberParts | undefined = await numberParts(right.fd, frameById(after.frames, 'TRCK'), after.version);
      preserveNumberPart(oldTrack, newTrack,
        fields.track !== undefined, fields.trackTotal !== undefined);
      checkExpectedNumber(newTrack === undefined ? undefined : newTrack.first, fields.track, 'TRCK');
      checkExpectedNumber(newTrack === undefined || !newTrack.hasTotal ? undefined : newTrack.total, fields.trackTotal, 'TRCK 总数');
    }
    if (fields.disc !== undefined || fields.discTotal !== undefined) {
      const oldDisc: NumberParts | undefined = await numberParts(left.fd, frameById(before.frames, 'TPOS'), before.version);
      const newDisc: NumberParts | undefined = await numberParts(right.fd, frameById(after.frames, 'TPOS'), after.version);
      preserveNumberPart(oldDisc, newDisc,
        fields.disc !== undefined, fields.discTotal !== undefined);
      checkExpectedNumber(newDisc === undefined ? undefined : newDisc.first, fields.disc, 'TPOS');
      checkExpectedNumber(newDisc === undefined || !newDisc.hasTotal ? undefined : newDisc.total, fields.discTotal, 'TPOS 总数');
    }
    await checkExpectedText(right.fd, after.frames, 'TIT2', fields.title, after.version);
    await checkExpectedText(right.fd, after.frames, 'TPE1', fields.artist, after.version);
    await checkExpectedText(right.fd, after.frames, 'TALB', fields.album, after.version);
    await checkExpectedText(right.fd, after.frames, 'TCON', fields.genre, after.version);
    await checkExpectedText(right.fd, after.frames, 'TPE2', fields.albumArtist, after.version);
    await checkExpectedText(right.fd, after.frames, 'TCOM', fields.composer, after.version);
    await checkExpectedText(right.fd, after.frames, 'TIT1', fields.grouping, after.version);
    await checkExpectedText(right.fd, after.frames, 'TSRC', fields.isrc, after.version);
    await checkExpectedText(right.fd, after.frames, 'TCOP', fields.copyright, after.version);
    await checkExpectedNumericFrame(right.fd, after.frames, 'TBPM', fields.bpm, after.version);
    await checkExpectedNumericFrame(right.fd, after.frames, after.version === 3 ? 'TYER' : 'TDRC', fields.year, after.version);
    // Keep the sequence as well as the bytes of every unrelated frame.
    if (oldKept.length !== newKept.length) throw new Error('未编辑的 ID3 帧数量发生变化。');
    for (let i: number = 0; i < oldKept.length; i++) {
      if (oldKept[i].id !== newKept[i].id || oldKept[i].length !== newKept[i].length ||
          !(await equalRegions(left.fd, oldKept[i].start, right.fd, newKept[i].start, oldKept[i].length))) {
        throw new Error('未编辑的 ID3 帧发生变化：' + oldKept[i].id);
      }
    }
    const tailLength: number = before.size - before.tail;
    if (tailLength !== after.size - after.tail ||
        !(await equalRegions(left.fd, before.tail, right.fd, after.tail, tailLength))) {
      throw new Error('MP3 音频或尾部标签发生变化。');
    }
    if (fileIo.statSync(left.fd).size !== before.size || fileIo.statSync(right.fd).size !== after.size) {
      throw new Error('校验时 MP3 文件发生变化。');
    }
  } finally {
    try { fileIo.closeSync(left.fd); } catch (_error) {}
    if (right !== undefined) { try { fileIo.closeSync(right.fd); } catch (_error) {} }
  }
}
