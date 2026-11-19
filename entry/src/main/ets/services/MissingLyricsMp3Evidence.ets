import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { assertBareMp3Frames } from './BareMp3';

/** Short-lived identity evidence, valid only across the immediately following read. */
export interface Mp3SourceIdentity {
  ino: string;
  size: number;
  mtime: string;
  ctime: string;
}

export interface Mp3SourceObservation {
  uri: string;
  file: fileIo.File;
  identity: Mp3SourceIdentity;
}

/** Keep uncertain resources alive and prevent unbounded extractor/fd accumulation. */
export class MetadataExtractorCleanupError extends Error {
  constructor() { super('音频检查资源未能安全释放；请重启应用后再检查。'); }
}
interface RetainedProofResources {
  file: fileIo.File;
  extractor: media.AVMetadataExtractor | undefined;
}
let activeProof: boolean = false;
let activeObservation: boolean = false;
let currentObservation: Mp3SourceObservation | undefined = undefined;
let retainedProof: RetainedProofResources[] = [];
const RELEASE_TIMEOUT_MS: number = 10000;

function retainProof(file: fileIo.File, extractor: media.AVMetadataExtractor | undefined): void {
  retainedProof.push({ file, extractor });
}

function closeChecked(file: fileIo.File): void {
  try { fileIo.closeSync(file.fd); }
  catch (_error) {
    // This numeric descriptor may already have been closed and reused.
    retainProof(file, undefined);
    throw new MetadataExtractorCleanupError();
  }
}

function requireAvailable(): void {
  if (retainedProof.length > 0) throw new MetadataExtractorCleanupError();
  if (activeProof || activeObservation) throw new Error('上一次音频检查仍在进行，请稍后重试。');
}

async function releaseExtractor(extractor: media.AVMetadataExtractor): Promise<void> {
  let timer: number = -1;
  try {
    await Promise.race<void>([extractor.release(), new Promise<void>((_resolve: () => void, reject: (error: Error) => void): void => {
      timer = setTimeout((): void => reject(new Error('提取器释放超时。')), RELEASE_TIMEOUT_MS);
    })]);
  } finally { if (timer >= 0) clearTimeout(timer); }
}

function identity(stat: fileIo.Stat): Mp3SourceIdentity {
  const ino: string = stat.ino.toString();
  if (!stat.isFile() || ino === '0' || !Number.isSafeInteger(stat.size) || stat.size <= 0 ||
      stat.mtimeNs === undefined || stat.ctimeNs === undefined) throw new Error('无法确认源文件身份。');
  return { ino, size: stat.size, mtime: stat.mtimeNs.toString(), ctime: stat.ctimeNs.toString() };
}

function same(a: Mp3SourceIdentity, b: Mp3SourceIdentity): boolean {
  return a.ino === b.ino && a.size === b.size && a.mtime === b.mtime && a.ctime === b.ctime;
}

/** Keep the original descriptor open across the metadata read or private copy. */
export async function beginMp3SourceObservation(uri: string): Promise<Mp3SourceObservation> {
  requireAvailable();
  activeObservation = true;
  let file: fileIo.File | undefined = undefined;
  try {
    file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    const observation: Mp3SourceObservation = { uri, file, identity: identity(fileIo.statSync(file.fd)) };
    currentObservation = observation;
    return observation;
  } catch (error) {
    if (file !== undefined) closeChecked(file);
    throw error as Error;
  } finally {
    if (currentObservation === undefined) activeObservation = false;
  }
}

async function selectedStillSame(uri: string, expected: Mp3SourceIdentity): Promise<boolean> {
  const check: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try { return same(expected, identity(fileIo.statSync(check.fd))); }
  finally { closeChecked(check); }
}

/** Source and selected URI must still refer to the same unchanged file. */
export async function endMp3SourceObservation(observation: Mp3SourceObservation): Promise<Mp3SourceIdentity> {
  if (!activeObservation || currentObservation !== observation) throw new Error('音频观察已结束或无效。');
  try {
    const expected: Mp3SourceIdentity = observation.identity;
    if (!same(expected, identity(fileIo.statSync(observation.file.fd))) ||
        !await selectedStillSame(observation.uri, expected) ||
        !same(expected, identity(fileIo.statSync(observation.file.fd)))) {
      throw new Error('读取期间源文件发生变化。');
    }
    return expected;
  } finally {
    currentObservation = undefined;
    try { closeChecked(observation.file); } finally { activeObservation = false; }
  }
}

function positive(value: Object | undefined): boolean {
  const n: number = typeof value === 'number' ? value :
    (typeof value === 'string' && /^\d+$/.test(value) ? Number(value) : NaN);
  return Number.isSafeInteger(n) && n > 0;
}

/**
 * Proof is restricted to an unchanged, strictly bare MPEG Layer III stream.
 * No assumption is made about ID3, trailing tags, sidecars, or unsupported files.
 */
export async function proveBareMp3HasNoTags(uri: string, expected: Mp3SourceIdentity): Promise<boolean> {
  requireAvailable();
  activeProof = true;
  let source: fileIo.File | undefined = undefined;
  let extractor: media.AVMetadataExtractor | undefined = undefined;
  let releaseAttempted: boolean = false;
  try {
    source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    if (!same(expected, identity(fileIo.statSync(source.fd)))) return false;
    await assertBareMp3Frames(source.fd, expected.size);
    if (!same(expected, identity(fileIo.statSync(source.fd)))) return false;
    extractor = await media.createAVMetadataExtractor();
    extractor.fdSrc = { fd: source.fd, offset: 0, length: expected.size };
    const raw: media.AVMetadata | undefined = await extractor.fetchMetadataWithTimeout(10000);
    if (raw === undefined || !positive(raw.duration) || !positive(raw.sampleRate) || raw.tracks === undefined) return false;
    let audioCount: number = 0;
    for (const track of raw.tracks) {
      if (track[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] === media.MediaType.MEDIA_TYPE_AUD) {
        audioCount++;
        if (track[media.MediaDescriptionKey.MD_KEY_CODEC_MIME] !== media.CodecMimeType.AUDIO_MP3 ||
            !positive(track[media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT])) return false;
      }
    }
    if (audioCount !== 1) return false;
    releaseAttempted = true;
    try { await releaseExtractor(extractor); }
    catch (_error) {
      retainProof(source, extractor);
      throw new MetadataExtractorCleanupError();
    }
    extractor = undefined;
    if (!same(expected, identity(fileIo.statSync(source.fd))) || !await selectedStillSame(uri, expected)) return false;
    return same(expected, identity(fileIo.statSync(source.fd)));
  } finally {
    try {
      if (source !== undefined && extractor !== undefined && !releaseAttempted) {
        try { await releaseExtractor(extractor); extractor = undefined; }
        catch (_error) {
          retainProof(source, extractor);
          throw new MetadataExtractorCleanupError();
        }
      }
      if (source !== undefined && !retainedProof.some((item: RetainedProofResources): boolean => item.file === source)) {
        closeChecked(source);
      }
    } finally { activeProof = false; }
  }
}
