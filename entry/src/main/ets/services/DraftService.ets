import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AudioMetadataService, WorkingAudio } from './AudioMetadataService';
import { FileSelectionService, SelectedDocument } from './FileSelectionService';

/** Only edit text and a reminder are persisted. No cover, URI, grant or original audio is stored. */
export interface DraftContent {
  title: string;
  artist: string;
  album: string;
  composer: string;
  genre: string;
  year: string;
  albumArtist: string;
  track: string;
  disc: string;
  discTotal: string;
  trackTotal: string;
  bpm: string;
  grouping: string;
  isrc: string;
  copyright: string;
  comment: string;
  lyricText: string;
  lyricSourceName: string;
  lyricSummary: string;
  coverNeedsReselection: boolean;
}

export interface DraftSession { token: string; }
export interface DraftSummary { revision: string; sourceName: string; savedAt: number; coverNeedsReselection: boolean; }
export interface CorruptDraftSummary { token: string; size: number; }
export interface DraftRestore { session: DraftSession; audio: WorkingAudio; content: DraftContent; revision: string; }
export interface DraftCommitResult { state: 'committed' | 'rejected' | 'uncertain'; editorAccepted: boolean; warning: string; }

interface AudioIdentity { size: number; sha256: string; }
interface DraftPayload {
  version: number;
  revision: string;
  sourceName: string;
  savedAt: number;
  audio: AudioIdentity;
  content: DraftContent;
}
interface DraftRecord extends DraftPayload {
  checksum: string;
}
interface ActiveSession {
  token: string; root: string; sourceName: string; audio: AudioIdentity; revision: string; generation: number;
  writable: boolean;
  uncertainRevision?: string;
  uncertainChecksum?: string;
}
interface PendingRestore {
  token: string; root: string; generation: number; revision: string; sourceName: string; audio: AudioIdentity;
}
interface CheckedRestore { token: string; record: DraftRecord; }

class DraftCorruptError extends Error {}

const DRAFT_FILE: string = 'lyricflow_edit_draft.json';
const LOCK_FILE: string = 'lyricflow_edit_draft.lock';
const MAX_RECORD_BYTES: number = 4 * 1024 * 1024;
const MAX_LYRIC_CHARS: number = 1024 * 1024;
const MAX_FIELD_CHARS: number = 8192;
const MAX_AUDIO_BYTES: number = 16 * 1024 * 1024 * 1024;
const CHUNK: number = 64 * 1024;
const UUID: RegExp = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CONTENT_KEYS: string[] = ['title', 'artist', 'album', 'composer', 'genre', 'year', 'albumArtist', 'track',
  'disc', 'discTotal', 'trackTotal', 'bpm', 'grouping', 'isrc', 'copyright', 'comment', 'lyricText',
  'lyricSourceName', 'lyricSummary', 'coverNeedsReselection'];
let queue: Promise<void> = Promise.resolve();
let generation: number = 0;
let beginAttempt: number = 0;
let active: ActiveSession | undefined = undefined;
let pendingSaves: number = 0;
let stagedRestore: PendingRestore | undefined = undefined;

function rootOf(context: common.UIAbilityContext): string {
  const root: string = context.filesDir.endsWith('/') ? context.filesDir.slice(0, -1) : context.filesDir;
  if (!root.startsWith('/') || root.length < 2 || root.indexOf('://') >= 0 || root.indexOf('\0') >= 0 ||
      root.split('/').indexOf('..') >= 0) throw new Error('应用私有目录无效，无法处理草稿。');
  return root;
}

function namesMatch(value: Object, allowed: string[]): boolean {
  const keys: string[] = Object.keys(value);
  if (keys.length !== allowed.length) return false;
  for (let i: number = 0; i < keys.length; i++) if (allowed.indexOf(keys[i]) < 0) return false;
  return true;
}

function safeUnicode(value: string): boolean {
  for (let i: number = 0; i < value.length; i++) {
    const c: number = value.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      if (++i >= value.length) return false;
      const low: number = value.charCodeAt(i);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (c >= 0xdc00 && c <= 0xdfff) return false;
  }
  return true;
}

