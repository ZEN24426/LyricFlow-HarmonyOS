import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/**
 * 导出模块 — 手机端 API 规范。
 *
 * 所有导出均通过 DocumentViewPicker DOWNLOAD 模式。
 * DOWNLOAD 模式返回系统为应用提供的下载位置；直接在该位置保存文件，
 * 不再额外创建 LyricFlow 子目录。
 *
 * 文件写入使用 fileIo.open + fileIo.read/write 分块流式复制，
 * fileIo.fsyncSync 确保落盘，fileIo.closeSync 释放 fd。
 */

export interface SavedExport {
  name: string;
  uri: string;
  size: number;
}

interface ExportTarget {
  name: string;
  path: string;
}

export type ExportProgressFn = (copied: number, total: number) => void;

export interface SandboxExportResult {
  copied: string[];
  failed: string[];
}

const BLOCK: number = 512 * 1024;
const FALLBACK_DIR: string = 'export';

function syncBackupDirectory(path: string): void {
  const dir: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.DIR);
  try { fileIo.fsyncSync(dir.fd); } finally { fileIo.closeSync(dir.fd); }
}

export class ExportService {

  // ── 公共 API ──

  /**
   * 将文本保存到 DOWNLOAD 模式返回的应用下载位置/<fileName>。
   * DOWNLOAD 模式，无需用户选择保存位置。
   */
  static async saveTextToDownload(
    context: common.UIAbilityContext,
    fileName: string,
    text: string
  ): Promise<SavedExport | undefined> {
    const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
    const encoded: Uint8Array = encoder.encodeInto(text);
    const data: ArrayBuffer = encoded.buffer.slice(encoded.byteOffset, encoded.byteOffset + encoded.byteLength) as ArrayBuffer;
    const total: number = encoded.length;
    for (let attempt: number = 0; attempt < 2; attempt++) {
      const dirUri: string | undefined = await ExportService.getDownloadDirUri(context);
      if (dirUri === undefined) return undefined;
      try {
        const output = ExportService.uniqueExportTarget(dirUri, fileName);
        await ExportService.writeBytes(output.path, data, total);
        return { name: output.name, uri: output.path, size: total } as SavedExport;
      } catch (error) {
        if (attempt === 0 && ExportService.isAccessRelatedError(error)) continue;
        throw error as Error;
      }
    }
    return undefined;
  }

  /**
   * 将沙箱音频文件保存到 DOWNLOAD 模式返回的应用下载位置/<fileName>。
   * DOWNLOAD 模式，无需用户选择保存位置。
   */
  static async saveAudioToDownload(
    context: common.UIAbilityContext,
    fileName: string,
    sourcePath: string,
    onProgress?: ExportProgressFn
  ): Promise<SavedExport | undefined> {
    const totalSize: number = fileIo.statSync(sourcePath).size;
    for (let attempt: number = 0; attempt < 2; attempt++) {
      const dirUri: string | undefined = await ExportService.getDownloadDirUri(context);
      if (dirUri === undefined) return undefined;
      try {
        const output = ExportService.uniqueExportTarget(dirUri, fileName);
        await ExportService.streamCopy(sourcePath, output.path, totalSize, onProgress);
        return { name: output.name, uri: output.path, size: totalSize } as SavedExport;
      } catch (error) {
        if (attempt === 0 && ExportService.isAccessRelatedError(error)) continue;
        throw error as Error;
      }
    }
    return undefined;
  }

