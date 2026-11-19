import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Foreground-only audio preview. The caller supplies an application-private
 * working copy, not a user-selected URI. Each session owns a separate read-only
 * fd until AVPlayer has released it. Call close() when leaving the editor or
 * backgrounding the ability; never use this class for modifying audio.
 *
 * Consumers may poll snapshot() and seek, but MediaKit events have no request
 * identity and may be stale or duplicated. A resolved seek() only reports an
 * observed event; it cannot establish position or identify a calibration point.
 * An actual playback position used for calibration requires user confirmation.
 */
export interface PreviewSnapshot {
  state: string;
  positionMs: number;
  durationMs: number;
  error: string;
}

type PreviewStateCallback = (state: string) => void;
type PreviewCancel = () => void;
type PreviewCleanupErrorCallback = (message: string, retry: () => Promise<void>) => void;

class LatePreviewPlayer {
  player: media.AVPlayer;
  releasePromise: Promise<void> | undefined = undefined;
  constructor(player: media.AVPlayer) { this.player = player; }
}

export class LocalAudioPreview {
  // One process-wide owner, including factories which have not yet resolved.
  private static owner: LocalAudioPreview | undefined = undefined;
  private generation: number = 0;
  private queue: Promise<void> = Promise.resolve();
  private player: media.AVPlayer | undefined = undefined;
  private file: fileIo.File | undefined = undefined;
  private closeUncertain: boolean = false;
  private releasePromise: Promise<void> | undefined = undefined;
  private cancelWait: PreviewCancel | undefined = undefined;
  private stateCallback: PreviewStateCallback | undefined = undefined;
  private cleanupErrorCallback: PreviewCleanupErrorCallback | undefined = undefined;
  private stateListener: ((state: media.AVPlayerState, reason: media.StateChangeReason) => void) | undefined = undefined;
  private errorListener: ((error: BusinessError) => void) | undefined = undefined;
  private prepareState: ((state: media.AVPlayerState) => void) | undefined = undefined;
  private prepareError: PreviewCancel | undefined = undefined;
  private lastError: string = '';
  // A failed seek may still emit a late, indistinguishable event.
  private seekBlocked: boolean = false;
  private latePlayers: LatePreviewPlayer[] = [];
  private pendingFactories: number = 0;
  private closingRequested: boolean = false;
  private static readonly TIMEOUT_MS: number = 10000;

  setStateCallback(callback: PreviewStateCallback | undefined): void {
    this.stateCallback = callback;
  }

  /** Independent of UI state listeners; may fire after close when creation resolves late. */
  setCleanupErrorCallback(callback: PreviewCleanupErrorCallback | undefined): void {
    this.cleanupErrorCallback = callback;
  }

  private notify(state: string): void {
    if (this.stateCallback !== undefined) {
      try { this.stateCallback(state); } catch (_error) { /* UI callback cannot break cleanup. */ }
    }
  }

  private enqueue(operation: () => Promise<void>): Promise<void> {
    const result: Promise<void> = this.queue.then(operation);
    this.queue = result.catch((_error: Error): void => {});
    return result;
  }

  private invalidate(): number {
    this.generation++;
    if (this.cancelWait !== undefined) this.cancelWait();
    return this.generation;
  }

  private assertCurrent(ticket: number): void {
    if (ticket !== this.generation) throw new Error('试听请求已取消。');
  }

  private releaseOwnershipIfIdle(): void {
    if (LocalAudioPreview.owner === this && !this.closeUncertain && this.pendingFactories === 0 &&
        this.player === undefined && this.file === undefined && this.latePlayers.length === 0) {
      LocalAudioPreview.owner = undefined;
    }
  }

