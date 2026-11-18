// SPDX-License-Identifier: GPL-3.0-only
/* Experimental app-private staging only. GPL-3.0-only.
 * CREATE here is NOT an OS-level exclusive-create primitive. The fixed file
 * lives under a freshly created private directory; concurrent untrusted code
 * in the same app, provider URIs, and public publication are outside scope. */
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AsfReadStream, AsfStageStream, AsfExclusiveStage, AsfStageFactory } from './AsfStreamingExport';

function requireCondition(ok: boolean, reason: string): void { if (!ok) { throw new Error(reason); } }
function seekExact(fd: number, offset: number): void {
  requireCondition(Number.isSafeInteger(offset) && offset >= 0 &&
    fileIo.lseek(fd, offset, fileIo.WhenceType.SEEK_SET) === offset, 'seek failed');
}
function sameFile(a: fileIo.Stat, b: fileIo.Stat): boolean {
  return a.isFile() && b.isFile() && a.ino.toString() !== '0' && a.ino === b.ino;
}
function timeKey(stat: fileIo.Stat): string {
  const m: string = stat.mtimeNs === undefined ? String(stat.mtime) : stat.mtimeNs.toString();
  const c: string = stat.ctimeNs === undefined ? String(stat.ctime) : stat.ctimeNs.toString();
  return stat.ino.toString() + ':' + stat.size.toString() + ':' + m + ':' + c;
}
function syncDirectory(dir: string): void {
  const handle: fileIo.File = fileIo.openSync(dir, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.DIR | fileIo.OpenMode.NOFOLLOW);
  try { fileIo.fsyncSync(handle.fd); } finally { fileIo.closeSync(handle.fd); }
}

function removeProvenEmptyDirectory(dir: string, ino: bigint): void {
  const current: fileIo.Stat = fileIo.lstatSync(dir);
  requireCondition(current.isDirectory() && current.ino === ino && ino.toString() !== '0', 'temporary directory identity changed');
  requireCondition(fileIo.listFileSync(dir).length === 0, 'temporary directory not empty');
  // CoreFileKit rmdir is recursive. This depends on the app-private,
  // no-malicious-same-app-writer assumption documented in the class contract.
  fileIo.rmdirSync(dir);
}
/** A local regular source only. Call close() after all users of its fd finish. */
export class AsfPrivateSource implements AsfReadStream {
  private sourcePath: string;
  private file: fileIo.File;
  private closed: boolean = false;
  constructor(path: string) {
    requireCondition(path.startsWith('/') && path.indexOf('://') < 0 && path.indexOf('\0') < 0, 'local source path required');
    this.sourcePath = path;
    const entry: fileIo.Stat = fileIo.lstatSync(path);
    requireCondition(entry.isFile() && entry.ino.toString() !== '0', 'source is not a regular file');
    this.file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    try { requireCondition(sameFile(entry, fileIo.statSync(this.file.fd)), 'source identity changed on open'); }
    catch (error) { fileIo.closeSync(this.file.fd); this.closed = true; throw new Error('source open verification failed: ' + String(error)); }
  }
  path(): string { return this.sourcePath; }
  fileDescriptor(): number { requireCondition(!this.closed, 'source closed'); return this.file.fd; }
  size(): number { requireCondition(!this.closed, 'source closed'); return fileIo.statSync(this.file.fd).size; }
  snapshotToken(): string {
    requireCondition(!this.closed, 'source closed');
    const opened: fileIo.Stat = fileIo.statSync(this.file.fd); const entry: fileIo.Stat = fileIo.lstatSync(this.sourcePath);
    requireCondition(sameFile(opened, entry), 'source path or identity changed');
    requireCondition(timeKey(opened) === timeKey(entry), 'source state differs from path');
    return timeKey(opened);
  }
  readAt(offset: number, maxLength: number): Uint8Array {
    requireCondition(!this.closed && Number.isSafeInteger(maxLength) && maxLength > 0 && maxLength <= 1024 * 1024, 'read size outside limit');
    seekExact(this.file.fd, offset);
    const buf: ArrayBuffer = new ArrayBuffer(maxLength);
    const count: number = fileIo.readSync(this.file.fd, buf, { length: maxLength });
    requireCondition(Number.isInteger(count) && count >= 0 && count <= maxLength, 'invalid read result');
    return new Uint8Array(buf, 0, count);
  }
  close(): void { if (!this.closed) { fileIo.closeSync(this.file.fd); this.closed = true; } }
}

