import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { AudioMetadata, AudioMetadataWriter } from './AudioMetadataTypes';

// Isolated variable-length Ogg comment repagination experiment.
// A single Vorbis or Opus logical stream is accepted. Audio pages preserve
// their data, lacing, flags and granules; sequence numbers and CRCs are rebuilt.
const MAX_COMMENT: number = 4 * 1024 * 1024;
const MAX_SETUP: number = 4 * 1024 * 1024;
const MAX_PAGES: number = 1000000;
const CHUNK: number = 256 * 1024;
interface Span { at: number; length: number; packetOffset: number; page: number; pageLength: number; }
interface Entry { key: string; raw: Uint8Array; value: string; }
interface Comments { vendor: Uint8Array; entries: Entry[]; suffix: Uint8Array; }
interface Parsed { size: number; codec: string; sampleRate: number; channels: number; comment: Uint8Array; setup: Uint8Array; firstPageLength: number; audioOffset: number; serial: number; spans: Span[]; tags: Comments; }
interface Edit { key: string; aliases: string[]; value: string | undefined; }
export interface OggMetadata extends AudioMetadata { codec: string; hasArtwork: boolean; requiresSystemAudioValidation: boolean; }

async function readAt(fd: number, offset: number, length: number): Promise<Uint8Array> {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || length > CHUNK) {
    throw new Error('Ogg 读取范围无效。');
  }
  const result: Uint8Array = new Uint8Array(length);
  let done: number = 0;
  while (done < length) {
    if (fileIo.lseek(fd, offset + done, fileIo.WhenceType.SEEK_SET) !== offset + done) throw new Error('Ogg 定位失败。');
    const part: ArrayBuffer = new ArrayBuffer(length - done);
    const n: number = await fileIo.read(fd, part, { length: part.byteLength });
    if (n <= 0 || n > part.byteLength) throw new Error('Ogg 读取不完整。');
    result.set(new Uint8Array(part, 0, n), done); done += n;
  }
  return result;
}
async function writeAll(fd: number, data: Uint8Array): Promise<void> {
  let done: number = 0;
  while (done < data.length) {
    const part: ArrayBuffer = data.buffer.slice(data.byteOffset + done, data.byteOffset + data.length) as ArrayBuffer;
    const n: number = await fileIo.write(fd, part, { length: part.byteLength });
    if (n <= 0 || n > part.byteLength) throw new Error('Ogg 写入不完整。');
    done += n;
  }
}
function le(b: Uint8Array, p: number): number {
  if (p < 0 || p + 4 > b.length) throw new Error('Ogg 长度字段不完整。');
  return b[p] + b[p + 1] * 256 + b[p + 2] * 65536 + b[p + 3] * 16777216;
}
function putLe(b: Uint8Array, p: number, n: number): void {
  for (let i: number = 0; i < 4; i++) { b[p + i] = n % 256; n = Math.floor(n / 256); }
}
const CRC_TABLE: number[] = [];
for (let i: number = 0; i < 256; i++) {
  let c: number = (i << 24) >>> 0;
  for (let j: number = 0; j < 8; j++) c = (((c << 1) ^ ((c & 0x80000000) !== 0 ? 0x04c11db7 : 0)) >>> 0);
  CRC_TABLE.push(c);
}
function crc(page: Uint8Array): number {
  let c: number = 0;
  for (let i: number = 0; i < page.length; i++) {
    const octet: number = i >= 22 && i < 26 ? 0 : page[i];
    c = (((c << 8) ^ CRC_TABLE[((c >>> 24) ^ octet) & 255]) >>> 0);
  }
  return c;
}
function signature(data: Uint8Array, prefix: number[]): boolean {
  if (data.length < prefix.length) return false;
  for (let i: number = 0; i < prefix.length; i++) if (data[i] !== prefix[i]) return false;
  return true;
}
function decode(bytes: Uint8Array): string {
  const opts: util.TextDecoderOptions = { fatal: true, ignoreBOM: true };
  return util.TextDecoder.create('utf-8', opts).decodeToString(bytes);
}
function utf8Length(text: string): number {
  let length: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const c: number = text.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      if (i + 1 >= text.length || text.charCodeAt(i + 1) < 0xdc00 || text.charCodeAt(i + 1) > 0xdfff) throw new Error('Ogg 注释包含无效 Unicode。');
      length += 4; i++;
    } else if (c >= 0xdc00 && c <= 0xdfff) throw new Error('Ogg 注释包含无效 Unicode。');
    else if (c < 0x80) length++;
    else if (c < 0x800) length += 2;
    else length += 3;
    if (length > MAX_COMMENT) throw new Error('Ogg 注释过长。');
  }
  return length;
}
function encode(text: string): Uint8Array {
  utf8Length(text);
  const result: Uint8Array = util.TextEncoder.create('utf-8').encodeInto(text);
  if (result.length > MAX_COMMENT) throw new Error('Ogg 注释过长。');
  return result;
}
function parseComments(packet: Uint8Array, codec: string): Comments {
  const prefix: number[] = codec === 'opus' ? [79,112,117,115,84,97,103,115] : [3,118,111,114,98,105,115];
  if (!signature(packet, prefix)) throw new Error('Ogg 注释包标识无效。');
  let p: number = prefix.length;
  const vn: number = le(packet, p); p += 4;
  if (vn > packet.length - p - 4) throw new Error('Ogg 厂商字符串不完整。');
  const vendor: Uint8Array = packet.slice(p, p + vn); p += vn;
  const count: number = le(packet, p); p += 4;
  if (count > 65536 || count > Math.floor((packet.length - p) / 4)) throw new Error('Ogg 注释数量无效。');
  const entries: Entry[] = [];
  for (let i: number = 0; i < count; i++) {
    const n: number = le(packet, p); p += 4;
    if (n > packet.length - p) throw new Error('Ogg 注释长度无效。');
    const end: number = p + n;
    let q: number = p;
    while (q < end && packet[q] !== 61) {
      if (q - p >= 255 || packet[q] < 32 || packet[q] > 125) throw new Error('Ogg 注释字段名无效。');
      q++;
    }
    if (q === p || q === end) throw new Error('Ogg 注释字段缺少名称或等号。');
    let key: string = '';
    for (let j: number = p; j < q; j++) key += String.fromCharCode(packet[j]);
    entries.push({ key: key.toUpperCase(), raw: packet.slice(p, end), value: decode(packet.slice(q + 1, end)) });
    p = end;
  }
  const suffix: Uint8Array = packet.slice(p);
  if (codec === 'vorbis' && (suffix.length !== 1 || suffix[0] !== 1)) throw new Error('Vorbis 注释结束标记或尾部数据不支持。');
  return { vendor, entries, suffix };
}
function uniqueValue(tags: Comments, keys: string[]): string {
  let found: boolean = false;
  let value: string = '';
  for (let i: number = 0; i < tags.entries.length; i++) {
    if (keys.indexOf(tags.entries[i].key) < 0) continue;
    if (found) throw new Error('Ogg 字段包含重复值或别名，暂不支持：' + keys[0]);
    found = true; value = tags.entries[i].value;
  }
  return value;
}
function hasAny(tags: Comments, keys: string[]): boolean {
  for (let i: number = 0; i < tags.entries.length; i++) if (keys.indexOf(tags.entries[i].key) >= 0) return true;
  return false;
}
function numberField(value: string): number {
  if (value.length === 0) return 0;
  if (!/^[0-9]+$/.test(value)) throw new Error('Ogg 数字字段格式无效。');
  const n: number = Number(value);
  if (!Number.isSafeInteger(n) || n > 99999) throw new Error('Ogg 数字字段超出范围。');
  return n;
}
function numberText(n: number | undefined, max: number = 99999): string | undefined {
  if (n === undefined) return undefined;
  if (!Number.isSafeInteger(n) || n < 0 || n > max) throw new Error('Ogg 待写数字超出范围。');
  return n === 0 ? '' : n.toString();
}
function fields(changes: AudioMetadataWriter): Edit[] {
  if (changes.coverImage !== undefined) throw new Error('Ogg 实验写入暂不支持修改封面。');
  const year: string | undefined = numberText(changes.year, 9999);
  return [
    {key:'TITLE',aliases:['TITLE'],value:changes.title}, {key:'ARTIST',aliases:['ARTIST'],value:changes.artist},
    {key:'ALBUM',aliases:['ALBUM'],value:changes.album}, {key:'GENRE',aliases:['GENRE'],value:changes.genre},
    {key:'COMMENT',aliases:['COMMENT','DESCRIPTION'],value:changes.comment},
    {key:'LYRICS',aliases:['LYRICS','UNSYNCEDLYRICS','SYNCEDLYRICS'],value:changes.lyrics},
    {key:'ALBUMARTIST',aliases:['ALBUMARTIST','ALBUM ARTIST'],value:changes.albumArtist},
    {key:'COMPOSER',aliases:['COMPOSER'],value:changes.composer}, {key:'GROUPING',aliases:['GROUPING'],value:changes.grouping},
    {key:'ISRC',aliases:['ISRC'],value:changes.isrc}, {key:'COPYRIGHT',aliases:['COPYRIGHT'],value:changes.copyright},
    {key:'DATE',aliases:['DATE','YEAR'],value:year === undefined || year.length === 0 ? year : year.padStart(4, '0')},
    {key:'TRACKNUMBER',aliases:['TRACKNUMBER','TRACKNUM'],value:numberText(changes.track)},
    {key:'TRACKTOTAL',aliases:['TRACKTOTAL','TOTALTRACKS'],value:numberText(changes.trackTotal)},
    {key:'DISCNUMBER',aliases:['DISCNUMBER'],value:numberText(changes.disc)},
    {key:'DISCTOTAL',aliases:['DISCTOTAL','TOTALDISCS'],value:numberText(changes.discTotal)},
    {key:'BPM',aliases:['BPM'],value:numberText(changes.bpm)}
  ];
}
function replacement(parsed: Parsed, changes: AudioMetadataWriter): Uint8Array {
  const edits: Edit[] = fields(changes);
  const tags: Comments = parsed.tags;
  const values: Uint8Array[] = [];
  let active: number = 0;
  let requestedBytes: number = 0;
  for (let i: number = 0; i < edits.length; i++) {
    if (edits[i].value !== undefined) {
      uniqueValue(tags, edits[i].aliases); active++;
      requestedBytes += edits[i].key.length + 1 + utf8Length(edits[i].value!);
      if (requestedBytes > MAX_COMMENT) throw new Error('Ogg 注释总量过大。');
    }
  }
  if (changes.year !== undefined) {
    const date: string = uniqueValue(tags, ['DATE','YEAR']);
    if (date.length > 0 && !/^[0-9]{4}$/.test(date)) throw new Error('原日期包含年份以外信息，无法安全修改。');
  }
  if (changes.track !== undefined || changes.trackTotal !== undefined) {
    const track: string = uniqueValue(tags, ['TRACKNUMBER','TRACKNUM']);
    if (track.indexOf('/') >= 0) throw new Error('曲目号包含总数，暂不支持修改。');
  }
  if (changes.disc !== undefined || changes.discTotal !== undefined) {
    const disc: string = uniqueValue(tags, ['DISCNUMBER']);
    if (disc.indexOf('/') >= 0) throw new Error('碟片号包含总数，暂不支持修改。');
  }
  if (active === 0) throw new Error('没有可写入的 Ogg 字段。');
  const seen: string[] = [];
  for (let i: number = 0; i < tags.entries.length; i++) {
    const entry: Entry = tags.entries[i];
    let edit: Edit | undefined = undefined;
    for (let j: number = 0; j < edits.length; j++) if (edits[j].aliases.indexOf(entry.key) >= 0 && edits[j].value !== undefined) edit = edits[j];
    if (edit === undefined) values.push(entry.raw);
    else {
      seen.push(edit.key);
      let separator: number = 0;
      while (separator < entry.raw.length && entry.raw[separator] !== 61) separator++;
      const originalKey: string = decode(entry.raw.slice(0, separator));
      values.push(encode(originalKey + '=' + edit.value!));
    }
  }
  for (let i: number = 0; i < edits.length; i++) {
    if (edits[i].value !== undefined && seen.indexOf(edits[i].key) < 0 && edits[i].value!.length > 0) {
      values.push(encode(edits[i].key + '=' + edits[i].value!));
    }
  }
  const prefix: number[] = parsed.codec === 'opus' ? [79,112,117,115,84,97,103,115] : [3,118,111,114,98,105,115];
  const suffixLength: number = tags.suffix.length;
  let length: number = prefix.length + 8 + tags.vendor.length + suffixLength;
  for (let i: number = 0; i < values.length; i++) length += 4 + values[i].length;
  if (length > MAX_COMMENT) throw new Error('新 Ogg 标签超过安全大小上限。');
  const out: Uint8Array = new Uint8Array(length);
  out.set(prefix, 0);
  let p: number = prefix.length;
  putLe(out, p, tags.vendor.length); p += 4; out.set(tags.vendor, p); p += tags.vendor.length;
  putLe(out, p, values.length); p += 4;
  for (let i: number = 0; i < values.length; i++) { putLe(out, p, values[i].length); p += 4; out.set(values[i], p); p += values[i].length; }
  out.set(tags.suffix.subarray(0, suffixLength), p);
  return out;
}

