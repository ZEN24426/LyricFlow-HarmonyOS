import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { AudioMetadata, AudioMetadataWriter } from './AudioMetadataTypes';

// FLAC metadata blocks are bounded; compressed audio is copied in chunks and never decoded.
const MAX_META: number = 16 * 1024 * 1024;
const CHUNK: number = 256 * 1024;
interface Block { type: number; data: Uint8Array; }
interface CommentEntry { key: string; raw: Uint8Array; value: string; }
interface Comments { vendor: Uint8Array; entries: CommentEntry[]; }
interface Layout { size: number; audioOffset: number; blocks: Block[]; comments?: Comments; sampleRate: number; channels: number; samples: number; }
interface FieldEdit { keys: string[]; name: string; value: string | undefined; count: number; }

async function readAt(fd: number, pos: number, size: number): Promise<Uint8Array> {
  const result: Uint8Array = new Uint8Array(size);
  let done: number = 0;
  while (done < size) {
    if (fileIo.lseek(fd, pos + done, fileIo.WhenceType.SEEK_SET) !== pos + done) throw new Error('无法定位 FLAC 文件。');
    const buffer: ArrayBuffer = new ArrayBuffer(size - done);
    const n: number = await fileIo.read(fd, buffer, { length: size - done });
    if (n <= 0 || n > size - done) throw new Error('FLAC 文件读取不完整。');
    result.set(new Uint8Array(buffer, 0, n), done); done += n;
  }
  return result;
}
async function writeAll(fd: number, value: Uint8Array): Promise<void> {
  let done: number = 0;
  while (done < value.length) {
    const buf: ArrayBuffer = value.buffer.slice(value.byteOffset + done, value.byteOffset + value.length) as ArrayBuffer;
    const n: number = await fileIo.write(fd, buf, { length: buf.byteLength });
    if (n <= 0 || n > value.length - done) throw new Error('FLAC 文件写入不完整。');
    done += n;
  }
}
function le(b: Uint8Array, p: number): number {
  if (p < 0 || p + 4 > b.length) throw new Error('FLAC 注释长度无效。');
  return b[p] + b[p + 1] * 256 + b[p + 2] * 65536 + b[p + 3] * 16777216;
}
function be(b: Uint8Array, p: number): number {
  if (p < 0 || p + 4 > b.length) throw new Error('FLAC 图片长度无效。');
  return b[p] * 16777216 + b[p + 1] * 65536 + b[p + 2] * 256 + b[p + 3];
}
function putLe(n: number): Uint8Array { return new Uint8Array([n & 255, Math.floor(n / 256) & 255, Math.floor(n / 65536) & 255, Math.floor(n / 16777216) & 255]); }
function putBe(n: number): Uint8Array { return new Uint8Array([Math.floor(n / 16777216) & 255, Math.floor(n / 65536) & 255, Math.floor(n / 256) & 255, n & 255]); }
function encode(s: string): Uint8Array { return util.TextEncoder.create('utf-8').encodeInto(s); }
// Count UTF-8 before allocation and reject unpaired UTF-16 surrogates.
function utf8SizeWithin(s: string, limit: number): number {
  let bytes: number = 0;
  for (let i: number = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c < 0x80) bytes++;
    else if (c < 0x800) bytes += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length &&
             s.charCodeAt(i + 1) >= 0xdc00 && s.charCodeAt(i + 1) <= 0xdfff) { bytes += 4; i++; }
    else if (c >= 0xd800 && c <= 0xdfff) throw new Error('FLAC 文本含无效的 Unicode 字符。');
    else bytes += 3;
    if (bytes > limit) throw new Error('FLAC 注释过大。');
  }
  return bytes;
}
function decode(b: Uint8Array): string {
  const options: util.TextDecoderOptions = { fatal: true, ignoreBOM: true };
  return util.TextDecoder.create('utf-8', options).decodeToString(b);
}
function parseComments(raw: Uint8Array): Comments {
  const len: number = le(raw, 0);
  if (len > raw.length - 8) throw new Error('FLAC 厂商注释不完整。');
  const vendor: Uint8Array = raw.slice(4, 4 + len);
  let p: number = 4 + len;
  const count: number = le(raw, p); p += 4;
  if (count > 65536 || count > Math.floor((raw.length - p) / 4)) throw new Error('FLAC 注释过多。');
  const entries: CommentEntry[] = [];
  for (let i: number = 0; i < count; i++) {
    const n: number = le(raw, p); p += 4;
    if (n > raw.length - p) throw new Error('FLAC 注释不完整。');
    const end: number = p + n;
    let q: number = p;
    while (q < end && raw[q] !== 61) {
      if (q - p >= 255 || raw[q] < 32 || raw[q] > 125) throw new Error('FLAC 注释字段名无效。');
      q++;
    }
    if (q === p || q === end) throw new Error('FLAC 注释格式无效。');
    let key: string = '';
    for (let j: number = p; j < q; j++) key += String.fromCharCode(raw[j]);
    entries.push({ key: key.toUpperCase(), raw: raw.slice(p, end), value: decode(raw.slice(q + 1, end)) });
    p = end;
  }
  if (p !== raw.length) throw new Error('FLAC 注释含未识别的尾随数据。');
  return { vendor, entries };
}
function pictureData(raw: Uint8Array): Uint8Array {
  if (raw.length < 32) throw new Error('FLAC 图片块不完整。');
  let p: number = 4;
  const mime: number = be(raw, p); p += 4;
  if (mime > raw.length - p - 4) throw new Error('FLAC 图片类型无效。');
  p += mime;
  const desc: number = be(raw, p); p += 4;
  if (desc > raw.length - p - 20) throw new Error('FLAC 图片描述无效。');
  p += desc;
  const length: number = be(raw, p + 16); p += 20;
  if (length !== raw.length - p) throw new Error('FLAC 图片长度无效。');
  return raw.slice(p);
}
async function layout(fd: number): Promise<Layout> {
  const st: fileIo.Stat = fileIo.statSync(fd);
  if (!st.isFile() || !Number.isSafeInteger(st.size) || st.size < 42) throw new Error('FLAC 文件无效。');
  const magic: Uint8Array = await readAt(fd, 0, 4);
  if (magic[0] !== 102 || magic[1] !== 76 || magic[2] !== 97 || magic[3] !== 67) throw new Error('不是标准 FLAC 文件。');
  let p: number = 4;
  let last: boolean = false;
  let comments: Comments | undefined = undefined;
  const blocks: Block[] = [];
  while (!last) {
    if (blocks.length >= 1024 || p > st.size - 4 || p > MAX_META) throw new Error('FLAC 元数据过大或不完整。');
    const header: Uint8Array = await readAt(fd, p, 4);
    const type: number = header[0] & 127;
    const length: number = header[1] * 65536 + header[2] * 256 + header[3];
    if (type === 127 || p + 4 + length > st.size || p + 4 + length > MAX_META) throw new Error('FLAC 元数据块无效。');
    const data: Uint8Array = await readAt(fd, p + 4, length);
    if ((blocks.length === 0 && (type !== 0 || length !== 34)) || (blocks.length > 0 && type === 0)) throw new Error('FLAC 流信息块无效。');
    if (type === 4) {
      if (comments !== undefined) throw new Error('存在多个 FLAC 注释块。');
      comments = parseComments(data);
    }
    if (type === 6) pictureData(data);
    blocks.push({ type, data });
    p += 4 + length; last = (header[0] & 128) !== 0;
  }
  if (p >= st.size) throw new Error('FLAC 音频帧缺失。');
  const info: Uint8Array = blocks[0].data;
  const sr: number = info[10] * 4096 + info[11] * 16 + (info[12] >> 4);
  const channels: number = ((info[12] >> 1) & 7) + 1;
  const samples: number = (info[13] & 15) * 4294967296 + info[14] * 16777216 + info[15] * 65536 + info[16] * 256 + info[17];
  if (sr <= 0) throw new Error('FLAC 采样率无效。');
  return { size: st.size, audioOffset: p, blocks, comments, sampleRate: sr, channels, samples };
}
function first(c: Comments | undefined, keys: string[]): string {
  if (c === undefined) return '';
  for (let i: number = 0; i < c.entries.length; i++) if (keys.indexOf(c.entries[i].key) >= 0) return c.entries[i].value;
  return '';
}
function numberValue(value: string): number {
  const part: string = value.split('/')[0];
  if (!/^\d+$/.test(part)) return 0;
  const n: number = Number(part);
  return Number.isSafeInteger(n) && n >= 0 ? n : 0;
}
function totalValue(primary: string, combined: string): number {
  if (primary.length > 0) return numberValue(primary);
  const parts: string[] = combined.split('/');
  return parts.length === 2 ? numberValue(parts[1]) : 0;
}
async function decodeCover(blocks: Block[]): Promise<image.PixelMap | undefined> {
  let cover: Uint8Array | undefined = undefined;
  for (let i: number = 0; i < blocks.length; i++) {
    if (blocks[i].type === 6 && be(blocks[i].data, 0) === 3) {
      if (cover !== undefined) throw new Error('存在多个前封面，无法确定显示内容。');
      cover = pictureData(blocks[i].data);
    }
  }
  if (cover === undefined || cover.length === 0) return undefined;
  if (cover.length > 8 * 1024 * 1024) throw new Error('封面编码数据过大。');
  const buf: ArrayBuffer = cover.buffer.slice(cover.byteOffset, cover.byteOffset + cover.byteLength) as ArrayBuffer;
  const source: image.ImageSource = image.createImageSource(buf);
  try {
    // Check the encoded dimensions before asking the platform to allocate pixels.
    const info: image.ImageInfo = await source.getImageInfo();
    const w: number = info.size.width;
    const h: number = info.size.height;
    if (!Number.isInteger(w) || !Number.isInteger(h) || w <= 0 || h <= 0 || w > 16384 || h > 16384 || w * h > 16777216 || info.isHdr) {
      throw new Error('封面尺寸或 HDR 格式超出安全范围。');
    }
    const decoded: image.PixelMap = await source.createPixelMap();
    try {
      const actual: image.ImageInfo = await decoded.getImageInfo();
      if (actual.size.width !== w || actual.size.height !== h || actual.isHdr) throw new Error('封面解码尺寸或格式不一致。');
      return decoded;
    } catch (error) {
      try { await decoded.release(); } catch (_releaseError) {}
      throw error as Error;
    }
  } finally { try { await source.release(); } catch (_error) {} }
}
export async function readFlacMetadata(path: string): Promise<AudioMetadata> {
  const source: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  try {
    const info: Layout = await layout(source.fd);
    const c: Comments | undefined = info.comments;
    const track: string = first(c, ['TRACKNUMBER', 'TRACKNUM']);
    const disc: string = first(c, ['DISCNUMBER']);
    const durationMs: number = Math.floor(info.samples * 1000 / info.sampleRate);
    const coverImage: image.PixelMap | undefined = await decodeCover(info.blocks);
    return {
      title: first(c, ['TITLE']), artist: first(c, ['ARTIST']), album: first(c, ['ALBUM']),
      genre: first(c, ['GENRE']), comment: first(c, ['COMMENT', 'DESCRIPTION']), lyrics: first(c, ['LYRICS']),
      albumArtist: first(c, ['ALBUMARTIST']), composer: first(c, ['COMPOSER']), grouping: first(c, ['GROUPING']),
      isrc: first(c, ['ISRC']), copyright: first(c, ['COPYRIGHT']), year: numberValue(first(c, ['DATE', 'YEAR']).split('-')[0]),
      track: numberValue(track), disc: numberValue(disc), trackTotal: totalValue(first(c, ['TRACKTOTAL', 'TOTALTRACKS']), track),
      discTotal: totalValue(first(c, ['DISCTOTAL', 'TOTALDISCS']), disc), bpm: numberValue(first(c, ['BPM'])),
      duration: Math.floor(durationMs / 1000), durationMs, sampleRate: info.sampleRate, channels: info.channels,
      bitrate: durationMs > 0 ? Math.round((info.size - info.audioOffset) * 8 / durationMs) : 0,
      coverImage, fileType: 'audio/flac', fileSize: info.size, creationTime: 0, modifyTime: 0
    };
  } finally { try { fileIo.closeSync(source.fd); } catch (_error) {} }
}
function num(n: number | undefined, max: number = 99999): string | undefined {
  if (n === undefined) return undefined;
  if (!Number.isInteger(n) || n < 0 || n > max) throw new Error('FLAC 数字标签无效。');
  return n === 0 ? '' : n.toString();
}
function editsFor(f: AudioMetadataWriter): FieldEdit[] {
  return [
    { keys: ['TITLE'], name: 'TITLE', value: f.title, count: 0 }, { keys: ['ARTIST'], name: 'ARTIST', value: f.artist, count: 0 },
    { keys: ['ALBUM'], name: 'ALBUM', value: f.album, count: 0 }, { keys: ['GENRE'], name: 'GENRE', value: f.genre, count: 0 },
    { keys: ['COMMENT', 'DESCRIPTION'], name: 'COMMENT', value: f.comment, count: 0 },
    { keys: ['LYRICS'], name: 'LYRICS', value: f.lyrics, count: 0 }, { keys: ['ALBUMARTIST'], name: 'ALBUMARTIST', value: f.albumArtist, count: 0 },
    { keys: ['COMPOSER'], name: 'COMPOSER', value: f.composer, count: 0 }, { keys: ['GROUPING'], name: 'GROUPING', value: f.grouping, count: 0 },
    { keys: ['ISRC'], name: 'ISRC', value: f.isrc, count: 0 }, { keys: ['COPYRIGHT'], name: 'COPYRIGHT', value: f.copyright, count: 0 },
    { keys: ['DATE', 'YEAR'], name: 'DATE', value: f.year === undefined ? undefined : (f.year === 0 ? '' : num(f.year, 9999)!.padStart(4, '0')), count: 0 },
    { keys: ['TRACKNUMBER', 'TRACKNUM'], name: 'TRACKNUMBER', value: num(f.track), count: 0 },
    { keys: ['DISCNUMBER'], name: 'DISCNUMBER', value: num(f.disc), count: 0 },
    { keys: ['TRACKTOTAL', 'TOTALTRACKS'], name: 'TRACKTOTAL', value: num(f.trackTotal), count: 0 },
    { keys: ['DISCTOTAL', 'TOTALDISCS'], name: 'DISCTOTAL', value: num(f.discTotal), count: 0 },
    { keys: ['BPM'], name: 'BPM', value: num(f.bpm), count: 0 }
  ];
}
function buildComments(c: Comments | undefined, edits: FieldEdit[], coverChange: boolean): Uint8Array {
  const vendor: Uint8Array = c === undefined ? encode('LyricFlow') : c.vendor;
  const list: Uint8Array[] = [];
  const entries: CommentEntry[] = c === undefined ? [] : c.entries;
  for (let i: number = 0; i < entries.length; i++) {
    const e: CommentEntry = entries[i];
    if (coverChange && e.key === 'METADATA_BLOCK_PICTURE') throw new Error('存在注释内嵌图片，无法安全替换封面。');
    let edit: FieldEdit | undefined = undefined;
    for (let j: number = 0; j < edits.length; j++) if (edits[j].value !== undefined && edits[j].keys.indexOf(e.key) >= 0) edit = edits[j];
    // A combined value contains information not represented by one field.
    if ((e.key === 'TRACKNUMBER' || e.key === 'TRACKNUM') && e.value.indexOf('/') >= 0 &&
        (edits[12].value !== undefined || edits[14].value !== undefined)) throw new Error('曲目号包含总数，无法安全替换。');
    if (e.key === 'DISCNUMBER' && e.value.indexOf('/') >= 0 &&
        (edits[13].value !== undefined || edits[15].value !== undefined)) throw new Error('碟片号包含总数，无法安全替换。');
    if (edit === undefined) { list.push(e.raw); continue; }
    edit.count++;
    if (edit.count > 1) throw new Error('待修改的 FLAC 标签含多个值或别名：' + edit.name);
    if (edit.name === 'DATE' && !/^\d{4}$/.test(e.value)) throw new Error('原始日期包含年份以外信息，无法安全修改。');
  }
  let size: number = 8 + vendor.length;
  for (let i: number = 0; i < list.length; i++) size += 4 + list[i].length;
  const limit: number = Math.min(0xffffff, MAX_META);
  if (size > limit) throw new Error('FLAC 注释过大。');
  // Bound the combined encoded size before encoding any newly supplied value.
  for (let i: number = 0; i < edits.length; i++) {
    const e: FieldEdit = edits[i];
    if (e.value !== undefined && e.value.length > 0) {
      size += 4 + e.name.length + 1;
      if (size > limit) throw new Error('FLAC 注释过大。');
      size += utf8SizeWithin(e.value, limit - size);
    }
  }
  for (let i: number = 0; i < edits.length; i++) {
    const e: FieldEdit = edits[i];
    if (e.value !== undefined && e.value.length > 0) list.push(encode(e.name + '=' + e.value));
  }
  const result: Uint8Array = new Uint8Array(size);
  let pos: number = 0;
  result.set(putLe(vendor.length), pos); pos += 4; result.set(vendor, pos); pos += vendor.length;
  result.set(putLe(list.length), pos); pos += 4;
  for (let i: number = 0; i < list.length; i++) { result.set(putLe(list[i].length), pos); pos += 4; result.set(list[i], pos); pos += list[i].length; }
  return result;
}
// Restrict the PNG output to 8-bit non-indexed formats with an integrity-checked
// IHDR structure, so FLAC's bits-per-pixel field reflects the actual image.
function pngPixelDepth(png: Uint8Array, width: number, height: number): number {
  const signature: number[] = [137, 80, 78, 71, 13, 10, 26, 10];
  if (png.length < 45) throw new Error('封面 PNG 数据不完整。');
  for (let i: number = 0; i < signature.length; i++) {
    if (png[i] !== signature[i]) throw new Error('封面编码不是标准 PNG。');
  }
  if (be(png, 8) !== 13 || png[12] !== 73 || png[13] !== 72 || png[14] !== 68 || png[15] !== 82 ||
      be(png, 16) !== width || be(png, 20) !== height || png[26] !== 0 || png[27] !== 0 || png[28] > 1) {
    throw new Error('封面 PNG 头部或尺寸无效。');
  }
  let crc: number = 0xffffffff;
  for (let i: number = 12; i < 29; i++) {
    crc ^= png[i];
    for (let bit: number = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) !== 0 ? 0xedb88320 : 0);
  }
  if (((crc ^ 0xffffffff) >>> 0) !== be(png, 29)) throw new Error('封面 PNG 头部校验失败。');
  const end: number = png.length - 12;
  if (be(png, end) !== 0 || png[end + 4] !== 73 || png[end + 5] !== 69 || png[end + 6] !== 78 ||
      png[end + 7] !== 68 || be(png, end + 8) !== 0xae426082) throw new Error('封面 PNG 结尾无效。');
  if (png[24] !== 8) throw new Error('封面 PNG 位深暂不支持。');
  const color: number = png[25];
  if (color === 0) return 8; // grayscale
  if (color === 2) return 24; // RGB
  if (color === 4) return 16; // grayscale + alpha
  if (color === 6) return 32; // RGBA
  throw new Error('封面 PNG 色彩类型暂不支持。');
}
async function newPicture(cover: image.PixelMap): Promise<Uint8Array> {
  const info: image.ImageInfo = await cover.getImageInfo();
  if (info.isHdr || !Number.isInteger(info.size.width) || !Number.isInteger(info.size.height) || info.size.width <= 0 || info.size.height <= 0 || info.size.width > 16384 || info.size.height > 16384 || info.size.width * info.size.height > 16777216) throw new Error('封面尺寸或格式不支持。');
  const packer: image.ImagePacker = image.createImagePacker();
  try {
    const png: ArrayBuffer = await packer.packToData(cover, { format: 'image/png', quality: 100, bufferSize: 8388608 });
    if (png.byteLength <= 0 || png.byteLength > 8388608) throw new Error('封面过大或编码失败。');
    const depth: number = pngPixelDepth(new Uint8Array(png), info.size.width, info.size.height);
    const mime: Uint8Array = encode('image/png');
    const out: Uint8Array = new Uint8Array(32 + mime.length + png.byteLength);
    let p: number = 0;
    out.set(putBe(3), p); p += 4; out.set(putBe(mime.length), p); p += 4; out.set(mime, p); p += mime.length;
    out.set(putBe(0), p); p += 4; out.set(putBe(info.size.width), p); p += 4; out.set(putBe(info.size.height), p); p += 4;
    out.set(putBe(depth), p); p += 4; out.set(putBe(0), p); p += 4; out.set(putBe(png.byteLength), p); p += 4;
    out.set(new Uint8Array(png), p); return out;
  } finally { try { await packer.release(); } catch (_error) {} }
}
export async function writeFlacMetadata(filesDir: string, inputPath: string, fields: AudioMetadataWriter): Promise<string> {
  const root: string = filesDir.endsWith('/') ? filesDir.substring(0, filesDir.length - 1) : filesDir;
  if (!root.startsWith('/') || !inputPath.startsWith(root + '/') || root.indexOf('\\') >= 0 || inputPath.indexOf('\\') >= 0) throw new Error('仅允许编辑应用私有目录中的副本。');
  const parts: string[] = inputPath.split('/');
  for (let i: number = 1; i < parts.length; i++) if (parts[i] === '' || parts[i] === '.' || parts[i] === '..' || parts[i].indexOf('\u0000') >= 0) throw new Error('FLAC 副本路径无效。');
  const source: fileIo.File = fileIo.openSync(inputPath, fileIo.OpenMode.READ_ONLY);
  let output: fileIo.File | undefined = undefined;
  let directory: string = '';
  let result: string = '';
  let complete: boolean = false;
  try {
    const parsed: Layout = await layout(source.fd);
    const edits: FieldEdit[] = editsFor(fields);
    let hasText: boolean = false;
    for (let i: number = 0; i < edits.length; i++) if (edits[i].value !== undefined) hasText = true;
    const changeCover: boolean = fields.coverImage !== undefined;
    if (!hasText && !changeCover) throw new Error('没有需要写入的 FLAC 标签更改。');
    const comments: Uint8Array = buildComments(parsed.comments, edits, changeCover);
    let cover: Uint8Array | undefined = undefined;
    if (fields.coverImage !== undefined) cover = await newPicture(fields.coverImage);
    const blocks: Block[] = [];
    let foundComments: boolean = false;
    let pictureCount: number = 0;
    for (let i: number = 0; i < parsed.blocks.length; i++) {
      const block: Block = parsed.blocks[i];
      if (block.type === 4 && hasText) { blocks.push({ type: 4, data: comments }); foundComments = true; }
      else if (block.type === 6 && changeCover) {
        if (be(block.data, 0) !== 3 || ++pictureCount > 1) throw new Error('存在多个封面或其他图片，无法安全替换。');
        // Preserve picture descriptions by refusing to replace nonempty descriptions.
        const mimeLen: number = be(block.data, 4);
        if (be(block.data, 8 + mimeLen) !== 0) throw new Error('原封面含描述，无法安全替换。');
        if (cover !== undefined) blocks.push({ type: 6, data: cover });
      } else blocks.push(block);
    }
    if (hasText && !foundComments) blocks.push({ type: 4, data: comments });
    if (changeCover && pictureCount === 0 && cover !== undefined) blocks.push({ type: 6, data: cover });
    let metaSize: number = 4;
    for (let i: number = 0; i < blocks.length; i++) metaSize += 4 + blocks[i].data.length;
    if (metaSize > MAX_META) throw new Error('更新后的 FLAC 元数据超限。');
    directory = fileIo.mkdtempSync(root + '/lyricflow_flac_XXXXXX');
    result = directory + '/edited.flac';
    output = fileIo.openSync(result, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    await writeAll(output.fd, new Uint8Array([102, 76, 97, 67]));
    for (let i: number = 0; i < blocks.length; i++) {
      const b: Block = blocks[i]; const n: number = b.data.length;
      await writeAll(output.fd, new Uint8Array([b.type | (i === blocks.length - 1 ? 128 : 0), (n >> 16) & 255, (n >> 8) & 255, n & 255]));
      await writeAll(output.fd, b.data);
    }
    for (let p: number = parsed.audioOffset; p < parsed.size;) {
      const n: number = Math.min(CHUNK, parsed.size - p);
      await writeAll(output.fd, await readAt(source.fd, p, n)); p += n;
    }
    if (fileIo.statSync(source.fd).size !== parsed.size || fileIo.statSync(output.fd).size !== parsed.size - parsed.audioOffset + metaSize) throw new Error('FLAC 副本大小校验失败。');
    fileIo.fsyncSync(output.fd); complete = true; return result;
  } finally {
    if (output !== undefined) { try { fileIo.closeSync(output.fd); } catch (_error) {} }
    try { fileIo.closeSync(source.fd); } catch (_error) {}
    if (!complete && result.length > 0) { try { fileIo.unlinkSync(result); } catch (_error) {} }
    if (!complete && directory.length > 0) { try { fileIo.rmdirSync(directory); } catch (_error) {} }
  }
}
