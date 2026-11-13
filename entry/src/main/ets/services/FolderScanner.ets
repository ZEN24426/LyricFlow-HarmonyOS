import { fileIo, fileUri } from '@kit.CoreFileKit';
import { AudioMatchInput, LyricMatchInput } from './MatchEngine';
import { AudioMetadataService } from './AudioMetadataService';
import { FileSelectionService } from './FileSelectionService';
import { LyricEngine } from './LyricEngine';

export interface ScannedImageFile {
  id: string;
  name: string;
  uri: string;
}

export type ScanProgressFn = (message: string) => void;
export type ScanCancelFn = () => boolean;

export interface FolderScanResult {
  audioFiles: AudioMatchInput[];
  lyricFiles: LyricMatchInput[];
  imageFiles: ScannedImageFile[];
  warnings: string[];
  visitedFiles: number;
}

interface PendingDirectory {
  uri: string;
  depth: number;
}

function leafName(uri: string): string {
  const path: string = uri.split('?')[0].split('#')[0];
  const parts: string[] = path.split('/');
  return parts.length > 0 ? parts[parts.length - 1] : path;
}

function joinUri(parent: string, entry: string): string {
  if (entry.indexOf('://') >= 0) return entry;
  const normalizedParent: string = parent.replace(/\/+$/, '');
  return normalizedParent + '/' + entry;
}

function classifyAudio(name: string): boolean {
  return /\.(mp3|flac|wav|m4a|aac|ogg|opus|aiff|aif|wma)$/i.test(name);
}

function classifyLyric(name: string): boolean {
  return /\.(lrc|txt|srt|vtt|sbv|ass|ssa)$/i.test(name);
}

function classifyImage(name: string): boolean {
  return /\.(jpg|jpeg|png|webp|bmp|gif)$/i.test(name);
}

function addWarning(warnings: string[], message: string): void {
  if (warnings.length < 100) {
    warnings.push(message);
  } else if (warnings.length === 100) {
    warnings.push('其余扫描警告过多，已省略；请缩小目录范围后重试。');
  }
}

export class FolderScanner {
  static readonly MAX_SANDBOX_COPIES: number = 300;
  static readonly MAX_METADATA_ATTEMPTS: number = 2000;