function granuleZero(page: Uint8Array): boolean {
  for (let i: number = 6; i < 14; i++) if (page[i] !== 0) return false;
  return true;
}
function granuleUnknown(page: Uint8Array): boolean {
  for (let i: number = 6; i < 14; i++) if (page[i] !== 255) return false;
  return true;
}
// Opus TOC duration in 48 kHz samples (RFC 6716 section 3.1). This is
// not a full compressed-packet decoder; platform codec verification remains required.
interface OpusLength { size: number; next: number; }
function opusFrameLength(packet: Uint8Array, p: number, end: number): OpusLength {
  if (p >= end) throw new Error('Opus 音频帧长度字段不完整。');
  const first: number = packet[p++];
  if (first < 252) return { size: first, next: p };
  if (p >= end) throw new Error('Opus 音频帧长度字段不完整。');
  return { size: first + packet[p++] * 4, next: p };
}
function opusPacketSamples(packet: Uint8Array): number {
  const n: number = packet.length;
  if (n < 1 || n > 61440) throw new Error('Opus 音频包为空或过大。');
  const toc: number = packet[0]; const config: number = toc >> 3; const code: number = toc & 3;
  const silk: number[] = [480, 960, 1920, 2880];
  const celt: number[] = [120, 240, 480, 960];
  const perFrame: number = config < 12 ? silk[config % 4] : (config < 16 ? (config % 2 === 0 ? 480 : 960) : celt[config % 4]);
  let count: number = code === 0 ? 1 : 2;
  if (code === 0 && n - 1 > 1275) throw new Error('Opus 帧长度超出范围。');
  if (code === 1 && ((n - 1) % 2 !== 0 || (n - 1) / 2 > 1275)) throw new Error('Opus 等长帧格式无效。');
  if (code === 2) {
    const first: OpusLength = opusFrameLength(packet, 1, n);
    const remaining: number = n - first.next;
    if (first.size > remaining || remaining - first.size > 1275) throw new Error('Opus 双帧长度无效。');
  }
  if (code === 3) {
    if (n < 2) throw new Error('Opus 帧数信息不完整。');
    count = packet[1] & 63;
    if (count === 0 || perFrame * count > 5760) throw new Error('Opus 音频包时长无效。');
    let cursor: number = 2; let padding: number = 0;
    if ((packet[1] & 64) !== 0) {
      let part: number = 255;
      while (part === 255) {
        if (cursor >= n) throw new Error('Opus 填充长度不完整。');
        part = packet[cursor++]; padding += part === 255 ? 254 : part;
        if (padding > n - cursor) throw new Error('Opus 填充过大。');
      }
    }
    const end: number = n - padding;
    if (cursor > end) throw new Error('Opus 填充长度无效。');
    if ((packet[1] & 128) === 0) {
      const remaining: number = end - cursor;
      if (remaining % count !== 0 || remaining / count > 1275) throw new Error('Opus 等长帧格式无效。');
    } else {
      let sum: number = 0;
      for (let i: number = 0; i < count - 1; i++) {
        const part: OpusLength = opusFrameLength(packet, cursor, end);
        cursor = part.next; sum += part.size;
        if (sum > end - cursor) throw new Error('Opus 可变帧长度超出包范围。');
      }
      const last: number = end - cursor - sum;
      if (last < 0 || last > 1275) throw new Error('Opus 最后一帧长度无效。');
    }
  }
  const samples: number = perFrame * count;
  if (count === 0 || samples > 5760) throw new Error('Opus 音频包时长无效。');
  return samples;
}

