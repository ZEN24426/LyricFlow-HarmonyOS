import { fileIo } from '@kit.CoreFileKit';

// Strict read-only structural validation for a bare MPEG Layer III stream.
// Walk every frame through EOF so arbitrary trailing tags, junk and partial
// frames are not silently reclassified as audio. Free-format streams and
// streams changing MPEG version/sample rate are deliberately not supported.
const WINDOW: number = 256 * 1024;

async function readWindow(fd: number, offset: number, length: number): Promise<Uint8Array> {
  const data: Uint8Array = new Uint8Array(length);
  let done: number = 0;
  while (done < length) {
    if (fileIo.lseek(fd, offset + done, fileIo.WhenceType.SEEK_SET) !== offset + done) {
      throw new Error('MP3 帧无法定位。');
    }
    const chunk: ArrayBuffer = new ArrayBuffer(length - done);
    const count: number = await fileIo.read(fd, chunk, { length: length - done });
    if (count <= 0 || count > length - done) throw new Error('MP3 帧读取不完整。');
    data.set(new Uint8Array(chunk, 0, count), done);
    done += count;
  }
  return data;
}

/** Must also be followed by the platform's read-only audio verification. */
export async function assertBareMp3Frames(fd: number, size: number): Promise<void> {
  if (!Number.isSafeInteger(size) || size < 8) throw new Error('裸 MP3 长度无效。');
  let data: Uint8Array = new Uint8Array(0);
  let base: number = 0;
  let offset: number = 0;
  let frameCount: number = 0;
  let firstVersion: number = -1;
  let firstRate: number = -1;
  const version1Bitrates: number[] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
  const version2Bitrates: number[] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
  const rates: number[] = [44100, 48000, 32000];
  while (offset < size) {
    if (size - offset < 4) throw new Error('MP3 存在不完整的音频帧或尾部数据。');
    if (offset < base || offset + 4 > base + data.length) {
      base = offset;
      data = await readWindow(fd, base, Math.min(WINDOW, size - base));
    }
    const index: number = offset - base;
    const b0: number = data[index];
    const b1: number = data[index + 1];
    const b2: number = data[index + 2];
    const b3: number = data[index + 3];
    const version: number = (b1 >> 3) & 3;
    const layer: number = (b1 >> 1) & 3;
    const bitrateIndex: number = b2 >> 4;
    const rateIndex: number = (b2 >> 2) & 3;
    if (b0 !== 0xff || (b1 & 0xe0) !== 0xe0 || version === 1 || layer !== 1 ||
        bitrateIndex === 0 || bitrateIndex === 15 || rateIndex === 3 || (b3 & 3) === 2) {
      throw new Error('文件不是完整的裸 MPEG Layer III，或包含不支持的尾部数据。');
    }
    const rate: number = rates[rateIndex] / (version === 3 ? 1 : (version === 2 ? 2 : 4));
    const bitrate: number = version === 3 ? version1Bitrates[bitrateIndex] : version2Bitrates[bitrateIndex];
    const frameLength: number = Math.floor((version === 3 ? 144000 : 72000) * bitrate / rate) + ((b2 >> 1) & 1);
    if (frameLength < 24 || frameLength > size - offset) throw new Error('MP3 音频帧不完整。');
    if (frameCount === 0) { firstVersion = version; firstRate = rate; }
    else if (version !== firstVersion || rate !== firstRate) {
      throw new Error('MP3 音频参数在文件内发生变化，无法安全处理。');
    }
    offset += frameLength;
    frameCount++;
  }
  if (frameCount < 2 || fileIo.statSync(fd).size !== size) throw new Error('无法确认裸 MP3 音频完整。');
}