function validateContent(value: DraftContent): DraftContent {
  if (value === null || typeof value !== 'object' || Array.isArray(value) || !namesMatch(value, CONTENT_KEYS)) {
    throw new Error('草稿字段不完整或不受支持。');
  }
  const values: string[] = [value.title, value.artist, value.album, value.composer, value.genre, value.year,
    value.albumArtist, value.track, value.disc, value.discTotal, value.trackTotal, value.bpm, value.grouping,
    value.isrc, value.copyright, value.comment, value.lyricText, value.lyricSourceName, value.lyricSummary];
  for (let i: number = 0; i < values.length; i++) {
    if (typeof values[i] !== 'string' || values[i].length > (i === 16 ? MAX_LYRIC_CHARS : MAX_FIELD_CHARS) ||
        !safeUnicode(values[i])) throw new Error('草稿文本无效或超过大小限制。');
  }
  if (typeof value.coverNeedsReselection !== 'boolean') throw new Error('草稿封面状态无效。');
  return { title: value.title, artist: value.artist, album: value.album, composer: value.composer, genre: value.genre,
    year: value.year, albumArtist: value.albumArtist, track: value.track, disc: value.disc, discTotal: value.discTotal,
    trackTotal: value.trackTotal, bpm: value.bpm, grouping: value.grouping, isrc: value.isrc,
    copyright: value.copyright, comment: value.comment, lyricText: value.lyricText, lyricSourceName: value.lyricSourceName,
    lyricSummary: value.lyricSummary, coverNeedsReselection: value.coverNeedsReselection };
}

function sourceNameValid(name: string): boolean {
  return typeof name === 'string' && name.trim().length > 0 && name.length <= 512 && safeUnicode(name) &&
    !/[\\/\0]/.test(name);
}

function checksumOf(record: DraftRecord): string {
  const checked: DraftPayload = { version: record.version, revision: record.revision,
    sourceName: record.sourceName, savedAt: record.savedAt, audio: record.audio, content: record.content };
  const payload: string = JSON.stringify(checked);
  const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  digest.updateSync({ data: util.TextEncoder.create('utf-8').encodeInto(payload) });
  const hash: Uint8Array = digest.digestSync().data;
  if (hash.length !== 32) throw new Error('无法核对草稿摘要。');
  let hex: string = '';
  for (let i: number = 0; i < hash.length; i++) hex += hash[i].toString(16).padStart(2, '0');
  return hex;
}

function parseRecord(text: string): DraftRecord {
  let record: DraftRecord;
  try { record = JSON.parse(text) as DraftRecord; } catch (_error) { throw new DraftCorruptError('草稿数据损坏，无法恢复。'); }
  if (record === null || typeof record !== 'object' || Array.isArray(record) ||
      !namesMatch(record, ['version', 'revision', 'sourceName', 'savedAt', 'audio', 'content', 'checksum']) ||
      record.version !== 1 || typeof record.revision !== 'string' || !UUID.test(record.revision) ||
      !sourceNameValid(record.sourceName) || !Number.isSafeInteger(record.savedAt) || record.savedAt <= 0 ||
      record.audio === null || typeof record.audio !== 'object' || Array.isArray(record.audio) ||
      !namesMatch(record.audio, ['size', 'sha256']) || !Number.isSafeInteger(record.audio.size) ||
      record.audio.size <= 0 || record.audio.size > MAX_AUDIO_BYTES || typeof record.audio.sha256 !== 'string' ||
      !/^[0-9a-f]{64}$/.test(record.audio.sha256) || typeof record.checksum !== 'string' ||
      !/^[0-9a-f]{64}$/.test(record.checksum)) throw new DraftCorruptError('草稿数据无效，无法恢复。');
  try { record.content = validateContent(record.content); }
  catch (_error) { throw new DraftCorruptError('草稿字段无效，无法恢复。'); }
  if (checksumOf(record) !== record.checksum) throw new DraftCorruptError('草稿校验失败，无法恢复。');
  return record;
}

