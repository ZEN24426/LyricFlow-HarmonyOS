import { MissingLyricsQueue, MissingLyricsSnapshot, MissingLyricsRow, MissingLyricsKind,
  ConfirmedLyricsDraft } from '../services/MissingLyricsQueue';
import { CloudSong, CloudSongCandidate, CloudSongMatcher, LocalSongIdentity } from '../services/CloudSongMatcher';

const BLUE: string = '#3478F6';
const INK: string = '#172B4D';
const MUTED: string = '#7A8AA8';
const CAUTION: string = '#A86523';

/** This is a draft handoff, never permission to overwrite or save a file. */
export interface MissingLyricsSelection {
  audioUri: string;
  audioName: string;
  rowId: string;
  source: string;
  songId: string;
  kind: MissingLyricsKind;
  text: string;
  expectedIdentity: LocalSongIdentity;
  expectedTitleFromFilename: boolean;
}

function stateLabel(value: string): string {
  if (value === 'missing') return '已确认无内嵌标签（扫描时）';
  if (value === 'plain') return '已有纯文本歌词';
  if (value === 'timed') return '已有时间歌词';
  return '未知，不能视为缺失';
}

function songDescription(song: CloudSong): string {
  const seconds: number = Number.isFinite(song.durationMs) && song.durationMs > 0 ? Math.floor(song.durationMs / 1000) : 0;
  const duration: string = seconds > 0 ? Math.floor(seconds / 60).toString() + ':' +
    (seconds % 60).toString().padStart(2, '0') : '时长未知';
  return (song.artists.length > 0 ? song.artists.join(' / ') : '歌手未知') + ' · ' +
    (song.album.length > 0 ? song.album : '专辑未知') + ' · ' + duration;
}

@Component
export struct MissingLyricsPage {
  @Prop @Watch('onFolderChanged') folderUri: string = '';
  @Prop @Watch('onFolderChanged') filesDir: string = '';
  onConfirm: (selection: MissingLyricsSelection) => void = (_selection: MissingLyricsSelection): void => {};
  onClose: () => void = (): void => {};
  onCleanupError: (message: string) => void = (_message: string): void => {};

  @State private rows: MissingLyricsRow[] = [];
  @State private warnings: string[] = [];
  @State private candidates: CloudSongCandidate[] = [];
  @State private selectedRowId: string = '';
  @State private searchRowId: string = '';
  @State private selectedKey: string = '';
  @State private recommendedId: string = '';
  @State private keyword: string = '';
  @State private queryDirty: boolean = true;
  @State private screen: string = 'list';
  @State private busy: boolean = false;
  @State private cancelling: boolean = false;
  @State private cancelRequested: boolean = false;
  @State private operation: string = '';
  @State private status: string = '';
  @State private original: string = '';
  @State private translation: string = '';
  @State private translationWarning: string = '';
  @State private bilingual: string = '';
  @State private bilingualWarning: string = '';
  @State private bilingualError: string = '';
  @State private kind: MissingLyricsKind = 'original';
  @State private acknowledged: boolean = false;
  @State private previewReady: boolean = false;
  @State private previewSong: string = '';
  @State private previewDescription: string = '';

  private queue: MissingLyricsQueue = new MissingLyricsQueue();
  private visible: boolean = false;
  private generation: number = 0;
  private delivered: boolean = false;

  aboutToAppear(): void { this.visible = true; this.delivered = false; this.onFolderChanged(); }
  aboutToDisappear(): void { this.visible = false; this.generation++; this.queue.cancel(); }

  private onFolderChanged(): void {
    this.generation++;
    this.queue.cancel();
    // Old I/O may finish later; the new directory must never reuse its queue.
    this.queue = new MissingLyricsQueue();
    const cleanupCallback: (message: string) => void = this.onCleanupError;
    this.queue.setCleanupErrorCallback((message: string): void => { cleanupCallback(message); });
    this.rows = []; this.warnings = []; this.candidates = []; this.selectedRowId = '';
    this.searchRowId = ''; this.selectedKey = ''; this.screen = 'list'; this.keyword = '';
    this.queryDirty = true; this.acknowledged = false; this.previewReady = false; this.cancelRequested = false;
    this.status = '请扫描已授权目录。';
    this.sync();
  }

