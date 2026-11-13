import { fileIo } from '@kit.CoreFileKit';
import { AudioMetadataWriter } from '@dabing/taglib_harmony';

// RFC 9639 and Xiph Vorbis comments: field names are ASCII and
// case-insensitive; values (including duplicate values) are byte-preserved.
// All I/O is bounded. Oversized or malformed metadata fails closed.
const CHUNK: number = 256 * 1024;
const MAX_COMMENT: number = 8 * 1024 * 1024;
const MAX_ENTRIES: number = 4096;
const MAX_BLOCKS: number = 4096;

interface FlacBlock { type: number; start: number; size: number; pictureType: number; }
interface FlacLayout { blocks: FlacBlock[]; audioOffset: number; size: number; comments: Comments | undefined; }
interface Entry { key: string; start: number; size: number; }
interface Comments { raw: Uint8Array; vendorStart: number; vendorSize: number; entries: Entry[]; }
interface AllowedGroup { keys: string[]; countBefore: number; countAfter: number; }

async function readAt(fd: number, offset: number, length: number): Promise<Uint8Array> {
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(length) || length < 0 || length > MAX_COMMENT) {
    throw new Error('FLAC 读取范围无效。');
  }
  const result: Uint8Array = new Uint8Array(length);
  let done: number = 0;
  while (done < length) {
    if (fileIo.lseek(fd, offset + done, fileIo.WhenceType.SEEK_SET) !== offset + done) {
      throw new Error('FLAC 无法可靠定位。');
    }
    const bytes: ArrayBuffer = new ArrayBuffer(length - done);
    const got: number = await fileIo.read(fd, bytes, { length: length - done });
    if (got <= 0 || got > length - done) throw new Error('FLAC 读取不完整。');
    result.set(new Uint8Array(bytes, 0, got), done);
    done += got;
  }
  return result;
}

async function checkPadding(fd: number, start: number, size: number): Promise<void> {
  for (let done: number = 0; done < size;) {
    const count: number = Math.min(CHUNK, size - done);
    const data: Uint8Array = await readAt(fd, start + done, count);
    for (let i: number = 0; i < data.length; i++) {
      if (data[i] !== 0) throw new Error('FLAC 填充块包含非零数据，无法安全忽略。');
    }
    done += count;
  }
}

function u32le(bytes: Uint8Array, at: number): number {
  if (at < 0 || at + 4 > bytes.length) throw new Error('FLAC 注释长度无效。');
  return bytes[at] + bytes[at + 1] * 256 + bytes[at + 2] * 65536 + bytes[at + 3] * 16777216;
}

function u32be(bytes: Uint8Array, at: number): number {
  if (at < 0 || at + 4 > bytes.length) throw new Error('FLAC 图片字段不完整。');
  return bytes[at] * 16777216 + bytes[at + 1] * 65536 + bytes[at + 2] * 256 + bytes[at + 3];
}

async function pictureTypeOf(fd: number, start: number, size: number): Promise<number> {
  if (size < 32) throw new Error('FLAC 图片块不完整。');
  const prefix: Uint8Array = await readAt(fd, start, 8);
  const kind: number = u32be(prefix, 0);
  let pos: number = 8;
  const mediaLength: number = u32be(prefix, 4);
  if (mediaLength > size - pos - 4) throw new Error('FLAC 图片媒体类型不完整。');
  pos += mediaLength;
  const descLength: number = u32be(await readAt(fd, start + pos, 4), 0);
  pos += 4;
  if (descLength > size - pos - 20) throw new Error('FLAC 图片描述不完整。');
  pos += descLength;
  const dimensions: Uint8Array = await readAt(fd, start + pos, 20);
  const dataLength: number = u32be(dimensions, 16);
  pos += 20;
  if (dataLength !== size - pos) throw new Error('FLAC 图片数据长度无效。');
  return kind;
}

