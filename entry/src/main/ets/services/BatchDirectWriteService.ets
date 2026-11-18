import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { AudioMetadataWriter } from './AudioMetadataTypes';
import { AudioMetadataService } from './AudioMetadataService';
import { DirectAudioWriteService, DirectWriteReport } from './DirectAudioWriteService';
import { FileSelectionService } from './FileSelectionService';
import { MatchCandidate } from './MatchEngine';
import { LyricDocument } from './LyricEngine';
import { parseLyricAsync, convertToLrcAsync } from './BackgroundTasks';

export interface BatchDirectWriteSuccess {
  candidateKey: string;
  audioName: string;
  backupName: string;
  backupUri: string;
}

export interface BatchDirectWriteResult {
  succeeded: number;
  failed: number;
  unprocessed: number;
  cancelled: boolean;
  details: string[];
  completed: BatchDirectWriteSuccess[];
}

function message(error: Object): string {
  return error instanceof Error ? error.message : String(error);
}

function progress(callback: (text: string) => void, text: string): void {
  // A presentation callback cannot turn an already committed write into failure.
  try { callback(text); } catch (_error) {}
}

function cancelled(callback: () => boolean): boolean {
  try { return callback(); } catch (_error) { return true; }
}

/**
 * Confirmed folder matches only. A batch is deliberately not atomic: every
 * successful item has its own verified backup and durable recovery record.
 * On the first failure no later item is started, including when the previous
 * item's recovery could not be confirmed. Cancellation is only between items.
 */
export class BatchDirectWriteService {
  static async run(
    context: common.UIAbilityContext,
    confirmed: MatchCandidate[],
    onProgress: (text: string) => void,
    shouldCancel: () => boolean
  ): Promise<BatchDirectWriteResult> {
    const total: number = confirmed.length;
    const result: BatchDirectWriteResult = {
      succeeded: 0, failed: 0, unprocessed: total, cancelled: false, details: [], completed: []
    };
    if (total === 0) return result;

    // Validate the entire selection before changing anything. Inode checks are
    // conservative: without device IDs, aliases and collisions are refused.
    const seenUris: Set<string> = new Set<string>();
    const seenInodes: Set<string> = new Set<string>();
    const seenKeys: Set<string> = new Set<string>();
    const sourceInodes: string[] = [];
    for (let i: number = 0; i < total; i++) {
      if (cancelled(shouldCancel)) { result.cancelled = true; return result; }
      const item: MatchCandidate = confirmed[i];
      try {
        if (item.state !== 'confirmed') throw new Error('配对尚未确认。');
        if (item.key.length === 0 || seenKeys.has(item.key)) throw new Error('配对标识缺失或重复。');
        if (item.audioUri === undefined || item.audioUri.length === 0 ||
            item.lyricUri === undefined || item.lyricUri.length === 0) {
          throw new Error('缺少音频或歌词授权 URI。');
        }
        if (!/\.(mp3|flac)$/i.test(item.audioName)) throw new Error('批量直写仅支持 MP3 和 FLAC。');
        if (!/\.(lrc|txt|srt|vtt|sbv|ass|ssa)$/i.test(item.lyricName)) throw new Error('歌词格式不受支持。');
        if (item.audioUri === item.lyricUri) throw new Error('音频与歌词不能是同一文件。');
        if (seenUris.has(item.audioUri)) throw new Error('同一音频在批次中重复。');
        const sourceStat: fileIo.Stat = await fileIo.stat(item.audioUri);
        const inode: string = sourceStat.ino.toString();
        if (!sourceStat.isFile() || inode === '0') throw new Error('无法确认音频文件身份。');
        if (seenInodes.has(inode)) throw new Error('音频文件身份重复或无法区分。');
        seenUris.add(item.audioUri);
        seenInodes.add(inode);
        seenKeys.add(item.key);
        sourceInodes.push(inode);
        progress(onProgress, '正在检查访问权限 ' + (i + 1) + ' / ' + total + '：' + item.audioName);
        await DirectAudioWriteService.probe(context, item.audioUri, item.audioName);
      } catch (error) {
        result.failed = 1;
        result.unprocessed = total - 1;
        result.details.push('预检失败（尚未开始写入） ' + item.audioName + '：' + message(error as Object));
        return result;
      }
    }

    for (let i: number = 0; i < total; i++) {
      if (cancelled(shouldCancel)) { result.cancelled = true; break; }
      const item: MatchCandidate = confirmed[i];
      const audioUri: string = item.audioUri as string;
      const lyricUri: string = item.lyricUri as string;
      let sourceWorkingPath: string = '';
      try {
        progress(onProgress, '正在处理 ' + (i + 1) + ' / ' + total + '：' + item.audioName);
        const sourceStat: fileIo.Stat = await fileIo.stat(audioUri);
        if (!sourceStat.isFile() || sourceStat.ino.toString() !== sourceInodes[i]) {
          throw new Error('预检后音频文件身份发生变化，请重新扫描并确认。');
        }
        const lyricText: string = await FileSelectionService.readUtf8Text(lyricUri);
        if (lyricText.trim().length === 0) throw new Error('歌词为空，已拒绝覆盖原歌词。');
        if (lyricText.indexOf('\uFFFD') >= 0 || lyricText.indexOf('\u0000') >= 0) {
          throw new Error('歌词编码无法可靠识别，请先转换为 UTF-8 后重新扫描。');
        }
        let embeddedLyrics: string = lyricText;
        const lowerLyricName: string = item.lyricName.toLowerCase();
        if (!lowerLyricName.endsWith('.lrc') && !lowerLyricName.endsWith('.txt')) {
          const document: LyricDocument = await parseLyricAsync(lyricText, item.lyricName);
          const converted = await convertToLrcAsync(document);
          embeddedLyrics = converted.text;
          if (embeddedLyrics.trim().length === 0) throw new Error('歌词转换结果为空，已拒绝覆盖原歌词。');
          if (converted.warnings.length > 0) {
            throw new Error('歌词转换可能丢失信息，已停止批量直写：' + converted.warnings.join('；'));
          }
        }
        const working = await AudioMetadataService.importToSandbox(audioUri, item.audioName, context.filesDir);
        sourceWorkingPath = working.workingPath;
        if (cancelled(shouldCancel)) { result.cancelled = true; break; }
        const fields: AudioMetadataWriter = { lyrics: embeddedLyrics };
        const report: DirectWriteReport = await DirectAudioWriteService.writeMetadataInPlace(
          context, audioUri, item.audioName, fields, sourceWorkingPath
        );
        result.completed.push({ candidateKey: item.key, audioName: item.audioName,
          backupName: report.externalBackupName, backupUri: report.externalBackupUri });
        result.succeeded++;
        result.unprocessed--;
      } catch (error) {
        result.failed = 1;
        result.unprocessed--;
        result.details.push(item.audioName + '：' + message(error as Object));
        break;
      } finally {
        if (sourceWorkingPath.length > 0) {
          try { await AudioMetadataService.removeWorkingFile(sourceWorkingPath); } catch (_cleanupError) {}
        }
      }
    }
    return result;
  }
}
