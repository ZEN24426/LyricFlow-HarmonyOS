import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { AudioMetadata } from './AudioMetadataTypes';

// The system extractor supplies duration (milliseconds), sample rate (Hz),
// and track descriptions. It does not supply the app's full tag contract.
// Required duration, sample rate and channels must be present for integrity
// checks. Optional bitrate may be unknown and is never used as proof.
function positiveInteger(value: Object | undefined, name: string, max: number): number {
  let parsed: number = NaN;
  if (typeof value === 'number') parsed = value;
  else if (typeof value === 'string' && /^\d+$/.test(value)) parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > max) {
    throw new Error('系统未提供可验证的音频' + name + '，已取消操作。');
  }
  return parsed;
}

/** Read technical properties from a dedicated, read-only file descriptor. */
export async function fillAudioProperties(path: string, metadata: AudioMetadata, requireMp3Codec: boolean = false): Promise<void> {
  const source: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  let extractor: media.AVMetadataExtractor | undefined = undefined;
  try {
    const before: fileIo.Stat = fileIo.statSync(source.fd);
    if (!before.isFile() || !Number.isSafeInteger(before.size) || before.size <= 0) {
      throw new Error('无法确认音频文件大小，已取消操作。');
    }
    extractor = await media.createAVMetadataExtractor();
    // This fd belongs exclusively to the extractor until release completes.
    extractor.fdSrc = { fd: source.fd, offset: 0, length: before.size };
    const raw: media.AVMetadata | undefined = await extractor.fetchMetadataWithTimeout(10000);
    if (raw === undefined) throw new Error('系统没有返回音频属性，已取消操作。');
    const durationMs: number = positiveInteger(raw.duration, '时长', Number.MAX_SAFE_INTEGER);
    const rate: number = positiveInteger(raw.sampleRate, '采样率', 1536000);
    const tracks: media.MediaDescription[] | undefined = raw.tracks;
    if (tracks === undefined) throw new Error('系统没有返回音频轨道信息，已取消操作。');
    let audioTrack: media.MediaDescription | undefined = undefined;
    for (let i: number = 0; i < tracks.length; i++) {
      const track: media.MediaDescription = tracks[i];
      if (track[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] === media.MediaType.MEDIA_TYPE_AUD) {
        if (audioTrack !== undefined) throw new Error('存在多个音频轨道，无法可靠验证。');
        audioTrack = track;
      }
    }
    if (audioTrack === undefined) throw new Error('系统没有识别到音频轨道，已取消操作。');
    if (requireMp3Codec && audioTrack[media.MediaDescriptionKey.MD_KEY_CODEC_MIME] !== media.CodecMimeType.AUDIO_MP3) {
      throw new Error('系统未确认 MPEG Layer III 音轨，已取消操作。');
    }
    const channels: number = positiveInteger(
      audioTrack[media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT], '声道数', 64
    );
    // Bitrate is optional on some codecs (notably Opus) and is never used as
    // integrity evidence. Zero means unavailable and must be shown as unknown.
    let bitrateBits: number = 0;
    const bitrateValue: Object | undefined = audioTrack[media.MediaDescriptionKey.MD_KEY_BITRATE];
    if (bitrateValue !== undefined) {
      try { bitrateBits = positiveInteger(bitrateValue, '码率', 1000000000); } catch (_error) {}
    }
    // Release before inspecting or closing its dedicated fd.
    await extractor.release();
    extractor = undefined;
    const after: fileIo.Stat = fileIo.statSync(source.fd);
    if (!after.isFile() || after.size !== before.size || after.ino !== before.ino) {
      throw new Error('读取期间音频文件发生变化，已取消操作。');
    }
    metadata.durationMs = durationMs;
    metadata.duration = Math.floor(durationMs / 1000);
    metadata.sampleRate = rate;
    metadata.channels = channels;
    metadata.bitrate = Math.round(bitrateBits / 1000);
  } finally {
    if (extractor !== undefined) {
      try { await extractor.release(); } catch (_error) {}
    }
    try { fileIo.closeSync(source.fd); } catch (_error) {}
  }
}
