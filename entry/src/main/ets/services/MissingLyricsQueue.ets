import { FolderScanner, FolderScanResult, ScanProgressFn, ScanCancelFn } from './FolderScanner';
import { AudioMatchInput, LyricMatchInput } from './MatchEngine';
import { AudioMetadata } from './AudioMetadataTypes';
import { AudioMetadataService, WorkingFileCleanupError } from './AudioMetadataService';
import { FileSelectionService } from './FileSelectionService';
import { CloudLyrics, CloudLyricsService, CloudSearchResult } from './CloudLyricsService';
import { CloudSong, CloudSongCandidate, CloudSongMatcher, LocalSongIdentity } from './CloudSongMatcher';
import { combineCloudLyrics, BilingualLyricsResult } from './CloudBilingualLyrics';
import { Mp3SourceIdentity, Mp3SourceObservation, MetadataExtractorCleanupError, beginMp3SourceObservation,
  endMp3SourceObservation, proveBareMp3HasNoTags } from './MissingLyricsMp3Evidence';

/** Read-only preparation: this service has no API that saves or modifies audio or lyrics. */
export type MissingLyricsState = 'missing' | 'plain' | 'timed' | 'unknown';
export type MissingLyricsOperation = '' | 'scan' | 'search' | 'preview';
export type MissingLyricsKind = 'original' | 'translation' | 'bilingual';

/**
 * `complete` is a trusted inspector's assertion that *all* relevant embedded
 * lyric containers, variants and aliases were checked without ambiguity.
 * A partial/failed/unsupported inspection MUST return `unknown`.  The default
 * adapter claims absence only for a verified unchanged, fully bare MP3. In
 * particular AudioMetadata.lyrics alone never excludes SYLT or other aliases.
 */
export interface EmbeddedLyricEvidence {
  coverage: 'complete' | 'unknown';
  presence: 'absent' | 'present' | 'unknown';
  text: string;
}

export interface MissingLyricsRow {
  id: string;
  name: string;
  uri: string;
  identity: LocalSongIdentity;
  titleFromFilename: boolean;
  embedded: MissingLyricsState;
  embeddedHasReadableText: boolean;
  /** Classification of the text this reader exposed, not proof that other lyric tags are absent. */
  embeddedVisibleText: MissingLyricsState;
  sidecar: MissingLyricsState;
  sidecarName: string;
  note: string;
}

export interface MissingLyricsSnapshot {
  rows: MissingLyricsRow[];
  warnings: string[];
  busy: boolean;
  cancelling: boolean;
  operation: MissingLyricsOperation;
  progress: string;
  searchRowId: string;
  candidates: CloudSongCandidate[];
  recommendedId: string;
  searchIncomplete: boolean;
  selectedKey: string;
  previewOriginal: string;
  previewTranslation: string;
  previewTranslationWarning: string;
  previewBilingual: string;
  previewBilingualWarning: string;
  previewBilingualError: string;
  status: string;
}

/** A draft is not a write authorization; any later save must revalidate the file and existing lyrics. */
export interface ConfirmedLyricsDraft {
  rowId: string;
  source: string;
  songId: string;
  kind: MissingLyricsKind;
  text: string;
}

/** A port also makes it possible to test every queue operation without network or device I/O. */
export interface MissingLyricsQueuePort {
  scan(folderUri: string, maxFiles: number, onProgress: ScanProgressFn, shouldCancel: ScanCancelFn): Promise<FolderScanResult>;
  canReadDirectly(uri: string): boolean;
  readMetadata(uri: string, name: string, filesDir: string, allowCopy: boolean,
    onCopyAttempt: () => void): Promise<AudioMetadata>;
  inspectEmbedded(audio: AudioMatchInput, metadata: AudioMetadata): Promise<EmbeddedLyricEvidence>;
  readSidecar(uri: string): Promise<string>;
  search(keyword: string): Promise<CloudSearchResult>;
  lyrics(song: CloudSong): Promise<CloudLyrics>;
  cancelCloud(): void;
}

