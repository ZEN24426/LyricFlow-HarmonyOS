import { CloudSong } from './CloudSongMatcher';

// Independently implemented from the public response shapes documented by:
// https://github.com/jitwxs/163MusicLyrics/blob/883e3c2507d4fa8144e531a7e9f8df7636bf53d0/cross-platform/MusicLyricApp/Core/Service/Music/NetEaseMusicNativeApi.cs
// The anonymous API is not an officially supported third-party API contract.
export const CLOUD_SOURCE: string = 'netease';
export const MAX_CLOUD_RESPONSE_BYTES: number = 2 * 1024 * 1024;
const MAX_LYRIC_CHARS: number = 256 * 1024;

export interface CloudSearchResult {
  songs: CloudSong[];
  incomplete: boolean;
}

export interface CloudLyrics {
  text: string;
  translation: string;
  translationWarning: string;
  source: string;
  songId: string;
}

export class CloudLyricsError extends Error {
  kind: string;

  constructor(kind: string, message: string) {
    super(message);
    this.name = 'CloudLyricsError';
    this.kind = kind;
  }
}

interface RawArtist {
  name?: string;
}

interface RawAlbum {
  name?: string;
}

interface RawSong {
  id?: number | string;
  name?: string;
  artists?: RawArtist[];
  ar?: RawArtist[];
  album?: RawAlbum;
  al?: RawAlbum;
  duration?: number;
  dt?: number;
}

interface RawSearchResult {
  songCount?: number;
  songs?: RawSong[];
}

interface RawSearchResponse {
  code?: number;
  result?: RawSearchResult;
}

interface RawLyric {
  lyric?: string;
}

interface RawLyricsResponse {
  code?: number;
  nolyric?: boolean;
  uncollected?: boolean;
  lrc?: RawLyric;
  tlyric?: RawLyric;
}

function formatError(): CloudLyricsError {
  return new CloudLyricsError('FORMAT_CHANGED', '云端返回格式异常或接口已变更，请稍后重试。');
}

export function cloudBodyWithinLimit(text: string): boolean {
  let bytes: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code < 0x80) bytes++;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length &&
      text.charCodeAt(i + 1) >= 0xDC00 && text.charCodeAt(i + 1) <= 0xDFFF) {
      bytes += 4;
      i++;
    } else bytes += 3;
    if (bytes > MAX_CLOUD_RESPONSE_BYTES) return false;
  }
  return true;
}

function checkBody(text: string): void {
  if (!cloudBodyWithinLimit(text)) {
    throw new CloudLyricsError('TOO_LARGE', '云端响应超过 2 MiB，已停止读取。');
  }
  if (text.trim().length === 0) throw formatError();
}

function checkPlatformCode(code: number | undefined): void {
  if (typeof code !== 'number' || !Number.isInteger(code)) throw formatError();
  if (code !== 200) {
    if (code === 429 || code === 503) {
      throw new CloudLyricsError('RATE_LIMIT', '云端暂时限制请求，请稍后重试。');
    }
    throw new CloudLyricsError('REJECTED', '云端拒绝了匿名请求，可能需要登录或当前地区不可用。');
  }
}

function boundedText(text: string | undefined, max: number, required: boolean): string {
  if (text === undefined && !required) return '';
  if (typeof text !== 'string' || text.length > max || text.indexOf('\u0000') >= 0) throw formatError();
  const result: string = text.trim();
  if (required && result.length === 0) throw formatError();
  return result;
}

function songId(value: number | string | undefined): string {
  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value) || value <= 0) throw formatError();
    return String(value);
  }
  if (typeof value !== 'string' || !/^[1-9][0-9]{0,19}$/.test(value)) throw formatError();
  return value;
}

function parseSong(raw: RawSong): CloudSong {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) throw formatError();
  const id: string = songId(raw.id);
  const title: string = boundedText(raw.name, 512, true);
  const artists: RawArtist[] | undefined = raw.artists !== undefined ? raw.artists : raw.ar;
  if (!Array.isArray(artists) || artists.length === 0 || artists.length > 32) throw formatError();
  const names: string[] = [];
  for (const artist of artists) {
    if (artist === null || typeof artist !== 'object' || Array.isArray(artist)) throw formatError();
    names.push(boundedText(artist.name, 256, true));
  }
  const album: RawAlbum | undefined = raw.album !== undefined ? raw.album : raw.al;
  if (album !== undefined && (album === null || typeof album !== 'object' || Array.isArray(album))) throw formatError();
  const duration: number | undefined = raw.duration !== undefined ? raw.duration : raw.dt;
  if (duration !== undefined && (typeof duration !== 'number' || !Number.isFinite(duration) ||
    duration < 0 || duration > 24 * 60 * 60 * 1000 || !Number.isInteger(duration))) throw formatError();
  return {
    source: CLOUD_SOURCE, id: id, title: title, artists: names,
    album: album === undefined ? '' : boundedText(album.name, 512, false), durationMs: duration === undefined ? 0 : duration
  };
}

