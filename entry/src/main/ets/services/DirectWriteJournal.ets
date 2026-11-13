import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { acquireDirectWriteGuard, DirectWriteGuard } from './DirectWriteGuard';

export interface PendingDirectWrite {
  operationId: string;
  sourceName: string;
  sourceUri: string;
  externalBackupName: string;
}

const ENTRY_NAME: string = 'lyricflow_direct_write.pending.json';
const MAX_JOURNAL_SIZE: number = 16 * 1024;
let persistenceUncertain: boolean = false;

function rootPath(context: common.UIAbilityContext): string {
  return context.filesDir.endsWith('/')
    ? context.filesDir.substring(0, context.filesDir.length - 1) : context.filesDir;
}

function journalPath(context: common.UIAbilityContext): string {
  return rootPath(context) + '/' + ENTRY_NAME;
}

/** Persist directory entry changes; unsupported providers fail closed. */
function syncDirectory(path: string): void {
  const dir: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.DIR);
  try {
    fileIo.fsyncSync(dir.fd);
  } finally {
    fileIo.closeSync(dir.fd);
  }
}

function pendingFromText(text: string): PendingDirectWrite {
  let pending: PendingDirectWrite;
  try {
    pending = JSON.parse(text) as PendingDirectWrite;
  } catch (_error) {
    throw new Error('直写恢复记录无法解析，请检查备份和原文件。');
  }
  if (pending === null || typeof pending !== 'object' ||
      typeof pending.operationId !== 'string' ||
      !/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(pending.operationId) ||
      typeof pending.sourceName !== 'string' || pending.sourceName.trim().length === 0 ||
      typeof pending.sourceUri !== 'string' || pending.sourceUri.trim().length === 0 ||
      typeof pending.externalBackupName !== 'string' || pending.externalBackupName.trim().length === 0) {
    throw new Error('直写恢复记录不完整，请检查备份和原文件。');
  }
  return {
    operationId: pending.operationId,
    sourceName: pending.sourceName,
    sourceUri: pending.sourceUri,
    externalBackupName: pending.externalBackupName
  };
}

// Caller must hold the shared guard. Read from disk each time; Preferences are
// explicitly not safe for multi-process access and may return stale cache.
function readPending(context: common.UIAbilityContext, guard: DirectWriteGuard): PendingDirectWrite | undefined {
  guard.assertHeld();
  if (persistenceUncertain) throw new Error('直写恢复记录状态不确定，请检查备份和原文件。');
  const path: string = journalPath(context);
  let stat: fileIo.Stat;
  try {
    stat = fileIo.statSync(path);
  } catch (error) {
    if (Number((error as BusinessError).code) === 13900002) return undefined;
    throw new Error('无法读取直写恢复记录：' + String(error));
  }
  if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_JOURNAL_SIZE) {
    throw new Error('直写恢复记录损坏，请检查备份和原文件。');
  }
  return pendingFromText(fileIo.readTextSync(path));
}

function writeAll(fd: number, text: string): void {
  const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
  const encoded: Uint8Array = encoder.encodeInto(text);
  if (encoded.length === 0 || encoded.length > MAX_JOURNAL_SIZE) {
    throw new Error('直写恢复记录长度无效。');
  }
  let done: number = 0;
  while (done < encoded.length) {
    const bytes: ArrayBuffer = encoded.buffer.slice(encoded.byteOffset + done,
      encoded.byteOffset + encoded.byteLength) as ArrayBuffer;
    const count: number = fileIo.writeSync(fd, bytes);
    if (count <= 0 || count > bytes.byteLength) throw new Error('无法完整写入直写恢复记录。');
    done += count;
  }
  fileIo.fsyncSync(fd);
}

