import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { AudioMetadata, AudioMetadataWriter } from '@dabing/taglib_harmony';
import { AudioMetadataService } from './AudioMetadataService';
import { ExportService, SavedExport } from './ExportService';
import { verifyWrittenMetadata, verifyPreservedMetadata } from './MetadataVerification';
import { verifyFlacIntegrity } from './FlacIntegrity';
import { verifyId3Integrity } from './Id3Integrity';
import { writeMp3MetadataCopy } from './Mp3DirectWriter';
import { beginDirectWrite, clearDirectWrite } from './DirectWriteJournal';
import { acquireDirectWriteGuard, DirectWriteGuard } from './DirectWriteGuard';

export interface DirectWriteReport {
  backupPath: string;
  originalPath: string;
  originalBytes: number;
  externalBackupName: string;
  externalBackupUri: string;
}

const BLOCK: number = 256 * 1024;

function errorMessage(error: Object): string {
  return error instanceof Error ? error.message : String(error);
}

function checkFormat(sourceName: string): string {
  if (!/\.(mp3|flac)$/i.test(sourceName)) {
    throw new Error('直写目前仅支持 MP3 和 FLAC。');
  }
  return sourceName.toLowerCase().endsWith('.flac') ? '.flac' : '.mp3';
}

function checkedSize(fd: number): number {
  const info: fileIo.Stat = fileIo.statSync(fd);
  if (!info.isFile() || !Number.isSafeInteger(info.size) || info.size <= 0) {
    throw new Error('所选音频不是可用的普通文件，或文件大小无效。');
  }
  return info.size;
}

// Recheck that the selected URI still resolves to the file we opened. The SDK
// exposes inode but not the device identifier, so this is a conservative
// change detector, not a proof against every provider or cross-mount alias.
function assertSelectedFileUnchanged(sourceUri: string, fd: number): void {
  const opened: fileIo.Stat = fileIo.statSync(fd);
  const selected: fileIo.Stat = fileIo.statSync(sourceUri);
  const openedId: string = opened.ino.toString();
  const selectedId: string = selected.ino.toString();
  if (!selected.isFile() || openedId === '0' || selectedId === '0' || openedId !== selectedId) {
    throw new Error('所选文件的位置或身份已变化，无法安全继续直写。');
  }
}

function seekTo(fd: number, position: number): void {
  if (!Number.isSafeInteger(position) || position < 0 ||
      fileIo.lseek(fd, position, fileIo.WhenceType.SEEK_SET) !== position) {
    throw new Error('此文件不支持可靠的随机定位，已取消直写。');
  }
}

function syncDirectory(path: string): void {
  const dir: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.DIR);
  try { fileIo.fsyncSync(dir.fd); } finally { fileIo.closeSync(dir.fd); }
}

async function assertFlacSignature(fd: number): Promise<void> {
  if (fileIo.statSync(fd).size < 4) throw new Error('文件过小，不是有效的 FLAC 音频。');
  const signature: Uint8Array = new Uint8Array(await readRange(fd, 0, 4));
  if (signature[0] !== 0x66 || signature[1] !== 0x4c || signature[2] !== 0x61 || signature[3] !== 0x43) {
    throw new Error('文件内容不是标准 FLAC，已取消直写。');
  }
}

async function assertFormatSignature(fd: number, extension: string): Promise<void> {
  if (extension === '.flac') return await assertFlacSignature(fd);
  if (fileIo.statSync(fd).size < 10) throw new Error('文件过小，不是受支持的 MP3。');
  const header: Uint8Array = new Uint8Array(await readRange(fd, 0, 4));
  if (header[0] !== 0x49 || header[1] !== 0x44 || header[2] !== 0x33 ||
      (header[3] !== 3 && header[3] !== 4)) {
    throw new Error('仅支持包含 ID3v2.3 或 ID3v2.4 标签的 MP3 直写。');
  }
}

/** Read exactly the requested region; short reads are handled without assuming EOF. */
async function readRange(fd: number, position: number, length: number): Promise<ArrayBuffer> {
  const result: Uint8Array = new Uint8Array(length);
  let done: number = 0;
  while (done < length) {
    const part: ArrayBuffer = new ArrayBuffer(length - done);
    seekTo(fd, position + done);
    const count: number = await fileIo.read(fd, part, { length: length - done });
    if (count <= 0 || count > length - done) {
      throw new Error('读取文件时提前结束，文件可能已发生变化。');
    }
    result.set(new Uint8Array(part, 0, count), done);
    done += count;
  }
  return result.buffer as ArrayBuffer;
}