function sameSongMetadata(left: CloudSong, right: CloudSong): boolean {
  if (left.title !== right.title || left.album !== right.album || left.durationMs !== right.durationMs ||
    left.artists.length !== right.artists.length) return false;
  for (let i: number = 0; i < left.artists.length; i++) {
    if (left.artists[i] !== right.artists[i]) return false;
  }
  return true;
}

export function parseCloudSearch(text: string): CloudSearchResult {
  checkBody(text);
  let raw: RawSearchResponse;
  try { raw = JSON.parse(text) as RawSearchResponse; } catch (_error) { throw formatError(); }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) throw formatError();
  checkPlatformCode(raw.code);
  const result: RawSearchResult | undefined = raw.result;
  if (result === undefined || result === null || typeof result !== 'object' || Array.isArray(result)) throw formatError();
  if (result.songCount !== undefined && (typeof result.songCount !== 'number' ||
    !Number.isSafeInteger(result.songCount) || result.songCount < 0)) throw formatError();
  if (result.songs === undefined && result.songCount === 0) return { songs: [], incomplete: false };
  if (!Array.isArray(result.songs) || result.songs.length > 200) throw formatError();
  const songs: CloudSong[] = [];
  const seen: Map<string, CloudSong> = new Map<string, CloudSong>();
  // Contradictory counts must not turn a partial response into a confident
  // recommendation. A normal paginated response may still report more hits.
  let incomplete: boolean = result.songs.length > 20 ||
    (result.songCount !== undefined && (result.songCount < result.songs.length ||
      (result.songCount > 0 && result.songs.length === 0)));
  const count: number = Math.min(result.songs.length, 20);
  for (let i: number = 0; i < count; i++) {
    try {
      // Preserve duplicates until the matcher can retain the one with better evidence.
      const song: CloudSong = parseSong(result.songs[i]);
      const previous: CloudSong | undefined = seen.get(song.id);
      if (previous === undefined) seen.set(song.id, song);
      else if (!sameSongMetadata(previous, song)) incomplete = true;
      songs.push(song);
    } catch (error) {
      if (error instanceof CloudLyricsError && error.kind === 'FORMAT_CHANGED') {
        incomplete = true;
      } else {
        throw error as Error;
      }
    }
  }
  if (count > 0 && songs.length === 0) throw formatError();
  return { songs, incomplete };
}

function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|amp|lt|gt|quot|apos);/g,
    (match: string, entity: string): string => {
      if (entity === 'amp') return '&';
      if (entity === 'lt') return '<';
      if (entity === 'gt') return '>';
      if (entity === 'quot') return '"';
      if (entity === 'apos') return "'";
      const value: number = entity.startsWith('#x') ? parseInt(entity.substring(2), 16) : parseInt(entity.substring(1), 10);
      return value > 0 && value <= 0x10FFFF && (value < 0xD800 || value > 0xDFFF) ? String.fromCodePoint(value) : match;
    });
}

function lyricText(raw: RawLyric | undefined): string {
  if (raw === undefined || raw === null) return '';
  if (typeof raw !== 'object' || Array.isArray(raw)) throw formatError();
  return decodeEntities(boundedText(raw.lyric, MAX_LYRIC_CHARS, false));
}

function isPureMusicNotice(line: string): boolean {
  const clean: string = line.replace(/[\s，,。.!！:：;；、~～\[\]()（）]/g, '').toUpperCase();
  return clean === '纯音乐请欣赏' || clean === '此歌曲为没有填词的纯音乐请您欣赏' ||
    clean === '此歌曲为纯音乐请欣赏' || clean === 'INSTRUMENTALPLEASEENJOY';
}

function lyricContentLine(line: string): string {
  // Time stamps and known LRC metadata only; [合唱] and other bracketed lyrics remain content.
  return line.trim().replace(/^(?:\s*(?:\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]|\[(?:ar|ti|al|by|offset|re|ve|length|id|tool|source|language|total):[^\]]*\]))+\s*/i, '').trim();
}