async function parse(fd: number): Promise<Parsed> {
  const stat: fileIo.Stat = fileIo.statSync(fd);
  if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size < 28) throw new Error('Ogg 文件无效。');
  let offset: number = 0;
  let sequence: number = 0;
  let serial: number = -1;
  let codec: string = '';
  let sampleRate: number = 0;
  let channels: number = 0;
  let preSkip: number = 0;
  let lastAudioLow: number = -1;
  let lastAudioHigh: number = -1;
  let pending: boolean = false;
  let ended: boolean = false;
  let packet: number = 0;
  let packetLength: number = 0;
  let opusParts: Uint8Array[] = [];
  let head: number[] = [];
  let audioPackets: number = 0;
  let commentLength: number = 0;
  let setupLength: number = 0;
  let firstPageLength: number = 0;
  let audioOffset: number = -1;
  const setupParts: Uint8Array[] = [];
  const commentParts: Uint8Array[] = [];
  const spans: Span[] = [];
  while (offset < stat.size) {
    if (sequence >= MAX_PAGES || ended || stat.size - offset < 27) throw new Error('Ogg 页面数量过多或尾部数据无效。');
    const h: Uint8Array = await readAt(fd, offset, 27);
    if (!signature(h, [79,103,103,83]) || h[4] !== 0 || (h[5] & 0xf8) !== 0) throw new Error('Ogg 页面头无效。');
    const segments: number = h[26];
    if (segments === 0 || stat.size - offset < 27 + segments) throw new Error('Ogg 分段表为空或不完整。');
    const table: Uint8Array = await readAt(fd, offset + 27, segments);
    let body: number = 0;
    for (let i: number = 0; i < segments; i++) body += table[i];
    const pageLength: number = 27 + segments + body;
    if (pageLength > stat.size - offset) throw new Error('Ogg 页面不完整。');
    const page: Uint8Array = await readAt(fd, offset, pageLength);
    if (sequence === 0) firstPageLength = pageLength;
    if (crc(page) !== le(page, 22)) throw new Error('Ogg 页面 CRC 校验失败。');
    if (sequence === 0) {
      if ((page[5] & 2) === 0 || (page[5] & 1) !== 0) throw new Error('Ogg 起始页标志无效。');
      serial = le(page, 14);
    } else if ((page[5] & 2) !== 0 || le(page, 14) !== serial) {
      throw new Error('Ogg 多流、链式或重复起始页暂不支持。');
    }
    if (le(page, 18) !== sequence || (((page[5] & 1) !== 0) !== pending)) {
      throw new Error('Ogg 页面序号或跨页延续标志无效。');
    }
    let payload: number = 27 + segments;
    let completedOnPage: number = 0;
    let completedHeader: boolean = false;
    const audioBefore: number = audioPackets;
    let pageOpusSamples: number = 0;
    for (let i: number = 0; i < segments; i++) {
      const n: number = table[i];
      if (packet === 1) {
        if (commentLength + n > MAX_COMMENT) throw new Error('Ogg 注释超过实验大小上限。');
        if (n > 0) {
          commentParts.push(page.slice(payload, payload + n));
          spans.push({ at: offset + payload, length: n, packetOffset: commentLength, page: offset, pageLength });
          commentLength += n;
        }
      }
      if (codec === 'vorbis' && packet === 2 && n > 0) {
        setupLength += n;
        if (setupLength > MAX_SETUP) throw new Error('Vorbis setup 包超过安全大小上限。');
        setupParts.push(page.slice(payload, payload + n));
      }
      if (codec.length > 0 && packet >= (codec === 'opus' ? 2 : 3) && audioOffset < 0) {
        if (i !== 0 || pending) throw new Error('Ogg 音频未从新页面开始。');
        audioOffset = offset;
      }
      if (codec === 'opus' && packet >= 2) {
        if (packetLength + n > 61440) throw new Error('Opus 音频包过大。');
        if (n > 0) opusParts.push(page.slice(payload, payload + n));
      }
      if (packet === 0 || (codec === 'vorbis' && packet === 2)) {
        for (let j: number = 0; j < n && head.length < 64; j++) head.push(page[payload + j]);
      } else if (packet >= (codec === 'opus' ? 2 : 3) && head.length < 2) {
        for (let j: number = 0; j < n && head.length < 2; j++) head.push(page[payload + j]);
      }
      packetLength += n;
      payload += n;
      pending = n === 255;
      if (!pending) {
        const hbytes: Uint8Array = new Uint8Array(head);
        if (packet === 0) {
          if (sequence !== 0 || i !== segments - 1) throw new Error('Ogg 识别头必须独占首个页面。');
          if (signature(hbytes, [79,112,117,115,72,101,97,100])) {
            if (packetLength !== 19 || hbytes.length < 19 || (hbytes[8] & 0xf0) !== 0 ||
                (hbytes[9] !== 1 && hbytes[9] !== 2) || hbytes[18] !== 0) throw new Error('Opus 识别头暂不支持。');
            codec = 'opus'; sampleRate = 48000; channels = hbytes[9]; preSkip = hbytes[10] + hbytes[11] * 256;
          } else if (signature(hbytes, [1,118,111,114,98,105,115])) {
            if (packetLength !== 30 || hbytes.length < 30 || le(hbytes, 7) !== 0 || hbytes[11] === 0 ||
                le(hbytes, 12) === 0 || (hbytes[29] & 1) === 0 || (hbytes[28] & 15) < 6 ||
                (hbytes[28] >> 4) > 13 || (hbytes[28] & 15) > (hbytes[28] >> 4)) {
              throw new Error('Vorbis 识别头无效。');
            }
            codec = 'vorbis'; sampleRate = le(hbytes, 12); channels = hbytes[11];
          } else throw new Error('不是受支持的 Ogg Vorbis 或 Opus 音频。');
          completedHeader = true;
        } else if (packet === 1) {
          if (codec === 'opus' && i !== segments - 1) throw new Error('Opus 注释包后必须换页。');
          completedHeader = true;
        } else if (codec === 'vorbis' && packet === 2) {
          if (packetLength <= 7 || !signature(hbytes, [5,118,111,114,98,105,115]) || i !== segments - 1) {
            throw new Error('Vorbis setup 包无效或后续音频未换页。');
          }
          completedHeader = true;
        } else {
          if (packetLength === 0 || (codec === 'vorbis' && (head.length === 0 || (head[0] & 1) !== 0))) {
            throw new Error('Ogg 音频包无效。');
          }
          if (codec === 'opus') {
            const opusPacket: Uint8Array = new Uint8Array(packetLength);
            let position: number = 0;
            for (let partIndex: number = 0; partIndex < opusParts.length; partIndex++) {
              opusPacket.set(opusParts[partIndex], position); position += opusParts[partIndex].length;
            }
            pageOpusSamples += opusPacketSamples(opusPacket); opusParts = [];
          }
          audioPackets++;
        }
        completedOnPage++; packet++; packetLength = 0; head = [];
      }
    }
    if (sequence === 0 && packet !== 1) throw new Error('Ogg 首页面识别头不完整。');
    if (completedOnPage === 0 && !granuleUnknown(page)) throw new Error('无完整包的 Ogg 页应使用未知时间戳。');
    if (completedOnPage > 0 && granuleUnknown(page)) throw new Error('Ogg 时间戳无效。');
    if (completedHeader && !granuleZero(page)) throw new Error('Ogg 头页面时间戳无效。');
    ended = (page[5] & 4) !== 0;
    if (audioPackets > audioBefore) {
      const low: number = le(page, 6); const high: number = le(page, 10);
      if (high >= 0x80000000 || (lastAudioHigh >= 0 && (high < lastAudioHigh || (high === lastAudioHigh && low < lastAudioLow)))) {
        throw new Error('Ogg 音频时间戳为负或倒退。');
      }
      if (codec === 'opus') {
        if (audioBefore === 0) {
          if (ended && high === 0 && low < preSkip) throw new Error('Opus 音频长度小于 pre-skip，文件无效。');
          if (!ended && high === 0 && low < pageOpusSamples) throw new Error('Opus 首个音频页时间戳小于页面音频时长。');
        } else {
          const sum: number = lastAudioLow + pageOpusSamples;
          const expectedLow: number = sum % 4294967296;
          const expectedHigh: number = lastAudioHigh + Math.floor(sum / 4294967296);
          const tooLarge: boolean = high > expectedHigh || (high === expectedHigh && low > expectedLow);
          const equal: boolean = high === expectedHigh && low === expectedLow;
          if ((!ended && !equal) || (ended && tooLarge)) throw new Error('Opus 时间戳与音频包时长不一致。');
        }
      }
      lastAudioLow = low; lastAudioHigh = high;
    }
    if (ended && (pending || offset + pageLength !== stat.size)) throw new Error('Ogg 末尾页面不完整或存在尾随数据。');
    offset += pageLength; sequence++;
  }
  if (!ended || pending || audioPackets === 0 || codec.length === 0 || commentLength === 0 || audioOffset < 0 ||
      fileIo.statSync(fd).size !== stat.size) throw new Error('Ogg 缺少完整音频、注释或结束页。');
  const comment: Uint8Array = new Uint8Array(commentLength);
  let p: number = 0;
  for (let i: number = 0; i < commentParts.length; i++) { comment.set(commentParts[i], p); p += commentParts[i].length; }
  const tags: Comments = parseComments(comment, codec);
  const setup: Uint8Array = new Uint8Array(setupLength);
  let setupAt: number = 0;
  for (let i: number = 0; i < setupParts.length; i++) { setup.set(setupParts[i], setupAt); setupAt += setupParts[i].length; }
  return { size: stat.size, codec, sampleRate, channels, comment, setup, firstPageLength, audioOffset, serial, spans, tags };
}