  private sync(): void {
    const s: MissingLyricsSnapshot = this.queue.snapshot();
    this.busy = s.busy; this.cancelling = s.cancelling; this.operation = s.operation;
    this.rows = s.rows; this.warnings = s.warnings; this.searchRowId = s.searchRowId;
    this.candidates = s.candidates; this.selectedKey = s.selectedKey; this.recommendedId = s.recommendedId;
    this.original = s.previewOriginal; this.translation = s.previewTranslation;
    this.translationWarning = s.previewTranslationWarning; this.bilingual = s.previewBilingual;
    this.bilingualWarning = s.previewBilingualWarning; this.bilingualError = s.previewBilingualError;
  }

  private accepts(ticket: number, folder: string, dir: string): boolean {
    return this.visible && !this.delivered && ticket === this.generation && folder === this.folderUri && dir === this.filesDir;
  }

  private row(): MissingLyricsRow | undefined {
    return this.rows.find((item: MissingLyricsRow): boolean => item.id === this.selectedRowId);
  }

  private async scan(): Promise<void> {
    if (this.busy || this.folderUri.length === 0 || this.filesDir.length === 0) return;
    this.generation++;
    const ticket: number = this.generation; const folder: string = this.folderUri; const dir: string = this.filesDir;
    this.screen = 'list'; this.selectedRowId = ''; this.queryDirty = true; this.acknowledged = false;
    this.cancelRequested = false; this.status = '正在只读检查文件，耗时取决于文件数量。';
    try {
      const pending: Promise<void> = this.queue.scan(folder, dir);
      this.sync();
      await pending;
      if (this.accepts(ticket, folder, dir)) this.status = this.cancelRequested ? '任务已取消。' : this.queue.snapshot().status;
    } catch (_error) {
      if (this.accepts(ticket, folder, dir)) this.status = this.cancelRequested ? '任务已取消。' : '扫描未完成，请检查目录授权后重试。';
    } finally {
      if (this.accepts(ticket, folder, dir)) {
        const cancelled: boolean = this.cancelRequested;
        this.sync();
        if (cancelled) { this.rows = []; this.warnings = []; }
        this.cancelRequested = false;
      }
    }
  }

  private chooseRow(row: MissingLyricsRow): void {
    if (this.busy || row.uri.length === 0) return;
    this.selectedRowId = row.id; this.keyword = CloudSongMatcher.buildKeyword(row.identity);
    this.queryDirty = true; this.acknowledged = false; this.previewReady = false; this.screen = 'search';
    this.status = '请核对歌曲后主动搜索。';
  }

  private changeKeyword(value: string): void {
    if (this.busy || value === this.keyword) return;
    this.keyword = value; this.queryDirty = true; this.acknowledged = false;
  }

  private async search(): Promise<void> {
    if (this.busy || this.selectedRowId.length === 0 || this.keyword.trim().length === 0) return;
    this.generation++;
    const ticket: number = this.generation; const folder: string = this.folderUri; const dir: string = this.filesDir;
    const target: string = this.selectedRowId;
    this.queryDirty = true; this.acknowledged = false; this.cancelRequested = false; this.status = '正在搜索…';
    try {
      const pending: Promise<void> = this.queue.search(target, this.keyword);
      this.sync();
      await pending;
      if (this.accepts(ticket, folder, dir) && this.selectedRowId === target) {
        this.queryDirty = this.cancelRequested; this.status = this.cancelRequested ? '任务已取消。' : this.queue.snapshot().status;
      }
    } catch (_error) {
      if (this.accepts(ticket, folder, dir)) this.status = this.cancelRequested ? '任务已取消。' : '搜索失败，请检查网络或搜索词后重试。';
    } finally { if (this.accepts(ticket, folder, dir)) { this.sync(); this.cancelRequested = false; } }
  }