function withLock<T>(root: string, action: () => T): T {
  let file: fileIo.File | undefined = undefined;
  try {
    file = fileIo.openSync(root + '/' + LOCK_FILE, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW);
    file.tryLock(true);
    return action();
  } finally {
    if (file !== undefined) {
      try { file.unlock(); } catch (_error) {}
      fileIo.closeSync(file.fd);
    }
  }
}

function syncDir(root: string): void {
  const dir: fileIo.File = fileIo.openSync(root, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.DIR);
  try { fileIo.fsyncSync(dir.fd); } finally { fileIo.closeSync(dir.fd); }
}

function readRecord(root: string): DraftRecord | undefined {
  const path: string = root + '/' + DRAFT_FILE;
  let stat: fileIo.Stat;
  try { stat = fileIo.lstatSync(path); } catch (error) {
    if (Number((error as BusinessError).code) === 13900002) return undefined;
    throw new Error('无法读取草稿。');
  }
  if (!stat.isFile() || !Number.isSafeInteger(stat.size)) throw new Error('草稿文件类型无效。');
  if (stat.size <= 0 || stat.size > MAX_RECORD_BYTES) throw new DraftCorruptError('草稿文件大小无效。');
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
  try {
    const opened: fileIo.Stat = fileIo.statSync(file.fd);
    if (!opened.isFile() || opened.ino.toString() !== stat.ino.toString() || opened.size !== stat.size) {
      throw new Error('草稿文件在读取时发生变化。');
    }
    const bytes: Uint8Array = new Uint8Array(stat.size);
    let done: number = 0;
    while (done < bytes.length) {
      const chunk: ArrayBuffer = new ArrayBuffer(Math.min(CHUNK, bytes.length - done));
      const count: number = fileIo.readSync(file.fd, chunk, { length: chunk.byteLength });
      if (!Number.isInteger(count) || count <= 0 || count > chunk.byteLength) throw new Error('草稿文件读取不完整。');
      bytes.set(new Uint8Array(chunk, 0, count), done);
      done += count;
    }
    if (fileIo.statSync(file.fd).size !== stat.size) throw new Error('草稿文件在读取时发生变化。');
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true });
    let text: string;
    try { text = decoder.decodeToString(bytes); } catch (_error) { throw new DraftCorruptError('草稿文本编码无效。'); }
    return parseRecord(text);
  } finally { fileIo.closeSync(file.fd); }
}

function writeRecord(root: string, record: DraftRecord): void {
  const encoded: Uint8Array = util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(record));
  if (encoded.length <= 0 || encoded.length > MAX_RECORD_BYTES) throw new Error('草稿内容超过大小限制。');
  const dir: string = fileIo.mkdtempSync(root + '/lyricflow_draft_XXXXXX');
  const temp: string = dir + '/draft.json';
  let file: fileIo.File | undefined = undefined;
  try {
    // mkdtemp creates a private, unique directory, so the fixed child is new.
    file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.NOFOLLOW);
    let offset: number = 0;
    while (offset < encoded.length) {
      const end: number = Math.min(offset + CHUNK, encoded.length);
      const bytes: ArrayBuffer = encoded.buffer.slice(encoded.byteOffset + offset, encoded.byteOffset + end) as ArrayBuffer;
      let written: number = 0;
      while (written < bytes.byteLength) {
        const part: ArrayBuffer = bytes.slice(written);
        const count: number = fileIo.writeSync(file.fd, part);
        if (!Number.isInteger(count) || count <= 0 || count > part.byteLength) throw new Error('草稿写入不完整。');
        written += count;
      }
      offset = end;
    }
    fileIo.fsyncSync(file.fd);
    fileIo.closeSync(file.fd);
    file = undefined;
    fileIo.renameSync(temp, root + '/' + DRAFT_FILE);
    syncDir(root);
    const saved: DraftRecord | undefined = readRecord(root);
    if (saved === undefined || JSON.stringify(saved) !== JSON.stringify(record)) throw new Error('草稿回读验证失败。');
  } finally {
    if (file !== undefined) { try { fileIo.closeSync(file.fd); } catch (_error) {} }
    try { fileIo.unlinkSync(temp); } catch (_error) {}
    try { fileIo.rmdirSync(dir); } catch (_error) {}
  }
}

