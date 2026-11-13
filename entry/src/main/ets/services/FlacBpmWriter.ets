import { fileIo } from '@kit.CoreFileKit';

// The current TagLib bridge reads FLAC BPM but ignores BPM updates. This
// narrowly scoped repair edits only BPM in the Vorbis comment block of an
// app-owned staging file. All other blocks, comments and audio bytes are
// copied unchanged. Ambiguous or excessively large metadata is rejected.
const LIMIT: number = 16 * 1024 * 1024;
const CHUNK: number = 256 * 1024;

async function readExactly(fd: number, position: number, length: number): Promise<Uint8Array> {
  const result: Uint8Array = new Uint8Array(length);
  let done: number = 0;
  while (done < length) {
    if (fileIo.lseek(fd, position + done, fileIo.WhenceType.SEEK_SET) !== position + done) {
      throw new Error('FLAC 工作副本无法可靠定位。');
    }
    const buffer: ArrayBuffer = new ArrayBuffer(length - done);
    const count: number = await fileIo.read(fd, buffer, { length: length - done });
    if (count <= 0 || count > length - done) throw new Error('读取 FLAC 元数据失败。');
    result.set(new Uint8Array(buffer, 0, count), done);
    done += count;
  }
  return result;
}

async function writeAll(fd: number, data: Uint8Array): Promise<void> {
  let done: number = 0;
  while (done < data.length) {
    const bytes: ArrayBuffer = data.buffer.slice(data.byteOffset + done, data.byteOffset + data.length) as ArrayBuffer;
    const count: number = await fileIo.write(fd, bytes, { length: bytes.byteLength });
    if (count <= 0 || count > data.length - done) throw new Error('写入 FLAC 工作副本失败。');
    done += count;
  }
}

function uint32le(data: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 4 > data.length) throw new Error('FLAC 注释长度无效。');
  return (data[offset] + data[offset + 1] * 256 + data[offset + 2] * 65536 + data[offset + 3] * 16777216);
}

function bytes32le(value: number): Uint8Array {
  return new Uint8Array([value & 255, Math.floor(value / 256) & 255,
    Math.floor(value / 65536) & 255, Math.floor(value / 16777216) & 255]);
}

function isBpmComment(value: Uint8Array): boolean {
  return value.length >= 4 && (value[0] | 32) === 98 && (value[1] | 32) === 112 &&
    (value[2] | 32) === 109 && value[3] === 61;
}

function withBpm(data: Uint8Array, bpm: number): Uint8Array {
  const vendorLength: number = uint32le(data, 0);
  const countOffset: number = 4 + vendorLength;
  const count: number = uint32le(data, countOffset);
  let offset: number = countOffset + 4;
  if (count > 65536 || count > Math.floor((data.length - offset) / 4)) {
    throw new Error('FLAC 注释数量无效或超限。');
  }
  const entries: Uint8Array[] = [];
  let bpmEntries: number = 0;
  for (let i: number = 0; i < count; i++) {
    const length: number = uint32le(data, offset);
    offset += 4;
    if (length > data.length - offset) throw new Error('FLAC 注释长度超出数据范围。');
    const entry: Uint8Array = data.slice(offset, offset + length);
    offset += length;
    if (isBpmComment(entry)) bpmEntries++;
    else entries.push(entry);
  }
  if (bpmEntries > 1) throw new Error('FLAC 包含多个 BPM 注释，无法安全确定要修改的值。');
  if (offset !== data.length) throw new Error('FLAC 注释包含无法识别的尾部数据。');
  if (bpm > 0) {
    const text: string = 'BPM=' + bpm.toString();
    const entry: Uint8Array = new Uint8Array(text.length);
    for (let i: number = 0; i < text.length; i++) entry[i] = text.charCodeAt(i);
    entries.push(entry);
  }
  let total: number = countOffset + 4;
  for (let i: number = 0; i < entries.length; i++) total += 4 + entries[i].length;
  if (total > 0xffffff || total > LIMIT) throw new Error('FLAC 注释过大，无法安全写入 BPM。');
  const out: Uint8Array = new Uint8Array(total);
  out.set(data.slice(0, countOffset), 0);
  out.set(bytes32le(entries.length), countOffset);
  let cursor: number = countOffset + 4;
  for (let i: number = 0; i < entries.length; i++) {
    out.set(bytes32le(entries[i].length), cursor);
    cursor += 4;
    out.set(entries[i], cursor);
    cursor += entries[i].length;
  }
  return out;
}