  private async preview(candidate: CloudSongCandidate): Promise<void> {
    if (this.busy || this.queryDirty || this.searchRowId !== this.selectedRowId) return;
    this.generation++;
    const ticket: number = this.generation; const folder: string = this.folderUri; const dir: string = this.filesDir;
    const target: string = this.selectedRowId;
    this.acknowledged = false; this.previewReady = false; this.cancelRequested = false; this.kind = 'original'; this.screen = 'preview';
    this.previewSong = candidate.song.title + ' · ID ' + candidate.song.id;
    this.previewDescription = songDescription(candidate.song);
    this.status = '正在获取所选歌词…';
    try {
      this.queue.selectCandidate(candidate.song.source, candidate.song.id);
      const pending: Promise<void> = this.queue.previewSelected();
      this.sync();
      await pending;
      if (this.accepts(ticket, folder, dir) && this.selectedRowId === target) {
        this.previewReady = !this.cancelRequested;
        const result: MissingLyricsSnapshot = this.queue.snapshot();
        this.kind = result.previewOriginal.trim().length > 0 ? 'original' : 'translation';
        this.status = this.cancelRequested ? '任务已取消。' : this.queue.snapshot().status;
      }
    } catch (_error) {
      if (this.accepts(ticket, folder, dir)) this.status = this.cancelRequested ? '任务已取消。' : '歌词获取失败，请返回候选后重试。';
    } finally { if (this.accepts(ticket, folder, dir)) { this.sync(); this.cancelRequested = false; } }
  }

  private cancel(): void {
    if (!this.busy) return;
    this.cancelRequested = true; this.queue.cancel(); this.sync(); this.status = '正在取消，请等待当前读取结束。';
  }

  private returnToList(): void {
    if (this.busy) return;
    this.screen = 'list'; this.selectedRowId = ''; this.acknowledged = false; this.status = '';
  }

  private returnToCandidates(): void {
    if (this.busy) return;
    this.screen = 'search'; this.acknowledged = false; this.previewReady = false; this.status = '请核对候选并预览。';
  }

  private currentText(): string {
    if (!this.previewReady) return '';
    if (this.kind === 'translation') return this.translation;
    if (this.kind === 'bilingual') return this.bilingual;
    return this.original;
  }

  private confirm(): void {
    const row: MissingLyricsRow | undefined = this.row();
    if (!this.visible || this.delivered || this.busy || !this.previewReady || !this.acknowledged || row === undefined ||
        row.uri.length === 0 || this.searchRowId !== row.id || this.currentText().trim().length === 0) return;
    try {
      const draft: ConfirmedLyricsDraft = this.queue.confirmPreview(this.kind);
      if (draft.rowId !== row.id || draft.text !== this.currentText()) throw new Error('歌词草稿已失效。');
      this.delivered = true; this.generation++; this.queue.cancel();
      this.onConfirm({ audioUri: row.uri, audioName: row.name, rowId: row.id, source: draft.source,
        songId: draft.songId, kind: draft.kind, text: draft.text,
        expectedIdentity: { title: row.identity.title, artist: row.identity.artist,
          album: row.identity.album, durationMs: row.identity.durationMs },
        expectedTitleFromFilename: row.titleFromFilename });
    } catch (_error) { this.status = '歌词草稿已失效，请重新预览。'; }
  }

  private close(): void { this.visible = false; this.generation++; this.queue.cancel(); this.onClose(); }