function be(b: Uint8Array, p: number): number {
  if (p < 0 || p + 4 > b.length) throw new Error('Ogg 封面长度无效。');
  return b[p] * 16777216 + b[p + 1] * 65536 + b[p + 2] * 256 + b[p + 3];
}
function base64Value(c: number): number {
  if (c >= 65 && c <= 90) return c - 65;
  if (c >= 97 && c <= 122) return c - 97 + 26;
  if (c >= 48 && c <= 57) return c - 48 + 52;
  if (c === 43) return 62;
  if (c === 47) return 63;
  return -1;
}
function base64Picture(value: string): Uint8Array {
  if (value.length === 0 || value.length % 4 !== 0 || value.length > MAX_COMMENT) throw new Error('Ogg 封面 Base64 长度无效。');
  const pad: number = value.endsWith('==') ? 2 : (value.endsWith('=') ? 1 : 0);
  for (let i: number = 0; i < value.length - pad; i++) if (base64Value(value.charCodeAt(i)) < 0) throw new Error('Ogg 封面 Base64 无效。');
  if ((pad === 2 && (base64Value(value.charCodeAt(value.length - 3)) & 15) !== 0) ||
      (pad === 1 && (base64Value(value.charCodeAt(value.length - 2)) & 3) !== 0)) throw new Error('Ogg 封面 Base64 填充无效。');
  const bytes: Uint8Array = new Uint8Array(value.length / 4 * 3 - pad);
  let p: number = 0;
  for (let i: number = 0; i < value.length; i += 4) {
    const a: number = base64Value(value.charCodeAt(i));
    const b: number = base64Value(value.charCodeAt(i + 1));
    const c: number = value[i + 2] === '=' ? 0 : base64Value(value.charCodeAt(i + 2));
    const d: number = value[i + 3] === '=' ? 0 : base64Value(value.charCodeAt(i + 3));
    if (a < 0 || b < 0 || c < 0 || d < 0) throw new Error('Ogg 封面 Base64 无效。');
    if (p < bytes.length) bytes[p++] = a * 4 + (b >> 4);
    if (p < bytes.length) bytes[p++] = (b & 15) * 16 + (c >> 2);
    if (p < bytes.length) bytes[p++] = (c & 3) * 64 + d;
  }
  return bytes;
}
interface Picture { kind: number; width: number; height: number; data: Uint8Array; }
function parsePicture(raw: Uint8Array): Picture {
  if (raw.length < 32) throw new Error('Ogg 封面块不完整。');
  const kind: number = be(raw, 0);
  let p: number = 4;
  const mimeLen: number = be(raw, p); p += 4;
  if (mimeLen === 0 || mimeLen > 255 || mimeLen > raw.length - p - 4) throw new Error('Ogg 封面 MIME 无效。');
  const mime: string = decode(raw.slice(p, p + mimeLen)); p += mimeLen;
  if (mime !== 'image/png' && mime !== 'image/jpeg') throw new Error('Ogg 封面类型暂不支持。');
  const descLen: number = be(raw, p); p += 4;
  if (descLen > raw.length - p - 20) throw new Error('Ogg 封面描述不完整。');
  decode(raw.slice(p, p + descLen)); p += descLen;
  const width: number = be(raw, p); const height: number = be(raw, p + 4);
  const depth: number = be(raw, p + 8); const colors: number = be(raw, p + 12);
  const length: number = be(raw, p + 16); p += 20;
  if (kind > 20 || width === 0 || height === 0 || width > 16384 || height > 16384 || width * height > 16777216 ||
      depth > 128 || colors > 16777216 || length === 0 || length !== raw.length - p) throw new Error('Ogg 封面数据无效。');
  return { kind, width, height, data: raw.slice(p) };
}
async function decodeArtwork(tags: Comments): Promise<image.PixelMap | undefined> {
  let front: Picture | undefined = undefined;
  let legacy: Uint8Array | undefined = undefined;
  let legacyMime: string = '';
  let hasLegacyMime: boolean = false;
  for (let i: number = 0; i < tags.entries.length; i++) {
    const e: Entry = tags.entries[i];
    if (e.key === 'METADATA_BLOCK_PICTURE') {
      const picture: Picture = parsePicture(base64Picture(e.value));
      if (picture.kind === 3) {
        if (front !== undefined) throw new Error('Ogg 中存在多个前封面。');
        front = picture;
      }
    } else if (e.key === 'COVERART') {
      if (legacy !== undefined) throw new Error('Ogg 中存在多个旧式封面。');
      legacy = base64Picture(e.value);
    } else if (e.key === 'COVERARTMIME') {
      if (hasLegacyMime) throw new Error('Ogg 旧式封面 MIME 重复。');
      hasLegacyMime = true; legacyMime = e.value;
    }
  }
  if (legacy !== undefined && front !== undefined) throw new Error('Ogg 新旧封面并存，无法确定前封面。');
  if (hasLegacyMime && legacy === undefined) throw new Error('Ogg 旧式封面缺失。');
  if (hasLegacyMime && legacyMime !== 'image/png' && legacyMime !== 'image/jpeg') throw new Error('Ogg 旧式封面类型不支持。');
  const data: Uint8Array | undefined = front !== undefined ? front.data : legacy;
  if (data === undefined) return undefined;
  const source: image.ImageSource = image.createImageSource(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer);
  try {
    const info: image.ImageInfo = await source.getImageInfo();
    const w: number = info.size.width; const h: number = info.size.height;
    if (!Number.isInteger(w) || !Number.isInteger(h) || w <= 0 || h <= 0 || w > 16384 || h > 16384 ||
        w * h > 16777216 || info.isHdr || (front !== undefined && (front.width !== w || front.height !== h))) {
      throw new Error('Ogg 封面尺寸或格式不安全。');
    }
    const result: image.PixelMap = await source.createPixelMap();
    try {
      const decoded: image.ImageInfo = await result.getImageInfo();
      if (decoded.size.width !== w || decoded.size.height !== h || decoded.isHdr) throw new Error('Ogg 封面解码结果不一致。');
      return result;
    } catch (error) { try { await result.release(); } catch (_e) {} throw error as Error; }
  } finally { try { await source.release(); } catch (_e) {} }
}
function pair(value: string): number[] {
  if (value.length === 0) return [0, 0];
  const parts: string[] = value.split('/');
  if (parts.length > 2 || parts[0].length === 0 || (parts.length === 2 && parts[1].length === 0)) throw new Error('Ogg 数字字段不完整。');
  return [numberField(parts[0]), parts.length === 2 ? numberField(parts[1]) : 0];
}
export async function readOggMetadata(path: string): Promise<OggMetadata> {
  const source: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  try {
    const data: Parsed = await parse(source.fd);
    const tags: Comments = data.tags;
    let hasArtwork: boolean = false;
    for (let i: number = 0; i < tags.entries.length; i++) {
      if (tags.entries[i].key === 'METADATA_BLOCK_PICTURE' || tags.entries[i].key === 'COVERART') hasArtwork = true;
    }
    const trackValue: string = uniqueValue(tags, ['TRACKNUMBER','TRACKNUM']);
    const discValue: string = uniqueValue(tags, ['DISCNUMBER']);
    const track: number[] = pair(trackValue); const disc: number[] = pair(discValue);
    const trackTotal: string = uniqueValue(tags, ['TRACKTOTAL','TOTALTRACKS']);
    const discTotal: string = uniqueValue(tags, ['DISCTOTAL','TOTALDISCS']);
    if ((trackValue.indexOf('/') >= 0 && hasAny(tags, ['TRACKTOTAL','TOTALTRACKS'])) ||
        (discValue.indexOf('/') >= 0 && hasAny(tags, ['DISCTOTAL','TOTALDISCS']))) {
      throw new Error('Ogg 曲目或碟片总数存在多个来源。');
    }
    const date: string = uniqueValue(tags, ['DATE','YEAR']);
    if (date.length > 0 && !/^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$/.test(date)) throw new Error('Ogg 日期格式不支持。');
    const coverImage: image.PixelMap | undefined = await decodeArtwork(tags);
    try {
      return { codec: data.codec, hasArtwork, requiresSystemAudioValidation: true, title: uniqueValue(tags,['TITLE']), artist: uniqueValue(tags,['ARTIST']),
        album: uniqueValue(tags,['ALBUM']), genre: uniqueValue(tags,['GENRE']), comment: uniqueValue(tags,['COMMENT','DESCRIPTION']),
        lyrics: uniqueValue(tags,['LYRICS','UNSYNCEDLYRICS','SYNCEDLYRICS']), albumArtist: uniqueValue(tags,['ALBUMARTIST','ALBUM ARTIST']),
        composer: uniqueValue(tags,['COMPOSER']), grouping: uniqueValue(tags,['GROUPING']), isrc: uniqueValue(tags,['ISRC']),
        copyright: uniqueValue(tags,['COPYRIGHT']), year: date.length === 0 ? 0 : Number(date.substring(0,4)),
        track: track[0], trackTotal: trackTotal.length > 0 ? numberField(trackTotal) : track[1],
        disc: disc[0], discTotal: discTotal.length > 0 ? numberField(discTotal) : disc[1], bpm: numberField(uniqueValue(tags,['BPM'])),
        duration: 0, durationMs: 0, bitrate: 0, sampleRate: data.sampleRate, channels: data.channels, coverImage,
        fileType: data.codec === 'opus' ? 'audio/opus' : 'audio/ogg', fileSize: data.size, creationTime: 0, modifyTime: 0 };
    } catch (error) { if (coverImage !== undefined) { try { await coverImage.release(); } catch (_e) {} } throw error as Error; }
  } finally { try { fileIo.closeSync(source.fd); } catch (_error) {} }
}