function serial<T>(action: () => T): Promise<T> {
  const result: Promise<T> = queue.then(action);
  queue = result.then((): void => {}, (_error: Object): void => {});
  return result;
}

function statKey(stat: fileIo.Stat): string {
  if (!stat.isFile() || stat.ino.toString() === '0' || stat.mtimeNs === undefined || stat.ctimeNs === undefined) {
    throw new Error('无法可靠核对音频身份。');
  }
  return stat.ino.toString() + ':' + stat.size.toString() + ':' + stat.mtimeNs.toString() + ':' + stat.ctimeNs.toString();
}

function requireCorrupt(root: string): CorruptDraftSummary {
  try {
    if (readRecord(root) === undefined) throw new Error('没有可处理的草稿。');
  } catch (error) {
    if (!(error instanceof DraftCorruptError)) throw error as Error;
    const stat: fileIo.Stat = fileIo.lstatSync(root + '/' + DRAFT_FILE);
    const key: string = statKey(stat);
    if (!Number.isSafeInteger(stat.size) || stat.size < 0) throw new Error('无法可靠核对损坏草稿。');
    const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    digest.updateSync({ data: util.TextEncoder.create('utf-8').encodeInto(key) });
    const hash: Uint8Array = digest.digestSync().data;
    if (hash.length !== 32 || statKey(fileIo.lstatSync(root + '/' + DRAFT_FILE)) !== key) {
      throw new Error('无法可靠核对损坏草稿。');
    }
    let token: string = '';
    for (let i: number = 0; i < hash.length; i++) token += hash[i].toString(16).padStart(2, '0');
    return { token: token, size: stat.size };
  }
  throw new Error('草稿有效，不能按损坏草稿删除。');
}

async function identifyWorking(root: string, path: string): Promise<AudioIdentity> {
  const prefix: string = root + '/lyricflow_work_';
  if (!path.startsWith(prefix) || !/^[a-zA-Z0-9_.-]+$/.test(path.substring(prefix.length))) {
    throw new Error('只能核对本次导入的应用私有音频副本。');
  }
  const before: fileIo.Stat = fileIo.lstatSync(path);
  const key: string = statKey(before);
  if (!Number.isSafeInteger(before.size) || before.size <= 0 || before.size > MAX_AUDIO_BYTES) {
    throw new Error('音频文件大小不受支持。');
  }
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
  try {
    if (statKey(fileIo.statSync(file.fd)) !== key) throw new Error('音频文件在核对时发生变化。');
    const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    let total: number = 0;
    while (total < before.size) {
      const length: number = Math.min(CHUNK, before.size - total);
      const bytes: ArrayBuffer = new ArrayBuffer(length);
      const count: number = await fileIo.read(file.fd, bytes, { length: length });
      if (!Number.isInteger(count) || count <= 0 || count > length) throw new Error('音频读取不完整。');
      await digest.update({ data: new Uint8Array(bytes, 0, count) });
      total += count;
    }
    if (statKey(fileIo.statSync(file.fd)) !== key || statKey(fileIo.lstatSync(path)) !== key) {
      throw new Error('音频文件在核对时发生变化。');
    }
    const hash: Uint8Array = (await digest.digest()).data;
    if (hash.length !== 32) throw new Error('无法核对音频摘要。');
    let hex: string = '';
    for (let i: number = 0; i < hash.length; i++) hex += hash[i].toString(16).padStart(2, '0');
    return { size: total, sha256: hex };
  } finally { fileIo.closeSync(file.fd); }
}

