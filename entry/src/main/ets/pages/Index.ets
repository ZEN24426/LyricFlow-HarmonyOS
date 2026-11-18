import { common } from '@kit.AbilityKit';
import { FileSelectionService, SelectedDocument } from '../services/FileSelectionService';
import { FolderScanner, FolderScanResult } from '../services/FolderScanner';
import { AudioMatchInput, LyricMatchInput, MatchCandidate, MatchReviewState } from '../services/MatchEngine';
import { LyricDocument } from '../services/LyricEngine';
import { AudioMetadataService } from '../services/AudioMetadataService';
import { AudioSaveService } from '../services/AudioSaveService';
import { DirectAudioWriteService } from '../services/DirectAudioWriteService';
import { PendingDirectWrite, getPendingDirectWrite, acknowledgeDirectWrite } from '../services/DirectWriteJournal';
import { DIRECT_WRITE_BUSY } from '../services/DirectWriteGuard';
import { ExportService } from '../services/ExportService';
import { parseLyricAsync, convertToLrcAsync, matchAsync } from '../services/BackgroundTasks';
import { BusinessError } from '@kit.BasicServicesKit';
import { FolderAccessService } from '../services/FolderAccessService';
import { BatchDirectWriteService, BatchDirectWriteResult } from '../services/BatchDirectWriteService';
import { AudioMetadataWriter } from '../services/AudioMetadataTypes';
import { image } from '@kit.ImageKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';

const BLUE: string = '#3478F6';
const INK: string = '#172B4D';
const MUTED: string = '#7A8AA8';
const BG: string = '#F6F8FB';
const BORDER: string = '#DDE4EC';
const MAX_MATCH_COMPARISONS: number = 200000;

interface NumericTagField {
  value: string;
  label: string;
  key: string;
  original: number;
}

interface PreparedAudioMetadata {
  fields: AudioMetadataWriter;
  warning: string;
}

// Snapshot the displayed values at import or after a confirmed direct write.
// In particular, the filename fallback for an empty title is display-only.
interface EditBaseline {
  title: string; artist: string; album: string; genre: string; albumArtist: string;
  composer: string; comment: string; grouping: string; isrc: string; copyright: string;
  lyrics: string; year: string; track: string; disc: string; discTotal: string;
  trackTotal: string; bpm: string;
}

@Entry
@Component
struct Index {
  @State page: string = 'editor';
  @State currentTab: number = 0;
  @State toastText: string = '';
  @State busy: boolean = false;
  @State showHelp: boolean = false;
  @State activeGuide: string = '';
  @State seenGuides: string[] = [];
  @State guidesReady: boolean = false;
  private pendingGuideAction: (() => void) | undefined = undefined;
  @State moreInfoVisible: boolean = false;
  @State directOptionsVisible: boolean = false;
  @State audioSaveMode: string = 'exportCopy';
  private originalYear: number = 0;
  private originalTrack: number = 0;
  private originalDisc: number = 0;
  private originalDiscTotal: number = 0;
  private originalTrackTotal: number = 0;
  private originalBpm: number = 0;
  private editBaseline: EditBaseline | undefined = undefined;
  private coverChanged: boolean = false;

  @State audioUri: string = '';
  @State audioName: string = '';
  @State audioWorkingPath: string = '';
  @State audioTechnicalSummary: string = '';
  @State songTitle: string = '';
  @State artist: string = '';
  @State album: string = '';
  @State composer: string = '';
  @State genre: string = '';
  @State year: string = '';
  @State albumArtist: string = '';
  @State track: string = '';
  @State disc: string = '';
  @State discTotal: string = '';
  @State trackTotal: string = '';
  @State bpm: string = '';
  @State grouping: string = '';
  @State isrc: string = '';
  @State copyright: string = '';
  @State comment: string = '';

  @State coverUri: string = '';
  @State coverPixelMap: image.PixelMap | null = null;
  @State pendingCoverImage: image.PixelMap | undefined = undefined;
  @State pendingCoverName: string = '';

  @State lyricUri: string = '';
  @State lyricText: string = '';
  @State lyricSourceName: string = '';
  @State lyricSummary: string = '';

  @State folderUri: string = '';
  @State folderName: string = '';
  @State audioFiles: AudioMatchInput[] = [];
  @State lyricFiles: LyricMatchInput[] = [];
  @State candidates: MatchCandidate[] = [];
  @State candidate: number = 0;
  @State rejectedCandidateKeys: string[] = [];
  @State scannedAudioCount: number = 0;
  @State scannedLyricCount: number = 0;
  @State scannedImageCount: number = 0;
  @State scanWarnings: string[] = [];
  @State scanning: boolean = false;
  @State scanStatus: string = '';
  @State scanCancelRequested: boolean = false;
  @State batchRunning: boolean = false;
  @State batchStopRequested: boolean = false;
  @State batchStatus: string = '';
  @State batchDetails: string[] = [];
  @State batchCompletedKeys: string[] = [];

  aboutToAppear(): void {
    this.restoreSavedFolder();
    this.loadFirstUseGuides();
    this.checkInterruptedDirectWrite();
  }

  private async checkInterruptedDirectWrite(showEmpty: boolean = false): Promise<void> {
    try {
      const pending: PendingDirectWrite | undefined = await getPendingDirectWrite(this.ctx());
      if (pending === undefined) {
        if (showEmpty) this.notify('没有需要处理的直写恢复记录。');
        return;
      }
      this.showPendingDirectWrite(
        '上次直写可能被中断：' + pending.sourceName + '。原文件位置：' + pending.sourceUri +
        '。请先检查原文件，并在下载目录查找备份：' +
        pending.externalBackupName + '。确认已处理之前，应用不会继续直写。', pending.operationId);
    } catch (error) {
      if (this.describeError(error).indexOf(DIRECT_WRITE_BUSY) >= 0) {
        this.notify('直写正在进行，请稍后检查恢复记录。');
        return;
      }
      this.showPendingDirectWrite('无法读取或确认上次直写记录：' + this.describeError(error) +
        '。请检查下载目录中的 LyricFlow-backup 文件夹，确认备份和原文件状态。', '');
    }
  }