  /**
   * Store a verified pre-write backup in a new dedicated download directory.
   * The directory is reserved with mkdir (which fails if it already exists),
   * rather than choosing an unreserved file name via stat followed by open.
   * A failed or interrupted backup is left in place for the user to inspect.
   */
  static async saveDirectBackup(
    context: common.UIAbilityContext,
    backupName: string,
    privateBackupPath: string
  ): Promise<SavedExport | undefined> {
    const dirUri: string | undefined = await ExportService.getDownloadDirUri(context);
    if (dirUri === undefined) return undefined;
    const basePath: string = new fileUri.FileUri(dirUri).path;
    if (!fileIo.statSync(basePath).isDirectory()) {
      throw new Error('系统返回的下载位置不是目录，无法创建备份。');
    }
    const name: string = backupName.replace(/[\\/<>:"|?*\u0000-\u001f\u007f]/g, '_')
      .replace(/[. ]+$/g, '').trim().substring(0, 160);
    if (name.length === 0 || name === '.' || name === '..') {
      throw new Error('备份文件名无效，已取消直写。');
    }

    const totalSize: number = fileIo.statSync(privateBackupPath).size;
    if (totalSize <= 0) throw new Error('私有备份为空，已取消直写。');
    let directoryName: string = '';
    let backupDirectory: string = '';
    for (let attempt: number = 0; attempt < 10; attempt++) {
      directoryName = 'LyricFlow-backup-' + util.generateRandomUUID();
      backupDirectory = basePath.replace(/\/+$/, '') + '/' + directoryName;
      try {
        fileIo.mkdirSync(backupDirectory);
        break;
      } catch (error) {
        if (Number((error as BusinessError).code) !== 13900015) throw error as Error;
        backupDirectory = '';
      }
    }
    if (backupDirectory.length === 0) throw new Error('无法预留独立备份目录，已取消直写。');

    const target: string = backupDirectory + '/' + name;
    try {
      fileIo.statSync(target);
      throw new Error('备份目标意外存在，已取消直写。');
    } catch (error) {
      if (Number((error as BusinessError).code) !== 13900002) throw error as Error;
    }
    // Do not unlink a failed output: only the newly reserved directory is ours,
    // and the platform does not expose an exclusive file-create flag here.
    await ExportService.streamCopy(privateBackupPath, target, totalSize, undefined, false, true);
    // Ensure the backup file and its reserved directory are published before
    // allowing the source file to be changed. Unsupported providers fail closed.
    syncBackupDirectory(backupDirectory);
    syncBackupDirectory(basePath);
    return { name: directoryName + '/' + name, uri: target, size: totalSize } as SavedExport;
  }

  // ── 沙箱文件搬运 ──

  /**
   * 将沙箱 filesDir/export/ 中的所有文件复制到 DOWNLOAD 模式返回的应用下载位置。
   * 用于设备此前降级写入了沙箱、现在需要搬到可见下载目录的场景。
   * 用户取消时返回 undefined。
   */
  static async copySandboxToDownload(
    context: common.UIAbilityContext
  ): Promise<SandboxExportResult | undefined> {
    const sandboxDir: string = ExportService.sandboxExportDir(context.filesDir);
    let entries: string[];
    try {
      entries = fileIo.listFileSync(sandboxDir);
    } catch (_) {
      return { copied: [], failed: [] } as SandboxExportResult;
    }

    // 仅保留文件，跳过子目录
    const fileNames: string[] = [];
    for (let i: number = 0; i < entries.length; i++) {
      const name: string = entries[i];
      try {
        const stat = fileIo.statSync(sandboxDir + '/' + name);
        if (!stat.isDirectory()) fileNames.push(name);
      } catch (_) { /* skip */ }
    }
    if (fileNames.length === 0) {
      return { copied: [], failed: [] } as SandboxExportResult;
    }

    const dirUri: string | undefined = await ExportService.getDownloadDirUri(context);
    if (dirUri === undefined) return undefined;

    const copied: string[] = [];
    const failed: string[] = [];
    for (let i: number = 0; i < fileNames.length; i++) {
      const name: string = fileNames[i];
      const sourcePath: string = sandboxDir + '/' + name;
      try {
        const output = ExportService.uniqueExportTarget(dirUri, name);
        const totalSize: number = fileIo.statSync(sourcePath).size;
        await ExportService.streamCopy(sourcePath, output.path, totalSize);
        copied.push(output.name);
      } catch (_) {
        failed.push(name);
      }
    }
    return { copied, failed } as SandboxExportResult;
  }

  // ── 内部管线 ──

  /**
   * 获取 DOWNLOAD 模式目录 URI。
   * 系统负责提供应用对应的下载位置；本模块不再额外创建 LyricFlow 子目录。
   */
  private static async getDownloadDirUri(
    context: common.UIAbilityContext
  ): Promise<string | undefined> {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const result: Array<string> = await documentPicker.save(options);
    return result.length > 0 ? result[0] : undefined;
  }

  /**
   * 校验 DOWNLOAD 模式返回的目录，并直接构建 <directory>/<fileName>。
   * 不创建额外的应用子目录。
   */
  private static buildExportPath(dirUri: string, fileName: string): string {
    const basePath: string = new fileUri.FileUri(dirUri).path;
    const baseStat = fileIo.statSync(basePath);
    if (!baseStat.isDirectory()) {
      throw new Error('系统返回的下载 URI 不是可用目录，请重新获取下载位置。');
    }
    return new fileUri.FileUri(dirUri + '/' + fileName).path;
  }

  /**
   * 保留已有导出结果：如「歌曲.mp3」已存在，就使用「歌曲 (1).mp3」。
   * 只把明确的 ENOENT 当作文件不存在，权限错误不能误判为空位置。
   */
  private static uniqueExportTarget(dirUri: string, requestedName: string): ExportTarget {
    // 保存文件名来自用户输入或媒体标签，不能让它变成路径的一部分。
    const normalizedName: string = requestedName
      .replace(/[\\/<>:"|?*\u0000-\u001f\u007f]/g, '_')
      .replace(/[. ]+$/g, '').trim()
      .substring(0, 160);
    if (normalizedName.length === 0 || normalizedName === '.' || normalizedName === '..') {
      throw new Error('文件名无效，请先修改歌曲标题再导出。');
    }
    const dot: number = normalizedName.lastIndexOf('.');
    const hasExtension: boolean = dot > 0 && dot < normalizedName.length - 1;
    const stem: string = hasExtension ? normalizedName.substring(0, dot) : normalizedName;
    const ext: string = hasExtension ? normalizedName.substring(dot) : '';

    for (let suffix: number = 0; suffix < 10000; suffix++) {
      const name: string = suffix === 0 ? normalizedName : stem + ' (' + suffix + ')' + ext;
      const path: string = ExportService.buildExportPath(dirUri, name);
      try {
        fileIo.statSync(path);
      } catch (error) {
        const code: number = Number((error as BusinessError).code);
        if (code === 13900002) return { name: name, path: path } as ExportTarget;
        throw error as Error;
      }
    }
    throw new Error('已有太多同名导出文件，请先整理下载目录。');
  }

  /**
   * 仅对访问权限/URI/目录访问类错误重新请求一次 DOWNLOAD URI。
   * 存储空间不足、内容不一致等错误不重复请求，避免误导用户。
   */
  private static isAccessRelatedError(error: Object): boolean {
    const message: string = error instanceof Error
      ? error.message
      : ((error as BusinessError).message || '');
    const code: string = error instanceof Error ? '' : String((error as BusinessError).code || '');
    return /permission|denied|access|not permitted|授权|权限|访问被拒|EACCES|EPERM|ENOENT|URI|路径|目录|not found|no such file|file not found|invalid path/i.test(message) ||
      code === '13900013' || code === '13900014';
  }

  /** 降级目录：filesDir/export */
  private static sandboxExportDir(filesDir: string): string {
    const dir: string = filesDir.endsWith('/')
      ? filesDir.substring(0, filesDir.length - 1)
      : filesDir;
    return dir + '/' + FALLBACK_DIR;
  }

  /**
   * 将字节缓冲分块写入目标文件。
   * 目标路径由 uniqueExportTarget 确认不存在；失败时移除不完整的新文件。
   */
  private static async writeBytes(
    target: string,
    data: ArrayBuffer,
    totalSize: number
  ): Promise<void> {
    const file: fileIo.File = await fileIo.open(
      target, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE
    );
    try {
      try {
        let written: number = 0;
        while (written < totalSize) {
          const toWrite: number = Math.min(BLOCK, totalSize - written);
          const slice: ArrayBuffer = data.slice(written, written + toWrite);
          const len: number = await fileIo.write(file.fd, slice, { length: toWrite });
          if (len <= 0) throw new Error('写入文件失败，导出已中止。');
          written += len;
        }
        fileIo.fsyncSync(file.fd);
      } finally {
        try { fileIo.closeSync(file); } catch (_) {}
      }
      await ExportService.verifyBytes(target, data, totalSize);
    } catch (error) {
      try { fileIo.unlinkSync(target); } catch (_cleanupError) {}
      throw error as Error;
    }
  }

  /**
   * 分块流式复制文件.
   * 源以 READ_ONLY 打开，目标以 WRITE_ONLY | CREATE 打开（不覆盖已有文件）。
   * 每块读后立即写入，通过 onProgress 回报进度。
   */
  private static async streamCopy(
    sourcePath: string,
    target: string,
    totalSize: number,
    onProgress?: ExportProgressFn,
    cleanupOnFailure: boolean = true,
    noFollow: boolean = false
  ): Promise<void> {
    const source: fileIo.File = await fileIo.open(sourcePath, fileIo.OpenMode.READ_ONLY);
    let targetFile: fileIo.File | undefined = undefined;
    let targetOpened: boolean = false;
    try {
      targetFile = await fileIo.open(
        target, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE |
          (noFollow ? fileIo.OpenMode.NOFOLLOW : 0)
      );
      // open 失败时尚未取得目标文件句柄，绝不能删除对应的路径。
      targetOpened = true;
      try {
        let copied: number = 0;
        while (copied < totalSize) {
          const toRead: number = Math.min(BLOCK, totalSize - copied);
          const buffer: ArrayBuffer = new ArrayBuffer(toRead);
          const bytesRead: number = await fileIo.read(source.fd, buffer, { length: toRead });
          if (bytesRead <= 0) throw new Error('读取源文件时意外结束，导出已中止。');

          let batchWritten: number = 0;
          while (batchWritten < bytesRead) {
            const slice: ArrayBuffer = buffer.slice(batchWritten, bytesRead);
            const written: number = await fileIo.write(targetFile.fd, slice, { length: bytesRead - batchWritten });
            if (written <= 0) throw new Error('写入目标文件失败，导出已中止。');
            batchWritten += written;
          }

          copied += bytesRead;
          if (onProgress !== undefined) onProgress(copied, totalSize);
        }
        fileIo.fsyncSync(targetFile.fd);
      } finally {
        try { fileIo.closeSync(targetFile.fd); } catch (_) {}
        targetFile = undefined;
      }
      await ExportService.verifyFilesEqual(sourcePath, target, totalSize);
    } catch (error) {
      if (targetFile !== undefined) {
        try { fileIo.closeSync(targetFile.fd); } catch (_) {}
      }
      // 仅在本次确实成功打开目标之后才清理；open 自身抛错时不可误删。
      // 仍需注意外部进程同时创建同名文件的竞争窗口（非原子创建）。
      if (targetOpened && cleanupOnFailure) {
        try { fileIo.unlinkSync(target); } catch (_cleanupError) {}
      }
      throw error as Error;
    } finally {
      try { fileIo.closeSync(source.fd); } catch (_) {}
    }
  }

  /** 回读导出文件，与预期字节逐块比对；歌词、文本和图片均使用此校验。 */
  private static async verifyBytes(
    target: string,
    expected: ArrayBuffer,
    expectedSize: number
  ): Promise<void> {
    const stat = fileIo.statSync(target);
    if (stat.size !== expectedSize) {
      throw new Error('导出校验失败：文件大小与预期不一致。');
    }
    const file: fileIo.File = await fileIo.open(target, fileIo.OpenMode.READ_ONLY);
    try {
      let offset: number = 0;
      while (offset < expectedSize) {
        const length: number = Math.min(BLOCK, expectedSize - offset);
        const buffer: ArrayBuffer = new ArrayBuffer(length);
        const read: number = await fileIo.read(file.fd, buffer, { length });
        if (read <= 0) throw new Error('导出校验失败：回读文件时意外结束。');
        const actualBytes = new Uint8Array(buffer, 0, read);
        const expectedBytes = new Uint8Array(expected, offset, read);
        for (let i: number = 0; i < read; i++) {
          if (actualBytes[i] !== expectedBytes[i]) {
            throw new Error('导出校验失败：回读内容与写入内容不一致。');
          }
        }
        offset += read;
      }
    } finally {
      try { fileIo.closeSync(file.fd); } catch (_) {}
    }
  }

  /** 音频分块回读并与最终待导出的沙箱文件逐字节比对，避免将整首音频载入内存。 */
  private static async verifyFilesEqual(
    expectedPath: string,
    actualPath: string,
    expectedSize: number
  ): Promise<void> {
    const expectedStat = fileIo.statSync(expectedPath);
    const actualStat = fileIo.statSync(actualPath);
    if (expectedStat.size !== expectedSize || actualStat.size !== expectedSize) {
      throw new Error('导出校验失败：音频文件大小与预期不一致。');
    }
    const expectedFile: fileIo.File = await fileIo.open(expectedPath, fileIo.OpenMode.READ_ONLY);
    let actualFile: fileIo.File | undefined = undefined;
    try {
      actualFile = await fileIo.open(actualPath, fileIo.OpenMode.READ_ONLY);
      let offset: number = 0;
      while (offset < expectedSize) {
        const length: number = Math.min(BLOCK, expectedSize - offset);
        const expectedBuffer: ArrayBuffer = new ArrayBuffer(length);
        const actualBuffer: ArrayBuffer = new ArrayBuffer(length);
        const expectedRead: number = await fileIo.read(expectedFile.fd, expectedBuffer, { length });
        const actualRead: number = await fileIo.read(actualFile.fd, actualBuffer, { length });
        if (expectedRead <= 0 || actualRead !== expectedRead) {
          throw new Error('导出校验失败：音频回读长度与预期不一致。');
        }
        const expectedBytes = new Uint8Array(expectedBuffer, 0, expectedRead);
        const actualBytes = new Uint8Array(actualBuffer, 0, actualRead);
        for (let i: number = 0; i < expectedRead; i++) {
          if (expectedBytes[i] !== actualBytes[i]) {
            throw new Error('导出校验失败：音频内容与待导出文件不一致。');
          }
        }
        offset += expectedRead;
      }
    } finally {
      try { fileIo.closeSync(expectedFile.fd); } catch (_) {}
      if (actualFile !== undefined) {
        try { fileIo.closeSync(actualFile.fd); } catch (_) {}
      }
    }
  }
}