/** One private draft. Replacing or discarding it always requires its exact revision. */
export class DraftService {
  static inspect(context: common.UIAbilityContext): Promise<DraftSummary | undefined> {
    const root: string = rootOf(context);
    return serial((): DraftSummary | undefined => withLock(root, (): DraftSummary | undefined => {
      const record: DraftRecord | undefined = readRecord(root);
      return record === undefined ? undefined : { revision: record.revision, sourceName: record.sourceName,
        savedAt: record.savedAt, coverNeedsReselection: record.content.coverNeedsReselection };
    }));
  }

  /** Begin only after the normal picker/import created the private working copy. Existing drafts are never replaced. */
  static async begin(context: common.UIAbilityContext, workingPath: string, sourceName: string): Promise<DraftSession> {
    const root: string = rootOf(context);
    if (!sourceNameValid(sourceName)) throw new Error('音频名称无效。');
    const myGeneration: number = generation;
    const myAttempt: number = ++beginAttempt;
    if (await DraftService.inspect(context) !== undefined) throw new Error('已有未处理草稿，请先恢复或丢弃。');
    const audio: AudioIdentity = await identifyWorking(root, workingPath);
    return await serial((): DraftSession => {
      const token: string = withLock(root, (): string => {
        if (generation !== myGeneration || beginAttempt !== myAttempt) throw new Error('编辑会话已变化。');
        if (readRecord(root) !== undefined) throw new Error('已有未处理草稿，请先恢复或丢弃。');
        return util.generateRandomUUID();
      });
      generation++;
      stagedRestore = undefined;
      active = { token: token, root: root, sourceName: sourceName, audio: audio, revision: '', generation: generation,
        writable: true };
      return { token: token };
    });
  }

  /** The snapshot is validated/copied at call time, before queuing. */
  static save(context: common.UIAbilityContext, session: DraftSession, content: DraftContent): Promise<DraftSummary> {
    const root: string = rootOf(context);
    if (pendingSaves >= 2) throw new Error('草稿保存尚未完成，请稍后重试。');
    const snapshot: DraftContent = validateContent(content);
    const token: string = session.token;
    const requestedGeneration: number = generation;
    pendingSaves++;
    const saved: Promise<DraftSummary> = serial((): DraftSummary => withLock(root, (): DraftSummary => {
      const current: ActiveSession | undefined = active;
      if (current === undefined || !current.writable || current.token !== token || current.root !== root ||
          current.generation !== requestedGeneration || generation !== requestedGeneration) throw new Error('草稿会话已失效。');
      let previous: DraftRecord | undefined = readRecord(root);
      if (current.uncertainRevision !== undefined) {
        if (previous !== undefined && previous.revision === current.uncertainRevision &&
            previous.checksum === current.uncertainChecksum) {
          syncDir(root);
          previous = readRecord(root);
          if (previous === undefined || previous.revision !== current.uncertainRevision ||
              previous.checksum !== current.uncertainChecksum) throw new Error('草稿状态不确定，请重新检查。');
          current.revision = previous.revision;
        } else if ((previous === undefined ? '' : previous.revision) !== current.revision) {
          throw new Error('草稿已变化，请重新检查。');
        }
        current.uncertainRevision = undefined;
        current.uncertainChecksum = undefined;
      }
      if ((previous === undefined ? '' : previous.revision) !== current.revision) throw new Error('草稿已变化，请重新检查。');
      const record: DraftRecord = { version: 1, revision: util.generateRandomUUID(), sourceName: current.sourceName,
        savedAt: Date.now(), audio: current.audio, content: snapshot, checksum: '' };
      record.checksum = checksumOf(record);
      try { writeRecord(root, record); } catch (error) {
        current.uncertainRevision = record.revision;
        current.uncertainChecksum = record.checksum;
        throw error as Error;
      }
      current.revision = record.revision;
      return { revision: record.revision, sourceName: record.sourceName, savedAt: record.savedAt,
        coverNeedsReselection: record.content.coverNeedsReselection };
    }));
    return saved.then((summary: DraftSummary): DraftSummary => {
      pendingSaves--;
      return summary;
    }, (error: Object): DraftSummary => {
      pendingSaves--;
      throw error as Error;
    });
  }