class DefaultMissingLyricsQueuePort implements MissingLyricsQueuePort {
  // One instance preserves the existing cache, cancellation and 500 ms request gate.
  private cloud: CloudLyricsService = new CloudLyricsService();
  private observedMetadata: AudioMetadata | undefined = undefined;
  private observedUri: string = '';
  private observedIdentity: Mp3SourceIdentity | undefined = undefined;
  async scan(folderUri: string, maxFiles: number, onProgress: ScanProgressFn,
    shouldCancel: ScanCancelFn): Promise<FolderScanResult> {
    // Pass an empty filesDir: the queue performs the bounded audio metadata pass once below.
    return await FolderScanner.scan(folderUri, maxFiles, '', onProgress, shouldCancel);
  }
  canReadDirectly(uri: string): boolean { return AudioMetadataService.canReadDirectly(uri); }
  async readMetadata(uri: string, name: string, filesDir: string, allowCopy: boolean,
    onCopyAttempt: () => void): Promise<AudioMetadata> {
    this.observedMetadata = undefined; this.observedIdentity = undefined; this.observedUri = '';
    let observation: Mp3SourceObservation | undefined = undefined;
    if (/\.mp3$/i.test(name)) {
      try { observation = await beginMp3SourceObservation(uri); }
      catch (error) { if (error instanceof MetadataExtractorCleanupError) throw error as Error; }
    }
    let result: AudioMetadata | undefined = undefined;
    let id: Mp3SourceIdentity | undefined = undefined;
    let usedSandboxCopy: boolean = true;
    try {
      const read = await AudioMetadataService.readForMatching(uri, name, filesDir, allowCopy, onCopyAttempt, true);
      result = read.metadata;
      usedSandboxCopy = read.usedSandboxCopy;
    } finally {
      if (observation !== undefined) {
        try { id = await endMp3SourceObservation(observation); }
        catch (error) {
          if (error instanceof MetadataExtractorCleanupError) {
            if (result !== undefined && result.coverImage !== undefined) {
              try { await result.coverImage.release(); } catch (_releaseError) {}
            }
            throw error as Error;
          }
        }
      }
    }
    if (result === undefined) throw new Error('音频元数据不可用。');
    // Matching's fallback deletes its copy before returning; that copy cannot be
    // bound or inspected after the fact, so keep its absence status unknown.
    if (!usedSandboxCopy && id !== undefined && result.fileSize === id.size) {
      this.observedMetadata = result; this.observedIdentity = id; this.observedUri = uri;
    }
    return result;
  }
  async inspectEmbedded(audio: AudioMatchInput, metadata: AudioMetadata): Promise<EmbeddedLyricEvidence> {
    const expected: Mp3SourceIdentity | undefined = this.observedIdentity;
    const uri: string = audio.uri === undefined ? '' : audio.uri;
    const bound: boolean = this.observedMetadata === metadata && this.observedUri === uri;
    this.observedMetadata = undefined; this.observedIdentity = undefined; this.observedUri = '';
    if (bound && expected !== undefined && /\.mp3$/i.test(audio.name) && metadata.lyrics.length === 0) {
      try {
        if (await proveBareMp3HasNoTags(uri, expected)) return { coverage: 'complete', presence: 'absent', text: '' };
      } catch (error) {
        if (error instanceof MetadataExtractorCleanupError) throw error as Error;
        /* Unsupported, changed or unreadable remains unknown. */
      }
    }
    return { coverage: 'unknown', presence: 'unknown', text: metadata.lyrics };
  }
  async readSidecar(uri: string): Promise<string> { return await FileSelectionService.readUtf8Text(uri, 128 * 1024); }
  async search(keyword: string): Promise<CloudSearchResult> { return await this.cloud.searchDetailed(keyword); }
  async lyrics(song: CloudSong): Promise<CloudLyrics> { return await this.cloud.lyrics(song); }
  cancelCloud(): void { this.cloud.cancel(); }
}

const MAX_TEXT_CHARS: number = 256 * 1024;
const MAX_TEXT_ROWS: number = 10000;
const MAX_ROWS: number = 2000;
const MAX_SIDECAR_READS: number = 1000;