export async function repairFlacBpm(workingPath: string, bpm: number): Promise<void> {
  if (!Number.isInteger(bpm) || bpm < 0 || bpm > 99999) throw new Error('BPM 数值无效。');
  const source: fileIo.File = fileIo.openSync(workingPath, fileIo.OpenMode.READ_ONLY);
  let sourceOpen: boolean = true;
  let temporary: fileIo.File | undefined = undefined;
  let directory: string = '';
  let temporaryPath: string = '';
  try {
    const size: number = fileIo.statSync(source.fd).size;
    if (!Number.isSafeInteger(size) || size < 4) throw new Error('音频工作副本无效。');
    const magic: Uint8Array = await readExactly(source.fd, 0, 4);
    if (magic[0] !== 0x66 || magic[1] !== 0x4c || magic[2] !== 0x61 || magic[3] !== 0x43) return;
    const blocks: Uint8Array[] = [];
    let cursor: number = 4;
    let commentCount: number = 0;
    let done: boolean = false;
    while (!done) {
      if (blocks.length >= 1024) throw new Error('FLAC 元数据块数量超限。');
      if (cursor + 4 > size || cursor > LIMIT) throw new Error('FLAC 元数据超限或不完整。');
      const header: Uint8Array = await readExactly(source.fd, cursor, 4);
      const length: number = header[1] * 65536 + header[2] * 256 + header[3];
      if (cursor + 4 + length > size || cursor + 4 + length > LIMIT) throw new Error('FLAC 元数据长度无效或超限。');
      let body: Uint8Array = await readExactly(source.fd, cursor + 4, length);
      if ((header[0] & 0x7f) === 4) {
        commentCount++;
        body = withBpm(body, bpm);
        header[1] = (body.length >> 16) & 255;
        header[2] = (body.length >> 8) & 255;
        header[3] = body.length & 255;
      }
      const block: Uint8Array = new Uint8Array(4 + body.length);
      block.set(header, 0);
      block.set(body, 4);
      blocks.push(block);
      cursor += 4 + length;
      done = (header[0] & 0x80) !== 0;
    }
    if (commentCount !== 1) throw new Error('FLAC 注释块缺失或重复，无法安全写入 BPM。');
    const slash: number = workingPath.lastIndexOf('/');
    if (slash < 1) throw new Error('FLAC 工作副本路径无效。');
    directory = fileIo.mkdtempSync(workingPath.substring(0, slash) + '/lyricflow_bpm_XXXXXX');
    temporaryPath = directory + '/edited.flac';
    temporary = fileIo.openSync(temporaryPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    await writeAll(temporary.fd, magic);
    for (let i: number = 0; i < blocks.length; i++) await writeAll(temporary.fd, blocks[i]);
    while (cursor < size) {
      const n: number = Math.min(CHUNK, size - cursor);
      await writeAll(temporary.fd, await readExactly(source.fd, cursor, n));
      cursor += n;
    }
    if (fileIo.statSync(source.fd).size !== size) throw new Error('FLAC 工作副本在处理期间发生变化。');
    fileIo.fsyncSync(temporary.fd);
    fileIo.closeSync(temporary.fd);
    temporary = undefined;
    fileIo.closeSync(source.fd);
    sourceOpen = false;
    // The target belongs to the app's private staging area, not the user URI.
    fileIo.renameSync(temporaryPath, workingPath);
    temporaryPath = '';
  } finally {
    if (temporary !== undefined) { try { fileIo.closeSync(temporary.fd); } catch (_error) {} }
    if (sourceOpen) { try { fileIo.closeSync(source.fd); } catch (_error) {} }
    if (temporaryPath.length > 0) { try { fileIo.unlinkSync(temporaryPath); } catch (_error) {} }
    if (directory.length > 0) { try { fileIo.rmdirSync(directory); } catch (_error) {} }
  }
}