  static async scan(
    folderUri: string,
    maxFiles: number = 10000,
    filesDir: string = '',
    onProgress?: ScanProgressFn,
    shouldCancel?: ScanCancelFn
  ): Promise<FolderScanResult> {
    const audioFiles: AudioMatchInput[] = [];
    const lyricFiles: LyricMatchInput[] = [];
    const imageFiles: ScannedImageFile[] = [];
    const warnings: string[] = [];
    const rootPath: string = new fileUri.FileUri(folderUri).path;
    const queue: PendingDirectory[] = [{ uri: rootPath, depth: 0 }];
    let queueHead: number = 0;
    const visitedDirectories: Set<string> = new Set<string>();
    const maxDirectories: number = 2000;
    let visitedFiles: number = 0;

    // 文件夹遍历始终只读；数组索引队列避免 shift() 的反复搬移。
    if (onProgress !== undefined) onProgress('正在查找文件…');
    while (queueHead < queue.length && visitedFiles < maxFiles && visitedDirectories.size < maxDirectories) {
      if (shouldCancel !== undefined && shouldCancel()) throw new Error('扫描已取消');
      const current: PendingDirectory = queue[queueHead++];
      if (visitedDirectories.has(current.uri)) continue;
      visitedDirectories.add(current.uri);

      let entries: string[];
      try {
        entries = await fileIo.listFile(current.uri);
      } catch (error) {
        const detail: string = error instanceof Error ? error.message : '未知错误';
        if (current.depth === 0) {
          throw new Error('无法读取所选目录。系统可能未向此设备提供目录遍历能力，或所选 URI 需要转换/重新授权。详情：' + detail);
        }
        addWarning(warnings, '无法读取子目录 ' + leafName(current.uri) + '：' + detail);
        continue;
      }

      for (let i: number = 0; i < entries.length; i++) {
        if (shouldCancel !== undefined && shouldCancel()) throw new Error('扫描已取消');
        if (visitedFiles >= maxFiles) break;
        const entry: string = entries[i];
        const childPath: string = joinUri(current.uri, entry);
        const childUri: string = fileUri.getUriFromPath(childPath);
        let isDirectory: boolean = false;
        try {
          const stat = await fileIo.stat(childPath);
          isDirectory = stat.isDirectory();
        } catch (error) {
          const detail: string = error instanceof Error ? error.message : '未知错误';
          addWarning(warnings, '跳过无法识别的条目 ' + leafName(childPath) + '：' + detail);
          continue;
        }

        if (isDirectory) {
          if (current.depth < 16) {
            queue.push({ uri: childPath, depth: current.depth + 1 });
          } else {
            addWarning(warnings, '目录层级超过 16 层，已跳过更深的子目录：' + leafName(childPath));
          }
          continue;
        }

        visitedFiles++;
        if (onProgress !== undefined && visitedFiles % 50 === 0) {
          onProgress('已找到 ' + visitedFiles + ' 个文件，继续扫描中…');
        }
        const name: string = leafName(childPath);
        if (classifyAudio(name)) {
          audioFiles.push({ id: childUri, name, uri: childUri });
        } else if (classifyLyric(name)) {
          lyricFiles.push({ id: childUri, name, uri: childUri });
        } else if (classifyImage(name)) {
          imageFiles.push({ id: childUri, name, uri: childUri });
        }
      }
    }

    if (visitedFiles >= maxFiles) {
      addWarning(warnings, '已达到本轮扫描的文件数上限（' + maxFiles + '）。请分批选择较小的目录。');
    }
    if (visitedDirectories.size >= maxDirectories) {
      addWarning(warnings, '已达到本轮扫描的目录数上限（' + maxDirectories + '）。为保护响应速度，未继续遍历更深的目录。');
    }
    const maxLyricMetadataReads: number = 1000;
    const lyricMetadataCount: number = Math.min(lyricFiles.length, maxLyricMetadataReads);
    if (onProgress !== undefined && lyricMetadataCount > 0) onProgress('正在读取歌词信息…');
    for (let i: number = 0; i < lyricMetadataCount; i++) {
      if (shouldCancel !== undefined && shouldCancel()) throw new Error('扫描已取消');
      if (onProgress !== undefined && i % 25 === 0) {
        onProgress('读取歌词信息 ' + (i + 1) + ' / ' + lyricMetadataCount);
      }
      const lyric: LyricMatchInput = lyricFiles[i];
      if (lyric.uri === undefined) continue;
      try {
        const text: string = await FileSelectionService.readUtf8Text(lyric.uri, 128 * 1024);
        const document = LyricEngine.parse(text, lyric.name);
        if (document.metadata['ti'] !== undefined && document.metadata['ti'].trim().length > 0) {
          lyric.title = document.metadata['ti'].trim();
        }
        if (document.metadata['ar'] !== undefined && document.metadata['ar'].trim().length > 0) {
          lyric.artist = document.metadata['ar'].trim();
        }
      } catch (error) {
        const detail: string = error instanceof Error ? error.message : '未知错误';
        addWarning(warnings, '未能读取歌词头部元数据，将仅按文件名匹配：' + lyric.name + '（' + detail + '）');
      }
    }
    if (lyricFiles.length > maxLyricMetadataReads) {
      addWarning(warnings, '歌词文件数量超过头部元数据读取上限 ' + maxLyricMetadataReads + '；其余歌词仍参与文件名匹配。');
    }

    if (filesDir.length > 0 && audioFiles.length > 0) {
      const maxSandboxCopies: number = FolderScanner.MAX_SANDBOX_COPIES;
      const maxMetadataAttempts: number = FolderScanner.MAX_METADATA_ATTEMPTS;
      let sandboxCopies: number = 0;
      let skippedMetadata: number = Math.max(0, audioFiles.length - maxMetadataAttempts);
      const metadataCount: number = Math.min(audioFiles.length, maxMetadataAttempts);
      for (let i: number = 0; i < metadataCount; i++) {
        if (shouldCancel !== undefined && shouldCancel()) throw new Error('扫描已取消');
        if (onProgress !== undefined && i % 10 === 0) {
          onProgress('读取音频标签 ' + (i + 1) + ' / ' + metadataCount);
        }
        const audio: AudioMatchInput = audioFiles[i];
        if (audio.uri === undefined) continue;
        const allowCopy: boolean = sandboxCopies < maxSandboxCopies;
        if (!AudioMetadataService.canReadDirectly(audio.uri) && !allowCopy) {
          skippedMetadata++;
          continue;
        }
        try {
          const readResult = await AudioMetadataService.readForMatching(
            audio.uri, audio.name, filesDir, allowCopy, () => { sandboxCopies++; });
          audio.title = readResult.metadata.title;
          audio.artist = readResult.metadata.artist;
        } catch (error) {
          const detail: string = error instanceof Error ? error.message : '未知错误';
          addWarning(warnings, '未能读取音频标签，改用文件名匹配：' + audio.name + '（' + detail + '）');
        }
      }
      if (skippedMetadata > 0) {
        addWarning(warnings, '有 ' + skippedMetadata + ' 个音频未进行元数据读取；这些文件仍参与文件名匹配。单轮元数据读取上限为 ' + maxMetadataAttempts + ' 个，沙箱全文件复制上限为 ' + maxSandboxCopies + ' 个。');
      }
    }

    if (audioFiles.length === 0) addWarning(warnings, '没有发现扩展名位于支持范围内的音频文件。');
    if (lyricFiles.length === 0) addWarning(warnings, '没有发现扩展名位于支持范围内的歌词文件。');

    if (shouldCancel !== undefined && shouldCancel()) throw new Error('扫描已取消');
    if (onProgress !== undefined) onProgress('扫描完成，准备匹配…');
    return { audioFiles, lyricFiles, imageFiles, warnings, visitedFiles };
  }
}
