import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';

export type DocumentKind = 'audio' | 'lyric' | 'image';

export interface SelectedDocument {
  uri: string;
  name: string;
}

function displayName(uri: string): string {
  const withoutQuery: string = uri.split('?')[0].split('#')[0];
  const pieces: string[] = withoutQuery.split('/');
  const leaf: string = pieces.length > 0 ? pieces[pieces.length - 1] : withoutQuery;
  try {
    return decodeURIComponent(leaf);
  } catch (_error) {
    return leaf;
  }
}

function isAllowedExtension(name: string, kind: DocumentKind): boolean {
  const lower: string = name.toLowerCase();
  if (kind === 'audio') {
    return /\.(mp3|flac|wav|m4a|aac|ogg|opus|aiff|aif|wma)$/i.test(lower);
  }
  if (kind === 'image') return /\.(jpg|jpeg|png|webp|bmp|gif)$/i.test(lower);
  return /\.(lrc|txt|srt|vtt|sbv|ass|ssa)$/i.test(lower);
}

export class FileSelectionService {
  static async selectOne(
    context: common.UIAbilityContext,
    kind: DocumentKind
  ): Promise<SelectedDocument | undefined> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = kind === 'audio'
      ? ['.mp3', '.flac', '.wav', '.m4a', '.aac', '.ogg', '.opus', '.aiff', '.aif', '.wma']
      : kind === 'image'
        ? ['.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif']
        : ['.lrc', '.txt', '.srt', '.vtt', '.sbv', '.ass', '.ssa'];

    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: Array<string> = await documentPicker.select(options);
    if (uris.length === 0) return undefined;

