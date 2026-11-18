import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { AudioMetadata, AudioMetadataWriter } from './AudioMetadataTypes';
import { verifyWrittenMetadata, verifyPreservedMetadata } from './MetadataVerification';

// Constrained ISO-BMFF/M4A support. Atom positions and all bytes outside one
// pre-existing metadata window stay unchanged; unsupported layouts fail closed.
const META_LIMIT: number = 16 * 1024 * 1024;
const CHUNK: number = 256 * 1024;
const MAX_ATOMS: number = 4096;
interface Atom { start: number; end: number; head: number; type: string; }
interface Item { tag: string; atom: Atom; }
interface M4aLayout { fileSize: number; moovOffset: number; moov: Uint8Array; items: Item[]; windowStart: number; windowEnd: number; }
interface Edit { tag: string; value: Uint8Array | undefined; }
interface TextEntry { tag: string; value: string | undefined; }
interface DataValue { type: number; bytes: Uint8Array; }
interface Pair { a: number; b: number; }

function u32(b: Uint8Array, p: number): number {
  if (p < 0 || p + 4 > b.length) throw new Error('M4A 数据长度无效。');
  return b[p] * 16777216 + b[p + 1] * 65536 + b[p + 2] * 256 + b[p + 3];
}
function u64(b: Uint8Array, p: number): number {
  const hi: number = u32(b, p); const lo: number = u32(b, p + 4);
  const value: number = hi * 4294967296 + lo;
  if (!Number.isSafeInteger(value)) throw new Error('M4A 文件偏移超限。');
  return value;
}
function be(n: number): Uint8Array { return new Uint8Array([(Math.floor(n / 16777216)) & 255, (Math.floor(n / 65536)) & 255, (Math.floor(n / 256)) & 255, n & 255]); }
function nameAt(b: Uint8Array, p: number): string {
  if (p < 0 || p + 4 > b.length) throw new Error('M4A atom 标识不完整。');
  return String.fromCharCode(b[p], b[p + 1], b[p + 2], b[p + 3]);
}
function atomList(b: Uint8Array, start: number, end: number): Atom[] {
  const out: Atom[] = []; let p: number = start;
  if (start < 0 || end > b.length || start > end) throw new Error('M4A atom 范围无效。');
  while (p < end) {
    if (out.length >= MAX_ATOMS || end - p < 8) throw new Error('M4A atom 不完整或数量超限。');
    const n32: number = u32(b, p); const kind: string = nameAt(b, p + 4);
    let n: number = n32; let h: number = 8;
    if (n32 === 1) { if (end - p < 16) throw new Error('M4A 扩展长度不完整。'); n = u64(b, p + 8); h = 16; }
    if (n32 === 0 || n < h || n > end - p) throw new Error('M4A atom 长度无效或不支持。');
    out.push({ start: p, end: p + n, head: h, type: kind }); p += n;
  }
  return out;
}
function one(list: Atom[], kind: string, required: boolean = true): Atom | undefined {
  let result: Atom | undefined = undefined;
  for (let i: number = 0; i < list.length; i++) if (list[i].type === kind) {
    if (result !== undefined) throw new Error('M4A 存在重复 atom：' + kind);
    result = list[i];
  }
  if (required && result === undefined) throw new Error('M4A 缺少 atom：' + kind);
  return result;
}
function children(b: Uint8Array, atom: Atom, prefix: number = 0): Atom[] {
  if (atom.end - atom.start - atom.head < prefix) throw new Error('M4A 容器不完整。');
  return atomList(b, atom.start + atom.head + prefix, atom.end);
}
function onlyKinds(list: Atom[], permitted: string[]): void {
  for (let i: number = 0; i < list.length; i++) if (permitted.indexOf(list[i].type) < 0) throw new Error('M4A 存在暂不支持的结构：' + list[i].type);
}
async function readAt(fd: number, start: number, length: number): Promise<Uint8Array> {
  const out: Uint8Array = new Uint8Array(length); let done: number = 0;
  while (done < length) {
    if (fileIo.lseek(fd, start + done, fileIo.WhenceType.SEEK_SET) !== start + done) throw new Error('无法定位 M4A 文件。');
    const buf: ArrayBuffer = new ArrayBuffer(length - done);
    const n: number = await fileIo.read(fd, buf, { length: length - done });
    if (n <= 0 || n > length - done) throw new Error('读取 M4A 文件不完整。');
    out.set(new Uint8Array(buf, 0, n), done); done += n;
  }
  return out;
}
async function writeAll(fd: number, b: Uint8Array): Promise<void> {
  let done: number = 0;
  while (done < b.length) {
    const data: ArrayBuffer = b.buffer.slice(b.byteOffset + done, b.byteOffset + b.length) as ArrayBuffer;
    const n: number = await fileIo.write(fd, data, { length: data.byteLength });
    if (n <= 0 || n > b.length - done) throw new Error('M4A 副本写入不完整。');
    done += n;
  }
}
async function copyRange(input: number, output: number, start: number, size: number): Promise<void> {
  for (let p: number = 0; p < size;) { const n: number = Math.min(CHUNK, size - p); await writeAll(output, await readAt(input, start + p, n)); p += n; }
}
function atom(b: Uint8Array, list: Atom[], kind: string): Atom {
  const value: Atom | undefined = one(list, kind);
  if (value === undefined) throw new Error('M4A 缺少必要容器。');
  return value;
}
function checkTrack(b: Uint8Array, track: Atom, mdatStart: number, mdatEnd: number): void {
  const trak: Atom[] = children(b, track);
  onlyKinds(trak, ['tkhd', 'edts', 'mdia', 'free', 'skip']);
  const mdia: Atom[] = children(b, atom(b, trak, 'mdia'));
  onlyKinds(mdia, ['mdhd', 'hdlr', 'minf', 'free', 'skip']);
  const hdlr: Atom = atom(b, mdia, 'hdlr');
  if (hdlr.end - hdlr.start - hdlr.head < 12 || nameAt(b, hdlr.start + hdlr.head + 8) !== 'soun') throw new Error('仅支持单音频轨道的 M4A。');
  const minf: Atom[] = children(b, atom(b, mdia, 'minf'));
  onlyKinds(minf, ['smhd', 'dinf', 'stbl', 'hdlr', 'free', 'skip']);
  const dinf: Atom[] = children(b, atom(b, minf, 'dinf'));
  onlyKinds(dinf, ['dref']); const dref: Atom = atom(b, dinf, 'dref');
  if (dref.end - dref.start - dref.head < 8 || u32(b, dref.start + dref.head) !== 0 || u32(b, dref.start + dref.head + 4) !== 1) throw new Error('M4A 数据引用不受支持。');
  const refs: Atom[] = children(b, dref, 8);
  if (refs.length !== 1 || refs[0].type !== 'url ' || refs[0].end - refs[0].start - refs[0].head !== 4 || u32(b, refs[0].start + refs[0].head) !== 1) throw new Error('M4A 外部数据引用不受支持。');
  const stbl: Atom[] = children(b, atom(b, minf, 'stbl'));
  onlyKinds(stbl, ['stsd', 'stts', 'stsc', 'stsz', 'stz2', 'stco', 'co64', 'ctts', 'stss', 'sdtp', 'sgpd', 'sbgp', 'free', 'skip']);
  const stsd: Atom = atom(b, stbl, 'stsd');
  if (stsd.end - stsd.start - stsd.head < 8 || u32(b, stsd.start + stsd.head) !== 0 || u32(b, stsd.start + stsd.head + 4) !== 1) throw new Error('M4A 音频样本描述不受支持。');
  const formats: Atom[] = children(b, stsd, 8);
  if (formats.length !== 1 || formats[0].type !== 'mp4a' || formats[0].end - formats[0].start - formats[0].head < 28 ||
      b[formats[0].start + formats[0].head + 6] !== 0 || b[formats[0].start + formats[0].head + 7] !== 1) throw new Error('仅支持未加密的单一 mp4a 音频描述。');
  const sample: Atom = formats[0]; const body: number = sample.start + sample.head;
  for (let i: number = 0; i < 6; i++) if (b[body + i] !== 0) throw new Error('M4A 样本保留字段不受支持。');
  for (let i: number = 8; i < 16; i++) if (b[body + i] !== 0) throw new Error('M4A 样本描述版本不受支持。');
  if (b[body + 20] !== 0 || b[body + 21] !== 0 || b[body + 22] !== 0 || b[body + 23] !== 0) throw new Error('M4A 样本保留字段不受支持。');
  const codec: Atom[] = atomList(b, body + 28, sample.end);
  onlyKinds(codec, ['esds', 'btrt', 'chan', 'free', 'skip']);
  atom(b, codec, 'esds');
  const low: Atom | undefined = one(stbl, 'stco', false); const high: Atom | undefined = one(stbl, 'co64', false);
  if ((low === undefined) === (high === undefined)) throw new Error('M4A 媒体偏移表缺失或重复。');
  const offsets: Atom = low !== undefined ? low : high!; const wide: boolean = high !== undefined;
  let p: number = offsets.start + offsets.head;
  if (offsets.end - p < 8 || u32(b, p) !== 0) throw new Error('M4A 偏移表无效。');
  const count: number = u32(b, p + 4); p += 8; const bytes: number = wide ? 8 : 4;
  if (count === 0 || count > 1000000 || count * bytes !== offsets.end - p) throw new Error('M4A 偏移表长度无效。');
  const offsetTable: number = p;
  // A chunk start inside mdat is insufficient: validate every sample span.
  // Compact stz2 and unfamiliar sample maps are refused rather than guessed.
  if (one(stbl, 'stz2', false) !== undefined) throw new Error('M4A 紧凑样本尺寸表暂不支持。');
  const sizes: Atom = atom(b, stbl, 'stsz'); const sizeBase: number = sizes.start + sizes.head;
  if (sizes.end - sizeBase < 12 || u32(b, sizeBase) !== 0) throw new Error('M4A 样本尺寸表无效。');
  const fixed: number = u32(b, sizeBase + 4); const sampleCount: number = u32(b, sizeBase + 8);
  if (sampleCount === 0 || sampleCount > 1000000 || sizes.end - sizeBase - 12 !== (fixed === 0 ? sampleCount * 4 : 0)) throw new Error('M4A 样本尺寸表长度无效。');
  // FFmpeg commonly emits a roll recovery group for AAC priming. Permit only
  // that narrowly checked two-byte description; unknown groups such as seig
  // (encryption) and additional/ambiguous tables remain unsupported.
  const sgpd: Atom | undefined = one(stbl, 'sgpd', false);
  const sbgp: Atom | undefined = one(stbl, 'sbgp', false);
  if ((sgpd === undefined) !== (sbgp === undefined)) throw new Error('M4A 样本分组不完整。');
  if (sgpd !== undefined && sbgp !== undefined) {
    const dp: number = sgpd.start + sgpd.head;
    if (sgpd.end - dp < 16 || u32(b, dp) !== 0x01000000 || nameAt(b, dp + 4) !== 'roll' || u32(b, dp + 8) !== 2) throw new Error('M4A 样本分组类型不受支持。');
    const entries: number = u32(b, dp + 12);
    if (entries === 0 || entries > 65535 || sgpd.end - dp - 16 !== entries * 2) throw new Error('M4A 样本分组描述无效。');
    const gp: number = sbgp.start + sbgp.head;
    if (sbgp.end - gp < 12 || u32(b, gp) !== 0 || nameAt(b, gp + 4) !== 'roll') throw new Error('M4A 样本分组映射不受支持。');
    const groups: number = u32(b, gp + 8);
    if (groups === 0 || groups > sampleCount || sbgp.end - gp - 12 !== groups * 8) throw new Error('M4A 样本分组映射无效。');
    let covered: number = 0;
    for (let i: number = 0; i < groups; i++) {
      const row: number = gp + 12 + i * 8; const n: number = u32(b, row); const index: number = u32(b, row + 4);
      if (n === 0 || n > sampleCount - covered || index > entries) throw new Error('M4A 样本分组范围无效。');
      covered += n;
    }
    if (covered !== sampleCount) throw new Error('M4A 样本分组数量不一致。');
  }
  const map: Atom = atom(b, stbl, 'stsc'); const mapBase: number = map.start + map.head;
  if (map.end - mapBase < 8 || u32(b, mapBase) !== 0) throw new Error('M4A 样本映射表无效。');
  const mapCount: number = u32(b, mapBase + 4);
  if (mapCount === 0 || mapCount > count || map.end - mapBase - 8 !== mapCount * 12) throw new Error('M4A 样本映射表长度无效。');
  let previousFirst: number = 0;
  for (let i: number = 0; i < mapCount; i++) {
    const q: number = mapBase + 8 + i * 12; const first: number = u32(b, q); const per: number = u32(b, q + 4);
    if ((i === 0 && first !== 1) || first <= previousFirst || first > count || per === 0 || per > sampleCount || u32(b, q + 8) !== 1) throw new Error('M4A 样本映射表内容不受支持。');
    previousFirst = first;
  }
  let group: number = 0; let sampleIndex: number = 0; let priorEnd: number = mdatStart;
  for (let i: number = 0; i < count; i++) {
    if (group + 1 < mapCount && u32(b, mapBase + 8 + (group + 1) * 12) === i + 1) group++;
    const per: number = u32(b, mapBase + 8 + group * 12 + 4);
    if (per > sampleCount - sampleIndex) throw new Error('M4A 样本映射数量超限。');
    const q: number = offsetTable + i * bytes; const offset: number = wide ? u64(b, q) : u32(b, q);
    if (offset < mdatStart || offset >= mdatEnd || offset < priorEnd) throw new Error('M4A 音频偏移不位于本文件媒体数据中，或样本范围重叠。');
    let end: number = offset;
    for (let j: number = 0; j < per; j++) {
      const n: number = fixed !== 0 ? fixed : u32(b, sizeBase + 12 + sampleIndex * 4);
      if (n === 0 || n > mdatEnd - end) throw new Error('M4A 音频样本超出媒体数据范围。');
      end += n; sampleIndex++;
    }
    priorEnd = end;
  }
  if (sampleIndex !== sampleCount) throw new Error('M4A 样本数量不一致。');
}
async function inspect(fd: number): Promise<M4aLayout> {
  const st: fileIo.Stat = fileIo.statSync(fd);
  if (!st.isFile() || !Number.isSafeInteger(st.size) || st.size < 32) throw new Error('M4A 文件无效。');
  let p: number = 0; let ftyp: number = 0; let moovPos: number = -1; let moovSize: number = 0; let moovHead: number = 0;
  let mdatStart: number = -1; let mdatEnd: number = -1; let count: number = 0;
  while (p < st.size) {
    if (++count > MAX_ATOMS || st.size - p < 8) throw new Error('M4A 顶层 atom 不完整。');
    const hdr: Uint8Array = await readAt(fd, p, Math.min(16, st.size - p));
    const n32: number = u32(hdr, 0); const kind: string = nameAt(hdr, 4);
    let n: number = n32; let h: number = 8;
    if (n32 === 1) { if (hdr.length < 16) throw new Error('M4A 扩展长度无效。'); n = u64(hdr, 8); h = 16; }
    if (n32 === 0 || n < h || n > st.size - p) throw new Error('M4A 顶层 atom 长度无效。');
    if (kind === 'ftyp') { if (++ftyp !== 1 || n < h + 8) throw new Error('M4A 文件类型标识无效。'); }
    else if (kind === 'moov') { if (moovPos >= 0 || n > META_LIMIT) throw new Error('M4A 索引重复或过大。'); moovPos = p; moovSize = n; moovHead = h; }
    else if (kind === 'mdat') { if (mdatStart >= 0 || n <= h) throw new Error('M4A 媒体数据重复或为空。'); mdatStart = p + h; mdatEnd = p + n; }
    else if (kind !== 'free' && kind !== 'skip' && kind !== 'wide') throw new Error('M4A 顶层结构不受支持：' + kind);
    p += n;
  }
  if (ftyp !== 1 || moovPos < 0 || mdatStart < 0) throw new Error('M4A 缺少文件类型、索引或媒体数据。');
  const b: Uint8Array = await readAt(fd, moovPos, moovSize);
  const moovChildren: Atom[] = atomList(b, moovHead, b.length);
  onlyKinds(moovChildren, ['mvhd', 'trak', 'udta', 'free', 'skip', 'iods']);
  const track: Atom = atom(b, moovChildren, 'trak'); checkTrack(b, track, mdatStart, mdatEnd);
  const udta: Atom[] = children(b, atom(b, moovChildren, 'udta'));
  onlyKinds(udta, ['meta', 'free', 'skip']);
  const meta: Atom = atom(b, udta, 'meta');
  if (meta.end - meta.start - meta.head < 4 || u32(b, meta.start + meta.head) !== 0) throw new Error('M4A 元数据版本不受支持。');
  const metaChildren: Atom[] = children(b, meta, 4);
  onlyKinds(metaChildren, ['hdlr', 'ilst', 'free', 'skip']);
  const mh: Atom = atom(b, metaChildren, 'hdlr');
  if (mh.end - mh.start - mh.head < 12 || nameAt(b, mh.start + mh.head + 8) !== 'mdir') throw new Error('仅支持 iTunes 风格 M4A 元数据。');
  const ilst: Atom = atom(b, metaChildren, 'ilst');
  const atoms: Atom[] = children(b, ilst); const items: Item[] = [];
  for (let i: number = 0; i < atoms.length; i++) items.push({ tag: atoms[i].type, atom: atoms[i] });
  let windowEnd: number = ilst.end;
  for (let i: number = 0; i < metaChildren.length; i++) if (metaChildren[i].start === ilst.end && metaChildren[i].type === 'free') {
    const free: Atom = metaChildren[i];
    // Refuse nonzero padding, retaining potentially meaningful opaque bytes.
    for (let j: number = free.start + free.head; j < free.end; j++) if (b[j] !== 0) throw new Error('M4A 可用填充包含非零数据。');
    windowEnd = free.end;
  }
  return { fileSize: st.size, moovOffset: moovPos, moov: b, items, windowStart: ilst.start, windowEnd };
}
function dataFor(b: Uint8Array, items: Item[], tag: string): DataValue | undefined {
  let selected: Atom | undefined = undefined;
  for (let i: number = 0; i < items.length; i++) if (items[i].tag === tag) {
    if (selected !== undefined) throw new Error('M4A 标签存在多个值：' + tag);
    selected = items[i].atom;
  }
  if (selected === undefined) return undefined;
  const parts: Atom[] = children(b, selected);
  if (parts.length !== 1 || parts[0].type !== 'data') throw new Error('M4A 标签含多语言或额外结构：' + tag);
  const data: Atom = parts[0]; const p: number = data.start + data.head;
  if (data.end - p < 8 || u32(b, p + 4) !== 0) throw new Error('M4A 标签语言或格式不受支持：' + tag);
  return { type: u32(b, p), bytes: b.slice(p + 8, data.end) };
}
function textFor(b: Uint8Array, items: Item[], tag: string): string {
  const value: DataValue | undefined = dataFor(b, items, tag);
  if (value === undefined) return '';
  if (value.type !== 1) throw new Error('M4A 文本编码不受支持：' + tag);
  const options: util.TextDecoderOptions = { fatal: true, ignoreBOM: true };
  return util.TextDecoder.create('utf-8', options).decodeToString(value.bytes);
}
function pairFor(b: Uint8Array, items: Item[], tag: string): Pair {
  const d: DataValue | undefined = dataFor(b, items, tag);
  if (d === undefined) return { a: 0, b: 0 };
  if (d.type !== 0 || (d.bytes.length !== 6 && d.bytes.length !== 8) || d.bytes[0] !== 0 || d.bytes[1] !== 0 ||
      (d.bytes.length === 8 && (d.bytes[6] !== 0 || d.bytes[7] !== 0))) throw new Error('M4A 曲目或碟片编号格式不受支持。');
  return { a: d.bytes[2] * 256 + d.bytes[3], b: d.bytes[4] * 256 + d.bytes[5] };
}
function bpmFor(b: Uint8Array, items: Item[]): number {
  const d: DataValue | undefined = dataFor(b, items, 'tmpo');
  if (d === undefined) return 0;
  if (d.type !== 21 || d.bytes.length !== 2 || (d.bytes[0] & 128) !== 0) throw new Error('M4A BPM 格式或有符号范围不受支持。');
  return d.bytes[0] * 256 + d.bytes[1];
}
async function coverFor(b: Uint8Array, items: Item[]): Promise<image.PixelMap | undefined> {
  const d: DataValue | undefined = dataFor(b, items, 'covr');
  if (d === undefined) return undefined;
  if ((d.type !== 13 && d.type !== 14) || d.bytes.length === 0 || d.bytes.length > 8388608) throw new Error('M4A 封面格式或大小不受支持。');
  const raw: ArrayBuffer = d.bytes.buffer.slice(d.bytes.byteOffset, d.bytes.byteOffset + d.bytes.byteLength) as ArrayBuffer;
  const source: image.ImageSource = image.createImageSource(raw);
  try {
    const info: image.ImageInfo = await source.getImageInfo(); const w: number = info.size.width; const h: number = info.size.height;
    if (!Number.isInteger(w) || !Number.isInteger(h) || w <= 0 || h <= 0 || w > 16384 || h > 16384 || w * h > 16777216 || info.isHdr) throw new Error('M4A 封面尺寸或 HDR 格式超限。');
    const result: image.PixelMap = await source.createPixelMap();
    try { const actual: image.ImageInfo = await result.getImageInfo(); if (actual.size.width !== w || actual.size.height !== h || actual.isHdr) throw new Error('M4A 封面解码尺寸不一致。'); return result; }
    catch (error) { try { await result.release(); } catch (_e) {} throw error as Error; }
  } finally { try { await source.release(); } catch (_e) {} }
}
export async function readM4aMetadata(path: string): Promise<AudioMetadata> {
  const f: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  try {
    const x: M4aLayout = await inspect(f.fd); const b: Uint8Array = x.moov; const i: Item[] = x.items;
    for (let n: number = 0; n < i.length; n++) {
      if (i[n].tag === 'gnre' || i[n].tag === '©cpy') throw new Error('M4A 含未支持的流派或版权别名，无法可靠读取。');
    }
    const tr: Pair = pairFor(b, i, 'trkn'); const ds: Pair = pairFor(b, i, 'disk');
    const date: string = textFor(b, i, '©day');
    if (date.length > 0 && !/^\d{4}$/.test(date)) throw new Error('M4A 日期包含年份以外的信息。');
    // Parse all fallible text/numeric fields before allocating a PixelMap.
    const title: string = textFor(b, i, '©nam'); const artist: string = textFor(b, i, '©ART'); const album: string = textFor(b, i, '©alb');
    const genre: string = textFor(b, i, '©gen'); const comment: string = textFor(b, i, '©cmt'); const lyrics: string = textFor(b, i, '©lyr');
    const albumArtist: string = textFor(b, i, 'aART'); const composer: string = textFor(b, i, '©wrt'); const grouping: string = textFor(b, i, '©grp');
    const copyright: string = textFor(b, i, 'cprt'); const bpm: number = bpmFor(b, i);
    const coverImage: image.PixelMap | undefined = await coverFor(b, i);
    return { title, artist, album, genre, comment, lyrics, albumArtist, composer, grouping,
      isrc: '', copyright, year: date.length > 0 ? Number(date) : 0,
      track: tr.a, trackTotal: tr.b, disc: ds.a, discTotal: ds.b, bpm,
      duration: 0, durationMs: 0, bitrate: 0, sampleRate: 0, channels: 0, coverImage,
      fileType: 'audio/mp4', fileSize: x.fileSize, creationTime: 0, modifyTime: 0 };
  } finally { try { fileIo.closeSync(f.fd); } catch (_e) {} }
}
function typeBytes(type: string): Uint8Array {
  if (type.length !== 4) throw new Error('M4A 标签标识无效。');
  const out: Uint8Array = new Uint8Array(4);
  for (let i: number = 0; i < 4; i++) { const n: number = type.charCodeAt(i); if (n > 255) throw new Error('M4A 标签标识无效。'); out[i] = n; }
  return out;
}
function box(type: string, payload: Uint8Array): Uint8Array {
  if (payload.length > META_LIMIT - 8) throw new Error('M4A 标签数据过大。');
  const out: Uint8Array = new Uint8Array(8 + payload.length); out.set(be(out.length), 0); out.set(typeBytes(type), 4); out.set(payload, 8); return out;
}
function makeItem(tag: string, type: number, raw: Uint8Array): Uint8Array {
  const d: Uint8Array = new Uint8Array(8 + raw.length); d.set(be(type), 0); d.set(raw, 8); return box(tag, box('data', d));
}
function utf8Within(value: string, limit: number): number {
  let n: number = 0;
  for (let i: number = 0; i < value.length; i++) {
    const c: number = value.charCodeAt(i);
    if (c < 128) n++; else if (c < 2048) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff) {
      if (i + 1 >= value.length || value.charCodeAt(i + 1) < 0xdc00 || value.charCodeAt(i + 1) > 0xdfff) throw new Error('M4A 文本含无效 Unicode 字符。');
      n += 4; i++;
    } else if (c >= 0xdc00 && c <= 0xdfff) throw new Error('M4A 文本含无效 Unicode 字符。');
    else n += 3;
    if (n > limit) throw new Error('M4A 文本标签过大。');
  }
  return n;
}
function textEdit(edits: Edit[], tag: string, value: string | undefined, budget: number): void {
  if (value === undefined) return;
  utf8Within(value, budget);
  const raw: Uint8Array = util.TextEncoder.create('utf-8').encodeInto(value);
  edits.push({ tag, value: value.length === 0 ? undefined : makeItem(tag, 1, raw) });
}
function pairEdit(edits: Edit[], b: Uint8Array, items: Item[], tag: string, a: number | undefined, total: number | undefined): void {
  if (a === undefined && total === undefined) return;
  const old: Pair = pairFor(b, items, tag); const x: number = a === undefined ? old.a : a; const y: number = total === undefined ? old.b : total;
  if (!Number.isInteger(x) || !Number.isInteger(y) || x < 0 || y < 0 || x > 65535 || y > 65535) throw new Error('M4A 曲目或碟片编号超限。');
  const raw: Uint8Array = new Uint8Array(tag === 'trkn' ? 8 : 6);
  raw[2] = (x >> 8) & 255; raw[3] = x & 255; raw[4] = (y >> 8) & 255; raw[5] = y & 255;
  edits.push({ tag, value: x === 0 && y === 0 ? undefined : makeItem(tag, 0, raw) });
}
async function coverEdit(edits: Edit[], cover: image.PixelMap): Promise<void> {
  const info: image.ImageInfo = await cover.getImageInfo(); const w: number = info.size.width; const h: number = info.size.height;
  if (info.isHdr || !Number.isInteger(w) || !Number.isInteger(h) || w <= 0 || h <= 0 || w > 16384 || h > 16384 || w * h > 16777216) throw new Error('M4A 封面尺寸或格式不受支持。');
  const packer: image.ImagePacker = image.createImagePacker();
  try {
    const png: ArrayBuffer = await packer.packToData(cover, { format: 'image/png', quality: 100, bufferSize: 8388608 });
    const b: Uint8Array = new Uint8Array(png);
    if (b.length < 45 || b.length > 8388608 || b[0] !== 137 || b[1] !== 80 || b[2] !== 78 || b[3] !== 71 ||
        b[4] !== 13 || b[5] !== 10 || b[6] !== 26 || b[7] !== 10 || u32(b, 8) !== 13 || nameAt(b, 12) !== 'IHDR' ||
        u32(b, 16) !== w || u32(b, 20) !== h || b[26] !== 0 || b[27] !== 0 || b[28] > 1) throw new Error('M4A 封面 PNG 结构无效。');
    let crc: number = 0xffffffff;
    for (let i: number = 12; i < 29; i++) { crc ^= b[i]; for (let bit: number = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) !== 0 ? 0xedb88320 : 0); }
    if (((crc ^ 0xffffffff) >>> 0) !== u32(b, 29) || u32(b, b.length - 12) !== 0 || nameAt(b, b.length - 8) !== 'IEND' || u32(b, b.length - 4) !== 0xae426082) throw new Error('M4A 封面 PNG 校验失败。');
    // Ensure there is a well-formed, nonempty IDAT sequence before trusting
    // an encoder result; actual pixel equivalence is verified after writing.
    let pos: number = 8; let idat: boolean = false; let ended: boolean = false; let chunks: number = 0;
    while (pos < b.length) {
      if (++chunks > 4096 || b.length - pos < 12) throw new Error('M4A 封面 PNG 数据块不完整。');
      const len: number = u32(b, pos); const kind: string = nameAt(b, pos + 4);
      if (len > b.length - pos - 12) throw new Error('M4A 封面 PNG 数据块长度无效。');
      if (kind === 'IDAT' && len > 0) idat = true;
      if (kind === 'IEND') { if (len !== 0 || pos + 12 !== b.length) throw new Error('M4A 封面 PNG 结尾无效。'); ended = true; }
      pos += 12 + len;
    }
    if (!idat || !ended) throw new Error('M4A 封面 PNG 缺少图像数据。');
    edits.push({ tag: 'covr', value: makeItem('covr', 14, b) });
  } finally { try { await packer.release(); } catch (_e) {} }
}
function isEdited(edits: Edit[], tag: string): boolean { for (let i: number = 0; i < edits.length; i++) if (edits[i].tag === tag) return true; return false; }
async function plan(x: M4aLayout, f: AudioMetadataWriter): Promise<Uint8Array> {
  if (f.isrc !== undefined) throw new Error('M4A 的 ISRC 暂不支持安全写入或清空。');
  const edits: Edit[] = []; const budget: number = x.windowEnd - x.windowStart;
  if (f.genre !== undefined) for (let i: number = 0; i < x.items.length; i++) if (x.items[i].tag === 'gnre') throw new Error('M4A 含另一种流派编码，无法安全修改。');
  if (f.copyright !== undefined) for (let i: number = 0; i < x.items.length; i++) if (x.items[i].tag === '©cpy') throw new Error('M4A 含另一种版权编码，无法安全修改。');
  const textFields: TextEntry[] = [
    { tag: '©nam', value: f.title }, { tag: '©ART', value: f.artist }, { tag: '©alb', value: f.album },
    { tag: '©gen', value: f.genre }, { tag: '©cmt', value: f.comment }, { tag: '©lyr', value: f.lyrics },
    { tag: 'aART', value: f.albumArtist }, { tag: '©wrt', value: f.composer }, { tag: '©grp', value: f.grouping },
    { tag: 'cprt', value: f.copyright }
  ];
  if (f.year !== undefined) {
    if (!Number.isInteger(f.year) || f.year < 0 || f.year > 9999) throw new Error('M4A 年份无效。');
    const old: string = textFor(x.moov, x.items, '©day');
    if (old.length > 0 && !/^\d{4}$/.test(old)) throw new Error('M4A 原日期包含年份以外的信息。');
    textFields.push({ tag: '©day', value: f.year === 0 ? '' : f.year.toString().padStart(4, '0') });
  }
  // Check the combined encoded size before allocating any requested value.
  let remaining: number = budget - 8;
  for (let i: number = 0; i < textFields.length; i++) {
    const entry: TextEntry = textFields[i];
    if (entry.value !== undefined) {
      textFor(x.moov, x.items, entry.tag); // Reject conflicting original representation.
      if (entry.value.length > 0) {
        remaining -= 24;
        if (remaining < 0) throw new Error('M4A 文本标签过大。');
        remaining -= utf8Within(entry.value, remaining);
      }
    }
  }
  for (let i: number = 0; i < textFields.length; i++) textEdit(edits, textFields[i].tag, textFields[i].value, budget);
  pairEdit(edits, x.moov, x.items, 'trkn', f.track, f.trackTotal); pairEdit(edits, x.moov, x.items, 'disk', f.disc, f.discTotal);
  if (f.bpm !== undefined) { if (!Number.isInteger(f.bpm) || f.bpm < 0 || f.bpm > 32767) throw new Error('M4A BPM 超出有符号范围。'); bpmFor(x.moov, x.items); const n: Uint8Array = new Uint8Array([(f.bpm >> 8) & 255, f.bpm & 255]); edits.push({ tag: 'tmpo', value: f.bpm === 0 ? undefined : makeItem('tmpo', 21, n) }); }
  if (f.coverImage !== undefined) {
    const oldCover: DataValue | undefined = dataFor(x.moov, x.items, 'covr');
    if (oldCover !== undefined && ((oldCover.type !== 13 && oldCover.type !== 14) || oldCover.bytes.length === 0 || oldCover.bytes.length > 8388608)) throw new Error('原 M4A 封面格式不受支持。');
    await coverEdit(edits, f.coverImage);
  }
  if (edits.length === 0) throw new Error('没有可写入的 M4A 标签更改。');
  // Validate edited items are unique and have a single default-locale data atom.
  for (let i: number = 0; i < edits.length; i++) dataFor(x.moov, x.items, edits[i].tag);
  let size: number = 8;
  for (let i: number = 0; i < x.items.length; i++) if (!isEdited(edits, x.items[i].tag)) size += x.items[i].atom.end - x.items[i].atom.start;
  for (let i: number = 0; i < edits.length; i++) if (edits[i].value !== undefined) size += edits[i].value!.length;
  const spare: number = budget - size;
  if (spare < 0 || (spare > 0 && spare < 8)) throw new Error('M4A 元数据预留空间不足，无法安全导出。');
  const out: Uint8Array = new Uint8Array(budget); out.set(be(size), 0); out.set(typeBytes('ilst'), 4); let pos: number = 8;
  for (let i: number = 0; i < x.items.length; i++) if (!isEdited(edits, x.items[i].tag)) { const a: Atom = x.items[i].atom; out.set(x.moov.slice(a.start, a.end), pos); pos += a.end - a.start; }
  for (let i: number = 0; i < edits.length; i++) if (edits[i].value !== undefined) { const item: Uint8Array = edits[i].value!; out.set(item, pos); pos += item.length; }
  if (spare > 0) { out.set(be(spare), pos); out.set(typeBytes('free'), pos + 4); }
  return out;
}
export async function verifyM4aIntegrity(beforePath: string, afterPath: string, fields: AudioMetadataWriter): Promise<void> {
  const a: fileIo.File = fileIo.openSync(beforePath, fileIo.OpenMode.READ_ONLY); let b: fileIo.File | undefined = undefined;
  try {
    b = fileIo.openSync(afterPath, fileIo.OpenMode.READ_ONLY);
    const before: M4aLayout = await inspect(a.fd); const after: M4aLayout = await inspect(b.fd);
    if (before.fileSize !== after.fileSize || before.moovOffset !== after.moovOffset || before.windowStart !== after.windowStart || before.windowEnd !== after.windowEnd) throw new Error('M4A 元数据窗口或文件长度发生变化。');
    const expected: Uint8Array = await plan(before, fields);
    const actual: Uint8Array = after.moov.slice(after.windowStart, after.windowEnd);
    if (expected.length !== actual.length) throw new Error('M4A 输出窗口长度不一致。');
    for (let i: number = 0; i < expected.length; i++) if (expected[i] !== actual[i]) throw new Error('M4A 元数据输出与计划不一致。');
    const start: number = before.moovOffset + before.windowStart; const end: number = before.moovOffset + before.windowEnd;
    const positions: number[] = [0, end]; const lengths: number[] = [start, before.fileSize - end];
    for (let r: number = 0; r < 2; r++) for (let p: number = 0; p < lengths[r];) {
      const n: number = Math.min(CHUNK, lengths[r] - p); const left: Uint8Array = await readAt(a.fd, positions[r] + p, n); const right: Uint8Array = await readAt(b.fd, positions[r] + p, n);
      for (let j: number = 0; j < n; j++) if (left[j] !== right[j]) throw new Error('M4A 未编辑数据或媒体字节发生变化。'); p += n;
    }
    if (fileIo.statSync(a.fd).size !== before.fileSize || fileIo.statSync(b.fd).size !== after.fileSize) throw new Error('校验期间 M4A 文件发生变化。');
    // Read independently and check requested fields, including cover pixels,
    // and all unmodified fields. The repeated plan comparison alone cannot
    // detect a consistent encoding mistake in the writer.
    const oldMetadata: AudioMetadata = await readM4aMetadata(beforePath);
    let newMetadata: AudioMetadata | undefined = undefined;
    try {
      newMetadata = await readM4aMetadata(afterPath);
      await verifyWrittenMetadata(fields, newMetadata);
      await verifyPreservedMetadata(fields, oldMetadata, newMetadata);
    } finally {
      if (oldMetadata.coverImage !== undefined) { try { await oldMetadata.coverImage.release(); } catch (_e) {} }
      if (newMetadata !== undefined && newMetadata.coverImage !== undefined) { try { await newMetadata.coverImage.release(); } catch (_e) {} }
    }
  } finally { try { fileIo.closeSync(a.fd); } catch (_e) {} if (b !== undefined) { try { fileIo.closeSync(b.fd); } catch (_e) {} } }
}
export async function writeM4aMetadata(filesDir: string, inputPath: string, fields: AudioMetadataWriter): Promise<string> {
  const root: string = filesDir.endsWith('/') ? filesDir.substring(0, filesDir.length - 1) : filesDir;
  if (!root.startsWith('/') || !inputPath.startsWith(root + '/') || root.indexOf('\\') >= 0 || inputPath.indexOf('\\') >= 0) throw new Error('仅允许编辑应用私有目录中的副本。');
  const parts: string[] = inputPath.split('/'); for (let i: number = 1; i < parts.length; i++) if (parts[i] === '' || parts[i] === '.' || parts[i] === '..' || parts[i].indexOf('\u0000') >= 0) throw new Error('M4A 工作路径无效。');
  const src: fileIo.File = fileIo.openSync(inputPath, fileIo.OpenMode.READ_ONLY); let out: fileIo.File | undefined = undefined;
  let dir: string = ''; let path: string = ''; let complete: boolean = false;
  try {
    const x: M4aLayout = await inspect(src.fd); const replacement: Uint8Array = await plan(x, fields);
    dir = fileIo.mkdtempSync(root + '/lyricflow_m4a_XXXXXX'); path = dir + '/edited.m4a'; out = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    const start: number = x.moovOffset + x.windowStart; const end: number = x.moovOffset + x.windowEnd;
    await copyRange(src.fd, out.fd, 0, start); await writeAll(out.fd, replacement); await copyRange(src.fd, out.fd, end, x.fileSize - end);
    if (fileIo.statSync(src.fd).size !== x.fileSize || fileIo.statSync(out.fd).size !== x.fileSize) throw new Error('M4A 副本长度校验失败。');
    fileIo.fsyncSync(out.fd); fileIo.closeSync(out.fd); out = undefined;
    await verifyM4aIntegrity(inputPath, path, fields);
    complete = true; return path;
  } finally {
    if (out !== undefined) { try { fileIo.closeSync(out.fd); } catch (_e) {} }
    try { fileIo.closeSync(src.fd); } catch (_e) {}
    if (!complete && path.length > 0) { try { fileIo.unlinkSync(path); } catch (_e) {} }
    if (!complete && dir.length > 0) { try { fileIo.rmdirSync(dir); } catch (_e) {} }
  }
}