  private async acquireOwnership(ticket: number): Promise<void> {
    let previous: LocalAudioPreview | undefined = LocalAudioPreview.owner;
    if (previous !== undefined && previous !== this && previous.closingRequested) {
      // Only a session already asked to close may be retried by a new page.
      await previous.close();
    }
    this.assertCurrent(ticket);
    previous = LocalAudioPreview.owner;
    if (previous !== undefined && previous !== this) {
      if (previous.closeUncertain) throw new Error('上次试听句柄状态不明，请重启应用。');
      throw new Error('上次试听仍在使用或释放中，请等待后重试。');
    }
    if (this.closeUncertain) throw new Error('试听文件句柄关闭状态不明，请重启应用。');
    if (this.pendingFactories > 0 || this.latePlayers.length > 0) {
      throw new Error('上次试听仍在释放中，请等待后重试。');
    }
    LocalAudioPreview.owner = this;
    this.closingRequested = false;
  }

  private static checkPrivatePath(path: string, filesDir: string): void {
    const root: string = filesDir.endsWith('/') ? filesDir.substring(0, filesDir.length - 1) : filesDir;
    const segments: string[] = path.split('/');
    const rootSegments: string[] = root.split('/');
    const leaf: string = path.startsWith(root + '/') ? path.substring(root.length + 1) : '';
    if (root.length < 2 || !root.startsWith('/') || !path.startsWith(root + '/') ||
        path.indexOf('://') >= 0 || path.indexOf('\\') >= 0 || root.indexOf('\\') >= 0 ||
        path.indexOf('\u0000') >= 0 || root.indexOf('\u0000') >= 0 ||
        segments.indexOf('.') >= 0 || segments.indexOf('..') >= 0 || rootSegments.indexOf('') !== 0 ||
        rootSegments.slice(1).indexOf('') >= 0 ||
        !/^lyricflow_work_\d+_[a-z0-9]{1,8}\.[a-z0-9]{1,8}$/.test(leaf)) {
      throw new Error('试听只接受 filesDir 直接子项中的应用音频工作副本。');
    }
  }

  /** A cancelled factory may still resolve; retain failures so close can retry. */
  private releaseLate(record: LatePreviewPlayer): Promise<void> {
    if (record.releasePromise !== undefined) return record.releasePromise;
    try {
      record.releasePromise = record.player.release().then((): void => {
        const index: number = this.latePlayers.indexOf(record);
        if (index >= 0) this.latePlayers.splice(index, 1);
        this.releaseOwnershipIfIdle();
      }).catch((_error: Error): void => {
        record.releasePromise = undefined;
        throw new Error('取消的试听播放器未能释放，请再次关闭。');
      });
      return record.releasePromise;
    } catch (_error) {
      return Promise.reject(new Error('取消的试听播放器未能释放，请再次关闭。'));
    }
  }

  private async releaseLatePlayers(): Promise<void> {
    for (const record of this.latePlayers.slice()) {
      let timer: number = -1;
      try {
        await Promise.race<void>([this.releaseLate(record), new Promise<void>((_resolve: () => void, reject: (reason: Error) => void): void => {
          timer = setTimeout((): void => reject(new Error('取消的试听播放器释放超时，请再次关闭。')), LocalAudioPreview.TIMEOUT_MS);
        })]);
      } finally { if (timer >= 0) clearTimeout(timer); }
    }
  }