function parseComments(raw: Uint8Array): Comments {
  let pos: number = 0;
  const vendorSize: number = u32le(raw, pos); pos += 4;
  const vendorStart: number = pos;
  if (vendorSize > raw.length - pos) throw new Error('FLAC 注释厂商标识不完整。');
  pos += vendorSize;
  const count: number = u32le(raw, pos); pos += 4;
  if (count > MAX_ENTRIES) throw new Error('FLAC 注释条目过多，无法安全验证。');
  const entries: Entry[] = [];
  for (let i: number = 0; i < count; i++) {
    const length: number = u32le(raw, pos); pos += 4;
    if (length > raw.length - pos) throw new Error('FLAC 注释条目不完整。');
    const end: number = pos + length;
    let equals: number = pos;
    while (equals < end && raw[equals] !== 0x3d) {
      if (equals - pos >= 255) throw new Error('FLAC 注释字段名过长。');
      if (raw[equals] < 0x20 || raw[equals] > 0x7d) throw new Error('FLAC 注释字段名无效。');
      equals++;
    }
    if (equals === pos || equals === end) throw new Error('FLAC 注释字段格式无效。');
    let key: string = '';
    for (let j: number = pos; j < equals; j++) key += String.fromCharCode(raw[j]);
    entries.push({ key: key.toUpperCase(), start: equals + 1, size: end - equals - 1 });
    pos = end;
  }
  if (pos !== raw.length) throw new Error('FLAC 注释存在无法验证的尾随数据。');
  return { raw, vendorStart, vendorSize, entries };
}

async function parseFlac(fd: number): Promise<FlacLayout> {
  const info: fileIo.Stat = fileIo.statSync(fd);
  if (!info.isFile() || !Number.isSafeInteger(info.size) || info.size < 42) throw new Error('FLAC 文件无效。');
  const magic: Uint8Array = await readAt(fd, 0, 4);
  if (magic[0] !== 0x66 || magic[1] !== 0x4c || magic[2] !== 0x61 || magic[3] !== 0x43) {
    throw new Error('不是标准 FLAC 文件。');
  }
  let offset: number = 4;
  let last: boolean = false;
  let comments: Comments | undefined = undefined;
  const blocks: FlacBlock[] = [];
  while (!last) {
    if (blocks.length >= MAX_BLOCKS || offset > info.size - 4) throw new Error('FLAC 元数据头无效或块数过多。');
    const header: Uint8Array = await readAt(fd, offset, 4);
    const type: number = header[0] & 0x7f;
    const size: number = header[1] * 65536 + header[2] * 256 + header[3];
    const start: number = offset + 4;
    if (type === 127 || size > info.size - start || (blocks.length === 0 && (type !== 0 || size !== 34)) ||
        (blocks.length > 0 && type === 0)) throw new Error('FLAC 元数据块结构无效。');
    let pictureType: number = -1;
    if (type === 1) await checkPadding(fd, start, size);
    if (type === 6) {
      pictureType = await pictureTypeOf(fd, start, size);
    }
    if (type === 4) {
      if (comments !== undefined || size > MAX_COMMENT) throw new Error('FLAC 注释块重复或过大。');
      comments = parseComments(await readAt(fd, start, size));
    }
    blocks.push({ type, start, size, pictureType });
    offset = start + size;
    last = (header[0] & 0x80) !== 0;
  }
  if (offset >= info.size) throw new Error('FLAC 缺少音频帧。');
  return { blocks, audioOffset: offset, size: info.size, comments };
}

function rangesEqual(a: Uint8Array, startA: number, b: Uint8Array, startB: number, size: number): boolean {
  for (let i: number = 0; i < size; i++) if (a[startA + i] !== b[startB + i]) return false;
  return true;
}

async function equalRegions(a: number, atA: number, b: number, atB: number, size: number): Promise<boolean> {
  for (let done: number = 0; done < size;) {
    const count: number = Math.min(CHUNK, size - done);
    const left: Uint8Array = await readAt(a, atA + done, count);
    const right: Uint8Array = await readAt(b, atB + done, count);
    if (!rangesEqual(left, 0, right, 0, count)) return false;
    done += count;
  }
  return true;
}

