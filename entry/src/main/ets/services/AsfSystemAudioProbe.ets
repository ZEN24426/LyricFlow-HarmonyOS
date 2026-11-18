// SPDX-License-Identifier: GPL-3.0-only
/* Experimental MediaKit source probe, isolated; GPL-3.0-only. */
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { AsfAudioInfo, AsfAudioProbe, AsfReadStream } from './AsfStreamingExport';

export interface AsfPathReadStream extends AsfReadStream { path(): string; }

export class AsfSystemAudioProbe implements AsfAudioProbe {
  static readonly CHUNK: number = 64 * 1024;
  static readonly MAX_PARTIAL_IO: number = 128;
  private static ok(x: boolean, s: string): void { if (!x) { throw new Error(s); } }
  /** NOFOLLOW covers the final component; ancestor checks do not defeat malicious rename races. */
  private static checkPath(path: string): void {
    AsfSystemAudioProbe.ok(path.startsWith('/') && !path.endsWith('/') && path.indexOf('//') < 0 &&
      path.indexOf(String.fromCharCode(0)) < 0 && path.indexOf('://') < 0, 'unsupported path');
    const parts: string[] = path.split('/'); let current: string = '';
    for (let i: number = 1; i < parts.length; i++) {
      AsfSystemAudioProbe.ok(parts[i].length > 0 && parts[i] !== '.' && parts[i] !== '..', 'unsafe path');
      current += '/' + parts[i];
      const item: fileIo.Stat = fileIo.lstatSync(current);
      AsfSystemAudioProbe.ok(!item.isSymbolicLink(), 'symlink unsupported');
      if (i < parts.length - 1) { AsfSystemAudioProbe.ok(item.isDirectory(), 'invalid ancestor'); }
      else { AsfSystemAudioProbe.ok(item.isFile(), 'not a regular file'); }
    }
  }
  private static same(a: fileIo.Stat, b: fileIo.Stat): boolean {
    return a.isFile() && b.isFile() && a.ino === b.ino && a.size === b.size &&
      a.mtimeNs !== undefined && a.ctimeNs !== undefined && b.mtimeNs !== undefined && b.ctimeNs !== undefined &&
      a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs;
  }
  private static openChecked(path: string, original: fileIo.Stat): fileIo.File {
    AsfSystemAudioProbe.checkPath(path); const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    try {
      const fdStat: fileIo.Stat = fileIo.statSync(file.fd); const pathStat: fileIo.Stat = fileIo.lstatSync(path);
      AsfSystemAudioProbe.ok(AsfSystemAudioProbe.same(original, fdStat) && AsfSystemAudioProbe.same(original, pathStat), 'file identity changed');
      return file;
    } catch (e) { fileIo.closeSync(file.fd); throw new Error('probe open failed: ' + String(e)); }
  }
  /** Bytewise comparison uses a separate fresh FD; never share it with the extractor. */
  private static compare(stream: AsfReadStream, path: string, original: fileIo.Stat, size: number, token: string): void {
    const f: fileIo.File = AsfSystemAudioProbe.openChecked(path, original);
    try {
      for (let pos: number = 0; pos < size;) {
        const n: number = Math.min(AsfSystemAudioProbe.CHUNK, size - pos); const buf: ArrayBuffer = new ArrayBuffer(n);
        let diskDone: number = 0; let diskAttempts: number = 0;
        while (diskDone < n) {
          AsfSystemAudioProbe.ok(++diskAttempts <= AsfSystemAudioProbe.MAX_PARTIAL_IO, 'probe read retry budget exceeded');
          const part: ArrayBuffer = new ArrayBuffer(n - diskDone);
          const count: number = fileIo.readSync(f.fd, part, { length: n - diskDone });
          AsfSystemAudioProbe.ok(Number.isInteger(count) && count > 0 && count <= n - diskDone, 'invalid probe short read');
          new Uint8Array(buf).set(new Uint8Array(part, 0, count), diskDone); diskDone += count;
        }
        let streamDone: number = 0; let streamAttempts: number = 0;
        while (streamDone < n) {
          AsfSystemAudioProbe.ok(++streamAttempts <= AsfSystemAudioProbe.MAX_PARTIAL_IO, 'stream read retry budget exceeded');
          const part: Uint8Array = stream.readAt(pos + streamDone, n - streamDone);
          AsfSystemAudioProbe.ok(part.length > 0 && part.length <= n - streamDone, 'invalid stream short read');
          const disk: Uint8Array = new Uint8Array(buf);
          for (let i: number = 0; i < part.length; i++) { AsfSystemAudioProbe.ok(part[i] === disk[streamDone + i], 'probe and stream differ'); }
          streamDone += part.length;
        }
        pos += n;
      }
      AsfSystemAudioProbe.ok(stream.size() === size && stream.snapshotToken() === token &&
        AsfSystemAudioProbe.same(original, fileIo.statSync(f.fd)) &&
        AsfSystemAudioProbe.same(original, fileIo.lstatSync(path)), 'file changed during probe compare');
    } finally { fileIo.closeSync(f.fd); }
  }
  private static positive(value: Object | undefined, field: string, max: number): number {
    let result: number = NaN;
    if (typeof value === 'number') { result = value; }
    else if (typeof value === 'string' && value.length > 0 && value.length <= 16 && /^[0-9]+$/.test(value)) { result = Number(value); }
    AsfSystemAudioProbe.ok(Number.isSafeInteger(result) && result > 0 && result <= max, 'media field unavailable or invalid: ' + field);
    return result;
  }
  private static extract(metadata: media.AVMetadata): AsfAudioInfo {
    const tracks: media.MediaDescription[] | undefined = metadata.tracks;
    AsfSystemAudioProbe.ok(tracks !== undefined && tracks.length > 0 && tracks.length <= 128, 'media tracks unavailable');
    if (tracks === undefined) { throw new Error('media tracks unavailable'); }
    let found: AsfAudioInfo | null = null;
    for (const track of tracks) {
      const type: Object = track[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE];
      AsfSystemAudioProbe.ok(typeof type === 'number' && Number.isSafeInteger(type as number) &&
        (type as number) >= 0 && (type as number) <= 6, 'track type unavailable or unsupported');
      if (type === media.MediaType.MEDIA_TYPE_AUD) {
        AsfSystemAudioProbe.ok(found === null, 'multiple audio tracks unsupported');
        // AVMetadata.tracks does not promise a duration key; use container-level duration in milliseconds.
        const duration: number = AsfSystemAudioProbe.positive(metadata.duration, 'duration', Number.MAX_SAFE_INTEGER);
        const channels: number = AsfSystemAudioProbe.positive(track[media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT], 'channel_count', 8);
        const trackRate: Object | undefined = track[media.MediaDescriptionKey.MD_KEY_AUD_SAMPLE_RATE];
        const topRate: Object | undefined = metadata.sampleRate;
        AsfSystemAudioProbe.ok(topRate !== undefined || trackRate !== undefined, 'media field unavailable or invalid: sample_rate');
        let rate: number = 0;
        if (topRate !== undefined) { rate = AsfSystemAudioProbe.positive(topRate, 'sampleRate', 384000); }
        if (trackRate !== undefined) {
          const trackValue: number = AsfSystemAudioProbe.positive(trackRate, 'track sample_rate', 384000);
          if (topRate !== undefined) { AsfSystemAudioProbe.ok(rate === trackValue, 'media sample rates disagree'); }
          else { rate = trackValue; }
        }
        found = new AsfAudioInfo(duration, channels, rate);
      }
    }
    AsfSystemAudioProbe.ok(found !== null, 'audio track unavailable');
    if (found === null) { throw new Error('audio track unavailable'); }
    return found;
  }
  async inspect(stream: AsfReadStream): Promise<AsfAudioInfo> {
    const size: number = stream.size(); const token: string = stream.snapshotToken();
    AsfSystemAudioProbe.ok(Number.isSafeInteger(size) && size >= 80 && size <= 8 * 1024 * 1024 * 1024 && token.length > 0, 'stream size or identity');
    const path: string = (stream as AsfPathReadStream).path();
    AsfSystemAudioProbe.checkPath(path); const initial: fileIo.Stat = fileIo.lstatSync(path);
    AsfSystemAudioProbe.ok(initial.isFile() && initial.size === size && initial.mtimeNs !== undefined && initial.ctimeNs !== undefined, 'stream stat unavailable');
    AsfSystemAudioProbe.compare(stream, path, initial, size, token);
    const f: fileIo.File = AsfSystemAudioProbe.openChecked(path, initial);
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    let result: AsfAudioInfo | null = null;
    try {
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: f.fd, offset: 0, length: size };
      result = AsfSystemAudioProbe.extract(await extractor.fetchMetadata());
    } finally {
      try { if (extractor !== undefined) { await extractor.release(); } }
      finally { fileIo.closeSync(f.fd); }
    }
    AsfSystemAudioProbe.compare(stream, path, initial, size, token);
    AsfSystemAudioProbe.ok(result !== null, 'media probe failed');
    if (result === null) { throw new Error('media probe failed'); }
    return result;
  }
}