/** Classifies only recognized, complete text; empty or ambiguous text is unknown. */
export function classifyKnownLyricText(text: string): MissingLyricsState {
  if (text.length === 0 || text.length > MAX_TEXT_CHARS || text.trim().length === 0 ||
      /[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffd]/.test(text)) return 'unknown';
  const rows: string[] = text.replace(/^\uFEFF/, '').split(/\r\n|\r|\n/);
  if (rows.length > MAX_TEXT_ROWS) return 'unknown';
  let hasTimed: boolean = false;
  let hasPlain: boolean = false;
  let hasContent: boolean = false;
  let seenOffset: boolean = false;
  for (let i: number = 0; i < rows.length; i++) {
    const row: string = rows[i].trim();
    if (row.length === 0) continue;
    const header: RegExpMatchArray | null = row.match(/^\[(ti|ar|al|by|re|ve|offset|length|id|tool|source|language|total):([^\]]*)\]$/i);
    if (header !== null) {
      if (header[1].toLowerCase() === 'offset') {
        const value: string = header[2].trim();
        if (seenOffset || !/^[+-]?\d+$/.test(value) || !Number.isSafeInteger(Number(value))) return 'unknown';
        seenOffset = true;
      }
      continue;
    }
    const timed: RegExpMatchArray | null = row.match(/^((?:\[\d{1,3}:\d{2}(?:\.\d{1,3})?\])+)(.*)$/);
    if (timed !== null) {
      const tags: RegExpMatchArray | null = timed[1].match(/\[\d{1,3}:\d{2}(?:\.\d{1,3})?\]/g);
      if (tags === null) return 'unknown';
      for (let j: number = 0; j < tags.length; j++) {
        const match: RegExpMatchArray | null = tags[j].match(/^\[\d{1,3}:(\d{2})/);
        if (match === null || Number(match[1]) >= 60) return 'unknown';
      }
      // Preserve enhanced LRC classification only for completely recognized word times.
      if (/\[\d{1,3}:\d{2}/.test(timed[2])) return 'unknown';
      let body: string = timed[2];
      const words: RegExpMatchArray | null = body.match(/<\d{1,3}:\d{2}(?:\.\d{1,3})?>/g);
      if (words !== null) {
        for (let j: number = 0; j < words.length; j++) {
          const match: RegExpMatchArray | null = words[j].match(/^<\d{1,3}:(\d{2})/);
          if (match === null || Number(match[1]) >= 60) return 'unknown';
        }
        body = body.replace(/<\d{1,3}:\d{2}(?:\.\d{1,3})?>/g, '');
      }
      // Time-like markers with leading whitespace or a sign are unsupported
      // too; never label them as completely recognized enhanced LRC.
      if (/<\s*[+-]?\d/.test(body)) return 'unknown';
      hasTimed = true;
      if (body.trim().length > 0) hasContent = true;
      continue;
    }
    // Untimed bracket lines, subtitle cues and mixed formats cannot be classified safely here.
    if (row.charAt(0) === '[' || /-->/.test(row) || /^WEBVTT\b/i.test(row) ||
        /^\d{1,3}:\d{2}:\d{2}[.,]\d+/.test(row)) return 'unknown';
    hasPlain = true;
    hasContent = true;
  }
  if (!hasContent || (hasTimed && hasPlain) || (seenOffset && !hasTimed)) return 'unknown';
  return hasTimed ? 'timed' : (hasPlain ? 'plain' : 'unknown');
}

/** `missing` requires explicit complete coverage and no contradictory reader text. */
export function classifyEmbeddedEvidence(metadataText: string, evidence: EmbeddedLyricEvidence): MissingLyricsState {
  if (evidence.coverage !== 'complete' || metadataText !== evidence.text) return 'unknown';
  if (evidence.presence === 'absent' && evidence.text.length === 0) return 'missing';
  if (evidence.presence !== 'present') return 'unknown';
  return classifyKnownLyricText(evidence.text);
}

function copySong(song: CloudSong): CloudSong {
  return { source: song.source, id: song.id, title: song.title, artists: song.artists.slice(),
    album: song.album, durationMs: song.durationMs };
}
function copyCandidate(candidate: CloudSongCandidate): CloudSongCandidate {
  return { song: copySong(candidate.song), score: candidate.score, reliable: candidate.reliable,
    evidence: candidate.evidence.slice(), warnings: candidate.warnings.slice() };
}
function copyIdentity(identity: LocalSongIdentity): LocalSongIdentity {
  return { title: identity.title, artist: identity.artist, album: identity.album, durationMs: identity.durationMs };
}
function copyRow(row: MissingLyricsRow): MissingLyricsRow {
  return { id: row.id, name: row.name, uri: row.uri, identity: copyIdentity(row.identity),
    titleFromFilename: row.titleFromFilename, embedded: row.embedded,
    embeddedHasReadableText: row.embeddedHasReadableText, embeddedVisibleText: row.embeddedVisibleText, sidecar: row.sidecar,
    sidecarName: row.sidecarName, note: row.note };
}
function parentUri(uri: string): string {
  const value: string = uri.split('?')[0].split('#')[0];
  const slash: number = value.lastIndexOf('/');
  return slash > 0 ? value.substring(0, slash) : '';
}
function stem(name: string): string {
  if (name.length === 0 || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) return '';
  return name.replace(/\.[^.]+$/, '');
}
function sidecarKey(uri: string, name: string): string {
  const parent: string = parentUri(uri); const base: string = stem(name);
  return parent.length > 0 && base.length > 0 ? JSON.stringify([parent, base]) : '';
}
function indexSidecars(lyrics: LyricMatchInput[]): Map<string, LyricMatchInput[]> {
  const index: Map<string, LyricMatchInput[]> = new Map<string, LyricMatchInput[]>();
  for (let i: number = 0; i < lyrics.length; i++) {
    const item: LyricMatchInput = lyrics[i];
    if (item.uri === undefined) continue;
    const group: string = sidecarKey(item.uri, item.name);
    if (group.length === 0) continue;
    const matches: LyricMatchInput[] | undefined = index.get(group);
    if (matches === undefined) index.set(group, [item]);
    else matches.push(item);
  }
  return index;
}
function key(song: CloudSong): string { return JSON.stringify([song.source, song.id]); }
function unknownNote(): string { return '歌词标签或旁路文件未完整核验；不能据此认定缺失。'; }

/**
 * One explicit operation at a time. Network calls occur only from search/preview.
 * cancel() invalidates pending results; no new operation starts until old I/O settles.
 */
export class MissingLyricsQueue {
  private port: MissingLyricsQueuePort;
  private rows: MissingLyricsRow[] = [];
  private warnings: string[] = [];
  private busy: boolean = false;
  private cancelling: boolean = false;
  private operation: MissingLyricsOperation = '';
  private generation: number = 0;
  private activeId: number = 0;
  private progress: string = '';
  private searchRowId: string = '';
  private candidates: CloudSongCandidate[] = [];
  private recommendedId: string = '';
  private searchIncomplete: boolean = false;
  private selectedKey: string = '';
  private previewOriginal: string = '';
  private previewTranslation: string = '';
  private previewTranslationWarning: string = '';
  private previewBilingual: string = '';
  private previewBilingualWarning: string = '';
  private previewBilingualError: string = '';
  private status: string = '';
  private cleanupErrorCallback: ((message: string) => void) | undefined = undefined;

  constructor(port?: MissingLyricsQueuePort) { this.port = port === undefined ? new DefaultMissingLyricsQueuePort() : port; }
  /** May fire after cancellation or page removal; the parent must retain its handler. */
  setCleanupErrorCallback(callback: ((message: string) => void) | undefined): void { this.cleanupErrorCallback = callback; }
  snapshot(): MissingLyricsSnapshot {
    return { rows: this.rows.map(copyRow), warnings: this.warnings.slice(), busy: this.busy,
      cancelling: this.cancelling, operation: this.operation, progress: this.progress,
      searchRowId: this.searchRowId, candidates: this.candidates.map(copyCandidate), recommendedId: this.recommendedId,
      searchIncomplete: this.searchIncomplete, selectedKey: this.selectedKey, previewOriginal: this.previewOriginal,
      previewTranslation: this.previewTranslation, previewTranslationWarning: this.previewTranslationWarning,
      previewBilingual: this.previewBilingual, previewBilingualWarning: this.previewBilingualWarning,
      previewBilingualError: this.previewBilingualError, status: this.status };
  }
  private begin(operation: MissingLyricsOperation): number {
    if (this.busy) throw new Error('已有任务正在进行，请先等待或取消。');
    this.busy = true; this.cancelling = false; this.operation = operation;
    this.generation++; this.activeId = this.generation;
    return this.activeId;
  }
  private active(id: number): boolean { return this.busy && !this.cancelling && id === this.activeId && id === this.generation; }
  private requireActive(id: number): void { if (!this.active(id)) throw new Error('任务已取消。'); }
  private finish(id: number): void {
    if (this.activeId === id) {
      if (this.cancelling) this.status = '任务已取消；未修改任何文件。';
      this.busy = false; this.cancelling = false; this.operation = ''; this.activeId = 0; this.progress = '';
    }
  }
  cancel(): void {
    this.generation++;
    if (this.busy) { this.cancelling = true; this.progress = '正在取消…'; }
    this.port.cancelCloud();
  }
  private clearPreview(): void {
    this.selectedKey = ''; this.previewOriginal = ''; this.previewTranslation = ''; this.previewTranslationWarning = '';
    this.previewBilingual = ''; this.previewBilingualWarning = ''; this.previewBilingualError = '';
  }
  private clearSearch(): void {
    this.searchRowId = ''; this.candidates = []; this.recommendedId = ''; this.searchIncomplete = false; this.clearPreview();
  }
  private row(id: string): MissingLyricsRow {
    const found: MissingLyricsRow | undefined = this.rows.find((item: MissingLyricsRow): boolean => item.id === id);
    if (found === undefined) throw new Error('歌曲不在当前队列中，请重新扫描。');
    return found;
  }

  async scan(folderUri: string, filesDir: string): Promise<void> {
    if (folderUri.length === 0 || filesDir.length === 0) throw new Error('请先选择目录。');
    const op: number = this.begin('scan');
    this.rows = []; this.warnings = []; this.clearSearch(); this.status = ''; this.progress = '正在只读扫描…';
    try {
      const scan: FolderScanResult = await this.port.scan(folderUri, 10000,
        (message: string): void => { if (this.active(op)) this.progress = message; },
        (): boolean => !this.active(op));
      this.requireActive(op);
      const limit: number = Math.min(scan.audioFiles.length, MAX_ROWS);
      if (scan.audioFiles.length > limit) this.warnings.push('歌曲超过队列上限，未列出的文件尚未检查。');
      this.warnings = this.warnings.concat(scan.warnings.slice(0, 100));
      const ids: Set<string> = new Set<string>();
      const uris: Set<string> = new Set<string>();
      const sidecarIndex: Map<string, LyricMatchInput[]> = indexSidecars(scan.lyricFiles);
      let copies: number = 0;
      let sidecarReads: number = 0;
      const rows: MissingLyricsRow[] = [];
      for (let i: number = 0; i < limit; i++) {
        this.requireActive(op);
        const audio: AudioMatchInput = scan.audioFiles[i];
        const sourceUri: string = audio.uri === undefined ? '' : audio.uri;
        if (audio.id.length === 0 || ids.has(audio.id) || (sourceUri.length > 0 && uris.has(sourceUri))) {
          if (this.warnings.length < 101) this.warnings.push('存在缺失或重复的歌曲标识，已跳过；请缩小目录范围重试。');
          continue;
        }
        ids.add(audio.id);
        if (sourceUri.length > 0) uris.add(sourceUri);
        const uri: string = sourceUri;
        const fallback: string = stem(audio.name);
        const row: MissingLyricsRow = { id: audio.id, name: audio.name, uri: uri,
          identity: { title: fallback, artist: '', album: '', durationMs: 0 }, titleFromFilename: true,
          embedded: 'unknown', embeddedHasReadableText: false, embeddedVisibleText: 'unknown',
          sidecar: 'unknown', sidecarName: '', note: unknownNote() };
        this.progress = '检查歌曲 ' + (i + 1).toString() + ' / ' + limit.toString();
        if (uri.length > 0) {
          let metadata: AudioMetadata | undefined = undefined;
          try {
            const allowCopy: boolean = copies < FolderScanner.MAX_SANDBOX_COPIES;
            if (!this.port.canReadDirectly(uri) && !allowCopy) throw new Error('副本预算已用尽');
            metadata = await this.port.readMetadata(uri, audio.name, filesDir, allowCopy, (): void => { copies++; });
            this.requireActive(op);
            const title: string = metadata.title.trim();
            row.titleFromFilename = title.length === 0;
            row.identity = { title: title.length > 0 ? title : fallback, artist: metadata.artist,
              album: metadata.album, durationMs: metadata.durationMs };
            row.embeddedHasReadableText = metadata.lyrics.trim().length > 0;
            row.embeddedVisibleText = classifyKnownLyricText(metadata.lyrics);
            const evidence: EmbeddedLyricEvidence = await this.port.inspectEmbedded(audio, metadata);
            this.requireActive(op);
            row.embedded = classifyEmbeddedEvidence(metadata.lyrics, evidence);
            if (row.embedded === 'missing') {
              row.note = '扫描时确认无内嵌标签；旁路歌词仍需单独核验，保存前必须重新检查。';
            }
          } catch (error) {
            if (error instanceof WorkingFileCleanupError || error instanceof MetadataExtractorCleanupError) {
              if (this.cleanupErrorCallback !== undefined) {
                try { this.cleanupErrorCallback(error.message); } catch (_callbackError) {}
              }
              if (this.warnings.length < 101) this.warnings.push(error.message);
            }
            this.requireActive(op);
            row.note = error instanceof WorkingFileCleanupError || error instanceof MetadataExtractorCleanupError ? error.message + ' 歌词状态未知。' :
              '读取或完整歌词核验失败；不能据此认定缺失。';
          } finally {
            if (metadata !== undefined && metadata.coverImage !== undefined) {
              try { await metadata.coverImage.release(); } catch (_releaseError) {}
            }
          }
          this.requireActive(op);
          const sidecars: LyricMatchInput[] = sidecarIndex.get(sidecarKey(uri, audio.name)) || [];
          if (sidecars.length === 1 && sidecars[0].uri !== undefined && sidecarReads < MAX_SIDECAR_READS) {
            sidecarReads++;
            row.sidecarName = sidecars[0].name;
            try {
              const text: string = await this.port.readSidecar(sidecars[0].uri as string);
              this.requireActive(op);
              row.sidecar = classifyKnownLyricText(text);
            } catch (_error) { this.requireActive(op); row.sidecar = 'unknown'; }
          } else if (sidecars.length > 1) {
            row.note = '同目录同名歌词有多个候选，需人工核对；不能认定缺失。';
          }
        }
        rows.push(row);
      }
      this.requireActive(op);
      this.rows = rows;
      if (sidecarReads >= MAX_SIDECAR_READS) this.warnings.push('歌词文件读取达到上限，其余项目未完整检查。');
      this.warnings.push('未找到同目录同名歌词不等于不存在其他旁路歌词；未知项不能视为缺失。');
      this.status = '只读检查完成；搜索和采用均需手动操作，不会自动写入。';
    } finally { this.finish(op); }
  }

  async search(rowId: string, keyword?: string): Promise<void> {
    const item: MissingLyricsRow = this.row(rowId);
    const original: string = CloudSongMatcher.buildKeyword(item.identity);
    const query: string = keyword === undefined ? original : keyword.trim().replace(/\s+/g, ' ');
    if (query.length === 0 || query.length > 160 || /[\u0000-\u001f]/.test(query)) throw new Error('搜索词为空、过长或含无效字符。');
    const op: number = this.begin('search');
    this.clearSearch(); this.searchRowId = rowId; this.status = ''; this.progress = '正在搜索…';
    try {
      const result: CloudSearchResult = await this.port.search(query);
      this.requireActive(op);
      const ranked = CloudSongMatcher.rank(item.identity, result.songs,
        !item.titleFromFilename && !result.incomplete && query === original);
      this.candidates = ranked.candidates.slice(0, 20).map(copyCandidate);
      this.searchIncomplete = result.incomplete;
      this.recommendedId = result.incomplete ? '' : ranked.recommendedId;
      this.status = result.incomplete ? '结果不完整，请人工核对；不会自动采用。' :
        (this.candidates.length === 0 ? '没有找到候选。' : '请人工核对歌曲并选择预览；不会自动采用。');
    } catch (error) {
      this.requireActive(op); this.clearSearch(); this.status = '搜索失败，请检查网络后重试。'; throw error as Error;
    } finally { this.finish(op); }
  }

  /** Explicit selection only; ranking or a recommendation never selects a candidate. */
  selectCandidate(source: string, songId: string): void {
    if (this.busy) throw new Error('任务进行中，请稍候。');
    const selected: string = JSON.stringify([source, songId]);
    if (this.searchRowId.length === 0 || !this.candidates.some((item: CloudSongCandidate): boolean => key(item.song) === selected)) {
      throw new Error('候选已失效，请重新搜索。');
    }
    this.clearPreview(); this.selectedKey = selected; this.status = '已选择候选，请主动预览歌词。';
  }

  async previewSelected(): Promise<void> {
    if (this.searchRowId.length === 0 || this.selectedKey.length === 0) throw new Error('请先选择候选。');
    const chosen: CloudSongCandidate | undefined = this.candidates.find((item: CloudSongCandidate): boolean => key(item.song) === this.selectedKey);
    if (chosen === undefined) throw new Error('候选已失效，请重新搜索。');
    const chosenKey: string = this.selectedKey;
    const chosenRow: string = this.searchRowId;
    const song: CloudSong = copySong(chosen.song);
    const expectedSource: string = song.source;
    const expectedId: string = song.id;
    const op: number = this.begin('preview');
    this.previewOriginal = ''; this.previewTranslation = ''; this.previewTranslationWarning = '';
    this.previewBilingual = ''; this.previewBilingualWarning = ''; this.previewBilingualError = '';
    this.status = ''; this.progress = '正在获取歌词…';
    try {
      const lyrics: CloudLyrics = await this.port.lyrics(copySong(song));
      this.requireActive(op);
      if (this.searchRowId !== chosenRow || this.selectedKey !== chosenKey ||
          lyrics.source !== expectedSource || lyrics.songId !== expectedId ||
          (lyrics.text.trim().length === 0 && lyrics.translation.trim().length === 0)) {
        throw new Error('返回的歌词与所选歌曲不一致。');
      }
      this.previewOriginal = lyrics.text;
      this.previewTranslation = lyrics.translation;
      this.previewTranslationWarning = lyrics.translationWarning;
      if (lyrics.text.trim().length > 0 && lyrics.translation.trim().length > 0) {
        const combined: BilingualLyricsResult = combineCloudLyrics(lyrics.text, lyrics.translation);
        this.previewBilingual = combined.text; this.previewBilingualWarning = combined.warning; this.previewBilingualError = combined.error;
      }
      this.status = lyrics.text.trim().length === 0 ? '平台暂无可用原文；仅有译文可供预览，确认不会写入文件。' :
        '仅供预览；请人工确认，确认不会写入文件。';
    } catch (error) {
      this.requireActive(op); this.clearPreview(); this.status = '歌词预览失败，请重新选择并重试。'; throw error as Error;
    } finally { this.finish(op); }
  }

  /** Returns an in-memory draft only after an explicit call; no file is created or modified. */
  confirmPreview(kind: MissingLyricsKind): ConfirmedLyricsDraft {
    if (kind !== 'original' && kind !== 'translation' && kind !== 'bilingual') throw new Error('歌词版本无效。');
    if (this.busy || this.searchRowId.length === 0 || this.selectedKey.length === 0) throw new Error('请先完成候选预览。');
    const chosen: CloudSongCandidate | undefined = this.candidates.find((item: CloudSongCandidate): boolean => key(item.song) === this.selectedKey);
    if (chosen === undefined) throw new Error('候选已失效，请重新搜索。');
    const text: string = kind === 'translation' ? this.previewTranslation :
      (kind === 'bilingual' ? this.previewBilingual : this.previewOriginal);
    if (text.trim().length === 0) throw new Error('所选歌词不可用，请选择其他版本。');
    this.row(this.searchRowId);
    return { rowId: this.searchRowId, source: chosen.song.source, songId: chosen.song.id, kind: kind, text: text };
  }
}