function groupsFor(fields: AudioMetadataWriter): AllowedGroup[] {
  const groups: AllowedGroup[] = [];
  if (fields.title !== undefined) groups.push({ keys: ['TITLE'], countBefore: 0, countAfter: 0 });
  if (fields.artist !== undefined) groups.push({ keys: ['ARTIST'], countBefore: 0, countAfter: 0 });
  if (fields.album !== undefined) groups.push({ keys: ['ALBUM'], countBefore: 0, countAfter: 0 });
  if (fields.genre !== undefined) groups.push({ keys: ['GENRE'], countBefore: 0, countAfter: 0 });
  if (fields.comment !== undefined) groups.push({ keys: ['COMMENT', 'DESCRIPTION'], countBefore: 0, countAfter: 0 });
  if (fields.lyrics !== undefined) groups.push({ keys: ['LYRICS'], countBefore: 0, countAfter: 0 });
  if (fields.albumArtist !== undefined) groups.push({ keys: ['ALBUMARTIST'], countBefore: 0, countAfter: 0 });
  if (fields.composer !== undefined) groups.push({ keys: ['COMPOSER'], countBefore: 0, countAfter: 0 });
  if (fields.grouping !== undefined) groups.push({ keys: ['GROUPING'], countBefore: 0, countAfter: 0 });
  if (fields.isrc !== undefined) groups.push({ keys: ['ISRC'], countBefore: 0, countAfter: 0 });
  if (fields.copyright !== undefined) groups.push({ keys: ['COPYRIGHT'], countBefore: 0, countAfter: 0 });
  if (fields.year !== undefined) groups.push({ keys: ['DATE', 'YEAR'], countBefore: 0, countAfter: 0 });
  if (fields.track !== undefined) groups.push({ keys: ['TRACKNUMBER', 'TRACKNUM'], countBefore: 0, countAfter: 0 });
  if (fields.disc !== undefined) groups.push({ keys: ['DISCNUMBER'], countBefore: 0, countAfter: 0 });
  if (fields.trackTotal !== undefined) groups.push({ keys: ['TRACKTOTAL', 'TOTALTRACKS'], countBefore: 0, countAfter: 0 });
  if (fields.discTotal !== undefined) groups.push({ keys: ['DISCTOTAL', 'TOTALDISCS'], countBefore: 0, countAfter: 0 });
  if (fields.bpm !== undefined) groups.push({ keys: ['BPM'], countBefore: 0, countAfter: 0 });
  return groups;
}

function groupFor(key: string, groups: AllowedGroup[]): AllowedGroup | undefined {
  for (let i: number = 0; i < groups.length; i++) {
    if (groups[i].keys.indexOf(key) >= 0) return groups[i];
  }
  return undefined;
}

function preservedEntries(comments: Comments | undefined, groups: AllowedGroup[], before: boolean): Entry[] {
  const result: Entry[] = [];
  if (comments === undefined) return result;
  for (let i: number = 0; i < comments.entries.length; i++) {
    const item: Entry = comments.entries[i];
    const group: AllowedGroup | undefined = groupFor(item.key, groups);
    if (group === undefined) { result.push(item); continue; }
    if (before) group.countBefore++; else group.countAfter++;
    // The UI represents only a year. Replacing a full date or other DATE/YEAR
    // representation would silently discard information the user did not edit.
    if (before && (item.key === 'DATE' || item.key === 'YEAR')) {
      if (item.size !== 4) throw new Error('原始日期包含年份以外的信息，无法安全修改年份。');
      for (let j: number = 0; j < item.size; j++) {
        const byte: number = comments.raw[item.start + j];
        if (byte < 0x30 || byte > 0x39) throw new Error('原始日期不是四位年份，无法安全修改年份。');
      }
    }
    // A combined number/total is not exposed reliably by the bridge. Never
    // allow an apparently single-field edit to discard its other component.
    if (item.key === 'TRACKNUMBER' || item.key === 'TRACKNUM' || item.key === 'DISCNUMBER') {
      for (let j: number = 0; j < item.size; j++) {
        if (comments.raw[item.start + j] === 0x2f) throw new Error('曲目或碟片字段包含组合总数，无法安全直写。');
      }
    }
  }
  // Stable sort keeps duplicate values in their original per-key order.
  result.sort((left: Entry, right: Entry): number => left.key < right.key ? -1 : (left.key > right.key ? 1 : 0));
  return result;
}