  /** Explicit user action: reselect and import, verify the entire private copy, then return text for review. */
  static async restore(context: common.UIAbilityContext, expectedRevision: string): Promise<DraftRestore | undefined> {
    const root: string = rootOf(context);
    if (!UUID.test(expectedRevision)) throw new Error('草稿标识无效。');
    const myGeneration: number = generation;
    const before: DraftRecord | undefined = await serial((): DraftRecord | undefined => withLock(root, (): DraftRecord | undefined => readRecord(root)));
    if (before === undefined || before.revision !== expectedRevision) throw new Error('草稿已变化，请重新检查。');
    const selected: SelectedDocument | undefined = await FileSelectionService.selectOne(context, 'audio');
    if (selected === undefined) return undefined;
    const working: WorkingAudio = await AudioMetadataService.importToSandbox(selected.uri, selected.name, root);
    let accepted: boolean = false;
    try {
      const identity: AudioIdentity = await identifyWorking(root, working.workingPath);
      if (identity.size !== before.audio.size || identity.sha256 !== before.audio.sha256) throw new Error('所选音频内容与草稿来源不同。');
      const restored: DraftRestore = await serial((): DraftRestore => {
        const checked: CheckedRestore = withLock(root, (): CheckedRestore => {
          const latest: DraftRecord | undefined = readRecord(root);
          if (generation !== myGeneration || latest === undefined || latest.revision !== expectedRevision) {
            throw new Error('草稿或编辑会话已变化，请重新检查。');
          }
          return { token: util.generateRandomUUID(), record: latest };
        });
        stagedRestore = { token: checked.token, root: root, sourceName: checked.record.sourceName, audio: checked.record.audio,
          revision: checked.record.revision, generation: myGeneration };
        return { session: { token: checked.token }, audio: working, content: checked.record.content, revision: checked.record.revision };
      });
      accepted = true;
      return restored;
    } finally {
      if (!accepted) {
        if (working.metadata.coverImage !== undefined) { try { await working.metadata.coverImage.release(); } catch (_error) {} }
        await AudioMetadataService.removeWorkingFile(working.workingPath);
      }
    }
  }

  /**
   * The synchronous callback must recheck the editor and call claim() BEFORE using the copy.
   * claim() irrevocably transfers ownership but keeps the new session non-writable.
   * The new session becomes writable only after the callback completes with true. It must not
   * perform asynchronous work; begin saving only after this promise resolves.
   * If the callback throws before claim(), ownership is uncertain and the copy must be retained.
   */
  static commitRestore(context: common.UIAbilityContext, session: DraftSession,
    accept: (claim: () => void) => boolean): Promise<DraftCommitResult> {
    const root: string = rootOf(context);
    return serial((): DraftCommitResult => {
      let claimed: boolean = false;
      let ownershipUncertain: boolean = false;
      let editorAccepted: boolean = false;
      try {
        return withLock(root, (): DraftCommitResult => {
          const pending: PendingRestore | undefined = stagedRestore;
          if (pending === undefined || pending.root !== root || pending.token !== session.token ||
              pending.generation !== generation) throw new Error('待恢复的草稿已过期，请重新检查。');
          const latest: DraftRecord | undefined = readRecord(root);
          if (latest === undefined || latest.revision !== pending.revision) {
            stagedRestore = undefined;
            throw new Error('草稿已变化，请重新检查。');
          }
          let claimWindowOpen: boolean = true;
          const claim: () => void = (): void => {
            if (!claimWindowOpen) throw new Error('草稿接管确认已结束。');
            if (claimed) throw new Error('草稿副本已接管。');
            generation++;
            active = { token: pending.token, root: root, sourceName: pending.sourceName, audio: pending.audio,
              revision: pending.revision, generation: generation, writable: false };
            claimed = true;
          };
          stagedRestore = undefined;
          let accepted: boolean = false;
          try { accepted = accept(claim); } catch (_error) {
            if (!claimed) ownershipUncertain = true;
            return claimed
              ? { state: 'committed', editorAccepted: false, warning: '草稿副本已接管，但页面接收时发生错误；自动保存已暂停，音频副本已保留。' }
              : { state: 'uncertain', editorAccepted: false, warning: '页面接收状态不确定；音频副本已保留，请检查当前编辑。' };
          } finally {
            claimWindowOpen = false;
          }
          editorAccepted = claimed && accepted === true;
          if (editorAccepted && active !== undefined && active.token === pending.token) active.writable = true;
          if (claimed) return { state: 'committed', editorAccepted: editorAccepted, warning: accepted === true ? '' :
            '草稿副本已接管，但页面未确认完成；自动保存已暂停，音频副本已保留。' };
          if (accepted !== false) ownershipUncertain = true;
          return accepted === false
            ? { state: 'rejected', editorAccepted: false, warning: '' }
            : { state: 'uncertain', editorAccepted: false, warning: '页面未明确接管音频副本，已保留副本供检查。' };
        });
      } catch (error) {
        if (claimed) return { state: 'committed', editorAccepted: editorAccepted, warning: '草稿副本已接管，但释放草稿锁失败；音频副本已保留。' +
          (editorAccepted ? '' : ' 页面未完成接收，自动保存已暂停。') };
        if (ownershipUncertain) return { state: 'uncertain', editorAccepted: false, warning: '页面接收状态不确定且草稿锁释放失败；音频副本已保留。' };
        throw error as Error;
      }
    });
  }

