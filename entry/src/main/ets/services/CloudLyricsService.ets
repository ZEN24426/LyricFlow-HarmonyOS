import { http } from '@kit.NetworkKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { CloudSong } from './CloudSongMatcher';
import { CLOUD_SOURCE, MAX_CLOUD_RESPONSE_BYTES, CloudLyrics, CloudLyricsError, CloudSearchResult,
  cloudBodyWithinLimit, parseCloudSearch, parseCloudLyrics } from './CloudLyricsProtocol';

export { CloudLyrics, CloudLyricsError, CloudSearchResult } from './CloudLyricsProtocol';

const API_ORIGIN: string = 'https://music.163.com';
const CACHE_TTL_MS: number = 10 * 60 * 1000;
const REQUEST_INTERVAL_MS: number = 500;

interface SearchCacheEntry {
  at: number;
  songs: CloudSong[];
  incomplete: boolean;
}

interface LyricsCacheEntry {
  at: number;
  lyrics: CloudLyrics;
}

class CloudOperation {
  cancelled: boolean = false;
  private handlers: Array<() => void> = [];

  assertActive(): void {
    if (this.cancelled) throw new CloudLyricsError('CANCELLED', '已取消云端请求。');
  }

  cancel(): void {
    this.cancelled = true;
    const handlers: Array<() => void> = this.handlers.slice();
    this.handlers = [];
    for (const handler of handlers) handler();
  }

  async waitFor<T>(pending: Promise<T>): Promise<T> {
    this.assertActive();
    return new Promise<T>((resolve, reject) => {
      const abort: () => void = (): void => {
        reject(new CloudLyricsError('CANCELLED', '已取消云端请求。'));
      };
      this.handlers.push(abort);
      pending.then((value: T): void => {
        this.remove(abort);
        if (this.cancelled) reject(new CloudLyricsError('CANCELLED', '已取消云端请求。'));
        else resolve(value);
      }, (error: Error): void => {
        this.remove(abort);
        reject(this.cancelled ? new CloudLyricsError('CANCELLED', '已取消云端请求。') : error);
      });
    });
  }

  async delay(ms: number): Promise<void> {
    this.assertActive();
    if (ms <= 0) return;
    return new Promise<void>((resolve, reject) => {
      const timer: number = setTimeout((): void => {
        this.remove(abort);
        resolve();
      }, ms);
      const abort: () => void = (): void => {
        clearTimeout(timer);
        reject(new CloudLyricsError('CANCELLED', '已取消云端请求。'));
      };
      this.handlers.push(abort);
    });
  }

  private remove(handler: () => void): void {
    const index: number = this.handlers.indexOf(handler);
    if (index >= 0) this.handlers.splice(index, 1);
  }
}

function cloneSong(song: CloudSong): CloudSong {
  return { source: song.source, id: song.id, title: song.title, artists: song.artists.slice(),
    album: song.album, durationMs: song.durationMs };
}

function cloneLyrics(lyrics: CloudLyrics): CloudLyrics {
  return { text: lyrics.text, translation: lyrics.translation, translationWarning: lyrics.translationWarning,
    source: lyrics.source, songId: lyrics.songId };
}

/** Anonymous, explicit user-triggered searches; never receives audio bytes or device file paths. */
export class CloudLyricsService {
  // A single process-wide gate prevents separate pages from bypassing the
  // platform interval. Cancellation still belongs to each service instance.
  private static requestQueue: Promise<void> = Promise.resolve();
  private static lastGlobalRequestAt: number = -1;
  private static cooldownUntil: number = 0;
  private operations: CloudOperation[] = [];
  private active: http.HttpRequest | undefined = undefined;
  private queue: Promise<void> = Promise.resolve();
  private searches: Map<string, SearchCacheEntry> = new Map<string, SearchCacheEntry>();
  private lyricCache: Map<string, LyricsCacheEntry> = new Map<string, LyricsCacheEntry>();

  cancel(): void {
    const current: CloudOperation[] = this.operations.slice();
    this.operations = [];
    this.queue = Promise.resolve();
    const active: http.HttpRequest | undefined = this.active;
    this.active = undefined;
    if (active !== undefined) {
      try { active.destroy(); } catch (_error) {}
    }
    for (const operation of current) operation.cancel();
  }

