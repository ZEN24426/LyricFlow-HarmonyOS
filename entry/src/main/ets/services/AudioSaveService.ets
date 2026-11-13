import { common } from '@kit.AbilityKit';
import { AudioMetadataWriter } from '@dabing/taglib_harmony';
import { AudioMetadataService } from './AudioMetadataService';
import { DirectAudioWriteService } from './DirectAudioWriteService';
import { ExportService } from './ExportService';

/**
 * A single editing pipeline with two deliberately separate persistence strategies.
 * The caller prepares metadata once; neither strategy parses lyrics or owns UI state.
 */
export type AudioSaveMode = 'exportCopy' | 'writeOriginal';

export interface AudioSaveRequest {
  context: common.UIAbilityContext;
  sourceUri: string;
  sourceName: string;
  workingPath: string;
  fields: AudioMetadataWriter;
}

export interface AudioSaveResult {
  mode: AudioSaveMode;
  outputName: string;
  outputUri: string;
  backupPath: string;
  externalBackupName: string;
  externalBackupUri: string;
}

export class AudioSaveService {
  static async save(mode: AudioSaveMode, request: AudioSaveRequest): Promise<AudioSaveResult> {
    if (request.sourceUri.length === 0 || request.sourceName.length === 0) {
      throw new Error('请先选择音频文件。');
    }
    if (mode === 'writeOriginal') {
      // Guarded ACL adapter owns authorization, preflight, backup and rollback.
      const result = await DirectAudioWriteService.writeMetadataInPlace(
        request.context, request.sourceUri, request.sourceName, request.fields, request.workingPath
      );
      return {
        mode: 'writeOriginal',
        outputName: request.sourceName,
        outputUri: request.sourceUri,
        backupPath: result.backupPath,
        externalBackupName: result.externalBackupName,
        externalBackupUri: result.externalBackupUri
      };
    }
    if (mode !== 'exportCopy') {
      throw new Error('不支持的音频保存模式。');
    }
    if (request.workingPath.length === 0) {
      throw new Error('缺少用于导出的工作副本。');
    }

    // Preserve the existing behavior: edit a *new* working copy, not the
    // imported working file or the original URI.
    let exportPath: string = '';
    try {
      exportPath = await AudioMetadataService.makeWorkingCopy(
        request.workingPath, request.context.filesDir, request.sourceName
      );
      await AudioMetadataService.write(exportPath, request.fields);
      const name = AudioMetadataService.safeOutputName(request.sourceName, request.fields.title || '');
      const saved = await ExportService.saveAudioToDownload(request.context, name, exportPath);
      if (saved === undefined) {
        throw new Error('已取消新音频导出，原始音频未修改。');
      }
      return {
        mode: 'exportCopy',
        outputName: saved.name,
        outputUri: saved.uri,
        backupPath: '',
        externalBackupName: '',
        externalBackupUri: ''
      };
    } finally {
      if (exportPath.length > 0) {
        await AudioMetadataService.removeWorkingFile(exportPath);
      }
    }
  }
}