  /** Discard only the prepared handoff; never invalidate the current editing session. */
  static abandonRestore(session: DraftSession): void {
    if (stagedRestore !== undefined && stagedRestore.token === session.token) stagedRestore = undefined;
  }

  /** Call only after explicit user confirmation; stale revisions cannot remove a newer draft. */
  static discard(context: common.UIAbilityContext, expectedRevision: string): Promise<void> {
    const root: string = rootOf(context);
    if (!UUID.test(expectedRevision)) throw new Error('草稿标识无效。');
    return serial((): void => withLock(root, (): void => {
      const current: DraftRecord | undefined = readRecord(root);
      if (current === undefined || current.revision !== expectedRevision) throw new Error('草稿已变化，请重新检查。');
      fileIo.unlinkSync(root + '/' + DRAFT_FILE);
      generation++;
      active = undefined;
      stagedRestore = undefined;
      syncDir(root);
    }));
  }

  /** After a verified audio save, remove only an exact draft if the editor is still unchanged. */
  static discardIf(context: common.UIAbilityContext, expectedRevision: string,
    editorStillMatches: () => boolean): Promise<boolean> {
    const root: string = rootOf(context);
    if (!UUID.test(expectedRevision)) throw new Error('草稿标识无效。');
    return serial((): boolean => withLock(root, (): boolean => {
      const current: DraftRecord | undefined = readRecord(root);
      if (current === undefined || current.revision !== expectedRevision) return false;
      if (editorStillMatches() !== true) return false;
      fileIo.unlinkSync(root + '/' + DRAFT_FILE);
      generation++;
      active = undefined;
      stagedRestore = undefined;
      syncDir(root);
      return true;
    }));
  }

  /** A corrupt file must be shown to the user before explicitly discarding this exact snapshot. */
  static inspectCorrupt(context: common.UIAbilityContext): Promise<CorruptDraftSummary> {
    const root: string = rootOf(context);
    return serial((): CorruptDraftSummary => withLock(root, (): CorruptDraftSummary => requireCorrupt(root)));
  }

  static discardCorrupt(context: common.UIAbilityContext, expectedToken: string): Promise<void> {
    const root: string = rootOf(context);
    if (!/^[0-9a-f]{64}$/.test(expectedToken)) throw new Error('损坏草稿标识无效。');
    return serial((): void => withLock(root, (): void => {
      const current: CorruptDraftSummary = requireCorrupt(root);
      if (current.token !== expectedToken) throw new Error('草稿已变化，请重新检查。');
      fileIo.unlinkSync(root + '/' + DRAFT_FILE);
      generation++;
      active = undefined;
      stagedRestore = undefined;
      syncDir(root);
    }));
  }
}