async function writeRange(fd: number, position: number, data: ArrayBuffer): Promise<void> {
  let done: number = 0;
  while (done < data.byteLength) {
    const part: ArrayBuffer = data.slice(done);
    seekTo(fd, position + done);
    const count: number = await fileIo.write(fd, part, { length: part.byteLength });
    if (count <= 0 || count > part.byteLength) {
      throw new Error('写入文件失败，数据未完整写入。');
    }
    done += count;
  }
}

/** Copy to an already-open destination. The caller owns both handles. */
async function copyHandles(sourceFd: number, destinationFd: number): Promise<number> {
  if (sourceFd === destinationFd) throw new Error('拒绝将文件复制到自身。');
  const length: number = checkedSize(sourceFd);
  // Confirm seekability before performing any writes.
  seekTo(sourceFd, 0);
  seekTo(destinationFd, 0);
  let position: number = 0;
  while (position < length) {
    const count: number = Math.min(BLOCK, length - position);
    const data: ArrayBuffer = await readRange(sourceFd, position, count);
    await writeRange(destinationFd, position, data);
    position += count;
  }
  if (fileIo.statSync(sourceFd).size !== length) {
    throw new Error('复制期间源文件大小发生变化。');
  }
  // Truncate only after the complete new content has been written. A failure
  // here still requires recovery because bytes may already have changed.
  fileIo.truncateSync(destinationFd, length);
  fileIo.fsyncSync(destinationFd);
  if (fileIo.statSync(destinationFd).size !== length) {
    throw new Error('写入后文件大小校验失败。');
  }
  return length;
}

async function handlesIdentical(leftFd: number, rightFd: number): Promise<boolean> {
  if (leftFd === rightFd) return true;
  const leftSize: number = fileIo.statSync(leftFd).size;
  const rightSize: number = fileIo.statSync(rightFd).size;
  if (!Number.isSafeInteger(leftSize) || leftSize < 0 || leftSize !== rightSize) return false;
  let position: number = 0;
  while (position < leftSize) {
    const count: number = Math.min(BLOCK, leftSize - position);
    const left: Uint8Array = new Uint8Array(await readRange(leftFd, position, count));
    const right: Uint8Array = new Uint8Array(await readRange(rightFd, position, count));
    for (let i: number = 0; i < count; i++) {
      if (left[i] !== right[i]) return false;
    }
    position += count;
  }
  return fileIo.statSync(leftFd).size === leftSize && fileIo.statSync(rightFd).size === rightSize;
}

function closeFile(file: fileIo.File | undefined): void {
  if (file !== undefined) {
    try { fileIo.closeSync(file.fd); } catch (_error) {}
  }
}

function sourceDisplayPath(sourceUri: string): string {
  try { return new fileUri.FileUri(sourceUri).path; } catch (_error) { return sourceUri; }
}

async function openSelectedForWrite(sourceUri: string): Promise<fileIo.File> {
  try {
    return await fileIo.open(sourceUri, fileIo.OpenMode.READ_WRITE);
  } catch (error) {
    throw new Error('无法读写所选文件；授权可能已失效，请重新选择音频并检查文件权限：' + errorMessage(error as Object));
  }
}

export class DirectAudioWriteService {
  static async probe(context: common.UIAbilityContext, sourceUri: string, sourceName: string): Promise<string> {
    const extension: string = checkFormat(sourceName);
    const guard: DirectWriteGuard = acquireDirectWriteGuard(context);
    let source: fileIo.File | undefined = undefined;
    let sourceLocked: boolean = false;
    try {
      source = await openSelectedForWrite(sourceUri);
      source.tryLock(true);
      sourceLocked = true;
      assertSelectedFileUnchanged(sourceUri, source.fd);
      checkedSize(source.fd);
      seekTo(source.fd, 0);
      await assertFormatSignature(source.fd, extension);
      fileIo.fsyncSync(source.fd);
      return '所选文件读写打开、协作锁和随机定位检测通过；尚未修改音频。';
    } catch (error) {
      throw new Error('无法安全访问所选音频：' + errorMessage(error as Object));
    } finally {
      if (sourceLocked && source !== undefined) {
        try { source.unlock(); } catch (_error) {}
      }
      closeFile(source);
      guard.release();
    }
  }

