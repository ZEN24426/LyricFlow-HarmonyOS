import { fileIo, fileUri } from '@kit.CoreFileKit';
import { AudioMetadata, AudioMetadataWriter, readAudioMetadata, writeAudioMetadata } from '@dabing/taglib_harmony';
import { Mp3Numbers, readMp3Numbers } from './Mp3DirectWriter';
import { repairFlacBpm } from './FlacBpmWriter';

export interface WorkingAudio {
  sourceUri: string;
  sourceName: string;
  workingPath: string;
  metadata: AudioMetadata;
}

export interface MatchingMetadataRead {
  metadata: AudioMetadata;
  usedSandboxCopy: boolean;
}

function safeFileStem(name: string, stripExtension: boolean): string {
  const leaf: string = name.replace(/\\/g, '/').split('/').pop() || 'audio';
  const source: string = stripExtension ? leaf.replace(/\.[^.]+$/, '') : leaf;
  // 保留日文假名、韩文、重音字母及其他 Unicode 歌名，仅排除文件名不允许的字符。
  const stem: string = source.replace(/[\\/:*?"<>|\u0000-\u001F\u007F]/g, '_').replace(/[. ]+$/g, '').trim();
  return stem.length > 0 ? Array.from(stem).slice(0, 80).join('') : 'audio';
}

function extensionOf(name: string): string {
  const match: RegExpMatchArray | null = name.match(/\.([A-Za-z0-9]{1,8})$/);
  return match === null ? '.audio' : '.' + match[1].toLowerCase();
}

async function copyFileByUri(
  sourceUri: string,
  destinationPath: string,
  onDestinationReady?: () => void
): Promise<void> {
  // Reject obvious aliases before opening either destination or truncating it.
  let sourceKey: string = sourceUri;
  let destinationKey: string = destinationPath;
  try { if (sourceUri.indexOf('://') >= 0) sourceKey = new fileUri.FileUri(sourceUri).path; } catch (_error) {}
  try { if (destinationPath.indexOf('://') >= 0) destinationKey = new fileUri.FileUri(destinationPath).path; } catch (_error) {}
  if (sourceUri === destinationPath || (sourceKey.length > 0 && sourceKey === destinationKey)) {
    throw new Error('拒绝将文件复制到自身，避免截断原始内容。');
  }
  let source: fileIo.File;
  try {
    source = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
  } catch (error) {
    throw error as Error;
  }
  let destination: fileIo.File | undefined;
  try {
    // Do not truncate during open: two different URIs or paths may identify the
    // same file. Check the opened handles first, then truncate the same handle.
    destination = await fileIo.open(destinationPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    const sourceInode: string = fileIo.statSync(source.fd).ino.toString();
    const destinationInode: string = fileIo.statSync(destination.fd).ino.toString();
    // The SDK exposes ino but not a device ID. Reject ambiguous zero IDs and
    // identical IDs even across different mounts, preferring a safe failure.
    if (source.fd === destination.fd || sourceInode === '0' || destinationInode === '0' ||
        sourceInode === destinationInode) {
      throw new Error('无法确认复制源与目标是不同文件，已取消操作以保护原文件。');
    }
    if (onDestinationReady !== undefined) onDestinationReady();
    fileIo.truncateSync(destination.fd, 0);
    const bufferSize: number = 1024 * 1024;
    while (true) {
      const buffer: ArrayBuffer = new ArrayBuffer(bufferSize);
      const count: number = await fileIo.read(source.fd, buffer, { length: bufferSize });
      if (count <= 0) break;
      let offset: number = 0;
      while (offset < count) {
        const view: ArrayBuffer = buffer.slice(offset, count);
        const written: number = await fileIo.write(destination.fd, view, { length: count - offset });
        if (written <= 0) throw new Error('复制文件时写入失败。');
        offset += written;
      }
    }
    fileIo.fsyncSync(destination.fd);
  } finally {
    try { fileIo.closeSync(source.fd); } catch (_error) {}
    if (destination !== undefined) {
      try { fileIo.closeSync(destination.fd); } catch (_error) {}
    }
  }
}

export class AudioMetadataService {
  static async importToSandbox(
    sourceUri: string,
    sourceName: string,
    filesDir: string
  ): Promise<WorkingAudio> {
    const workingPath: string = (filesDir.endsWith('/') ? filesDir.substring(0, filesDir.length - 1) : filesDir) + '/lyricflow_work_' +
      Date.now().toString() + '_' + Math.random().toString(36).slice(2, 10) + extensionOf(sourceName);
    let canCleanWorkingPath: boolean = false;
    try {
      await copyFileByUri(sourceUri, workingPath, () => { canCleanWorkingPath = true; });
      const metadata: AudioMetadata = await AudioMetadataService.readForDirect(workingPath, filesDir, false);
      return { sourceUri, sourceName, workingPath, metadata };
    } catch (error) {
      if (canCleanWorkingPath) {
        try { fileIo.unlinkSync(workingPath); } catch (_unlinkError) {}
      }
      throw error as Error;
    }
  }

  static async read(workingPath: string): Promise<AudioMetadata> {
    return await readAudioMetadata(workingPath);
  }

  /** Correct the bridge's incomplete MP3 number/total parsing for private copies. */
  static async readForDirect(workingPath: string, filesDir: string, strict: boolean = true): Promise<AudioMetadata> {
    const metadata: AudioMetadata = await readAudioMetadata(workingPath);
    if (/\.mp3$/i.test(workingPath)) {
      try {
        const numbers: Mp3Numbers = await readMp3Numbers(filesDir, workingPath);
        metadata.track = numbers.track;
        metadata.trackTotal = numbers.trackTotal;
        metadata.disc = numbers.disc;
        metadata.discTotal = numbers.discTotal;
      } catch (error) {
        if (strict) throw error as Error;
      }
    }
    return metadata;
  }

  static canReadDirectly(uri: string): boolean {
    try {
      const path: string = new fileUri.FileUri(uri).path;
      return path.indexOf('/storage/Users/') === 0 ||
        path.indexOf('/data/storage/') === 0;
    } catch (_error) {
      return false;
    }
  }

  static async readForMatching(
    sourceUri: string,
    sourceName: string,
    filesDir: string,
    allowSandboxCopy: boolean = true,
    onSandboxCopyAttempt?: () => void
  ): Promise<MatchingMetadataRead> {
    let sourcePath: string = '';
    try { sourcePath = new fileUri.FileUri(sourceUri).path; } catch (_error) {}
    if (sourcePath.indexOf('/storage/Users/') === 0 ||
        sourcePath.indexOf('/data/storage/') === 0) {
      try {
        const metadata: AudioMetadata = await readAudioMetadata(sourcePath);
        return { metadata, usedSandboxCopy: false };
      } catch (_directReadError) {
        if (!allowSandboxCopy) throw new Error('此文件的直接标签读取失败；为避免复制大量音频，本轮跳过沙箱副本回退。');
      }
    }
    if (!allowSandboxCopy) throw new Error('此文件 URI 不能直接用于标签读取，且本轮已达到沙箱副本读取上限。');
    // 在真正开始全文件复制前就计入预算，失败的文件也不能无限重试。
    if (onSandboxCopyAttempt !== undefined) onSandboxCopyAttempt();
    const working = await AudioMetadataService.importToSandbox(sourceUri, sourceName, filesDir);
    try {
      return { metadata: working.metadata, usedSandboxCopy: true };
    } finally {
      await AudioMetadataService.removeWorkingFile(working.workingPath);
    }
  }

  static async write(workingPath: string, fields: AudioMetadataWriter): Promise<void> {
    const success: boolean = await writeAudioMetadata(workingPath, fields);
    if (!success) throw new Error('音频标签库未能确认写入成功。');
    if (fields.bpm !== undefined) await repairFlacBpm(workingPath, fields.bpm);
    // Re-read after writing to verify the file remains parseable.
    // User-editable fields (title, artist, album, composer, lyrics, etc.) are not
    // compared against the re-read values, because the metadata writer may normalize
    // values (encoding, whitespace, etc.) which would cause false validation failures.
    const actual: AudioMetadata = await readAudioMetadata(workingPath);
    if (fields.bpm !== undefined && actual.bpm !== fields.bpm) {
      throw new Error('音频 BPM 写入后回读不一致，已取消保存。');
    }
  }

  /**
   * Byte-level comparison for a backup and the selected original URI.
   * Do not assume equal sizes mean equal audio contents.
   */
  static async filesIdentical(leftPath: string, rightUri: string): Promise<boolean> {
    const left: fileIo.File = await fileIo.open(leftPath, fileIo.OpenMode.READ_ONLY);
    let right: fileIo.File | undefined = undefined;
    try {
      right = await fileIo.open(rightUri, fileIo.OpenMode.READ_ONLY);
      const BLOCK: number = 256 * 1024;
      while (true) {
        const leftBuffer: ArrayBuffer = new ArrayBuffer(BLOCK);
        const leftCount: number = await fileIo.read(left.fd, leftBuffer, { length: BLOCK });
        if (leftCount <= 0) {
          const tail: ArrayBuffer = new ArrayBuffer(1);
          return await fileIo.read(right.fd, tail, { length: 1 }) === 0;
        }
        let compared: number = 0;
        while (compared < leftCount) {
          const rightBuffer: ArrayBuffer = new ArrayBuffer(leftCount - compared);
          const rightCount: number = await fileIo.read(
            right.fd, rightBuffer, { length: leftCount - compared }
          );
          if (rightCount <= 0) return false;
          const leftView: Uint8Array = new Uint8Array(leftBuffer, compared, rightCount);
          const rightView: Uint8Array = new Uint8Array(rightBuffer, 0, rightCount);
          for (let i: number = 0; i < rightCount; i++) {
            if (leftView[i] !== rightView[i]) return false;
          }
          compared += rightCount;
        }
      }
    } finally {
      try { fileIo.closeSync(left.fd); } catch (_error) {}
      if (right !== undefined) {
        try { fileIo.closeSync(right.fd); } catch (_error) {}
      }
    }
  }

  static async copyToUri(sourcePath: string, destinationUri: string): Promise<void> {
    await copyFileByUri(sourcePath, destinationUri);
  }

  static async makeWorkingCopy(
    sourcePath: string,
    filesDir: string,
    sourceName: string
  ): Promise<string> {
    const target: string = (filesDir.endsWith('/') ? filesDir.substring(0, filesDir.length - 1) : filesDir) + '/lyricflow_export_' +
      Date.now().toString() + '_' + Math.random().toString(36).slice(2, 10) + extensionOf(sourceName);
    let canCleanTarget: boolean = false;
    try {
      await copyFileByUri(sourcePath, target, () => { canCleanTarget = true; });
      return target;
    } catch (error) {
      // This generated target is in the application-private files directory.
      if (canCleanTarget) {
        try { fileIo.unlinkSync(target); } catch (_unlinkError) {}
      }
      throw error as Error;
    }
  }

  static async removeWorkingFile(path: string): Promise<void> {
    try { fileIo.unlinkSync(path); } catch (_error) {}
  }

  static async cleanupTemporaryFiles(filesDir: string): Promise<void> {
    try {
      const entries: string[] = fileIo.listFileSync(filesDir);
      for (let i: number = 0; i < entries.length; i++) {
        const entry: string = entries[i];
        const name: string = entry.split('/').pop() || entry;
        if (name.indexOf('lyricflow_work_') === 0 || name.indexOf('lyricflow_export_') === 0) {
          const path: string = entry.indexOf('/') >= 0 ? entry : (filesDir.endsWith('/') ? filesDir.substring(0, filesDir.length - 1) : filesDir) + '/' + name;
          try { fileIo.unlinkSync(path); } catch (_unlinkError) {}
        }
      }
    } catch (_error) {
      // Temporary cleanup is best effort; it must never prevent app startup.
    }
  }

  static safeOutputName(sourceName: string, title: string): string {
    const extension: string = extensionOf(sourceName);
    const base: string = title.length > 0 ? safeFileStem(title, false) : safeFileStem(sourceName, true);
    return base + extension;
  }
}