  private showPendingDirectWrite(message: string, operationId: string): void {
    if (operationId.length === 0) {
      this.getUIContext().showAlertDialog({
        title: '请检查直写备份', message: message,
        primaryButton: { value: '知道了', action: () => {} }
      });
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '请检查直写备份',
      message: message,
      primaryButton: { value: '稍后处理', action: () => {} },
      secondaryButton: { value: '我已检查并处理', action: () => { this.acknowledgePendingDirectWrite(operationId); } }
    });
  }

  private async acknowledgePendingDirectWrite(operationId: string): Promise<void> {
    try {
      await acknowledgeDirectWrite(this.ctx(), operationId);
      this.notify('已确认处理上次直写记录');
    } catch (error) {
      this.notify('无法清除直写记录：' + this.describeError(error));
    }
  }

  aboutToDisappear(): void {
    this.clearTask();
  }


  // 新手引导只在每个操作第一次触发，已阅读记录保存在应用偏好中。
  private async loadFirstUseGuides(): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.ctx(), { name: 'lyricflow_first_use_guides_v1' });
      const saved: string = store.getSync('seen', '') as string;
      this.seenGuides = saved.length > 0 ? saved.split('|') : [];
    } catch (_error) {
      this.seenGuides = [];
    }
    this.guidesReady = true;
    if (this.seenGuides.indexOf('welcome') < 0) {
      this.activeGuide = 'welcome';
    }
  }

  private async rememberGuide(key: string): Promise<void> {
    if (key.length === 0 || this.seenGuides.indexOf(key) >= 0) return;
    this.seenGuides = this.seenGuides.concat([key]);
    try {
      const store = await preferences.getPreferences(this.ctx(), { name: 'lyricflow_first_use_guides_v1' });
      store.putSync('seen', this.seenGuides.join('|'));
      await store.flush();
    } catch (_error) {
      // 保存失败不应影响用户继续操作；下次启动时可以再次看到引导。
    }
  }

  private guideThen(key: string, action: () => void): void {
    // Routine actions are explained in place; do not interrupt every first tap.
    action();
  }

  private switchMainTab(tab: number): void {
    if (this.busy) {
      this.notify('当前正在处理文件，请完成后再切换模式');
      return;
    }
    this.currentTab = tab;
    this.page = tab === 0 ? 'editor' : 'folder';
  }

  private confirmReplaceAudio(): void {
    if (this.busy) return;
    this.getUIContext().showAlertDialog({
      title: '更换歌曲？',
      message: '当前编辑任务会被新歌曲替换。请先保存需要保留的修改。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '选择新歌曲', action: () => { this.importAudio(); } }
    });
  }

  private confirmChangeFolder(): void {
    if (this.busy) return;
    if (this.candidates.length === 0) { this.chooseFolder(); return; }
    this.getUIContext().showAlertDialog({
      title: '更换文件夹？',
      message: '选择新文件夹后，当前匹配结果和确认状态会被清除。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '选择新文件夹', action: () => { this.chooseFolder(); } }
    });
  }

  private closeGuide(continueAction: boolean): void {
    const key: string = this.activeGuide;
    if (key.length === 0) return;
    const action: (() => void) | undefined = this.pendingGuideAction;
    this.pendingGuideAction = undefined;
    this.activeGuide = '';
    this.rememberGuide(key);
    // 点击遮罩仅关闭说明；只有明确点击继续才执行原来的操作。
    if (continueAction && action !== undefined) action();
  }

  private guideTitle(key: string): string {
    switch (key) {
      case 'welcome': return '欢迎来到 LyricFlow！';
      case 'switch_mode': return '这里可以切换模式';
      case 'import_audio': return '先选一首歌吧';
      case 'change_audio': return '准备换一首歌？';
      case 'edit_tags': return '修改歌曲信息';
      case 'cover': return '给歌曲换张封面';
      case 'confirm_cover': return '使用这张封面';
      case 'import_lyrics': return '导入一份歌词';
      case 'edit_lyrics': return '歌词可以直接修改';
      case 'parse_lyrics': return '重新检查歌词';
      case 'paste_lyrics': return '从剪贴板粘贴歌词';
      case 'save_lyrics': return '先保存这次编辑';
      case 'export_lyrics': return '把歌词单独导出';
      case 'export_audio': return '生成新的歌曲文件';
      case 'more_tags': return '还有更多歌曲信息';
      case 'choose_folder': return '选一个歌曲文件夹';
      case 'scan_folder': return '帮歌曲寻找歌词';
      case 'review_match': return '这对歌词匹配吗？';
      case 'export_matches': return '导出已确认的歌曲';
      default: return '小提示';
    }
  }

  private guideBody(key: string): string {
    switch (key) {
      case 'welcome':
        return '编辑歌曲信息、封面和歌词，或为文件夹里的歌曲匹配歌词。\n有疑问时，可以随时点右上角查看说明。';
      case 'switch_mode':
        return '轻点左上角的 LyricFlow，就能切换单曲编辑和文件夹匹配。切换模式不会清空正在编辑的歌曲，安心操作喵～';
      case 'import_audio':
        return '选一首手机里的歌曲，我们会先复制一份到应用里，再读取歌名、歌手和封面。原来的音频不会被修改喵。';
      case 'change_audio':
        return '重新选择会开始编辑另一首歌。上一首尚未导出的修改不会保留，记得先导出再换喵。';
      case 'edit_tags':
        return '歌名、歌手和专辑都可以在这里改。现在只是修改当前编辑内容，等你导出新音频副本才会写进文件。';
      case 'cover':
        return '可以从相册或文件中选择图片。我会先让你看看预览；确认后，新封面才会跟着下次导出写入歌曲。';
      case 'confirm_cover':
        return '确认后，这张图片会成为当前准备使用的封面。还需要导出新音频副本，才会真正写进歌曲里。';
      case 'import_lyrics':
        return '选一份歌词文件，就能把文字带进编辑页。支持 LRC、TXT 和常见字幕格式；原歌词文件不会被改动。';
      case 'edit_lyrics':
        return '可以直接改歌词，也能导入、使用系统“粘贴”按钮或重新解析。点“保存并返回”只是留在当前任务，还没有写入歌曲。';
      case 'parse_lyrics':
        return '让应用再看看当前歌词的格式、时间和行数。这里只做检查，不会替你修改原来的歌词文件。';
      case 'paste_lyrics':
        return '点系统“粘贴”按钮就能读取剪贴板文字。它只会替换当前编辑框里的歌词，不会动手机中的原文件喵。';
      case 'save_lyrics':
        return '把当前歌词留在这次编辑任务里，然后回到歌曲页面。想要生成文件，还需要点导出喵。';
      case 'export_lyrics':
        return '把当前歌词另存为一个文件。字幕歌词会尝试转成 LRC，部分样式可能丢失；遇到同名文件会自动编号，不会主动覆盖之前的导出。';
      case 'export_audio':
        return '把改好的歌名、封面和歌词写进一份新的音频文件，保存到系统提供的下载位置。原歌曲不变，但如果下载位置已有同名文件，会自动换个文件名保存喵。';
      case 'more_tags':
        return '这里还可以修改作曲者、年份、曲目编号、BPM 等信息。它们会在导出新音频副本时一起写入。';
      case 'choose_folder':
        return '选一个装有歌曲和歌词的文件夹。我们只会读取内容来寻找匹配，并尝试记住访问授权；扫描不会修改你的文件。';
      case 'scan_folder':
        return '会寻找文件夹里的歌曲和歌词，再根据文件名、歌名等信息推荐配对。这里只是找候选，不会自动改动任何歌曲。';
      case 'review_match':
        return '觉得配得对就点“确认”；不对就“取消此匹配”；拿不准可以“暂缓”。这一步只是在做选择，还不会改动文件。';
      case 'export_matches':
        return '只处理你确认过的配对：把歌词写进新的音频副本，保存到系统提供的下载位置。原歌曲不变，遇到同名文件会自动编号保存。';
      default:
        return '看完后可以继续操作，也可以轻点卡片外的空白处关闭喵。';
    }
  }

  private notify(message: string): void {
    this.toastText = message;
  }

  private showExportSuccess(message: string): void {
    // 正常完成时不占用页面底部空间，与元数据读取成功提示保持一致。
    this.notify('');
    this.getUIContext().getPromptAction().showToast({ message, duration: 2000 });
  }

  private resetFolderResults(): void {
    this.audioFiles = [];
    this.lyricFiles = [];
    this.candidates = [];
    this.candidate = 0;
    this.rejectedCandidateKeys = [];
    this.scannedAudioCount = 0;
    this.scannedLyricCount = 0;
    this.scannedImageCount = 0;
    this.scanWarnings = [];
    this.scanStatus = '';
    this.batchStatus = '';
    this.batchDetails = [];
    this.batchCompletedKeys = [];
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private describeError(error: Object, fallback: string = '未知错误'): string {
    if (error instanceof Error) return error.message;
    const msg: string = (error as BusinessError).message || '';
    return msg.length > 0 ? msg : fallback;
  }

  private clearTask(): void {
    if (this.audioWorkingPath.length > 0) AudioMetadataService.removeWorkingFile(this.audioWorkingPath);
    this.audioUri = '';
    this.audioName = '';
    this.audioWorkingPath = '';
    this.audioSaveMode = 'exportCopy';
    this.directOptionsVisible = false;
    this.originalYear = 0;
    this.originalTrack = 0;
    this.originalDisc = 0;
    this.originalDiscTotal = 0;
    this.originalTrackTotal = 0;
    this.originalBpm = 0;
    this.editBaseline = undefined;
    this.coverChanged = false;
    this.audioTechnicalSummary = '';
    this.songTitle = '';
    this.artist = '';
    this.album = '';
    this.composer = '';
    this.genre = '';
    this.year = '';
    this.albumArtist = '';
    this.track = '';
    this.disc = '';
    this.discTotal = '';
    this.trackTotal = '';
    this.bpm = '';
    this.grouping = '';
    this.isrc = '';
    this.copyright = '';
    this.comment = '';
    this.coverUri = '';
    this.coverPixelMap = null;
    this.pendingCoverImage = undefined;
    this.pendingCoverName = '';
    this.lyricUri = '';
    this.lyricText = '';
    this.lyricSourceName = '';
    this.lyricSummary = '';
    this.moreInfoVisible = false;
  }

  private async importAudio(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.notify('');
    try {
      const context = this.ctx();
      const selected: SelectedDocument | undefined = await FileSelectionService.selectOne(context, 'audio');
      if (selected === undefined) {
        this.notify('已取消音频选择');
        return;
      }
      const previousPath: string = this.audioWorkingPath;
      // 在新音频完整复制且标签读取成功前，保留当前编辑任务。
      const working = await AudioMetadataService.importToSandbox(selected.uri, selected.name, context.filesDir);
      this.audioUri = selected.uri;
      this.audioName = selected.name;
      this.audioWorkingPath = working.workingPath;
      this.audioSaveMode = 'exportCopy';
      this.directOptionsVisible = false;
      this.originalYear = working.metadata.year;
      this.originalTrack = working.metadata.track;
      this.originalDisc = working.metadata.disc;
      this.originalDiscTotal = working.metadata.discTotal;
      this.originalTrackTotal = working.metadata.trackTotal;
      this.originalBpm = working.metadata.bpm;
      this.lyricUri = '';
      this.lyricSourceName = '';
      this.lyricSummary = '';
      this.lyricText = '';
      this.pendingCoverImage = undefined;
      this.pendingCoverName = '';
      this.coverUri = '';
      this.songTitle = working.metadata.title || selected.name.replace(/\.[^.]+$/, '');
      this.artist = working.metadata.artist || '';
      this.album = working.metadata.album || '';
      this.genre = working.metadata.genre || '';
      this.year = working.metadata.year > 0 ? working.metadata.year.toString() : '';
      this.albumArtist = working.metadata.albumArtist || '';
      this.composer = working.metadata.composer || '';
      this.track = working.metadata.track > 0 ? working.metadata.track.toString() : '';
      this.disc = working.metadata.disc > 0 ? working.metadata.disc.toString() : '';
      this.discTotal = working.metadata.discTotal > 0 ? working.metadata.discTotal.toString() : '';
      this.trackTotal = working.metadata.trackTotal > 0 ? working.metadata.trackTotal.toString() : '';
      this.bpm = working.metadata.bpm > 0 ? working.metadata.bpm.toString() : '';
      this.grouping = working.metadata.grouping || '';
      this.isrc = working.metadata.isrc || '';
      this.copyright = working.metadata.copyright || '';
      this.comment = working.metadata.comment || '';
      this.audioTechnicalSummary = (/\.aac$/i.test(this.audioName) ? '约 ' : '时长 ') + working.metadata.duration.toString() + ' 秒 · ' +
        (working.metadata.bitrate > 0 ? working.metadata.bitrate.toString() + ' kbps' : '码率未知') + ' · ' + working.metadata.sampleRate.toString() +
        ' Hz · ' + working.metadata.channels.toString() + ' 声道 · ' +
        Math.round(working.metadata.fileSize / 1024 / 1024).toString() + ' MiB';
      this.coverPixelMap = working.metadata.coverImage || null;
      if (working.metadata.lyrics && working.metadata.lyrics.length > 0) this.lyricText = working.metadata.lyrics;
      this.captureEditBaseline();
      if (previousPath.length > 0 && previousPath !== working.workingPath) {
        await AudioMetadataService.removeWorkingFile(previousPath);
      }
      // 成功提示仅短暂显示，不占用底部的持久状态栏。
      if (/\.(ogg|opus)$/i.test(selected.name)) {
        this.notify('OGG/OPUS 目前仅支持部分单流文件的副本导出，暂不支持更换封面。');
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '已成功读取音频元数据', duration: 2000 });
      }
    } catch (error) {
      this.notify('音频读取失败：' + (this.describeError(error)));
    } finally {
      this.busy = false;
    }
  }

  private async loadCoverFromFile(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const context = this.ctx();
      const selected: SelectedDocument | undefined = await FileSelectionService.selectCoverFromFiles(context);
      if (selected === undefined) {
        this.notify('已取消封面选择');
        return;
      }
      await this.stageCover(selected);
    } catch (error) {
      this.notify(this.describeError(error, '封面读取失败'));
    } finally {
      this.busy = false;
    }
  }

  private async loadCoverFromAlbum(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const context = this.ctx();
      const selected: SelectedDocument | undefined = await FileSelectionService.selectCoverFromAlbum(context);
      if (selected === undefined) {
        this.notify('已取消封面选择');
        return;
      }
      await this.stageCover(selected);
    } catch (error) {
      this.notify(this.describeError(error, '封面读取失败'));
    } finally {
      this.busy = false;
    }
  }

  private async stageCover(selected: SelectedDocument): Promise<void> {
    const preview: image.PixelMap = await FileSelectionService.readCoverPixelMap(selected.uri);
    this.pendingCoverImage = preview;
    this.pendingCoverName = selected.name;
    this.notify('已加载封面预览，请确认后应用；取消不会更改当前封面');
  }

  private async importCover(): Promise<void> {
    if (this.busy) return;
    if (/\.(ogg|opus)$/i.test(this.audioName)) { this.notify('OGG/OPUS 暂不支持更换封面，原封面会保留。'); return; }
    this.getUIContext().showAlertDialog({
      title: '选择封面来源',
      message: '从哪里选取封面图片？',
      primaryButton: {
        value: '从文件',
        action: () => this.loadCoverFromFile()
      },
      secondaryButton: {
        value: '从相册',
        action: () => this.loadCoverFromAlbum()
      }
    });
  }

  private applyPendingCover(): void {
    if (!this.busy && this.pendingCoverImage !== undefined) {
      this.coverPixelMap = this.pendingCoverImage || null;
      this.coverChanged = true;
      this.pendingCoverImage = undefined;
      this.pendingCoverName = '';
      this.notify('已确认新封面；保存音频时写入');
    }
  }

  private cancelPendingCover(): void {
    this.pendingCoverImage = undefined;
    this.pendingCoverName = '';
  }

  private async importLyrics(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const context = this.ctx();
      const selected: SelectedDocument | undefined = await FileSelectionService.selectOne(context, 'lyric');
      if (selected === undefined) {
        this.notify('已取消歌词选择');
        return;
      }
      const text: string = await FileSelectionService.readUtf8Text(selected.uri);
      const document: LyricDocument = await parseLyricAsync(text, selected.name);
      if (this.songTitle.trim().length === 0 && document.metadata['ti'] !== undefined) this.songTitle = document.metadata['ti'];
      if (this.artist.trim().length === 0 && document.metadata['ar'] !== undefined) this.artist = document.metadata['ar'];
      this.lyricUri = selected.uri;
      this.lyricSourceName = selected.name;
      this.lyricText = text;
      this.lyricSummary = '识别格式：' + document.format + '；解析行数：' + document.lines.length +
        (document.warnings.length > 0 ? '；' + document.warnings.join('；') : '');
      if (text.indexOf('\uFFFD') >= 0) this.lyricSummary += '；文件可能不是 UTF-8，请检查显示内容';
      this.notify('歌词已读入当前编辑会话；未覆盖原文件');
    } catch (error) {
      this.notify(this.describeError(error, '歌词导入失败'));
    } finally {
      this.busy = false;
    }
  }

  private async pasteLyrics(): Promise<void> {
    // 仅由系统 PasteButton 的成功点击回调直接调用，使用其临时授权。
    if (this.busy) return;
    this.busy = true;
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      const pasted: string = data.getPrimaryText();
      if (!pasted || pasted.length === 0) {
        this.notify('剪贴板里还没有可用的文字歌词');
        return;
      }
      const document: LyricDocument = await parseLyricAsync(pasted, '');
      this.lyricText = pasted;
      this.lyricSourceName = '';
      this.lyricSummary = '识别格式：' + document.format + '；解析行数：' + document.lines.length +
        (document.warnings.length > 0 ? '；' + document.warnings.join('；') : '');
      this.notify('歌词已从剪贴板读入');
    } catch (error) {
      this.notify('粘贴失败：' + this.describeError(error));
    } finally {
      this.busy = false;
    }
  }

  private async exportLyrics(): Promise<void> {
    if (this.busy) return;
    if (this.lyricText.length === 0) {
      this.notify('没有可导出的歌词');
      return;
    }
    this.busy = true;
    this.notify('');
    try {
      const context = this.ctx();
      const base: string = this.lyricSourceName.length > 0
        ? this.lyricSourceName.replace(/\.[^.]+$/, '') : (this.songTitle.length > 0 ? this.songTitle : 'lyrics');
      // 依据当前文本而不是最初的扩展名判断格式，避免将普通文本误标为 LRC。
      const parsed: LyricDocument = await parseLyricAsync(this.lyricText, '');
      let outputName: string = base + (parsed.format === 'txt' || parsed.format === 'unknown' ? '.txt' : '.lrc');
      let outputText: string = this.lyricText;
      let conversionWarning: string = '';
      if (parsed.format === 'srt' || parsed.format === 'vtt' ||
          parsed.format === 'sbv' || parsed.format === 'ass') {
        const converted = await convertToLrcAsync(parsed);
        outputText = converted.text;
        if (converted.warnings.length > 0) conversionWarning = converted.warnings.join('；');
      }
      let savedUri: string | undefined = undefined;
      const saved = await ExportService.saveTextToDownload(context, outputName, outputText);
      if (saved !== undefined) {
        savedUri = saved.uri;
        outputName = saved.name;
      }
      if (savedUri === undefined) {
        this.notify('歌词导出失败；无法获取下载目录');
      } else {
        this.showExportSuccess('歌词已导出：' + outputName);
        if (conversionWarning.length > 0) this.notify('歌词格式转换提示：' + conversionWarning);
      }
    } catch (error) {
      this.notify('歌词导出失败：' + (this.describeError(error)));
    } finally {
      this.busy = false;
    }
  }

  private captureEditBaseline(): void {
    this.editBaseline = {
      title: this.songTitle, artist: this.artist, album: this.album, genre: this.genre,
      albumArtist: this.albumArtist, composer: this.composer, comment: this.comment,
      grouping: this.grouping, isrc: this.isrc, copyright: this.copyright,
      lyrics: this.lyricText, year: this.year, track: this.track, disc: this.disc,
      discTotal: this.discTotal, trackTotal: this.trackTotal, bpm: this.bpm
    };
    this.coverChanged = false;
  }

  /** Direct write includes only edits; copy export retains its existing behavior. */
  private async prepareAudioMetadata(direct: boolean = false): Promise<PreparedAudioMetadata> {
    const baseline: EditBaseline | undefined = this.editBaseline;
    if (direct && baseline === undefined) throw new Error('缺少导入时的标签基准，请重新选择音频。');
    const includeLyrics: boolean = !direct || (baseline !== undefined && this.lyricText !== baseline.lyrics);
    let embeddedLyrics: string = this.lyricText;
    let lyricConversionWarning: string = '';
    if (includeLyrics && embeddedLyrics.length > 0) {
      const lyricDocument: LyricDocument = await parseLyricAsync(embeddedLyrics, '');
      if (lyricDocument.format === 'srt' || lyricDocument.format === 'vtt' ||
          lyricDocument.format === 'sbv' || lyricDocument.format === 'ass') {
        const convertedLyrics = await convertToLrcAsync(lyricDocument);
        embeddedLyrics = convertedLyrics.text;
        if (convertedLyrics.warnings.length > 0) lyricConversionWarning = convertedLyrics.warnings.join('；');
      }
    }
    const writer: AudioMetadataWriter = {};
    if (!direct || (baseline !== undefined && this.songTitle !== baseline.title)) writer.title = this.songTitle;
    if (!direct || (baseline !== undefined && this.artist !== baseline.artist)) writer.artist = this.artist;
    if (!direct || (baseline !== undefined && this.album !== baseline.album)) writer.album = this.album;
    if (!direct || (baseline !== undefined && this.genre !== baseline.genre)) writer.genre = this.genre;
    if (!direct || (baseline !== undefined && this.albumArtist !== baseline.albumArtist)) writer.albumArtist = this.albumArtist;
    if (!direct || (baseline !== undefined && this.composer !== baseline.composer)) writer.composer = this.composer;
    if (!direct || (baseline !== undefined && this.comment !== baseline.comment)) writer.comment = this.comment;
    if (!direct || (baseline !== undefined && this.grouping !== baseline.grouping)) writer.grouping = this.grouping;
    if (!direct || (baseline !== undefined && this.isrc !== baseline.isrc)) writer.isrc = this.isrc;
    if (!direct || (baseline !== undefined && this.copyright !== baseline.copyright)) writer.copyright = this.copyright;
    if (includeLyrics) writer.lyrics = embeddedLyrics;
    const includeYear: boolean = !direct || (baseline !== undefined && this.year !== baseline.year);
    if (includeYear && this.year.trim().length > 0) {
      const yearValue: number = Number(this.year);
      if (!Number.isInteger(yearValue) || yearValue < 0 || yearValue > 9999) throw new Error('发行年份必须是 0 到 9999 的整数');
      writer.year = yearValue;
    } else if (includeYear && this.originalYear > 0) {
      writer.year = 0;
    }
    const includeTrack: boolean = !direct || (baseline !== undefined && this.track !== baseline.track);
    if (includeTrack && this.track.trim().length > 0) {
      const trackValue: number = Number(this.track);
      if (!Number.isInteger(trackValue) || trackValue < 0 || trackValue > 9999) throw new Error('曲目序号必须是 0 到 9999 的整数');
      writer.track = trackValue;
    } else if (includeTrack && this.originalTrack > 0) {
      writer.track = 0;
    }
    const numericFields: NumericTagField[] = [
      { value: this.disc, label: '碟片序号', key: 'disc', original: this.originalDisc },
      { value: this.discTotal, label: '碟片总数', key: 'discTotal', original: this.originalDiscTotal },
      { value: this.trackTotal, label: '专辑总曲目数', key: 'trackTotal', original: this.originalTrackTotal },
      { value: this.bpm, label: 'BPM', key: 'bpm', original: this.originalBpm }
    ];
    for (let i: number = 0; i < numericFields.length; i++) {
      if (direct && baseline !== undefined) {
        if (numericFields[i].key === 'disc' && this.disc === baseline.disc) continue;
        if (numericFields[i].key === 'discTotal' && this.discTotal === baseline.discTotal) continue;
        if (numericFields[i].key === 'trackTotal' && this.trackTotal === baseline.trackTotal) continue;
        if (numericFields[i].key === 'bpm' && this.bpm === baseline.bpm) continue;
      }
      if (numericFields[i].value.trim().length === 0 && numericFields[i].original <= 0) continue;
      const numericValue: number = numericFields[i].value.trim().length === 0 ? 0 : Number(numericFields[i].value);
      if (!Number.isInteger(numericValue) || numericValue < 0 || numericValue > 99999) {
        throw new Error(numericFields[i].label + '必须是 0 到 99999 的整数');
      }
      if (numericFields[i].key === 'disc') writer.disc = numericValue;
      if (numericFields[i].key === 'discTotal') writer.discTotal = numericValue;
      if (numericFields[i].key === 'trackTotal') writer.trackTotal = numericValue;
      if (numericFields[i].key === 'bpm') writer.bpm = numericValue;
    }
    if (this.coverChanged && this.coverPixelMap !== null) writer.coverImage = this.coverPixelMap;
    return { fields: writer, warning: lyricConversionWarning };
  }

  private async exportAudio(): Promise<void> {
    if (this.busy) return;
    if (this.pendingCoverImage !== undefined) {
      this.notify('请先确认或取消待确认的封面图片，再导出音频');
      return;
    }
    if (this.audioWorkingPath.length === 0) {
      this.notify('请先导入音频文件');
      return;
    }
    this.busy = true;
    this.notify('');
    try {
      const prepared: PreparedAudioMetadata = await this.prepareAudioMetadata(/\.(m4a|aif|aiff|ogg|opus|aac)$/i.test(this.audioName));
      const saved = await AudioSaveService.save('exportCopy', {
        context: this.ctx(),
        sourceUri: this.audioUri,
        sourceName: this.audioName,
        workingPath: this.audioWorkingPath,
        fields: prepared.fields
      });
      this.showExportSuccess('新音频已导出：' + saved.outputName);
      if (prepared.warning.length > 0) this.notify('歌词格式转换提示：' + prepared.warning);
    } catch (error) {
      this.notify('音频导出失败：' + this.describeError(error) + '。原始音频未修改');
    } finally {
      this.busy = false;
    }
  }

  // 选择直写必须单独确认；重新选择歌曲后始终回到副本导出。
  private selectDirectWriteMode(): void {
    if (this.busy || this.audioSaveMode === 'writeOriginal') return;
    if (!/\.(mp3|flac)$/i.test(this.audioName)) {
      this.notify('此音频格式目前只支持导出副本；直写仅支持 MP3 和 FLAC。');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '切换为直写源文件？',
      message: '直写会修改所选原文件。应用会先保存并校验备份，但写入中断、设备故障或其他程序同时修改仍可能导致文件损坏。' +
        '请保留其他备份。支持 FLAC、无标签 MP3 和带 ID3v2.3/2.4 的 MP3；无法安全保留标签的文件会在写入前拒绝。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '了解风险，切换', action: () => { this.audioSaveMode = 'writeOriginal'; } }
    });
  }

  private async probeOriginalAudioWrite(): Promise<void> {
    if (this.busy) return;
    if (this.audioUri.length === 0) {
      this.notify('请先选择一首音频文件');
      return;
    }
    this.busy = true;
    try {
      this.notify('正在检测原始 URI 的写入能力…');
      const result = await DirectAudioWriteService.probe(this.ctx(), this.audioUri, this.audioName);
      this.notify(result);
    } catch (error) {
      this.notify('直写检测未通过：' + this.describeError(error) + '。如使用副本导出，请检查导出文件的标签。');
    } finally {
      this.busy = false;
    }
  }

  private confirmOriginalAudioWrite(): void {
    if (this.busy) return;
    if (this.audioUri.length === 0 || this.audioWorkingPath.length === 0) {
      this.notify('请先选择音频');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '确认直写源文件？',
      message: '将修改所选原音频。写入前会创建并校验下载目录中的备份与应用内备份。' +
        '备份不能保证在所有故障下恢复；请确保另有可用备份后再继续。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '确认直写',
        action: () => { this.writeOriginalAudioMetadata(); }
      }
    });
  }

  private async writeOriginalAudioMetadata(): Promise<void> {
    if (this.busy) return;
    if (this.pendingCoverImage !== undefined) {
      this.notify('请先确认或取消待确认的封面图片，再保存');
      return;
    }
    this.busy = true;
    this.notify('');
    try {
      const prepared: PreparedAudioMetadata = await this.prepareAudioMetadata(true);
      if (Object.keys(prepared.fields).length === 0) {
        this.notify('没有需要直写的更改');
        return;
      }
      const saved = await AudioSaveService.save('writeOriginal', {
        context: this.ctx(),
        sourceUri: this.audioUri,
        sourceName: this.audioName,
        workingPath: this.audioWorkingPath,
        fields: prepared.fields
      });
      this.originalYear = prepared.fields.year === undefined ? this.originalYear : prepared.fields.year;
      this.originalTrack = prepared.fields.track === undefined ? this.originalTrack : prepared.fields.track;
      this.originalDisc = prepared.fields.disc === undefined ? this.originalDisc : prepared.fields.disc;
      this.originalDiscTotal = prepared.fields.discTotal === undefined ? this.originalDiscTotal : prepared.fields.discTotal;
      this.originalTrackTotal = prepared.fields.trackTotal === undefined ? this.originalTrackTotal : prepared.fields.trackTotal;
      this.originalBpm = prepared.fields.bpm === undefined ? this.originalBpm : prepared.fields.bpm;
      if (prepared.fields.lyrics !== undefined) this.lyricText = prepared.fields.lyrics;
      this.captureEditBaseline();
      // 后续副本导出必须基于直写后的文件，而不是之前导入时的旧工作副本。
      try {
        const previousPath: string = this.audioWorkingPath;
        const refreshed = await AudioMetadataService.importToSandbox(this.audioUri, this.audioName, this.ctx().filesDir);
        this.audioWorkingPath = refreshed.workingPath;
        if (previousPath.length > 0 && previousPath !== refreshed.workingPath) {
          await AudioMetadataService.removeWorkingFile(previousPath);
        }
      } catch (_refreshError) {
        this.clearTask();
        this.notify('直写已完成，但无法刷新编辑副本，请重新选择音频。下载目录备份：' + saved.externalBackupName);
        return;
      }
      this.showExportSuccess('直写完成：源音频已更新');
      this.notify('直写前备份已保存在下载目录：' + saved.externalBackupName +
        (prepared.warning.length > 0 ? '。歌词格式转换提示：' + prepared.warning : ''));
    } catch (error) {
      this.notify(this.describeError(error, '直写失败'));
    } finally {
      this.busy = false;
    }
  }

  private async chooseFolder(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.notify('');
    try {
      const context = this.ctx();
      const selected: SelectedDocument | undefined = await FileSelectionService.selectFolder(context);
      if (selected === undefined) {
        this.notify('已取消目录选择');
        return;
      }
      // 新目录不能沿用旧目录的候选结果或已确认任务。
      this.resetFolderResults();
      this.folderUri = selected.uri;
      this.folderName = selected.name;
      const persisted: boolean = await FolderAccessService.persist(context, { uri: selected.uri, name: selected.name });
      this.notify(persisted ? '已选择目录并保存持久授权；扫描为只读操作' : '已选择目录，可在当前会话扫描');
    } catch (error) {
      this.notify(this.describeError(error, '目录选择失败'));
    } finally {
      this.busy = false;
    }
  }

  private async scanAndMatch(): Promise<void> {
    if (this.folderUri.length === 0) {
      this.notify('请先选择文件夹');
      return;
    }
    if (this.busy) return;
    this.busy = true;
    this.notify('');
    // 重扫失败时不沿用旧候选。扫描与标签读取允许用户中途取消。
    this.resetFolderResults();
    this.scanning = true;
    this.scanCancelRequested = false;
    this.scanStatus = '正在准备扫描…';
    try {
      const context = this.ctx();
      const scan: FolderScanResult = await FolderScanner.scan(
        this.folderUri, 10000, context.filesDir,
        (message: string) => { this.scanStatus = message; },
        () => this.scanCancelRequested
      );
      if (this.scanCancelRequested) throw new Error('扫描已取消');
      this.scanStatus = '正在分析歌词匹配关系…';
      const results: MatchCandidate[] = await matchAsync(scan.audioFiles, scan.lyricFiles, MAX_MATCH_COMPARISONS);
      if (this.scanCancelRequested) throw new Error('扫描已取消');
      this.audioFiles = scan.audioFiles;
      this.lyricFiles = scan.lyricFiles;
      this.scannedAudioCount = scan.audioFiles.length;
      this.scannedLyricCount = scan.lyricFiles.length;
      this.scannedImageCount = scan.imageFiles.length;
      this.scanWarnings = scan.warnings;
      this.candidates = results;
      if (scan.audioFiles.length * scan.lyricFiles.length > MAX_MATCH_COMPARISONS) {
        this.scanWarnings = this.scanWarnings.concat(['大型目录已启用歌曲名称索引，优先比较有相关标题的候选。']);
      }
      this.candidate = 0;
      this.page = 'confirm';
      this.notify('只读扫描完成：生成 ' + this.candidates.length + ' 个候选，请逐项确认');
    } catch (error) {
      this.notify(this.describeError(error, '扫描失败；没有修改目录内文件'));
    } finally {
      this.scanning = false;
      this.scanStatus = '';
      this.scanCancelRequested = false;
      this.busy = false;
    }
  }

  private cancelFolderScan(): void {
    if (!this.scanning || this.scanCancelRequested) return;
    this.scanCancelRequested = true;
    this.scanStatus = '正在停止，请稍候…';
  }

  private jumpToCandidate(index: number): void {
    if (index < 0 || index >= this.candidates.length) return;
    this.candidate = index;
    this.notify('');
    this.page = 'confirm';
  }

  private currentCandidate(): MatchCandidate | undefined {
    return this.candidate >= 0 && this.candidate < this.candidates.length ? this.candidates[this.candidate] : undefined;
  }

  private reviewCandidate(nextState: MatchReviewState): void {
    const current = this.currentCandidate();
    if (current === undefined) return;
    if (nextState === 'confirmed') {
      const conflict: MatchCandidate | undefined = this.candidates.find((item: MatchCandidate) =>
        item.state === 'confirmed' && item.key !== current.key &&
        (item.audioId === current.audioId || item.lyricId === current.lyricId));
      if (conflict !== undefined) {
        const previousIndex: number = this.candidates.findIndex((item: MatchCandidate) => item.key === conflict.key);
        if (previousIndex >= 0) this.candidate = previousIndex;
        this.notify('这首歌或歌词已有确认的配对，已跳到旧配对。可取消旧配对后再回来确认。');
        return;
      }
    }
    if (nextState === 'rejected' && this.rejectedCandidateKeys.indexOf(current.key) < 0) {
      this.rejectedCandidateKeys = this.rejectedCandidateKeys.concat([current.key]);
    }
    this.candidates = this.candidates.map((item: MatchCandidate) => {
      if (item.key !== current.key) return item;
      return {
        key: item.key,
        audioId: item.audioId,
        audioName: item.audioName,
        audioUri: item.audioUri,
        lyricId: item.lyricId,
        lyricName: item.lyricName,
        lyricUri: item.lyricUri,
        confidence: item.confidence,
        strength: item.strength,
        strategy: item.strategy,
        evidence: item.evidence,
        warnings: item.warnings,
        audioTitle: item.audioTitle,
        audioArtist: item.audioArtist,
        lyricTitle: item.lyricTitle,
        lyricArtist: item.lyricArtist,
        state: nextState
      };
    });
    if (this.candidate < this.candidates.length - 1) {
      this.candidate += 1;
      this.notify('');
    } else {
      this.page = 'folder';
      this.notify('候选已逐项处理；没有文件被修改');
    }
  }

  private confirmedCandidates(): MatchCandidate[] {
    return this.candidates.filter((item: MatchCandidate) => item.state === 'confirmed');
  }

  private countCandidates(state: MatchReviewState): number {
    return this.candidates.filter((item: MatchCandidate) => item.state === state).length;
  }

  private pendingDirectMatches(): MatchCandidate[] {
    return this.confirmedCandidates().filter((item: MatchCandidate) => this.batchCompletedKeys.indexOf(item.key) < 0);
  }

  private confirmBatchDirectWrite(): void {
    if (this.busy) return;
    const count: number = this.pendingDirectMatches().length;
    if (count === 0) {
      this.notify('没有待直写的已确认匹配');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '批量写回原音频？',
      message: '将把已确认的 ' + count + ' 对歌词逐首写入原音频，覆盖其原有歌词。仅支持可安全处理的 MP3 和 FLAC。' +
        '请先保留独立备份。每首写入前会创建并校验备份，发生错误立即停止；已成功写入的歌曲不会自动撤销。' +
        '接下来请重新选择同一个文件夹以获取本次访问授权。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '确认并选择文件夹', action: () => { this.writeConfirmedMatches(); } }
    });
  }

  private async writeConfirmedMatches(): Promise<void> {
    if (this.busy) return;
    const pending: MatchCandidate[] = this.pendingDirectMatches();
    if (pending.length === 0 || this.folderUri.length === 0) return;
    this.busy = true;
    this.batchRunning = true;
    this.batchStopRequested = false;
    this.batchStatus = '请选择当前文件夹以获取本次授权';
    this.batchDetails = [];
    try {
      const context = this.ctx();
      const authorized: boolean = await FileSelectionService.reauthorizeFolderForBatch(context, this.folderUri);
      if (!authorized) {
        this.batchStatus = '已取消文件夹授权，没有写入任何歌曲。';
        return;
      }
      const result: BatchDirectWriteResult = await BatchDirectWriteService.run(context, pending,
        (message: string) => { this.batchStatus = message; }, () => this.batchStopRequested);
      for (let i: number = 0; i < result.completed.length; i++) {
        this.batchCompletedKeys = this.batchCompletedKeys.concat([result.completed[i].candidateKey]);
      }
      this.batchStatus = '批量直写：成功 ' + result.succeeded + '，失败 ' + result.failed +
        '，未处理 ' + result.unprocessed + (result.cancelled ? '（已停止）' : '') + '。';
      this.batchDetails = result.details.concat(result.completed.map(item =>
        item.audioName + '：备份 ' + item.backupName));
      this.notify(this.batchStatus);
    } catch (error) {
      this.batchStatus = '批量直写未开始或已中止：' + this.describeError(error);
      this.batchDetails = [this.batchStatus];
      this.notify(this.batchStatus);
    } finally {
      this.batchRunning = false;
      this.busy = false;
    }
  }

  private candidateStateLabel(): string {
    const item: MatchCandidate | undefined = this.currentCandidate();
    if (item === undefined) return '';
    if (item.state === 'confirmed') return '已确认';
    if (item.state === 'rejected') return '已取消';
    if (item.state === 'deferred') return '暂缓';
    return '待确认';
  }

  private async exportConfirmedMatches(): Promise<void> {
    if (this.busy) return;
    const confirmed: MatchCandidate[] = this.confirmedCandidates();
    if (confirmed.length === 0) {
      this.notify('没有已确认的匹配可供导出');
      return;
    }
    this.busy = true;
    this.notify('');
    let succeeded: number = 0;
    let failed: number = 0;
    const failureNotes: string[] = [];
    try {
      const context = this.ctx();
      for (let i: number = 0; i < confirmed.length; i++) {
        const item: MatchCandidate = confirmed[i];
        let sourceWorkingPath: string = '';
        let exportPath: string = '';
        let savedUri: string | undefined = undefined;
        let importedCover: image.PixelMap | undefined = undefined;
        try {
          if (item.audioUri === undefined || item.lyricUri === undefined) throw new Error('缺少音频或歌词授权 URI');
          const working = await AudioMetadataService.importToSandbox(item.audioUri, item.audioName, context.filesDir);
          sourceWorkingPath = working.workingPath;
          importedCover = working.metadata.coverImage;
          const lyricText: string = await FileSelectionService.readUtf8Text(item.lyricUri);
          let embeddedLyrics: string = lyricText;
          const lowerLyricSource: string = item.lyricName.toLowerCase();
          if (lowerLyricSource.length > 0 && !lowerLyricSource.endsWith('.lrc') && !lowerLyricSource.endsWith('.txt')) {
            const document: LyricDocument = await parseLyricAsync(lyricText, item.lyricName);
            const converted = await convertToLrcAsync(document);
            embeddedLyrics = converted.text;
            if (converted.warnings.length > 0) failureNotes.push(item.audioName + '：' + converted.warnings.join('；'));
          }
          exportPath = await AudioMetadataService.makeWorkingCopy(sourceWorkingPath, context.filesDir, item.audioName);
          await AudioMetadataService.write(exportPath, { lyrics: embeddedLyrics }, context.filesDir);
          const baseName: string = AudioMetadataService.safeOutputName(item.audioName, working.metadata.title || item.audioTitle || item.audioName);
          const saved = await ExportService.saveAudioToDownload(context, baseName, exportPath);
          if (saved !== undefined) {
            savedUri = saved.uri;
          }
          if (savedUri === undefined) {
            throw new Error('无法获取下载目录');
          }
          succeeded++;
        } catch (error) {
          failed++;
          failureNotes.push(item.audioName + '：' + (this.describeError(error)));
        } finally {
          if (importedCover !== undefined) { try { await importedCover.release(); } catch (_error) {} }
          if (sourceWorkingPath.length > 0) await AudioMetadataService.removeWorkingFile(sourceWorkingPath);
          if (exportPath.length > 0) await AudioMetadataService.removeWorkingFile(exportPath);
        }
      }
      if (failed === 0) {
        this.showExportSuccess('已导出 ' + succeeded + ' 首歌曲喵～');
        if (failureNotes.length > 0) this.notify('歌词格式转换提示：' + failureNotes.slice(0, 8).join('；'));
      } else {
        this.notify('批量导出：成功 ' + succeeded + ' 项，失败 ' + failed + ' 项。原始文件未修改。' +
          (failureNotes.length > 0 ? ' 详情：' + failureNotes.slice(0, 8).join('；') : ''));
      }
    } catch (error) {
      this.notify('批量导出中止：' + (this.describeError(error)));
    } finally {
      this.busy = false;
    }
  }

  private async restoreSavedFolder(): Promise<void> {
    try {
      const context = this.ctx();
      const saved = await FolderAccessService.restore(context);
      if (saved !== undefined) {
        this.folderUri = saved.uri;
        this.folderName = saved.name;
      }
    } catch (_error) {}
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        Row({ space: 11 }) {
          Text('♫').fontSize(23).fontWeight(FontWeight.Bold).fontColor(Color.White)
            .width(42).height(42).textAlign(TextAlign.Center).backgroundColor(BLUE).borderRadius(14)
          Column({ space: 2 }) {
            Text('LyricFlow').fontSize(23).fontWeight(FontWeight.Bold).fontColor(INK)
            Text('让每首歌，都有自己的故事').fontSize(11).fontColor(MUTED)
          }.alignItems(HorizontalAlign.Start)
          Blank()
        }.width('100%').padding({ left: 20, right: 68, top: 14, bottom: 12 })

        Row({ space: 4 }) {
          Button('单曲编辑').layoutWeight(1).height(40).enabled(!this.busy)
            .fontSize(14).fontWeight(FontWeight.Medium)
            .backgroundColor(this.currentTab === 0 ? Color.White : '#EDF1F7')
            .fontColor(this.currentTab === 0 ? BLUE : MUTED).borderRadius(13)
            .onClick(() => this.switchMainTab(0))
          Button('文件夹匹配').layoutWeight(1).height(40).enabled(!this.busy)
            .fontSize(14).fontWeight(FontWeight.Medium)
            .backgroundColor(this.currentTab === 1 ? Color.White : '#EDF1F7')
            .fontColor(this.currentTab === 1 ? BLUE : MUTED).borderRadius(13)
            .onClick(() => this.switchMainTab(1))
        }.padding(4).backgroundColor('#EDF1F7').borderRadius(16)
          .margin({ left: 18, right: 18, bottom: 10 })

        if (this.page === 'editor') this.EditorView();
        else if (this.page === 'lyrics') this.LyricsView();
        else if (this.page === 'folder') this.FolderView();
        else this.ConfirmView();

        if (this.toastText.length > 0) {
          Row({ space: 8 }) {
            Scroll() {
              Text(this.toastText).fontSize(12).fontColor(INK).lineHeight(18).width('100%')
            }.layoutWeight(1).constraintSize({ maxHeight: 96 })
            Button('关闭').fontSize(11).height(34).backgroundColor('#EDF3FF').fontColor(BLUE)
              .borderRadius(10).onClick(() => { this.toastText = ''; })
          }.padding({ left: 14, right: 10, top: 8, bottom: 8 }).width('100%')
            .backgroundColor(Color.White).border({ width: 1, color: BORDER }).borderRadius(16)
        }
      }.width('100%').height('100%').backgroundColor(BG)
        // 只延伸背景绘制，不改变内部组件的安全区布局。
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.activeGuide.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          Column() { }.width('100%').height('100%').backgroundColor('#66000000')
            .onClick(() => this.closeGuide(false))
          this.GuidePopup()
        }.width('100%').height('100%')
      } else if (this.showHelp) {
        Stack({ alignContent: Alignment.Center }) {
          Column() { }.width('100%').height('100%').backgroundColor('#66000000')
            .onClick(() => { this.showHelp = false; })
          this.HelpPanel()
        }.width('100%').height('100%')
      } else {
        Text('?').fontSize(19).fontColor(BLUE).width(40).height(40).textAlign(TextAlign.Center)
          .backgroundColor('#E3F0FF').borderRadius(20).margin({ top: 16, right: 18 })
          .onClick(() => { this.showHelp = true; })
      }
    }.width('100%').height('100%')
  }

  @Builder
  GuidePopup() {
    Column({ space: 14 }) {
      Text('🐾  小提醒').fontSize(13).fontColor(BLUE).width('100%')
      Text(this.guideTitle(this.activeGuide)).fontSize(21).fontWeight(FontWeight.Bold).fontColor(INK).width('100%')
      Text(this.guideBody(this.activeGuide)).fontSize(15).fontColor(INK).lineHeight(24).width('100%')
      Text('点卡片外的空白处也能关闭；关闭后可再点一次原按钮。')
        .fontSize(12).fontColor(MUTED).width('100%')
      Row({ space: 10 }) {
        Button('先关掉').layoutWeight(1).backgroundColor('#EFF3F9').fontColor(INK)
          .borderRadius(15).onClick(() => this.closeGuide(false))
        Button(this.activeGuide === 'welcome' ? '开始使用' : '明白啦，继续')
          .layoutWeight(1).backgroundColor(BLUE).fontColor(Color.White).borderRadius(15)
          .onClick(() => this.closeGuide(true))
      }.width('100%')
    }.padding(22).width('88%').constraintSize({ maxWidth: 400 })
      .backgroundColor(Color.White).borderRadius(22)
      .shadow({ radius: 20, color: '#22000000', offsetY: 6 })
  }

  @Builder
  HelpPanel() {
    Column({ space: 12 }) {
      Row() {
        Text('使用指南  🐾').fontSize(21).fontWeight(FontWeight.Bold).fontColor(INK)
        Blank()
        Text('关闭').fontSize(14).fontColor(BLUE).onClick(() => { this.showHelp = false; })
      }.width('100%')

      Text('想了解哪一步，就在这里看看吧。点卡片外的空白处也能退出喵～')
        .fontSize(13).fontColor(MUTED).lineHeight(20).width('100%')
      Scroll() {
        Column({ space: 10 }) {
          this.HelpSection('选歌与改信息', '选择音频后会先建立编辑副本。修改后可以导出新副本，也可以选择直写源文件。')
          this.HelpSection('更换封面', '先选图片、看预览，再点“使用此封面”。取消预览就保留旧封面。新封面会在保存音频时写入。')
          this.HelpSection('整理歌词', '可导入 LRC、TXT 或常见字幕歌词，也可以直接粘贴和修改。保存并返回只保留当前编辑内容；导出才能生成文件。')
          this.HelpSection('保存音频', '导出新副本会保留原文件；直写会修改原文件，写入前会创建并检查备份。请保留独立备份，授权失效时重新选择音频。')
          this.HelpSection('文件夹匹配', '选择文件夹后，应用会只读扫描歌曲和歌词，推荐可能匹配的组合。确认、取消或暂缓都不会直接修改原文件。')
          this.HelpSection('导出匹配结果', '只有你确认过的组合才会被处理，歌词写入新的音频副本；原有歌曲不变。')
          this.HelpSection('批量直写', '确认匹配后可选择写回原音频。请先保留独立备份；逐首生成备份并校验，遇到错误会停止，已完成的歌曲不会自动撤销。')
          this.HelpSection('切换模式', '使用顶部的“单曲编辑”和“文件夹匹配”切换。切换不会丢弃正在编辑的歌曲。')
        }.width('100%').padding({ bottom: 12 })
      }.layoutWeight(1).width('100%')
    }.padding(20).width('88%').height('83%')
      .backgroundColor(Color.White).borderRadius(22)
      .shadow({ radius: 18, color: '#22000000', offsetY: 4 })
  }

  @Builder
  HelpSection(title: string, body: string) {
    Column({ space: 6 }) {
      Text(title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK).width('100%')
      Text(body).fontSize(13).fontColor(INK).lineHeight(20).width('100%')
    }.padding(14).backgroundColor('#F6F8FB').borderRadius(14).width('100%')
  }

  @Builder
  EditorView() {
    Column() {
      if (this.audioWorkingPath.length === 0) {
        Scroll() {
          Column({ space: 16 }) {
            Column({ space: 12 }) {
              Text('♫').fontSize(34).fontColor(BLUE).width(72).height(72).textAlign(TextAlign.Center)
                .backgroundColor('#EAF1FF').borderRadius(24)
              Text('从一首歌开始').fontSize(22).fontWeight(FontWeight.Bold).fontColor(INK)
              Text('整理歌曲信息、封面和歌词，完成后选择适合你的保存方式。')
                .fontSize(14).fontColor(MUTED).lineHeight(22).textAlign(TextAlign.Center)
              Button('选择音频').width('100%').height(48).backgroundColor(BLUE).fontColor(Color.White)
                .borderRadius(16).enabled(!this.busy).onClick(() => this.importAudio())
            }.padding(24).width('100%').backgroundColor(Color.White).borderRadius(24)
            Row({ space: 10 }) {
              Text('🐾').fontSize(18)
              Text('选择后先在副本中编辑，保存时再决定如何处理原文件。')
                .fontSize(12).fontColor(MUTED).lineHeight(19).layoutWeight(1)
            }.padding(15).width('100%').backgroundColor('#EDF3FF').borderRadius(16)
          }.padding({ top: 8, bottom: 20 }).width('100%')
        }.layoutWeight(1).width('100%')
      } else {
        Scroll() {
          Column({ space: 12 }) {
            Row({ space: 14 }) {
              Stack({ alignContent: Alignment.BottomEnd }) {
                if (this.coverUri.length > 0) {
                  Image(this.coverUri).width(92).height(92).objectFit(ImageFit.Cover).borderRadius(17)
                } else if (this.coverPixelMap !== null) {
                  Image(this.coverPixelMap).width(92).height(92).objectFit(ImageFit.Cover).borderRadius(17)
                } else {
                  Column() { Text('♫').fontSize(30).fontColor(BLUE) }
                    .width(92).height(92).justifyContent(FlexAlign.Center).backgroundColor('#EAF1FF').borderRadius(17)
                }
                Text('✎').fontSize(13).fontColor(Color.White).width(27).height(27).textAlign(TextAlign.Center)
                  .backgroundColor('#A6172B4D').borderRadius(14).margin(5)
              }.width(92).height(92).onClick(() => { if (!this.busy) this.importCover(); })
              Column({ space: 5 }) {
                Text('当前歌曲').fontSize(11).fontColor(BLUE).fontWeight(FontWeight.Medium)
                Text(this.songTitle.length > 0 ? this.songTitle : '未命名歌曲').fontSize(17).fontWeight(FontWeight.Bold)
                  .fontColor(INK).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Text(this.artist.length > 0 ? this.artist : '未知歌手').fontSize(12).fontColor(MUTED)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Button('更换歌曲  ›').height(36).fontSize(12).enabled(!this.busy)
                  .backgroundColor('#EDF3FF').fontColor(BLUE).borderRadius(11).onClick(() => this.confirmReplaceAudio())
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.padding(16).width('100%').backgroundColor(Color.White).borderRadius(22)

            if (this.pendingCoverImage !== undefined) {
              Column({ space: 10 }) {
                Text('确认新封面').fontSize(15).fontWeight(FontWeight.Bold).fontColor(INK).width('100%')
                Row({ space: 12 }) {
                  Image(this.pendingCoverImage).width(78).height(78).objectFit(ImageFit.Contain)
                    .backgroundColor('#F5F7FB').borderRadius(12)
                  Column({ space: 5 }) {
                    Text(this.pendingCoverName).fontSize(12).fontColor(INK).maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text('确认后应用到当前编辑任务').fontSize(11).fontColor(MUTED)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%')
                Row({ space: 8 }) {
                  Button('取消').layoutWeight(1).height(40).enabled(!this.busy).backgroundColor('#F2F5FA')
                    .fontColor(INK).borderRadius(12).onClick(() => this.cancelPendingCover())
                  Button('使用此封面').layoutWeight(1).height(40).enabled(!this.busy).backgroundColor(BLUE)
                    .fontColor(Color.White).borderRadius(12).onClick(() => this.applyPendingCover())
                }.width('100%')
              }.padding(16).width('100%').backgroundColor(Color.White).borderRadius(20)
            }

            Column({ space: 10 }) {
              Row() {
                Text('基本信息').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK)
                Blank()
                Text('歌曲标签').fontSize(11).fontColor(MUTED)
              }.width('100%')
              Column({ space: 5 }) {
                Text('歌曲标题').fontSize(12).fontColor(MUTED).width('100%')
                TextInput({ text: this.songTitle, placeholder: '填写歌曲标题' }).enabled(!this.busy).height(44)
                  .backgroundColor('#F5F7FB').borderRadius(12).onChange((v: string) => { this.songTitle = v; })
              }.width('100%')
              Column({ space: 5 }) {
                Text('歌手').fontSize(12).fontColor(MUTED).width('100%')
                TextInput({ text: this.artist, placeholder: '填写歌手' }).enabled(!this.busy).height(44)
                  .backgroundColor('#F5F7FB').borderRadius(12).onChange((v: string) => { this.artist = v; })
              }.width('100%')
              Column({ space: 5 }) {
                Text('专辑').fontSize(12).fontColor(MUTED).width('100%')
                TextInput({ text: this.album, placeholder: '填写专辑' }).enabled(!this.busy).height(44)
                  .backgroundColor('#F5F7FB').borderRadius(12).onChange((v: string) => { this.album = v; })
              }.width('100%')
            }.padding(16).width('100%').backgroundColor(Color.White).borderRadius(20)

            Column({ space: 10 }) {
              Row() {
                Column({ space: 4 }) {
                  Text('歌词').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK)
                  Text(this.lyricText.length > 0 ? '已载入歌词，可继续编辑' : '还没有歌词')
                    .fontSize(12).fontColor(MUTED)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Button('编辑  ›').height(36).fontSize(12).enabled(!this.busy).backgroundColor('#EDF3FF')
                  .fontColor(BLUE).borderRadius(11).onClick(() => { this.page = 'lyrics'; })
              }.width('100%')
              if (this.lyricSummary.length > 0) {
                Text(this.lyricSummary).fontSize(11).fontColor(MUTED).maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
              }
              Row({ space: 8 }) {
                Button('导入歌词').layoutWeight(1).height(40).enabled(!this.busy).backgroundColor('#F1F5FD')
                  .fontColor(BLUE).borderRadius(12).onClick(() => this.importLyrics())
                Button('导出歌词').layoutWeight(1).height(40).enabled(!this.busy).backgroundColor('#F1F5FD')
                  .fontColor(BLUE).borderRadius(12).onClick(() => this.exportLyrics())
              }.width('100%')
            }.padding(16).width('100%').backgroundColor(Color.White).borderRadius(20)

            Column({ space: 10 }) {
              Row() {
                Column({ space: 3 }) {
                  Text('更多标签').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK)
                  Text('作曲、年份、曲目序号等').fontSize(11).fontColor(MUTED)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Text(this.moreInfoVisible ? '收起  ∧' : '展开  ∨').fontSize(12).fontColor(BLUE)
              }.width('100%').onClick(() => {
                this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => { this.moreInfoVisible = !this.moreInfoVisible; });
              })
              if (this.moreInfoVisible) {
                this.MoreTagsFields()
              }
            }.padding(16).width('100%').backgroundColor(Color.White).borderRadius(20)

            Text(this.audioName).fontSize(11).fontColor(MUTED).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            if (this.audioTechnicalSummary.length > 0) {
              Text(this.audioTechnicalSummary).fontSize(11).fontColor(MUTED).width('100%')
            }
          }.padding({ top: 2, bottom: 18 }).width('100%')
        }.layoutWeight(1).width('100%').align(Alignment.Top)
        this.SaveDock()
      }
    }.padding({ left: 18, right: 18, bottom: 12 }).layoutWeight(1).width('100%')
  }

  @Builder
  MoreTagsFields() {
    Column({ space: 8 }) {
      Text('作曲者').fontSize(12).fontColor(MUTED).width('100%')
      TextInput({ text: this.composer, placeholder: '作曲者' }).enabled(!this.busy).height(42).backgroundColor('#F5F7FB').borderRadius(12)
        .onChange((v: string) => { this.composer = v; })
      Text('流派').fontSize(12).fontColor(MUTED).width('100%')
      TextInput({ text: this.genre, placeholder: '流派' }).enabled(!this.busy).height(42).backgroundColor('#F5F7FB').borderRadius(12)
        .onChange((v: string) => { this.genre = v; })
      Text('发行年份').fontSize(12).fontColor(MUTED).width('100%')
      TextInput({ text: this.year, placeholder: '发行年份' }).enabled(!this.busy).height(42).type(InputType.Number).backgroundColor('#F5F7FB').borderRadius(12)
        .onChange((v: string) => { this.year = v; })
      Text('专辑艺术家').fontSize(12).fontColor(MUTED).width('100%')
      TextInput({ text: this.albumArtist, placeholder: '专辑艺术家' }).enabled(!this.busy).height(42).backgroundColor('#F5F7FB').borderRadius(12)
        .onChange((v: string) => { this.albumArtist = v; })
      Row({ space: 8 }) {
        Column({ space: 5 }) {
          Text('曲目序号').fontSize(12).fontColor(MUTED).width('100%')
          TextInput({ text: this.track, placeholder: '序号' }).enabled(!this.busy).height(42).type(InputType.Number).backgroundColor('#F5F7FB').borderRadius(12)
            .onChange((v: string) => { this.track = v; })
        }.layoutWeight(1)
        Column({ space: 5 }) {
          Text('专辑总曲目数').fontSize(12).fontColor(MUTED).width('100%')
          TextInput({ text: this.trackTotal, placeholder: '总数' }).enabled(!this.busy).height(42).type(InputType.Number).backgroundColor('#F5F7FB').borderRadius(12)
            .onChange((v: string) => { this.trackTotal = v; })
        }.layoutWeight(1)
      }.width('100%')
      Row({ space: 8 }) {
        Column({ space: 5 }) {
          Text('碟片序号').fontSize(12).fontColor(MUTED).width('100%')
          TextInput({ text: this.disc, placeholder: '序号' }).enabled(!this.busy).height(42).type(InputType.Number).backgroundColor('#F5F7FB').borderRadius(12)
            .onChange((v: string) => { this.disc = v; })
        }.layoutWeight(1)
        Column({ space: 5 }) {
          Text('碟片总数').fontSize(12).fontColor(MUTED).width('100%')
          TextInput({ text: this.discTotal, placeholder: '总数' }).enabled(!this.busy).height(42).type(InputType.Number).backgroundColor('#F5F7FB').borderRadius(12)
            .onChange((v: string) => { this.discTotal = v; })
        }.layoutWeight(1)
      }.width('100%')
      Text('BPM').fontSize(12).fontColor(MUTED).width('100%')
      TextInput({ text: this.bpm, placeholder: 'BPM' }).enabled(!this.busy).height(42).type(InputType.Number).backgroundColor('#F5F7FB').borderRadius(12)
        .onChange((v: string) => { this.bpm = v; })
      Text('分组').fontSize(12).fontColor(MUTED).width('100%')
      TextInput({ text: this.grouping, placeholder: '分组' }).enabled(!this.busy).height(42).backgroundColor('#F5F7FB').borderRadius(12)
        .onChange((v: string) => { this.grouping = v; })
      Text(/\.m4a$/i.test(this.audioName) ? 'ISRC（M4A 暂不支持读取和编辑）' : 'ISRC').fontSize(12).fontColor(MUTED).width('100%')
      TextInput({ text: this.isrc, placeholder: 'ISRC' }).enabled(!this.busy && !/\.m4a$/i.test(this.audioName)).height(42).backgroundColor('#F5F7FB').borderRadius(12)
        .onChange((v: string) => { this.isrc = v; })
      Text('版权信息').fontSize(12).fontColor(MUTED).width('100%')
      TextInput({ text: this.copyright, placeholder: '版权信息' }).enabled(!this.busy).height(42).backgroundColor('#F5F7FB').borderRadius(12)
        .onChange((v: string) => { this.copyright = v; })
      Text('备注').fontSize(12).fontColor(MUTED).width('100%')
      TextInput({ text: this.comment, placeholder: '备注' }).enabled(!this.busy).height(42).backgroundColor('#F5F7FB').borderRadius(12)
        .onChange((v: string) => { this.comment = v; })
    }.width('100%')
  }

  @Builder
  SaveDock() {
    Column({ space: 8 }) {
      Row() {
        Text('保存方式').fontSize(12).fontWeight(FontWeight.Medium).fontColor(INK)
        Blank()
        if (this.audioSaveMode === 'writeOriginal') {
          Button(this.directOptionsVisible ? '收起选项' : '直写选项').height(32).fontSize(11)
            .backgroundColor('#FFF3F3').fontColor('#B3262D').borderRadius(10)
            .enabled(!this.busy).onClick(() => { this.directOptionsVisible = !this.directOptionsVisible; })
        }
      }.width('100%')
      Row({ space: 6 }) {
        Button('导出新副本').layoutWeight(1).height(38).enabled(!this.busy).fontSize(12)
          .backgroundColor(this.audioSaveMode === 'exportCopy' ? '#E7EFFF' : '#F3F5F9')
          .fontColor(this.audioSaveMode === 'exportCopy' ? BLUE : MUTED).borderRadius(12)
          .onClick(() => { this.audioSaveMode = 'exportCopy'; this.directOptionsVisible = false; })
        Button('写回原文件').layoutWeight(1).height(38).enabled(!this.busy).fontSize(12)
          .backgroundColor(this.audioSaveMode === 'writeOriginal' ? '#FFF0F0' : '#F3F5F9')
          .fontColor(this.audioSaveMode === 'writeOriginal' ? '#B3262D' : MUTED).borderRadius(12)
          .onClick(() => this.selectDirectWriteMode())
      }.width('100%')
      if (this.audioSaveMode === 'writeOriginal') {
        Text('将修改原文件；写入前会创建备份，请保留其他备份。')
          .fontSize(11).fontColor('#B3262D').width('100%')
        if (this.directOptionsVisible) {
          Row({ space: 8 }) {
            Button('检查文件').layoutWeight(1).height(36).fontSize(11).enabled(!this.busy)
              .backgroundColor('#FFF5F5').fontColor('#B3262D').borderRadius(10).onClick(() => this.probeOriginalAudioWrite())
            Button('检查恢复记录').layoutWeight(1).height(36).fontSize(11).enabled(!this.busy)
              .backgroundColor('#FFF5F5').fontColor('#B3262D').borderRadius(10).onClick(() => this.checkInterruptedDirectWrite(true))
          }.width('100%')
        }
      }
      Button(this.busy ? '处理中…' : (this.audioSaveMode === 'writeOriginal' ? '确认写回原文件' : '导出新音频副本'))
        .width('100%').height(46).backgroundColor(this.audioSaveMode === 'writeOriginal' ? '#C9343B' : BLUE)
        .fontColor(Color.White).borderRadius(15).enabled(!this.busy)
        .onClick(() => { if (this.audioSaveMode === 'writeOriginal') this.confirmOriginalAudioWrite(); else this.exportAudio(); })
    }.padding(12).width('100%').backgroundColor(Color.White).borderRadius(20)
  }

  @Builder
  LyricsView() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 3 }) {
          Text('歌词编辑').fontSize(20).fontWeight(FontWeight.Bold).fontColor(INK)
          Text(this.lyricText.length > 0 ? '编辑当前歌曲的歌词' : '导入或粘贴歌词开始编辑')
            .fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('返回歌曲').height(36).fontSize(12).backgroundColor('#EAF1FF').fontColor(BLUE)
          .borderRadius(12).enabled(!this.busy).onClick(() => { this.page = 'editor'; })
      }.width('100%').padding({ top: 2, bottom: 3 })
      if (this.lyricSummary.length > 0) {
        Text(this.lyricSummary).fontSize(11).fontColor(MUTED).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      Row({ space: 8 }) {
        Button('导入歌词').layoutWeight(1).height(40).fontSize(12).enabled(!this.busy)
          .backgroundColor(Color.White).fontColor(BLUE).borderRadius(12).onClick(() => this.importLyrics())
        Button('重新解析').layoutWeight(1).height(40).fontSize(12).enabled(!this.busy)
          .backgroundColor(Color.White).fontColor(BLUE).borderRadius(12).onClick(async () => {
            if (this.busy) return;
            this.busy = true;
            try {
              const document: LyricDocument = await parseLyricAsync(this.lyricText, '');
              this.lyricSummary = '识别格式：' + document.format + '；解析行数：' + document.lines.length;
              this.notify('已重新解析歌词');
            } catch (error) { this.notify('歌词解析失败：' + this.describeError(error)); }
            finally { this.busy = false; }
          })
        Row() {
          PasteButton().width('100%').height(40).backgroundColor(Color.White).fontColor(BLUE)
            .borderWidth(1).borderColor(BORDER)
            .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
              if (result === PasteButtonOnClickResult.SUCCESS) this.pasteLyrics();
              else this.notify('粘贴暂不可用，可以长按歌词输入框粘贴');
            })
        }.layoutWeight(1).height(40)
      }.width('100%')
      TextArea({ text: this.lyricText, placeholder: '在这里编辑歌词，或导入 LRC、TXT、SRT 等文件' })
        .enabled(!this.busy).layoutWeight(1).width('100%').fontSize(14)
        .backgroundColor(Color.White).borderRadius(20)
        .onChange((v: string) => { this.lyricText = v; })
      Text('歌词暂存在本次编辑中；返回歌曲后还需保存音频。').fontSize(11).fontColor(MUTED).width('100%')
      Row({ space: 8 }) {
        Button('导出歌词').layoutWeight(1).height(46).enabled(!this.busy).backgroundColor(Color.White)
          .fontColor(BLUE).borderRadius(15).onClick(() => this.exportLyrics())
        Button('完成编辑').layoutWeight(1).height(46).enabled(!this.busy).backgroundColor(BLUE)
          .fontColor(Color.White).borderRadius(15).onClick(() => { this.page = 'editor'; this.notify('歌词已保留在当前编辑任务'); })
      }.width('100%')
    }.padding({ left: 18, right: 18, bottom: 14 }).layoutWeight(1).width('100%')
  }

  @Builder
  FolderView() {
    Column({ space: 12 }) {
      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 12 }) {
            Row({ space: 12 }) {
              Text('♫').fontSize(23).fontColor(BLUE).width(50).height(50).textAlign(TextAlign.Center)
                .backgroundColor('#EAF1FF').borderRadius(16)
              Column({ space: 4 }) {
                Text('文件夹匹配').fontSize(18).fontWeight(FontWeight.Bold).fontColor(INK)
                Text('为歌曲寻找合适的歌词').fontSize(12).fontColor(MUTED)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%')
            Row({ space: 10 }) {
              Column({ space: 4 }) {
                Text('当前文件夹').fontSize(11).fontColor(MUTED).width('100%')
                Text(this.folderUri.length > 0 ? this.folderName : '还没有选择文件夹').fontSize(13).fontColor(INK)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
              }.layoutWeight(1)
              Button(this.folderUri.length > 0 ? '更换' : '选择').height(36).fontSize(12).enabled(!this.busy)
                .backgroundColor('#EAF1FF').fontColor(BLUE).borderRadius(12).onClick(() => this.confirmChangeFolder())
            }.padding(12).width('100%').backgroundColor('#F5F7FB').borderRadius(14)
            Button(this.busy ? '处理中…' : '扫描并匹配').width('100%').height(46).backgroundColor(BLUE)
              .fontColor(Color.White).borderRadius(15).enabled(!this.busy && this.folderUri.length > 0)
              .onClick(() => this.scanAndMatch())
            Text('扫描只读取文件；确认后可导出副本或选择批量直写原音频。').fontSize(11).fontColor(MUTED).width('100%')
          }.padding(17).width('100%').backgroundColor(Color.White).borderRadius(22)

          if (this.scanning) {
            Row({ space: 10 }) {
              Text(this.scanStatus).fontSize(12).fontColor(INK).layoutWeight(1)
              Button(this.scanCancelRequested ? '正在停止' : '停止').height(36).fontSize(12)
                .backgroundColor('#EDF3FF').fontColor(BLUE).borderRadius(12).enabled(!this.scanCancelRequested)
                .onClick(() => this.cancelFolderScan())
            }.padding(15).width('100%').backgroundColor(Color.White).borderRadius(18)
          }
          if (this.batchRunning || this.batchStatus.length > 0) {
            Column({ space: 8 }) {
              Row({ space: 10 }) {
                Text(this.batchStatus).fontSize(12).fontColor(INK).layoutWeight(1)
                if (this.batchRunning) {
                  Button(this.batchStopRequested ? '等待当前歌曲' : '停止').height(36).fontSize(12)
                    .backgroundColor('#FFF0F0').fontColor('#B3262D').borderRadius(12)
                    .enabled(!this.batchStopRequested).onClick(() => { this.batchStopRequested = true; })
                }
              }.width('100%')
              ForEach(this.batchDetails, (detail: string, index: number) => {
                Text(detail).fontSize(11).fontColor(MUTED).width('100%')
              }, (detail: string, index: number) => index.toString() + detail)
            }.padding(15).width('100%').backgroundColor(Color.White).borderRadius(18)
          }
          if (this.scannedAudioCount > 0 || this.scannedLyricCount > 0 || this.candidates.length > 0) {
            Column({ space: 10 }) {
              Text('匹配概览').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK).width('100%')
              Text('音频 ' + this.scannedAudioCount + '  ·  歌词 ' + this.scannedLyricCount + '  ·  图片 ' + this.scannedImageCount)
                .fontSize(12).fontColor(MUTED).width('100%')
              Row({ space: 8 }) {
                Text('待确认  ' + this.countCandidates('pending')).layoutWeight(1).fontSize(12).fontColor(BLUE)
                  .padding(10).backgroundColor('#EDF3FF').borderRadius(12)
                Text('已确认  ' + this.countCandidates('confirmed')).layoutWeight(1).fontSize(12).fontColor('#178C72')
                  .padding(10).backgroundColor('#E9F7F1').borderRadius(12)
              }.width('100%')
              Text('暂缓 ' + this.countCandidates('deferred') + '  ·  已取消 ' + this.countCandidates('rejected'))
                .fontSize(11).fontColor(MUTED).width('100%')
              if (this.candidates.length > 0) {
                Button('查看匹配候选').width('100%').height(42).enabled(!this.busy)
                  .backgroundColor('#EDF3FF').fontColor(BLUE).borderRadius(13).onClick(() => this.jumpToCandidate(0))
              }
            }.padding(16).width('100%').backgroundColor(Color.White).borderRadius(20)
          }
          ForEach(this.scanWarnings, (warning: string) => {
            Text('提示：' + warning).fontSize(11).fontColor('#956A1C').padding(12)
              .width('100%').backgroundColor('#FFF5E4').borderRadius(12)
          }, (warning: string) => warning)
        }.padding({ top: 2, bottom: 16 }).width('100%')
      }.layoutWeight(1).width('100%').align(Alignment.Top)
      if (this.confirmedCandidates().length > 0) {
        Row({ space: 8 }) {
          Button('导出副本 ' + this.confirmedCandidates().length).layoutWeight(1).height(48)
            .backgroundColor('#178C72').fontColor(Color.White).borderRadius(16).enabled(!this.busy)
            .onClick(() => this.exportConfirmedMatches())
          Button('批量直写 ' + this.pendingDirectMatches().length).layoutWeight(1).height(48)
            .backgroundColor('#C9343B').fontColor(Color.White).borderRadius(16)
            .enabled(!this.busy && this.pendingDirectMatches().length > 0).onClick(() => this.confirmBatchDirectWrite())
        }.width('100%')
      }
    }.padding({ left: 18, right: 18, bottom: 14 }).layoutWeight(1).width('100%')
  }

  @Builder
  ConfirmView() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 3 }) {
          Text('确认匹配').fontSize(20).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('逐项检查歌曲和歌词的对应关系').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('返回').height(36).fontSize(12).backgroundColor(Color.White).fontColor(BLUE)
          .borderRadius(12).onClick(() => { this.page = 'folder'; })
      }.width('100%')
      if (this.candidates.length === 0 || this.currentCandidate() === undefined) {
        Column({ space: 10 }) {
          Text('暂时没有匹配候选').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('可以返回文件夹重新扫描。').fontSize(12).fontColor(MUTED)
          Button('返回文件夹').backgroundColor(BLUE).fontColor(Color.White).borderRadius(14)
            .onClick(() => { this.page = 'folder'; })
        }.padding(22).width('100%').backgroundColor(Color.White).borderRadius(20)
        Blank().layoutWeight(1)
      } else {
        this.ConfirmCandidateCard()
      }
    }.padding({ left: 18, right: 18, bottom: 14 }).layoutWeight(1).width('100%')
  }

  @Builder
  ConfirmCandidateCard() {
    Column({ space: 10 }) {
      Row() {
        Text('候选 ' + (this.candidate + 1) + ' / ' + this.candidates.length).fontSize(12).fontColor(MUTED)
        Blank()
        Text(this.candidateStateLabel()).fontSize(11).fontColor(BLUE).padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor('#EDF3FF').borderRadius(10)
      }.width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 9 }) {
            Text('音频').fontSize(11).fontColor(MUTED).width('100%')
            Text(this.currentCandidateAudioName()).fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK).width('100%')
            Text('匹配的歌词').fontSize(11).fontColor(MUTED).width('100%').margin({ top: 4 })
            Text(this.currentCandidateLyricName()).fontSize(14).fontColor(INK).width('100%')
            Text('匹配参考  ' + this.currentCandidateConfidence() + ' / 100').fontSize(12)
              .fontColor(this.currentCandidateConfidence() >= 75 ? '#178C72' : '#C47A18').width('100%')
            Text('匹配方式：' + this.currentCandidateStrategy()).fontSize(11).fontColor(MUTED).width('100%')
          }.padding(17).width('100%').backgroundColor(Color.White).borderRadius(20)
          ForEach(this.currentCandidateEvidence(), (evidenceItem: string) => {
            Text('依据：' + evidenceItem).fontSize(12).fontColor(INK).padding(12)
              .backgroundColor(Color.White).borderRadius(12).width('100%')
          }, (evidenceItem: string) => evidenceItem)
          ForEach(this.currentCandidateWarnings(), (warning: string) => {
            Text('注意：' + warning).fontSize(12).fontColor('#A35D18').padding(12)
              .backgroundColor('#FFF1DA').borderRadius(12).width('100%')
          }, (warning: string) => warning)
        }.padding({ bottom: 10 }).width('100%')
      }.layoutWeight(1).width('100%').align(Alignment.Top)
      Row({ space: 8 }) {
        Button('上一项').layoutWeight(1).height(40).backgroundColor(Color.White).fontColor(BLUE)
          .borderRadius(12).enabled(this.candidate > 0).onClick(() => this.jumpToCandidate(this.candidate - 1))
        Button('下一项').layoutWeight(1).height(40).backgroundColor(Color.White).fontColor(BLUE)
          .borderRadius(12).enabled(this.candidate < this.candidates.length - 1).onClick(() => this.jumpToCandidate(this.candidate + 1))
      }.width('100%')
      Row({ space: 8 }) {
        Button('取消匹配').layoutWeight(1).height(44).fontSize(12).backgroundColor(Color.White).fontColor('#B3262D')
          .borderRadius(13).onClick(() => this.reviewCandidate('rejected'))
        Button('暂缓').layoutWeight(1).height(44).fontSize(12).backgroundColor(Color.White).fontColor(BLUE)
          .borderRadius(13).onClick(() => this.reviewCandidate('deferred'))
        Button('确认匹配').layoutWeight(1).height(44).fontSize(12).backgroundColor(BLUE).fontColor(Color.White)
          .borderRadius(13).onClick(() => this.reviewCandidate('confirmed'))
      }.width('100%')
    }.layoutWeight(1).width('100%')
  }

  private currentCandidateAudioName(): string {
    const item = this.currentCandidate();
    return item === undefined ? '' : item.audioName;
  }

  private currentCandidateLyricName(): string {
    const item = this.currentCandidate();
    return item === undefined ? '' : item.lyricName;
  }

  private currentCandidateStrategy(): string {
    const item = this.currentCandidate();
    return item === undefined ? '' : item.strategy;
  }

  private currentCandidateConfidence(): number {
    const item = this.currentCandidate();
    return item === undefined ? 0 : item.confidence;
  }

  private currentCandidateEvidence(): string[] {
    const item = this.currentCandidate();
    return item === undefined ? [] : item.evidence;
  }

  private currentCandidateWarnings(): string[] {
    const item = this.currentCandidate();
    return item === undefined ? [] : item.warnings;
  }
}