  // For display-only consumers; recommendation decisions must use the
  // completeness flag returned by searchDetailed().
  async search(keyword: string): Promise<CloudSong[]> {
    return (await this.searchDetailed(keyword)).songs;
  }

  async searchDetailed(keyword: string): Promise<CloudSearchResult> {
    const normalized: string = keyword.trim().replace(/\s+/g, ' ');
    if (normalized.length === 0) return { songs: [], incomplete: false };
    if (normalized.length > 160 || /[\u0000-\u001f]/.test(normalized)) {
      throw new CloudLyricsError('INVALID_REQUEST', '搜索关键词过长或含无效字符。');
    }
    const operation: CloudOperation = this.start();
    const leave: () => void = await this.enter(operation);
    try {
      operation.assertActive();
      const cached: SearchCacheEntry | undefined = this.searches.get(normalized);
      if (cached !== undefined && Date.now() - cached.at < CACHE_TTL_MS) {
        return { songs: cached.songs.map(cloneSong), incomplete: cached.incomplete };
      }
      const url: string = API_ORIGIN + '/api/search/get/web?s=' + encodeURIComponent(normalized) + '&type=1&limit=20&offset=0';
      const result: CloudSearchResult = parseCloudSearch(await this.request(url, operation));
      operation.assertActive();
      this.searches.delete(normalized);
      if (this.searches.size >= 24) this.searches.delete(this.searches.keys().next().value);
      this.searches.set(normalized, { at: Date.now(), songs: result.songs.map(cloneSong), incomplete: result.incomplete });
      return { songs: result.songs, incomplete: result.incomplete };
    } finally { leave(); this.finish(operation); }
  }

  async lyrics(song: CloudSong): Promise<CloudLyrics> {
    if (song.source !== CLOUD_SOURCE || !/^[1-9][0-9]{0,19}$/.test(song.id)) {
      throw new CloudLyricsError('INVALID_REQUEST', '歌曲来源或歌曲 ID 无效，请重新搜索。');
    }
    const id: string = song.id;
    const operation: CloudOperation = this.start();
    const leave: () => void = await this.enter(operation);
    try {
      operation.assertActive();
      const cached: LyricsCacheEntry | undefined = this.lyricCache.get(id);
      if (cached !== undefined && Date.now() - cached.at < CACHE_TTL_MS) return cloneLyrics(cached.lyrics);
      const url: string = API_ORIGIN + '/api/song/lyric?id=' + id + '&lv=-1&kv=-1&tv=-1&rv=-1';
      const lyrics: CloudLyrics = parseCloudLyrics(await this.request(url, operation), id);
      operation.assertActive();
      this.lyricCache.delete(id);
      if (this.lyricCache.size >= 8) this.lyricCache.delete(this.lyricCache.keys().next().value);
      this.lyricCache.set(id, { at: Date.now(), lyrics: cloneLyrics(lyrics) });
      return lyrics;
    } finally { leave(); this.finish(operation); }
  }

  private start(): CloudOperation {
    const operation: CloudOperation = new CloudOperation();
    this.operations.push(operation);
    return operation;
  }

  private finish(operation: CloudOperation): void {
    const index: number = this.operations.indexOf(operation);
    if (index >= 0) this.operations.splice(index, 1);
  }

  private async enter(operation: CloudOperation): Promise<() => void> {
    const previous: Promise<void> = this.queue;
    let release: () => void = (): void => {};
    const held: Promise<void> = new Promise<void>((resolve) => { release = resolve; });
    this.queue = previous.then((): Promise<void> => held);
    try {
      await operation.waitFor(previous);
      operation.assertActive();
      return release;
    } catch (error) {
      release();
      this.finish(operation);
      throw error as Error;
    }
  }

  private async enterGlobal(operation: CloudOperation): Promise<() => void> {
    const previous: Promise<void> = CloudLyricsService.requestQueue;
    let release: () => void = (): void => {};
    const held: Promise<void> = new Promise<void>((resolve) => { release = resolve; });
    // Even if this waiter is cancelled, later waiters must still wait for the
    // earlier request to finish before they can reach our released slot.
    CloudLyricsService.requestQueue = previous.then((): Promise<void> => held);
    try {
      await operation.waitFor(previous);
      operation.assertActive();
      return release;
    } catch (error) {
      release();
      throw error as Error;
    }
  }