async function validateDisplayableMetadata(path: string): Promise<void> {
  const metadata: OggMetadata = await readOggMetadata(path);
  if (metadata.coverImage !== undefined) {
    try { await metadata.coverImage.release(); } catch (_error) {}
  }
}

async function readPage(fd: number, offset: number, size: number): Promise<Uint8Array> {
  if (offset < 0 || size - offset < 27) throw new Error('Ogg 页面不完整。');
  const h: Uint8Array = await readAt(fd, offset, 27);
  const table: Uint8Array = await readAt(fd, offset + 27, h[26]);
  let length: number = 27 + table.length;
  for (let i: number = 0; i < table.length; i++) length += table[i];
  if (length > size - offset) throw new Error('Ogg 页面长度无效。');
  const page: Uint8Array = await readAt(fd, offset, length);
  if (crc(page) !== le(page, 22)) throw new Error('Ogg 页面 CRC 无效。');
  return page;
}
function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i: number = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
function sameAudioPage(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i: number = 0; i < a.length; i++) {
    // The sequence and page CRC necessarily change if header page count changes.
    if (i >= 18 && i < 26) continue;
    if (a[i] !== b[i]) return false;
  }
  return true;
}
/** Compare codec headers, requested comments and all audio pages after repagination. */
export async function verifyOggIntegrity(beforePath: string, afterPath: string, changes: AudioMetadataWriter): Promise<void> {
  const left: fileIo.File = await fileIo.open(beforePath, fileIo.OpenMode.READ_ONLY);
  let right: fileIo.File | undefined = undefined;
  try {
    right = await fileIo.open(afterPath, fileIo.OpenMode.READ_ONLY);
    await validateDisplayableMetadata(beforePath); await validateDisplayableMetadata(afterPath);
    const before: Parsed = await parse(left.fd); const after: Parsed = await parse(right.fd);
    if (before.codec !== after.codec || before.serial !== after.serial ||
        !sameBytes(replacement(before, changes), after.comment) || !sameBytes(before.setup, after.setup)) {
      throw new Error('Ogg 编码头、注释或 setup 数据改变。');
    }
    const firstA: Uint8Array = await readPage(left.fd, 0, before.size);
    const firstB: Uint8Array = await readPage(right.fd, 0, after.size);
    if (!sameBytes(firstA, firstB)) throw new Error('Ogg 识别头页面发生变化。');
    let a: number = before.audioOffset; let b: number = after.audioOffset;
    while (a < before.size && b < after.size) {
      const pageA: Uint8Array = await readPage(left.fd, a, before.size);
      const pageB: Uint8Array = await readPage(right.fd, b, after.size);
      if (!sameAudioPage(pageA, pageB)) throw new Error('Ogg 音频页内容、时间戳或布局发生变化。');
      a += pageA.length; b += pageB.length;
    }
    if (a !== before.size || b !== after.size || fileIo.statSync(left.fd).size !== before.size ||
        fileIo.statSync(right.fd).size !== after.size) throw new Error('Ogg 音频页数量或源文件发生变化。');
  } finally {
    try { fileIo.closeSync(left.fd); } catch (_error) {}
    if (right !== undefined) { try { fileIo.closeSync(right.fd); } catch (_error) {} }
  }
}
function privateRoot(root: string, source: string): string {
  const base: string = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  if (!base.startsWith('/') || !source.startsWith(base + '/') || base.indexOf('\\') >= 0 || source.indexOf('\\') >= 0 ||
      base.indexOf('\u0000') >= 0 || source.indexOf('\u0000') >= 0) throw new Error('仅支持应用私有目录内的 Ogg 工作副本。');
  const parts: string[] = source.split('/');
  for (let i: number = 1; i < parts.length; i++) if (parts[i] === '' || parts[i] === '.' || parts[i] === '..') throw new Error('Ogg 工作路径无效。');
  return base;
}