  build() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 3 }) {
          Text('查找缺失歌词').fontSize(20).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('逐首核对 · 不会自动写入').fontSize(11).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('返回').id('missing-back').height(36).fontSize(12).backgroundColor('#EAF1FF')
          .fontColor(BLUE).borderRadius(12).onClick(() => this.close())
      }.width('100%')
      if (this.screen === 'list') { this.ListContent() }
      else if (this.screen === 'search') { this.SearchContent() }
      else { this.PreviewContent() }
    }.padding({ left: 18, right: 18, bottom: 14 }).layoutWeight(1).width('100%')
  }

  @Builder
  private Status() {
    if (this.status.length > 0) {
      Text(this.status).id('missing-status').fontSize(12).fontColor(MUTED).width('100%').lineHeight(18)
    }
    if (this.busy) {
      Button(this.cancelling ? '正在取消…' : '取消任务').id('missing-cancel').enabled(!this.cancelling)
        .height(36).fontSize(12).backgroundColor('#EDF3FF').fontColor(BLUE).onClick(() => this.cancel())
    }
  }

  @Builder
  private ListContent() {
    Text('内嵌和同目录同名歌词分别检查；未知表示无法确认，并不等于没有歌词。')
      .fontSize(12).fontColor(MUTED).width('100%').lineHeight(18)
    Button('扫描已授权目录').id('missing-scan').width('100%').height(42).enabled(!this.busy && this.folderUri.length > 0 && this.filesDir.length > 0)
      .backgroundColor(BLUE).fontColor(Color.White).borderRadius(12).onClick(() => this.scan())
    this.Status()
    Scroll() {
      Column({ space: 10 }) {
        ForEach(this.warnings, (warning: string) => {
          Text(warning).fontSize(11).fontColor(CAUTION).width('100%').lineHeight(16)
        }, (warning: string, index: number): string => index.toString() + warning)
        ForEach(this.rows, (row: MissingLyricsRow) => { this.RowCard(row) }, (row: MissingLyricsRow): string => row.id)
      }.width('100%').padding({ bottom: 8 })
    }.layoutWeight(1).width('100%').align(Alignment.Top)
  }

  @Builder
  private RowCard(row: MissingLyricsRow) {
    Column({ space: 6 }) {
      Text(row.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK).width('100%').maxLines(2)
      Text('内嵌：' + stateLabel(row.embedded)).fontSize(12).fontColor(row.embedded === 'missing' ? BLUE : CAUTION).width('100%')
      if (row.embeddedHasReadableText) {
        Text('读取器可见内容：' + stateLabel(row.embeddedVisibleText) + '；其他标签仍可能未知。')
          .fontSize(11).fontColor(CAUTION).width('100%').lineHeight(16)
      }
      Text('旁路：' + stateLabel(row.sidecar) + (row.sidecarName.length > 0 ? ' · ' + row.sidecarName : ''))
        .fontSize(12).fontColor(CAUTION).width('100%').lineHeight(17)
      Text(row.note).fontSize(11).fontColor(MUTED).width('100%').lineHeight(16)
      Button('逐首搜索').id('missing-row-' + row.id).height(36).fontSize(12).enabled(!this.busy && row.uri.length > 0)
        .backgroundColor('#EDF3FF').fontColor(BLUE).borderRadius(10).onClick(() => this.chooseRow(row))
    }.padding(14).width('100%').backgroundColor(Color.White).borderRadius(16)
  }

  @Builder
  private SearchContent() {
    Button('‹ 歌曲列表').height(34).fontSize(12).enabled(!this.busy).backgroundColor('#EDF3FF')
      .fontColor(BLUE).onClick(() => this.returnToList())
    Text(this.row() === undefined ? '歌曲已失效' : (this.row() as MissingLyricsRow).name)
      .fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK).width('100%').maxLines(2)
    TextInput({ text: this.keyword, placeholder: '歌曲名 歌手' }).id('missing-keyword').maxLength(160)
      .enabled(!this.busy).height(44).backgroundColor(Color.White).borderRadius(12).onChange((value: string) => this.changeKeyword(value))
    Button('搜索歌词').id('missing-search').width('100%').height(42).enabled(!this.busy && this.keyword.trim().length > 0)
      .backgroundColor(BLUE).fontColor(Color.White).borderRadius(12).onClick(() => this.search())
    Text('搜索词和所选歌曲 ID 会发往网易云，不上传音频或本地路径。匹配分仅供参考，请人工核对版本。')
      .fontSize(11).fontColor(MUTED).width('100%').lineHeight(16)
    this.Status()
    if (!this.queryDirty && this.searchRowId === this.selectedRowId) {
      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.candidates, (candidate: CloudSongCandidate, index: number) => {
            this.CandidateCard(candidate, index)
          }, (candidate: CloudSongCandidate): string => JSON.stringify([candidate.song.source, candidate.song.id]))
        }.width('100%').padding({ bottom: 8 })
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    } else { Blank().layoutWeight(1) }
  }

  @Builder
  private CandidateCard(candidate: CloudSongCandidate, index: number) {
    Column({ space: 6 }) {
      Text(candidate.song.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK).width('100%').maxLines(2)
      Text(songDescription(candidate.song)).fontSize(11).fontColor(MUTED).width('100%').maxLines(3)
      Text('匹配分 ' + candidate.score.toString() + (candidate.song.id === this.recommendedId ? ' · 推荐候选，仍需核对' : ''))
        .fontSize(11).fontColor(BLUE).width('100%')
      if (candidate.evidence.length > 0) { Text(candidate.evidence.join('；')).fontSize(11).fontColor(MUTED).width('100%') }
      if (candidate.warnings.length > 0) { Text(candidate.warnings.join('；')).fontSize(11).fontColor(CAUTION).width('100%') }
      Button('选择并预览').id('missing-candidate-' + index.toString()).height(36).fontSize(12).enabled(!this.busy)
        .backgroundColor('#EDF3FF').fontColor(BLUE).onClick(() => this.preview(candidate))
    }.padding(14).width('100%').backgroundColor(Color.White).borderRadius(16)
  }

  @Builder
  private PreviewContent() {
    Button('‹ 候选结果').height(34).fontSize(12).enabled(!this.busy).backgroundColor('#EDF3FF')
      .fontColor(BLUE).onClick(() => this.returnToCandidates())
    Text(this.previewSong).fontSize(14).fontWeight(FontWeight.Medium).fontColor(INK).width('100%').maxLines(2)
    Text(this.previewDescription).fontSize(11).fontColor(MUTED).width('100%').maxLines(2)
    this.Status()
    Row({ space: 6 }) {
      Button('原文').height(34).fontSize(11).enabled(!this.busy && this.original.length > 0)
        .backgroundColor(this.kind === 'original' ? BLUE : '#EDF3FF').fontColor(this.kind === 'original' ? Color.White : BLUE)
        .onClick(() => { this.kind = 'original'; this.acknowledged = false; })
      Button('译文').height(34).fontSize(11).enabled(!this.busy && this.translation.length > 0)
        .backgroundColor(this.kind === 'translation' ? BLUE : '#EDF3FF').fontColor(this.kind === 'translation' ? Color.White : BLUE)
        .onClick(() => { this.kind = 'translation'; this.acknowledged = false; })
      Button('原文+译文').height(34).fontSize(11).enabled(!this.busy && this.bilingual.length > 0)
        .backgroundColor(this.kind === 'bilingual' ? BLUE : '#EDF3FF').fontColor(this.kind === 'bilingual' ? Color.White : BLUE)
        .onClick(() => { this.kind = 'bilingual'; this.acknowledged = false; })
    }.width('100%')
    if (this.translationWarning.length > 0) { Text(this.translationWarning).fontSize(11).fontColor(CAUTION).width('100%') }
    if (this.bilingualWarning.length > 0) { Text(this.bilingualWarning).fontSize(11).fontColor(CAUTION).width('100%') }
    if (this.bilingualError.length > 0) { Text(this.bilingualError).fontSize(11).fontColor(CAUTION).width('100%') }
    Scroll() {
      Text(this.currentText().length > 0 ? this.currentText() : '暂无可预览的歌词。')
        .fontSize(13).fontColor(INK).width('100%').lineHeight(21).textAlign(TextAlign.Start)
    }.layoutWeight(1).width('100%').align(Alignment.Top).backgroundColor(Color.White).borderRadius(15).padding(12)
    Text('歌词状态可能未知或已有内容，扫描结果也可能过期。接下来只打开歌曲编辑；保存前请再次检查现有内嵌及旁路歌词，并自行确认。')
      .fontSize(11).fontColor(CAUTION).width('100%').lineHeight(16)
    Row({ space: 6 }) {
      Checkbox().select(this.acknowledged).onChange((checked: boolean) => { this.acknowledged = checked; })
      Text('我已知悉，继续前往编辑并再次核对').fontSize(12).fontColor(INK).layoutWeight(1)
    }.width('100%')
    Button('确认并打开编辑').id('missing-confirm').width('100%').height(42)
      .enabled(!this.busy && this.previewReady && this.acknowledged && this.currentText().trim().length > 0 && this.searchRowId === this.selectedRowId)
      .backgroundColor(BLUE).fontColor(Color.White).borderRadius(12).onClick(() => this.confirm())
  }
}
