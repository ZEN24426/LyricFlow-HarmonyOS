import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

// The in-runtime flag closes same-runtime reentry before a file is opened.
// The private, stable advisory lock coordinates cooperating processes.
let guardHeld: boolean = false;
export const DIRECT_WRITE_BUSY: string = 'DIRECT_WRITE_BUSY';
export const DIRECT_WRITE_GUARD_ERROR: string = 'DIRECT_WRITE_GUARD_ERROR';

export class DirectWriteGuard {
  private file: fileIo.File;
  private held: boolean = true;

  constructor(file: fileIo.File) {
    this.file = file;
  }

  assertHeld(): void {
    if (!this.held) throw new Error('直写操作锁已经释放，拒绝更改恢复记录。');
  }

  release(): void {
    if (!this.held) return;
    this.held = false;
    try { this.file.unlock(); } catch (_error) {}
    try {
      fileIo.closeSync(this.file.fd);
      guardHeld = false;
    } catch (_error) {
      // An uncertain close must fail closed until the process exits.
      guardHeld = true;
    }
  }
}

export function acquireDirectWriteGuard(context: common.UIAbilityContext): DirectWriteGuard {
  if (guardHeld) throw new Error(DIRECT_WRITE_BUSY + ': 直写正在进行，请稍后再处理恢复记录。');
  guardHeld = true;
  let file: fileIo.File | undefined = undefined;
  try {
    const root: string = context.filesDir.endsWith('/')
      ? context.filesDir.substring(0, context.filesDir.length - 1) : context.filesDir;
    file = fileIo.openSync(root + '/lyricflow_direct_write.lock',
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    file.tryLock(true);
    return new DirectWriteGuard(file);
  } catch (error) {
    if (file !== undefined) {
      try { fileIo.closeSync(file.fd); } catch (_closeError) {}
    }
    guardHeld = false;
    const marker: string = Number((error as BusinessError).code) === 13900034
      ? DIRECT_WRITE_BUSY : DIRECT_WRITE_GUARD_ERROR;
    throw new Error(marker + ': 无法取得直写操作锁，无法检查或修改恢复记录：' +
      (error instanceof Error ? error.message : String(error)));
  }
}