  static async writeMetadataInPlace(
    context: common.UIAbilityContext,
    sourceUri: string,
    sourceName: string,
    fields: AudioMetadataWriter,
    importedSnapshotPath: string
  ): Promise<DirectWriteReport> {
    const extension: string = checkFormat(sourceName);
    const guard: DirectWriteGuard = acquireDirectWriteGuard(context);
    let source: fileIo.File | undefined = undefined;
    let backup: fileIo.File | undefined = undefined;
    let work: fileIo.File | undefined = undefined;
    let importedSnapshot: fileIo.File | undefined = undefined;
    let backupPath: string = '';
    let workPath: string = '';
    let tempDir: string = '';
    let workCreated: boolean = false;
    let visibleBackup: SavedExport | undefined = undefined;
    let commitStarted: boolean = false;
    let backupVerified: boolean = false;
    let sourceLocked: boolean = false;
    let journalActive: boolean = false;
    let journalOperationId: string = '';
    let committed: boolean = false;
    try {
      // This single descriptor is the source of the backup, the commit target,
      // the readback target and, if necessary, the rollback target.
      source = await openSelectedForWrite(sourceUri);
      // Advisory locks coordinate only with cooperating writers. Refuse a
      // provider that cannot acquire one, and still recheck source bytes.
      source.tryLock(true);
      sourceLocked = true;
      assertSelectedFileUnchanged(sourceUri, source.fd);
      const originalBytes: number = checkedSize(source.fd);
      seekTo(source.fd, 0);
      await assertFormatSignature(source.fd, extension);
      if (importedSnapshotPath.length === 0) {
        throw new Error('缺少导入时的文件快照，请重新选择音频。');
      }
      importedSnapshot = await fileIo.open(importedSnapshotPath, fileIo.OpenMode.READ_ONLY);
      if (!(await handlesIdentical(source.fd, importedSnapshot.fd))) {
        throw new Error('原音频在导入后发生变化，请重新选择音频并检查内容后再直写。');
      }
      closeFile(importedSnapshot);
      importedSnapshot = undefined;
      // A provider without fd synchronization cannot support the required
      // verified commit/restore protocol; fail before changing original data.
      fileIo.fsyncSync(source.fd);

      // mkdtemp creates a new directory exclusively in the private sandbox;
      // only files created inside this directory are owned by this operation.
      const privateRoot: string = (context.filesDir.endsWith('/')
        ? context.filesDir.substring(0, context.filesDir.length - 1) : context.filesDir);
      tempDir = fileIo.mkdtempSync(privateRoot + '/lyricflow_direct_XXXXXX');
      backupPath = tempDir + '/original' + extension;
      workPath = tempDir + '/edited' + extension;
      backup = await fileIo.open(backupPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      await copyHandles(source.fd, backup.fd);
      if (!(await handlesIdentical(source.fd, backup.fd))) {
        throw new Error('备份期间源文件发生变化，未修改源文件。');
      }
      // Persist both the backup entry and its newly created parent entry before
      // the recovery journal can authorize a source modification.
      syncDirectory(tempDir);
      syncDirectory(privateRoot);
      backupVerified = true;
      const before: AudioMetadata = await AudioMetadataService.readForDirect(backupPath, privateRoot);

      const safeName: string = AudioMetadataService.safeOutputName(sourceName, '');
      const backupName: string = 'LyricFlow_backup_' + Date.now().toString() + '_' +
        Math.random().toString(36).slice(2, 10) + '_' + safeName;
      visibleBackup = await ExportService.saveDirectBackup(context, backupName, backupPath);
      if (visibleBackup === undefined) {
        throw new Error('没有取得可见备份保存位置，已取消直写。');
      }
      if (visibleBackup.size !== originalBytes ||
          !(await AudioMetadataService.filesIdentical(backupPath, visibleBackup.uri))) {
        throw new Error('可见备份的逐字节校验失败，已取消直写。');
      }

      work = await fileIo.open(workPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      workCreated = true;
      await copyHandles(backup.fd, work.fd);
      if (!(await handlesIdentical(backup.fd, work.fd))) {
        throw new Error('工作副本校验失败，已取消直写。');
      }
      closeFile(work);
      closeFile(importedSnapshot);
      work = undefined;
      // Both writers receive only an app-owned staging file, never a user URI.
      if (extension === '.mp3') {
        const editedPath: string = await writeMp3MetadataCopy(privateRoot, workPath, fields);
        const editedDir: string = editedPath.substring(0, editedPath.lastIndexOf('/'));
        try {
          fileIo.renameSync(editedPath, workPath);
        } finally {
          try { fileIo.unlinkSync(editedPath); } catch (_error) {}
          try { fileIo.rmdirSync(editedDir); } catch (_error) {}
        }
      } else {
        await AudioMetadataService.write(workPath, fields);
      }
      const actual: AudioMetadata = await AudioMetadataService.readForDirect(workPath, privateRoot);
      await verifyWrittenMetadata(fields, actual);
      await verifyPreservedMetadata(fields, before, actual);
      if (extension === '.mp3') await verifyId3Integrity(backupPath, workPath, fields);
      else await verifyFlacIntegrity(backupPath, workPath, fields);
      work = await fileIo.open(workPath, fileIo.OpenMode.READ_ONLY);
      checkedSize(work.fd);
      if (!(await handlesIdentical(source.fd, backup.fd))) {
        throw new Error('备份后源文件发生变化，已取消直写。');
      }
      // Flush a durable recovery reminder before any original byte is changed.
      journalOperationId = await beginDirectWrite(context, guard, sourceName, sourceUri, visibleBackup.name);
      journalActive = true;
      assertSelectedFileUnchanged(sourceUri, source.fd);
      if (!(await handlesIdentical(source.fd, backup.fd))) {
        throw new Error('写入前源文件发生变化，已取消直写。');
      }
      // The checked source descriptor remains open throughout. This prevents a
      // pathname/URI mix-up; advisory locking cannot stop non-cooperating
      // writers or make the operation atomic across crash or power failure.
      commitStarted = true;
      await copyHandles(work.fd, source.fd);
      if (!(await handlesIdentical(work.fd, source.fd))) {
        throw new Error('写入后逐字节回读与工作副本不一致。');
      }
      assertSelectedFileUnchanged(sourceUri, source.fd);
      committed = true;
      await clearDirectWrite(context, guard, journalOperationId);
      journalActive = false;
      // The durable external backup is the user-visible recovery copy. Only
      // after a verified commit and journal clear, recheck that copy before
      // disposing of this operation's private duplicate. Any uncertainty keeps
      // the private backup; cleanup failures never turn a commit into failure.
      try {
        if (await AudioMetadataService.filesIdentical(backupPath, visibleBackup.uri)) {
          closeFile(work);
          work = undefined;
          if (workCreated) {
            try { fileIo.unlinkSync(workPath); workCreated = false; } catch (_workError) {}
          }
          closeFile(backup);
          backup = undefined;
          fileIo.unlinkSync(backupPath);
          backupPath = '';
          try { fileIo.rmdirSync(tempDir); } catch (_dirError) {}
        }
      } catch (_cleanupError) {}
      return {
        backupPath: backupPath,
        originalPath: sourceDisplayPath(sourceUri),
        originalBytes: originalBytes,
        externalBackupName: visibleBackup.name,
        externalBackupUri: visibleBackup.uri
      };
    } catch (error) {
      if (committed) {
        throw new Error('音频写入和回读校验已完成，但恢复提醒未能清除：' +
          errorMessage(error as Object) + '。可见备份：' +
          (visibleBackup !== undefined ? visibleBackup.name : '未生成') + '。');
      }
      if (commitStarted && source !== undefined && backup !== undefined && backupVerified) {
        let restored: boolean = false;
        try {
          await copyHandles(backup.fd, source.fd);
          restored = await handlesIdentical(backup.fd, source.fd);
          if (restored) assertSelectedFileUnchanged(sourceUri, source.fd);
        } catch (_restoreError) {
          restored = false;
        }
        let clearFailure: string = '';
        if (restored && journalActive) {
          try {
            await clearDirectWrite(context, guard, journalOperationId);
            journalActive = false;
          } catch (journalError) {
            clearFailure = ' 恢复提醒未能清除：' + errorMessage(journalError as Object) + '。';
          }
        }
        const externalName: string = visibleBackup !== undefined ? visibleBackup.name : '未生成';
        throw new Error('直写失败：' + errorMessage(error as Object) +
          (restored ? '。已恢复并逐字节校验原文件。' : '。自动恢复未能确认成功，请停止操作。') +
          ' 可见备份：' + externalName + '；应用内备份：' + backupPath + clearFailure);
      }
      let pendingNote: string = '';
      if (journalActive && !commitStarted) {
        try {
          await clearDirectWrite(context, guard, journalOperationId);
          journalActive = false;
        } catch (journalError) {
          pendingNote = ' 恢复提醒未能清除：' + errorMessage(journalError as Object) + '。';
        }
      }
      const visibleName: string = visibleBackup !== undefined ? visibleBackup.name : '';
      throw new Error('直写未开始：' + errorMessage(error as Object) +
        (visibleName.length > 0 ? ' 可见备份：' + visibleName + '。' : '') + pendingNote);
    } finally {
      closeFile(work);
      closeFile(backup);
      closeFile(importedSnapshot);
      if (sourceLocked && source !== undefined) {
        try { source.unlock(); } catch (_error) {}
      }
      closeFile(source);
      // Never remove a source or backup. Only the private working file is ours.
      if (workCreated && workPath.length > 0) {
        try { fileIo.unlinkSync(workPath); } catch (_error) {}
      }
      guard.release();
    }
  }
}