    const selected: SelectedDocument = {
      uri: uris[0],
      name: displayName(uris[0])
    };
    if (!isAllowedExtension(selected.name, kind)) {
      throw new Error(kind === 'audio'
        ? '所选文件扩展名不在当前支持范围内。请选择 MP3、FLAC、WAV、M4A、AAC、OGG、OPUS、AIFF 或 WMA 文件。'
        : kind === 'image'
          ? '封面仅支持 JPG、PNG、WebP、BMP 或 GIF 图片。'
          : '所选文件扩展名不在当前支持范围内。请选择 LRC、TXT、SRT、VTT、SBV、ASS 或 SSA 文件。');
    }
    return selected;
  }

  static async selectCoverFromFiles(context: common.UIAbilityContext): Promise<SelectedDocument | undefined> {
    return FileSelectionService.selectOne(context, 'image');
  }

  static async selectCoverFromAlbum(context: common.UIAbilityContext): Promise<SelectedDocument | undefined> {
    const options: picker.PhotoSelectOptions = new picker.PhotoSelectOptions();
    options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 1;
    const photoPicker: picker.PhotoViewPicker = new picker.PhotoViewPicker(context);
    const result: picker.PhotoSelectResult = await photoPicker.select(options);
    if (result.photoUris.length === 0) return undefined;
    const uri: string = result.photoUris[0];
    const selected: SelectedDocument = {
      uri,
      name: displayName(uri)
    };
    // 相册 PhotoViewPicker 的 URI 不保证携带扩展名，真实类型由图片解码器识别。
    return selected;
  }

  static async selectFolder(context: common.UIAbilityContext): Promise<SelectedDocument | undefined> {
    if (!canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
      throw new Error('当前设备未报告文件夹选择能力。可先升级系统或使用单文件导入；应用不会改用未经授权的绝对路径扫描。');
    }

    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: Array<string> = await documentPicker.select(options);
    if (uris.length === 0) return undefined;
    return { uri: uris[0], name: displayName(uris[0]) };
  }

  /**
   * Request a fresh, temporary grant for the exact folder that was scanned.
   * This does not persist write access; each source file must still be opened
   * with READ_WRITE before modification, and errors must stop that write.
   */
  static async reauthorizeFolderForBatch(context: common.UIAbilityContext, scannedUri: string): Promise<boolean> {
    if (scannedUri.length === 0) throw new Error('缺少已扫描文件夹的授权地址，请先重新选择并扫描文件夹。');
    const selected: SelectedDocument | undefined = await FileSelectionService.selectFolder(context);
    if (selected === undefined) return false;
    // Compare the complete provider URI, not just a path or folder display
    // name: different authorities may expose identically named paths.
    const expected: string = scannedUri.replace(/\/+$/, '');
    const actual: string = selected.uri.replace(/\/+$/, '');
    if (expected.length === 0 || expected !== actual) {
      throw new Error('选择的文件夹与本轮扫描的文件夹不同，未开始直写。请重新选择原文件夹，或先重新扫描新文件夹。');
    }
    return true;
  }

  static async readUtf8Text(uri: string, maxBytes: number = 4 * 1024 * 1024): Promise<string> {
    let file: fileIo.File;
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    } catch (error) {
      throw error as Error;
    }
    const chunks: Uint8Array[] = [];
    let totalBytes: number = 0;
    try {
      while (true) {
        const buffer: ArrayBuffer = new ArrayBuffer(64 * 1024);
        const bytesRead: number = await fileIo.read(file.fd, buffer, { length: 64 * 1024 });
        if (bytesRead <= 0) break;
        totalBytes += bytesRead;
        if (totalBytes > maxBytes) {
          throw new Error('歌词文件超过 4 MiB 的初版读取上限，为避免内存占用过高已停止读取。');
        }
        chunks.push(new Uint8Array(buffer, 0, bytesRead));
      }
    } catch (error) {
      throw error as Error;
    } finally {
      try {
        fileIo.closeSync(file.fd);
      } catch (_closeError) {
        // The read error, if any, should remain the primary error.
      }
    }

    const bytes: Uint8Array = new Uint8Array(totalBytes);
    let offset: number = 0;
    for (let i: number = 0; i < chunks.length; i++) {
      bytes.set(chunks[i], offset);
      offset += chunks[i].length;
    }
    const decoderOptions: util.TextDecoderOptions = { fatal: false, ignoreBOM: true };
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', decoderOptions);
    const utf8Text: string = decoder.decodeToString(bytes);
    if (utf8Text.indexOf('\uFFFD') < 0) return utf8Text;
    try {
      const legacyDecoder: util.TextDecoder = util.TextDecoder.create('gbk', decoderOptions);
      const legacyText: string = legacyDecoder.decodeToString(bytes);
      const utf8Errors: number = (utf8Text.match(/\uFFFD/g) || []).length;
      const legacyErrors: number = (legacyText.match(/\uFFFD/g) || []).length;
      if (legacyErrors < utf8Errors) return legacyText;
    } catch (_encodingError) {
      // GBK is not available on every runtime; keep the UTF-8 replacement text for inspection.
    }
    return utf8Text;
  }

  static async readCoverPixelMap(uri: string): Promise<image.PixelMap> {
    let file: fileIo.File;
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    } catch (error) {
      throw error as Error;
    }
    let source: image.ImageSource | undefined = undefined;
    try {
      source = image.createImageSource(file.fd);
      const info: image.ImageInfo = await source.getImageInfo();
      const size: number = Math.max(info.size.width, info.size.height);
      if (size <= 0) throw new Error('无法识别图片尺寸，请选择其他封面');
      // 最大边解码到 1024 像素，既够音频封面使用，也避免大照片占用过多内存。
      const scale: number = Math.min(1, 1024 / size);
      const options: image.DecodingOptions = {
        desiredSize: {
          width: Math.max(1, Math.round(info.size.width * scale)),
          height: Math.max(1, Math.round(info.size.height * scale))
        }
      };
      return await source.createPixelMap(options);
    } finally {
      if (source !== undefined) {
        try { await source.release(); } catch (_releaseError) {}
      }
      try { fileIo.closeSync(file.fd); } catch (_error) {}
    }
  }
}