  private static monotonicMs(): number {
    const value: number = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
    if (!Number.isFinite(value) || value < 0) throw new CloudLyricsError('NETWORK', '系统计时不可用，已停止云端请求。');
    return value;
  }

  private async request(url: string, operation: CloudOperation): Promise<string> {
    for (let attempt: number = 0; attempt < 3; attempt++) {
      operation.assertActive();
      const releaseGlobal: () => void = await this.enterGlobal(operation);
      let client: http.HttpRequest | undefined = undefined;
      let retry: boolean = false;
      try {
        let now: number = CloudLyricsService.monotonicMs();
        let deadline: number = Math.max(CloudLyricsService.cooldownUntil,
          CloudLyricsService.lastGlobalRequestAt < 0 ? 0 : CloudLyricsService.lastGlobalRequestAt + REQUEST_INTERVAL_MS);
        while (now < deadline) {
          await operation.delay(deadline - now);
          operation.assertActive();
          now = CloudLyricsService.monotonicMs();
          deadline = Math.max(CloudLyricsService.cooldownUntil,
            CloudLyricsService.lastGlobalRequestAt < 0 ? 0 : CloudLyricsService.lastGlobalRequestAt + REQUEST_INTERVAL_MS);
        }
        operation.assertActive();
        client = http.createHttp();
        this.active = client;
        CloudLyricsService.lastGlobalRequestAt = CloudLyricsService.monotonicMs();
        const response: http.HttpResponse = await operation.waitFor(client.request(url, {
          method: http.RequestMethod.GET,
          header: { 'Accept': 'application/json', 'Referer': API_ORIGIN + '/' },
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 10000,
          readTimeout: 10000,
          maxLimit: MAX_CLOUD_RESPONSE_BYTES,
          maxRedirects: 0,
          remoteValidation: 'system',
          usingCache: false
        }));
        operation.assertActive();
        if (response.responseCode === 429 || response.responseCode === 503) {
          CloudLyricsService.cooldownUntil = Math.max(CloudLyricsService.cooldownUntil,
            CloudLyricsService.monotonicMs() + (attempt + 1) * 1000);
          if (attempt === 2) throw new CloudLyricsError('RATE_LIMIT', '云端请求过于频繁或服务繁忙，请稍后重试。');
          retry = true;
        } else {
          if (response.responseCode !== 200) throw new CloudLyricsError('REJECTED', '云端拒绝请求或暂不可用，请稍后重试。');
          if (typeof response.result !== 'string') throw new CloudLyricsError('FORMAT_CHANGED', '云端返回了无法识别的数据。');
          if (!cloudBodyWithinLimit(response.result)) throw new CloudLyricsError('TOO_LARGE', '云端响应超过 2 MiB，已停止读取。');
          return response.result;
        }
      } catch (error) {
        operation.assertActive();
        if (error instanceof CloudLyricsError) throw error;
        const code: number = Number((error as BusinessError).code);
        if (code === 2300063) throw new CloudLyricsError('TOO_LARGE', '云端响应超过 2 MiB，已停止读取。');
        if (code === 2300047 || code === 2300009 || code === 2300094 || code === 201 || code === 2300998) {
          throw new CloudLyricsError('REJECTED', '云端请求被拒绝，未跟随重定向或使用登录凭据。');
        }
        retry = code === 2300006 || code === 2300007 || code === 2300016 || code === 2300018 ||
          code === 2300028 || code === 2300052 || code === 2300055 || code === 2300056;
        if (!retry || attempt === 2) throw new CloudLyricsError('NETWORK', '网络请求失败，请检查连接后重试。');
      } finally {
        if (client !== undefined) {
          if (this.active === client) this.active = undefined;
          try { client.destroy(); } catch (_error) {}
        }
        releaseGlobal();
      }
      if (retry) await operation.delay((attempt + 1) * 1000);
    }
    throw new CloudLyricsError('NETWORK', '网络请求失败，请稍后重试。');
  }
}