class PrivateStageStream implements AsfStageStream {
  private file: fileIo.File;
  private stagePath: string;
  private closed: boolean = false;
  constructor(file: fileIo.File, path: string) { this.file = file; this.stagePath = path; }
  path(): string { return this.stagePath; }
  fileDescriptor(): number { requireCondition(!this.closed, 'stage closed'); return this.file.fd; }
  size(): number { return fileIo.statSync(this.fileDescriptor()).size; }
  snapshotToken(): string { return timeKey(fileIo.statSync(this.fileDescriptor())); }
  readAt(offset: number, maxLength: number): Uint8Array {
    requireCondition(Number.isSafeInteger(maxLength) && maxLength > 0 && maxLength <= 1024 * 1024, 'read size outside limit');
    seekExact(this.fileDescriptor(), offset);
    const buf: ArrayBuffer = new ArrayBuffer(maxLength);
    const count: number = fileIo.readSync(this.fileDescriptor(), buf, { length: maxLength });
    requireCondition(Number.isInteger(count) && count >= 0 && count <= maxLength, 'invalid read result');
    return new Uint8Array(buf, 0, count);
  }
  writeAt(offset: number, data: Uint8Array): number {
    requireCondition(data.length > 0 && data.length <= 1024 * 1024, 'write size outside limit');
    seekExact(this.fileDescriptor(), offset);
    const buf: ArrayBuffer = new ArrayBuffer(data.length); new Uint8Array(buf).set(data);
    const count: number = fileIo.writeSync(this.fileDescriptor(), buf, { length: data.length });
    requireCondition(Number.isInteger(count) && count >= 0 && count <= data.length, 'invalid write result'); return count;
  }
  flush(): void { fileIo.fsyncSync(this.fileDescriptor()); }
  close(): void { if (!this.closed) { fileIo.closeSync(this.file.fd); this.closed = true; } }
  isClosed(): boolean { return this.closed; }
}

/** Ownership checks use the private directory and inode; not safe against malicious same-app races. */
class PrivateStage implements AsfExclusiveStage {
  readonly stream: PrivateStageStream;
  readonly dir: string;
  readonly path: string;
  private dirId: bigint;
  private fileId: bigint;
  private finished: boolean = false;
  private discarded: boolean = false;
  constructor(dir: string, path: string, dirId: bigint, fileId: bigint, stream: PrivateStageStream) {
    this.dir=dir; this.path=path; this.dirId=dirId; this.fileId=fileId; this.stream=stream;
  }
  recoveryPath(): string { return this.discarded ? '' : this.dir; }
  private checkDir(): void {
    const stat: fileIo.Stat = fileIo.lstatSync(this.dir);
    requireCondition(stat.isDirectory() && stat.ino.toString() !== '0' && stat.ino === this.dirId, 'stage directory identity changed');
  }
  private checkFile(): void {
    const stat: fileIo.Stat = fileIo.lstatSync(this.path);
    requireCondition(stat.isFile() && stat.ino.toString() !== '0' && stat.ino === this.fileId, 'stage file identity changed');
  }
  finishPrivateStage(): void {
    requireCondition(!this.finished && !this.discarded && this.stream.isClosed(), 'invalid stage state');
    this.checkDir(); this.checkFile(); syncDirectory(this.dir); this.finished=true;
  }
  close(): void { this.stream.close(); }
  discardPrivateStage(): void {
    requireCondition(!this.finished && !this.discarded && this.stream.isClosed(), 'cannot discard stage');
    this.checkDir(); this.checkFile(); fileIo.unlinkSync(this.path);
    this.checkDir(); requireCondition(fileIo.listFileSync(this.dir).length === 0, 'stage directory is not empty');
    // rmdirSync is recursive. Only use after checking this task's newly created,
    // empty directory; malicious same-app races remain outside this contract.
    fileIo.rmdirSync(this.dir); this.discarded=true;
  }
  cleanupReady(): void {
    requireCondition(this.finished && !this.discarded && this.stream.isClosed(), 'stage not ready for cleanup');
    this.checkDir(); const entries: string[] = fileIo.listFileSync(this.dir);
    if (entries.length === 1 && entries[0] === 'candidate.wma') {
      this.checkFile(); fileIo.unlinkSync(this.path);
    } else {
      requireCondition(entries.length === 0, 'stage directory contains unowned entries');
    }
    removeProvenEmptyDirectory(this.dir, this.dirId); this.discarded = true;
  }
  readyPath(): string {
    requireCondition(this.finished && !this.discarded && this.stream.isClosed(), 'stage not closed and ready');
    this.checkDir(); this.checkFile(); return this.path;
  }
}