/** Atomically publish one record. Caller holds the guard. */
function publishPending(context: common.UIAbilityContext, guard: DirectWriteGuard, record: PendingDirectWrite): void {
  guard.assertHeld();
  const root: string = rootPath(context);
  syncDirectory(root);
  const text: string = JSON.stringify(record);
  const tempDir: string = fileIo.mkdtempSync(root + '/lyricflow_journal_XXXXXX');
  const tempPath: string = tempDir + '/pending.json';
  let created: boolean = false;
  let file: fileIo.File | undefined = undefined;
  try {
    file = fileIo.openSync(tempPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    created = true;
    writeAll(file.fd, text);
    fileIo.closeSync(file.fd);
    file = undefined;
    fileIo.renameSync(tempPath, journalPath(context));
    syncDirectory(root);
    const persisted: PendingDirectWrite = pendingFromText(fileIo.readTextSync(journalPath(context)));
    if (persisted.operationId !== record.operationId ||
        persisted.sourceName !== record.sourceName || persisted.sourceUri !== record.sourceUri ||
        persisted.externalBackupName !== record.externalBackupName) {
      throw new Error('持久恢复记录回读不一致。');
    }
  } finally {
    if (file !== undefined) {
      try { fileIo.closeSync(file.fd); } catch (_error) {}
    }
    if (created) {
      try { fileIo.unlinkSync(tempPath); } catch (_error) {}
    }
    try { fileIo.rmdirSync(tempDir); } catch (_error) {}
  }
}

/** Caller owns guard for the entire write, including completion or rollback. */
export async function beginDirectWrite(
  context: common.UIAbilityContext,
  guard: DirectWriteGuard,
  sourceName: string,
  sourceUri: string,
  externalBackupName: string
): Promise<string> {
  guard.assertHeld();
  if (sourceName.trim().length === 0 || sourceUri.trim().length === 0 || externalBackupName.trim().length === 0) {
    throw new Error('缺少源文件名、源 URI 或外部备份名，不能开始直写。');
  }
  if (readPending(context, guard) !== undefined) {
    throw new Error('存在尚未处理的直写恢复记录，请先检查备份并确认处理。');
  }
  const record: PendingDirectWrite = {
    operationId: util.generateRandomUUID(),
    sourceName: sourceName,
    sourceUri: sourceUri,
    externalBackupName: externalBackupName
  };
  try {
    // The guard prevents cooperating writers racing the absence check.
    publishPending(context, guard, record);
    return record.operationId;
  } catch (error) {
    persistenceUncertain = true;
    throw new Error('无法持久保存直写恢复记录，未修改源文件；请检查备份：' + String(error));
  }
}

/** Only a matching operation may clear a record. Caller must hold the guard. */
export async function clearDirectWrite(
  context: common.UIAbilityContext,
  guard: DirectWriteGuard,
  expectedOperationId: string
): Promise<void> {
  guard.assertHeld();
  if (expectedOperationId.length === 0) throw new Error('缺少恢复记录标识，拒绝清除。');
  const pending: PendingDirectWrite | undefined = readPending(context, guard);
  if (pending === undefined || pending.operationId !== expectedOperationId) {
    throw new Error('恢复记录已变化或不存在，拒绝清除。');
  }
  try {
    fileIo.unlinkSync(journalPath(context));
    syncDirectory(rootPath(context));
    persistenceUncertain = false;
  } catch (error) {
    // unlink may have succeeded before a directory fsync failed. Recreate the
    // exact old record while still holding the guard, so a later process has
    // the best available chance of seeing the warning. Any failure remains
    // uncertain and is never reported as a successful clear.
    try { publishPending(context, guard, pending); } catch (_restoreError) {}
    persistenceUncertain = true;
    throw new Error('无法确认清除直写恢复记录，请检查备份和原文件：' + String(error));
  }
}

/** Do not mistake another active writer's record for an interrupted write. */
export async function getPendingDirectWrite(context: common.UIAbilityContext): Promise<PendingDirectWrite | undefined> {
  const guard: DirectWriteGuard = acquireDirectWriteGuard(context);
  try {
    return readPending(context, guard);
  } finally {
    guard.release();
  }
}

/** The user may acknowledge only the exact record that was displayed. */
export async function acknowledgeDirectWrite(context: common.UIAbilityContext, expectedOperationId: string): Promise<void> {
  const guard: DirectWriteGuard = acquireDirectWriteGuard(context);
  try {
    await clearDirectWrite(context, guard, expectedOperationId);
  } finally {
    guard.release();
  }
}