// The packet is represented by floor(length/255) laces of 255 followed by
// one terminal lace, including a zero terminal lace for an exact multiple.
async function writeHeaderPacket(fd: number, packet: Uint8Array, serial: number, sequence: number): Promise<number> {
  const full: number = Math.floor(packet.length / 255);
  const total: number = full + 1;
  let segment: number = 0; let dataOffset: number = 0;
  while (segment < total) {
    if (sequence >= MAX_PAGES) throw new Error('Ogg 页面数量超出安全上限。');
    const count: number = Math.min(255, total - segment);
    let body: number = 0;
    for (let i: number = 0; i < count; i++) body += segment + i < full ? 255 : packet.length % 255;
    const page: Uint8Array = new Uint8Array(27 + count + body);
    page.set([79,103,103,83], 0); page[4] = 0; page[5] = segment === 0 ? 0 : 1;
    const completes: boolean = segment + count === total;
    if (!completes) for (let i: number = 6; i < 14; i++) page[i] = 255;
    putLe(page, 14, serial); putLe(page, 18, sequence); page[26] = count;
    for (let i: number = 0; i < count; i++) page[27 + i] = segment + i < full ? 255 : packet.length % 255;
    page.set(packet.subarray(dataOffset, dataOffset + body), 27 + count);
    putLe(page, 22, crc(page)); await writeAll(fd, page);
    segment += count; dataOffset += body; sequence++;
  }
  if (dataOffset !== packet.length) throw new Error('Ogg 头包分页不完整。');
  return sequence;
}
/** Create a variable-length Ogg metadata copy in a new private directory. */
export async function writeOggMetadata(root: string, sourcePath: string, changes: AudioMetadataWriter): Promise<string> {
  const base: string = privateRoot(root, sourcePath);
  const input: fileIo.File = await fileIo.open(sourcePath, fileIo.OpenMode.READ_ONLY);
  let output: fileIo.File | undefined = undefined;
  let dir: string = ''; let target: string = ''; let complete: boolean = false;
  try {
    const data: Parsed = await parse(input.fd);
    await validateDisplayableMetadata(sourcePath);
    const changed: Uint8Array = replacement(data, changes);
    dir = fileIo.mkdtempSync(base + '/lyricflow_ogg_repage_XXXXXX');
    target = dir + (/\.opus$/i.test(sourcePath) ? '/edited.opus' : '/edited.ogg');
    output = await fileIo.open(target, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    const first: Uint8Array = await readPage(input.fd, 0, data.size);
    if (first.length !== data.firstPageLength) throw new Error('Ogg 识别页面发生变化。');
    await writeAll(output.fd, first);
    let sequence: number = await writeHeaderPacket(output.fd, changed, data.serial, 1);
    if (data.codec === 'vorbis') sequence = await writeHeaderPacket(output.fd, data.setup, data.serial, sequence);
    let offset: number = data.audioOffset;
    while (offset < data.size) {
      if (sequence >= MAX_PAGES) throw new Error('Ogg 页面数量超出安全上限。');
      const page: Uint8Array = await readPage(input.fd, offset, data.size);
      if (le(page, 14) !== data.serial) throw new Error('Ogg 音频序列发生变化。');
      putLe(page, 18, sequence); putLe(page, 22, crc(page)); await writeAll(output.fd, page);
      offset += page.length; sequence++;
    }
    if (offset !== data.size || fileIo.statSync(input.fd).size !== data.size) throw new Error('Ogg 源文件在复制期间发生变化。');
    fileIo.fsyncSync(output.fd); fileIo.closeSync(output.fd); output = undefined;
    await verifyOggIntegrity(sourcePath, target, changes);
    complete = true; return target;
  } finally {
    if (output !== undefined) { try { fileIo.closeSync(output.fd); } catch (_error) {} }
    try { fileIo.closeSync(input.fd); } catch (_error) {}
    if (!complete && target.length > 0) { try { fileIo.unlinkSync(target); } catch (_error) {} }
    if (!complete && dir.length > 0) { try { fileIo.rmdirSync(dir); } catch (_error) {} }
  }
}