  /** Player creation may complete after cancellation: release that late player. */
  private createPlayer(ticket: number): Promise<media.AVPlayer> {
    return new Promise<media.AVPlayer>((resolve: (value: media.AVPlayer) => void, reject: (reason: Error) => void): void => {
      let done: boolean = false;
      const finishError = (message: string): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        if (this.cancelWait === cancel) this.cancelWait = undefined;
        reject(new Error(message));
      };
      const cancel: PreviewCancel = (): void => finishError('试听请求已取消。');
      const timer: number = setTimeout((): void => finishError('创建试听播放器超时。'), LocalAudioPreview.TIMEOUT_MS);
      this.cancelWait = cancel;
      this.pendingFactories++;
      try {
        media.createAVPlayer().then((created: media.AVPlayer): void => {
          this.pendingFactories--;
          if (done || ticket !== this.generation) {
            // No file is open yet. A late-created player is still released.
            const record: LatePreviewPlayer = new LatePreviewPlayer(created);
            this.latePlayers.push(record);
            this.releaseLate(record).catch((_error: Error): void => {
              this.lastError = '取消的试听播放器未能释放，请再次关闭。';
              this.notify('cleanupError');
              const callback: PreviewCleanupErrorCallback | undefined = this.cleanupErrorCallback;
              if (callback !== undefined) {
                try {
                  callback('取消的试听播放器未能释放，请重试释放播放器。', (): Promise<void> => this.releaseLate(record));
                } catch (_callbackError) { /* Keep the unreleased record for a later close. */ }
              }
            });
            return;
          }
          done = true;
          clearTimeout(timer);
          if (this.cancelWait === cancel) this.cancelWait = undefined;
          resolve(created);
        }).catch((_error: Error): void => {
          this.pendingFactories--;
          finishError('创建试听播放器失败。');
          this.releaseOwnershipIfIdle();
        });
      } catch (_error) {
        this.pendingFactories--;
        finishError('创建试听播放器失败。');
        this.releaseOwnershipIfIdle();
      }
    });
  }

  private waitOperation(operation: Promise<void>, ticket: number, description: string): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      let done: boolean = false;
      const finish = (error: string): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        if (this.cancelWait === cancel) this.cancelWait = undefined;
        if (error.length > 0) reject(new Error(error)); else resolve();
      };
      const cancel: PreviewCancel = (): void => finish('试听请求已取消。');
      const timer: number = setTimeout((): void => finish(description + '超时。'), LocalAudioPreview.TIMEOUT_MS);
      this.cancelWait = cancel;
      operation.then((): void => {
        if (ticket !== this.generation) finish('试听请求已取消。'); else finish('');
      }).catch((_error: Error): void => finish(description + '失败。'));
    });
  }

  private waitInitialized(player: media.AVPlayer, ticket: number, fd: number, length: number): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      let done: boolean = false;
      const finish = (error: string): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        if (this.cancelWait === cancel) this.cancelWait = undefined;
        if (error.length > 0) reject(new Error(error)); else resolve();
      };
      const cancel: PreviewCancel = (): void => finish('试听请求已取消。');
      const timer: number = setTimeout((): void => finish('初始化试听播放器超时。'), LocalAudioPreview.TIMEOUT_MS);
      this.cancelWait = cancel;
      this.stateListener = (state: media.AVPlayerState, _reason: media.StateChangeReason): void => {
        if (this.player !== player || ticket !== this.generation) return;
        this.notify(state);
        if (state === 'initialized') finish('');
        else if (state === 'error' || state === 'released') finish('初始化试听播放器失败。');
        if (this.prepareState !== undefined) this.prepareState(state);
      };
      this.errorListener = (error: BusinessError): void => {
        if (this.player !== player || ticket !== this.generation) return;
        this.lastError = '播放器错误 ' + String(error.code);
        this.notify('error');
        finish('初始化试听播放器失败。');
        if (this.prepareError !== undefined) this.prepareError();
      };
      try {
        player.on('stateChange', this.stateListener);
        player.on('error', this.errorListener);
        player.fdSrc = { fd, offset: 0, length };
        if (player.state === 'initialized') finish('');
      } catch (_error) { finish('设置试听音频失败。'); }
    });
  }

  /** Wait for the prepared state, not just the API promise's completion. */
  private waitPrepared(player: media.AVPlayer, ticket: number): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      let done: boolean = false;
      const finish = (error: string): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        if (this.cancelWait === cancel) this.cancelWait = undefined;
        if (this.prepareState === onState) this.prepareState = undefined;
        if (this.prepareError === onError) this.prepareError = undefined;
        if (error.length > 0) reject(new Error(error)); else resolve();
      };
      const cancel: PreviewCancel = (): void => finish('试听请求已取消。');
      const onError: PreviewCancel = (): void => finish('准备试听失败。');
      const onState = (state: media.AVPlayerState): void => {
        if (ticket !== this.generation) finish('试听请求已取消。');
        else if (state === 'prepared') finish('');
        else if (state === 'error' || state === 'released') finish('准备试听失败。');
      };
      const timer: number = setTimeout((): void => finish('准备试听超时。'), LocalAudioPreview.TIMEOUT_MS);
      this.cancelWait = cancel;
      this.prepareState = onState;
      this.prepareError = onError;
      try {
        player.prepare().then((): void => {
          if (ticket !== this.generation) finish('试听请求已取消。');
          else if (player.state === 'prepared') finish('');
        }).catch((_error: Error): void => finish('准备试听失败。'));
        if (player.state === 'prepared') finish('');
      } catch (_error) { finish('准备试听失败。'); }
    });
  }

  /** Release player first; retain the owned fd if release has not succeeded. */
  private async releaseOwned(): Promise<void> {
    if (this.closeUncertain) throw new Error('试听文件句柄关闭状态不明，不能安全重试；请重启应用。');
    const player: media.AVPlayer | undefined = this.player;
    if (player !== undefined) {
      if (this.releasePromise === undefined) this.releasePromise = player.release();
      const inFlight: Promise<void> = this.releasePromise;
      let timer: number = -1;
      let timedOut: boolean = false;
      try {
        await Promise.race<void>([inFlight, new Promise<void>((_resolve: () => void, reject: (reason: Error) => void): void => {
          timer = setTimeout((): void => {
            timedOut = true;
            reject(new Error('释放试听播放器超时，资源仍保留以便重试。'));
          }, LocalAudioPreview.TIMEOUT_MS);
        })]);
      } catch (error) {
        // Keep the same in-flight promise on timeout; otherwise a caller can retry release.
        if (!timedOut) this.releasePromise = undefined;
        throw error as Error;
      } finally { if (timer >= 0) clearTimeout(timer); }
      this.player = undefined;
      this.releasePromise = undefined;
      try { player.off('stateChange', this.stateListener); } catch (_error) {}
      try { player.off('error', this.errorListener); } catch (_error) {}
      this.stateListener = undefined;
      this.errorListener = undefined;
      this.prepareState = undefined;
      this.prepareError = undefined;
      this.seekBlocked = false;
    }
    const file: fileIo.File | undefined = this.file;
    if (file !== undefined) {
      // closeSync failure does not document whether the fd remained open. It
      // may already have been reused; never close that bare number twice.
      this.file = undefined;
      try { fileIo.closeSync(file.fd); }
      catch (_error) {
        this.closeUncertain = true;
        throw new Error('试听文件句柄关闭状态不明，不能安全重试；请重启应用。');
      }
    }
  }

  /** Replace any current session; only a private, already-imported copy is accepted. */
  open(path: string, filesDir: string): Promise<void> {
    LocalAudioPreview.checkPrivatePath(path, filesDir);
    const ticket: number = this.invalidate();
    return this.enqueue(async (): Promise<void> => {
      if (LocalAudioPreview.owner === this) this.closingRequested = true;
      await this.releaseOwned();
      await this.releaseLatePlayers();
      await this.acquireOwnership(ticket);
      try {
        this.assertCurrent(ticket);
        this.lastError = '';
        const created: media.AVPlayer = await this.createPlayer(ticket);
        this.player = created;
        this.assertCurrent(ticket);
        const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
        this.file = file;
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        const pathStat: fileIo.Stat = fileIo.lstatSync(path);
        if (!stat.isFile() || !pathStat.isFile() || stat.ino !== pathStat.ino ||
            !Number.isSafeInteger(stat.size) || stat.size <= 0) throw new Error('试听文件身份无效或已变化。');
        await this.waitInitialized(created, ticket, file.fd, stat.size);
        this.assertCurrent(ticket);
        await this.waitPrepared(created, ticket);
        this.assertCurrent(ticket);
        if (created.state !== 'prepared') throw new Error('播放器未就绪。');
      } catch (error) {
        this.closingRequested = true;
        try { await this.releaseOwned(); await this.releaseLatePlayers(); this.releaseOwnershipIfIdle(); }
        catch (releaseError) { throw releaseError as Error; }
        throw error as Error;
      }
    });
  }

  play(): Promise<void> {
    const ticket: number = this.generation;
    return this.enqueue(async (): Promise<void> => {
      this.assertCurrent(ticket);
      if (this.closingRequested) throw new Error('试听正在关闭或释放失败，请先完成关闭。');
      const p: media.AVPlayer | undefined = this.player;
      if (p === undefined || ['prepared', 'paused', 'completed'].indexOf(p.state) < 0) throw new Error('当前状态不能开始试听。');
      await this.waitOperation(p.play(), ticket, '开始试听');
    });
  }

  pause(): Promise<void> {
    const ticket: number = this.generation;
    return this.enqueue(async (): Promise<void> => {
      this.assertCurrent(ticket);
      if (this.closingRequested) throw new Error('试听正在关闭或释放失败，请先完成关闭。');
      const p: media.AVPlayer | undefined = this.player;
      if (p === undefined || p.state !== 'playing') throw new Error('当前状态不能暂停试听。');
      await this.waitOperation(p.pause(), ticket, '暂停试听');
    });
  }

  /** An uncorrelated seekDone is only an observation, never a confirmed anchor. */
  seek(positionMs: number): Promise<void> {
    const ticket: number = this.generation;
    return this.enqueue(async (): Promise<void> => {
      this.assertCurrent(ticket);
      if (this.closingRequested) throw new Error('试听正在关闭或释放失败，请先完成关闭。');
      const p: media.AVPlayer | undefined = this.player;
      if (p === undefined || ['prepared', 'playing', 'paused', 'completed'].indexOf(p.state) < 0) throw new Error('当前状态不能定位试听。');
      if (this.seekBlocked) throw new Error('上次定位未确认，请重新打开试听。');
      if (!Number.isSafeInteger(positionMs) || positionMs < 0 || !Number.isFinite(p.duration) || p.duration <= 0 || positionMs > p.duration) {
        throw new Error('试听定位时间超出音频范围。');
      }
      await this.waitSeek(p, ticket, positionMs);
    });
  }

  private waitSeek(player: media.AVPlayer, ticket: number, positionMs: number): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      let done: boolean = false;
      const finish = (error: string, value: number): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        if (this.cancelWait === cancel) this.cancelWait = undefined;
        if (this.prepareState === onState) this.prepareState = undefined;
        if (this.prepareError === onError) this.prepareError = undefined;
        try { player.off('seekDone', onSeekDone); } catch (_error) {}
        if (error.length > 0) {
          this.seekBlocked = true;
          reject(new Error(error));
        } else resolve();
      };
      const cancel: PreviewCancel = (): void => finish('试听请求已取消。', 0);
      const onError: PreviewCancel = (): void => finish('试听定位失败。', 0);
      const onState = (state: media.AVPlayerState): void => {
        if (state === 'error' || state === 'released') finish('试听定位失败。', 0);
      };
      const onSeekDone = (actualMs: number): void => {
        if (ticket !== this.generation || this.player !== player) finish('试听请求已取消。', 0);
        else if (!Number.isSafeInteger(actualMs) || actualMs < 0 || actualMs > player.duration) finish('试听定位结果无效。', 0);
        else finish('', actualMs);
      };
      const timer: number = setTimeout((): void => finish('试听定位超时，请重新打开试听。', 0), LocalAudioPreview.TIMEOUT_MS);
      this.cancelWait = cancel;
      this.prepareState = onState;
      this.prepareError = onError;
      try {
        player.on('seekDone', onSeekDone);
        player.seek(positionMs, media.SeekMode.SEEK_CLOSEST);
      } catch (_error) { finish('试听定位失败。', 0); }
    });
  }

  snapshot(): PreviewSnapshot {
    const p: media.AVPlayer | undefined = this.player;
    if (p === undefined) return { state: 'idle', positionMs: 0, durationMs: 0, error: this.lastError };
    return { state: p.state, positionMs: Number.isFinite(p.currentTime) && p.currentTime >= 0 ? p.currentTime : 0,
      durationMs: Number.isFinite(p.duration) && p.duration > 0 ? p.duration : 0, error: this.lastError };
  }

  /** Cancel an in-flight open/control and release before closing its private fd. */
  close(): Promise<void> {
    this.closingRequested = true;
    this.invalidate();
    return this.enqueue(async (): Promise<void> => {
      await this.releaseOwned(); await this.releaseLatePlayers(); this.releaseOwnershipIfIdle();
    });
  }
}