function verifyComments(before: Comments | undefined, after: Comments | undefined, fields: AudioMetadataWriter): void {
  const groups: AllowedGroup[] = groupsFor(fields);
  if (before !== undefined && after !== undefined &&
      (before.vendorSize !== after.vendorSize ||
       !rangesEqual(before.raw, before.vendorStart, after.raw, after.vendorStart, before.vendorSize))) {
    throw new Error('FLAC 注释厂商标识发生变化。');
  }
  if (before !== undefined && after === undefined) throw new Error('FLAC 注释块丢失。');
  if (before === undefined && after !== undefined && groups.length === 0) throw new Error('FLAC 注释块被意外新增。');
  const left: Entry[] = preservedEntries(before, groups, true);
  const right: Entry[] = preservedEntries(after, groups, false);
  for (let i: number = 0; i < groups.length; i++) {
    if (groups[i].countBefore > 1 || groups[i].countAfter > 1) {
      throw new Error('待修改的 FLAC 标签含多个值或别名，无法安全直写。');
    }
  }
  if (left.length !== right.length) throw new Error('未编辑的 FLAC 注释数量发生变化。');
  for (let i: number = 0; i < left.length; i++) {
    if (before === undefined || after === undefined || left[i].key !== right[i].key || left[i].size !== right[i].size ||
        !rangesEqual(before.raw, left[i].start, after.raw, right[i].start, left[i].size)) {
      throw new Error('未编辑的 FLAC 标签发生变化：' + left[i].key);
    }
  }
}

function preservedBlocks(layout: FlacLayout, changeCover: boolean, afterWrite: boolean): FlacBlock[] {
  const retained: FlacBlock[] = [];
  let frontCovers: number = 0;
  for (let i: number = 0; i < layout.blocks.length; i++) {
    const block: FlacBlock = layout.blocks[i];
    if (block.type === 1 || block.type === 4) continue; // padding may resize; comments are compared separately
    if (changeCover && block.type === 6) {
      if (block.pictureType !== 3) throw new Error('存在其他类型的图片，无法安全替换前封面。');
      frontCovers++;
      continue;
    }
    retained.push(block);
  }
  if (frontCovers > 1) throw new Error('存在多个前封面，无法安全替换封面。');
  if (changeCover && afterWrite && frontCovers !== 1) throw new Error('替换封面后缺少唯一前封面。');
  return retained;
}

/** Compare the staged FLAC with the verified private backup before committing. */
export async function verifyFlacIntegrity(backupPath: string, stagedPath: string, fields: AudioMetadataWriter): Promise<void> {
  const left: fileIo.File = await fileIo.open(backupPath, fileIo.OpenMode.READ_ONLY);
  let right: fileIo.File | undefined = undefined;
  try {
    right = await fileIo.open(stagedPath, fileIo.OpenMode.READ_ONLY);
    const before: FlacLayout = await parseFlac(left.fd);
    const after: FlacLayout = await parseFlac(right.fd);
    verifyComments(before.comments, after.comments, fields);
    if (fields.coverImage !== undefined) {
      const records: Comments[] = [];
      if (before.comments !== undefined) records.push(before.comments);
      if (after.comments !== undefined) records.push(after.comments);
      for (let i: number = 0; i < records.length; i++) {
        for (let j: number = 0; j < records[i].entries.length; j++) {
          if (records[i].entries[j].key === 'METADATA_BLOCK_PICTURE') {
            throw new Error('存在注释内嵌图片，无法确认唯一前封面。');
          }
        }
      }
    }
    const oldBlocks: FlacBlock[] = preservedBlocks(before, fields.coverImage !== undefined, false);
    const newBlocks: FlacBlock[] = preservedBlocks(after, fields.coverImage !== undefined, true);
    if (oldBlocks.length !== newBlocks.length) throw new Error('未编辑的 FLAC 元数据块数量发生变化。');
    for (let i: number = 0; i < oldBlocks.length; i++) {
      if (oldBlocks[i].type !== newBlocks[i].type || oldBlocks[i].size !== newBlocks[i].size ||
          !(await equalRegions(left.fd, oldBlocks[i].start, right.fd, newBlocks[i].start, oldBlocks[i].size))) {
        throw new Error('未编辑的 FLAC 元数据块发生变化。');
      }
    }
    const audioBytes: number = before.size - before.audioOffset;
    if (audioBytes !== after.size - after.audioOffset ||
        !(await equalRegions(left.fd, before.audioOffset, right.fd, after.audioOffset, audioBytes))) {
      throw new Error('FLAC 音频帧或尾随数据发生变化。');
    }
    if (fileIo.statSync(left.fd).size !== before.size || fileIo.statSync(right.fd).size !== after.size) {
      throw new Error('校验时 FLAC 文件发生变化。');
    }
  } finally {
    try { fileIo.closeSync(left.fd); } catch (_error) {}
    if (right !== undefined) { try { fileIo.closeSync(right.fd); } catch (_error) {} }
  }
}