function isPureMusicPlaceholder(text: string): boolean {
  const lines: string[] = text.split(/\r\n|\r|\n/);
  let hasNotice: boolean = false;
  for (let i: number = 0; i < lines.length; i++) {
    // Only strip time tags and known whole-line metadata. Bracketed lyric lines
    // such as [合唱] must remain evidence that the payload has real content.
    const line: string = lyricContentLine(lines[i]);
    if (line.length === 0) continue;
    if (isPureMusicNotice(line)) {
      hasNotice = true;
      continue;
    }
    // A delimiter and credit value are required: ordinary lyric lines that
    // happen to begin with a role word must never be treated as metadata.
    if (/^(?:作词|词曲|词|作曲|曲|编曲|编配|制作人|制作|录音|混音|母带|监制|演奏|配器|吉他|钢琴|鼓|弦乐|和声|人声|版权|版权方|copyright|composed|arranged|produced|mastered)(?:\s*[\/／&、]\s*(?:作词|词|作曲|曲|编曲|制作|录音|混音|母带|监制|演奏|配器))*\s*[:：]\s*\S.*$/i.test(line)) continue;
    return false;
  }
  return hasNotice;
}

function lyricBody(text: string): string {
  return text.split(/\r\n|\r|\n/).map((line: string): string => lyricContentLine(line)).join('\n').trim();
}

function isUnavailableText(text: string): boolean {
  const clean: string = lyricBody(text).replace(/[\s，,。.!！:：\[\]]/g, '').toUpperCase();
  return clean.length === 0 || clean === '暂无歌词' || clean === '歌词暂缺' || clean === '暂时没有歌词' ||
    clean === '暂无歌词敬请期待' || clean === '此歌曲暂无歌词' || clean === '没有歌词' ||
    clean === 'NOLYRICS' || clean === 'NOLYRIC' || clean === 'NOLYRICSFOUND';
}

function checkLyricPayload(text: string): void {
  const body: string = lyricBody(text);
  if (/^\s*<(?:!doctype|html|head|body|script|div|iframe)\b/i.test(body) ||
    /^\s*[{\[]\s*"(?:code|error|message)"/.test(body)) throw formatError();
}

export function parseCloudLyrics(text: string, id: string): CloudLyrics {
  checkBody(text);
  const checkedId: string = songId(id);
  let raw: RawLyricsResponse;
  try { raw = JSON.parse(text) as RawLyricsResponse; } catch (_error) { throw formatError(); }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) throw formatError();
  checkPlatformCode(raw.code);
  if ((raw.nolyric !== undefined && typeof raw.nolyric !== 'boolean') ||
    (raw.uncollected !== undefined && typeof raw.uncollected !== 'boolean')) throw formatError();
  if (raw.nolyric === true) throw new CloudLyricsError('PURE_MUSIC', '这首歌被平台标记为纯音乐。');
  if (raw.uncollected === true) throw new CloudLyricsError('NO_LYRICS', '平台暂未收录这首歌的歌词。');
  // A missing lrc field is allowed for translation-only responses, but an
  // explicitly malformed original must not be concealed by its translation.
  if (raw.lrc === null) throw formatError();
  const lyric: string = lyricText(raw.lrc);
  checkLyricPayload(lyric);
  if (isPureMusicPlaceholder(lyric)) throw new CloudLyricsError('PURE_MUSIC', '这首歌的返回内容为纯音乐提示。');
  const originalUnavailable: boolean = isUnavailableText(lyric);
  let translation: string = '';
  let translationWarning: string = '';
  try {
    translation = lyricText(raw.tlyric);
    checkLyricPayload(translation);
    if (isUnavailableText(translation) || isPureMusicPlaceholder(translation)) translation = '';
  } catch (error) {
    if (error instanceof CloudLyricsError && error.kind === 'FORMAT_CHANGED') {
      // With no valid original, a corrupt translation is an error rather than
      // evidence that the provider has no lyrics at all.
      if (originalUnavailable) throw error as Error;
      translation = '';
      translationWarning = '云端译文数据异常，暂时只能使用原文。';
    } else {
      throw error as Error;
    }
  }
  if (originalUnavailable && translation.length === 0) {
    if (raw.lrc === undefined && raw.tlyric === undefined && raw.nolyric === undefined && raw.uncollected === undefined) throw formatError();
    throw new CloudLyricsError('NO_LYRICS', '平台暂无可用的原文或译文歌词。');
  }
  return { text: originalUnavailable ? '' : lyric, translation: translation, translationWarning: translationWarning, source: CLOUD_SOURCE, songId: checkedId };
}