/** Creates one private stage. `filesDir` must be a trusted application filesDir. */
export class AsfPrivateStageFactory implements AsfStageFactory {
  private filesDir: string;
  private stage: PrivateStage | null = null;
  private pendingDirectory: string = '';
  constructor(filesDir: string) {
    requireCondition(filesDir.length > 1 && filesDir.startsWith('/') && filesDir.indexOf('://') < 0 && filesDir.indexOf('\0') < 0 &&
      filesDir.indexOf('/../') < 0 && !filesDir.endsWith('/..'), 'trusted local filesDir required');
    this.filesDir = filesDir.endsWith('/') ? filesDir.substring(0, filesDir.length - 1) : filesDir;
    requireCondition(fileIo.lstatSync(this.filesDir).isDirectory(), 'filesDir is not a directory');
  }
  createExclusivePrivateStage(): AsfExclusiveStage {
    requireCondition(this.stage === null && this.pendingDirectory.length === 0, 'factory already used or recovery pending');
    const prefix: string = this.filesDir + '/asf-stage-';
    let dir: string = '';
    try { dir = fileIo.mkdtempSync(prefix + 'XXXXXX'); }
    catch (error) {
      let code: number = NaN;
      if (error !== null && error !== undefined) { code = (error as BusinessError).code; }
      const suffix: string = Number.isSafeInteger(code) ? ' code=' + code.toString() : '';
      throw new Error('ASF_STAGE_CREATE_MKDTEMP failed' + suffix);
    }
    const suffix: string = dir.startsWith(prefix) ? dir.substring(prefix.length) : '';
    if (!/^[^\/\\\\\x00-\x1f\x7f]{6}$/.test(suffix)) {
      throw new Error('unexpected temporary directory; untrusted path retained');
    }
    this.pendingDirectory = dir;
    let directory: fileIo.Stat | null = null;
    try {
      directory = fileIo.lstatSync(dir);
      requireCondition(directory.isDirectory() && directory.ino.toString() !== '0', 'invalid temporary directory');
      requireCondition(fileIo.listFileSync(dir).length === 0, 'temporary directory not empty');
    } catch (error) {
      let state: string = 'retained';
      if (directory !== null && directory.isDirectory() && directory.ino.toString() !== '0') {
        try { removeProvenEmptyDirectory(dir, directory.ino); state = 'removed'; this.pendingDirectory = ''; }
        catch (cleanupError) { state = 'retained; cleanup failed: ' + String(cleanupError); }
      }
      throw new Error('private directory verification failed: ' + String(error) + '; directory ' + state + ': ' + dir);
    }
    if (directory === null) { throw new Error('private directory state unavailable; retained: ' + dir); }
    const path: string = dir + '/candidate.wma';
    let file: fileIo.File;
    try { file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW); }
    catch (error) {
      let state: string = 'retained';
      try { removeProvenEmptyDirectory(dir, directory.ino); state = 'removed'; this.pendingDirectory = ''; }
      catch (cleanupError) { state = 'retained; cleanup failed: ' + String(cleanupError); }
      throw new Error('private stage creation failed: ' + String(error) + '; directory ' + state + ': ' + dir);
    }
    try {
      const fdStat: fileIo.Stat = fileIo.statSync(file.fd); const entry: fileIo.Stat = fileIo.lstatSync(path);
      requireCondition(sameFile(fdStat, entry) && fdStat.size === 0, 'invalid new stage file');
      this.stage = new PrivateStage(dir, path, directory.ino, fdStat.ino, new PrivateStageStream(file, path));
      this.pendingDirectory = '';
      return this.stage;
    } catch (error) {
      // Do not unlink an object whose identity/ownership failed verification.
      let closeStatus: string = '';
      try { fileIo.closeSync(file.fd); } catch (closeError) { closeStatus = '; close failed: ' + String(closeError); }
      throw new Error('stage identity verification failed; stage directory retained: ' + dir + ': ' + String(error) + closeStatus);
    }
  }
  readyPrivatePath(): string {
    requireCondition(this.stage !== null, 'no stage');
    if (this.stage === null) { throw new Error('no stage'); } return this.stage.readyPath();
  }
  /** Return the recorded directory without doing filesystem I/O. */
  recoveryPrivateDir(): string { return this.stage === null ? this.pendingDirectory : this.stage.recoveryPath(); }
  /** After working-copy replacement or cancellation, remove only this private stage. */
  cleanupReadyPrivateStage(): void {
    requireCondition(this.stage !== null, 'no stage');
    if (this.stage === null) { throw new Error('no stage'); } this.stage.cleanupReady();
  }
}








