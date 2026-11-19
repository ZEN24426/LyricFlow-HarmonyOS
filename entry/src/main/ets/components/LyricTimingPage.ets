import { LocalAudioPreview } from '../services/LocalAudioPreview';
import { TimedLyricAdjuster, TimedLyricRow, TimedLyricPlaybackAnchor } from '../services/TimedLyricAdjuster';

const BLUE: string = '#3478F6';
const INK: string = '#172B4D';
const MUTED: string = '#7A8AA8';
const MAX_VISIBLE_ROWS: number = 1000;

/** The parent must verify targetKey and originalText still match before applying. */
export interface LyricTimingResult {
  targetKey: string;
  originalText: string;
  adjustedText: string;
}

/**
 * Independent timing editor. workingPath must be a private imported copy below
 * filesDir from the trusted UIAbility context. The parent owns lifecycle and
 * background handling: unmount on leaving or backgrounding, and surface the
 * cleanup failure; retry only when the error explicitly says it is safe.
 * onApply only returns a proposed edit; it never writes an audio file.
 */
@Component
export struct LyricTimingPage {
  @Prop @Watch('sourceChanged') targetKey: string = '';
  @Prop @Watch('sourceChanged') workingPath: string = '';
  @Prop @Watch('sourceChanged') filesDir: string = '';
  @Prop @Watch('sourceChanged') originalText: string = '';
  onApply: (result: LyricTimingResult) => void = (_result: LyricTimingResult): void => {};
  onClose: () => void = (): void => {};
  onCleanupError: (message: string, retry: () => Promise<void>) => void =
    (_message: string, _retry: () => Promise<void>): void => {};

  @State rows: TimedLyricRow[] = [];
  @State selectedRow: number = -1;
  @State firstRow: number = -1;
  @State lastRow: number = -1;
  @State shiftInput: string = '0';
  @State seekInput: string = '';
  @State anchorInput: string = '';
  @State previewText: string = '';
  @State previewDescription: string = '';
  @State status: string = '';
  @State busy: boolean = false;
  @State ready: boolean = false;
  @State playing: boolean = false;
  @State sourceValid: boolean = false;
  @State canUsePlayback: boolean = false;
  @State reportedPosition: string = '尚未读取';
  @State anchorOneText: string = '未设置';
  @State anchorTwoText: string = '未设置';

  @State playbackPosition: number = 0;
  @State playbackDuration: number = 0;
  @State playbackTime: number = -1;
  @State followPlayback: boolean = true;
  @State scrubbing: boolean = false;
  @State scrubPosition: number = 0;
  private editingInput: boolean = false;
  private playbackTimer: number = -1;
  private lastFollowIndex: number = -1;
  private lyricScroller: Scroller = new Scroller();

  private player: LocalAudioPreview = new LocalAudioPreview();
  private visible: boolean = false;
  private generation: number = 0;
  private baseKey: string = '';
  private baseText: string = '';
  private basePath: string = '';
  private baseFilesDir: string = '';
  private anchorOne: TimedLyricPlaybackAnchor | undefined = undefined;
  private anchorTwo: TimedLyricPlaybackAnchor | undefined = undefined;

  aboutToAppear(): void {
    this.visible = true;
    this.baseKey = this.targetKey;
    this.baseText = this.originalText;
    this.basePath = this.workingPath;
    this.baseFilesDir = this.filesDir;
    // Capture the parent callback independently: a cancelled player factory
    // may produce a resource only after this component has disappeared.
    const cleanupCallback: (message: string, retry: () => Promise<void>) => void = this.onCleanupError;
    this.player.setCleanupErrorCallback((message: string, retry: () => Promise<void>): void => {
      cleanupCallback(message, retry);
    });
    this.player.setStateCallback((state: string): void => {
      if (!this.visible || !this.sourceValid) return;
      this.playing = state === 'playing';
      if (state === 'error' || state === 'cleanupError') {
        this.ready = false;
        this.stopPlaybackTracking();
        this.playbackTime = -1;
      }
      if (state === 'error' || state === 'cleanupError') this.status = '试听发生错误，请关闭后重试。';
    });
    try {
      const parsed: TimedLyricRow[] = TimedLyricAdjuster.inspect(this.baseText);
      if (parsed.length > MAX_VISIBLE_ROWS) throw new Error('歌词行数超过页面上限，请先缩减后再校时。');
      if (this.baseKey.length === 0 || this.basePath.length === 0 || this.baseFilesDir.length === 0) {
        throw new Error('缺少歌曲或私有音频副本，无法试听。');
      }
      this.rows = parsed;
      this.sourceValid = true;
      this.canUsePlayback = this.hasSafeOffset(this.baseText);
      this.status = this.canUsePlayback ? '点击歌词行选择并定位；同一时间的双语行会一起调整。' :
        '歌词含非零或不明确的 offset：可以预览原始时间偏移，但不能把播放器位置当作原始时间校准。';
    } catch (error) {
      this.status = this.message(error as Object);
      // A missing/unsupported timeline must not invent a current line or prevent
      // listening to the already-imported private audio. Timing edits still run
      // through the strict adjuster and cannot produce a partial result.
      if (this.baseKey.length > 0 && this.basePath.length > 0 && this.baseFilesDir.length > 0) {
        this.rows = [];
        this.sourceValid = true;
        this.canUsePlayback = false;
        this.status = '当前歌词无可用逐行时间轴，可试听音频；' + this.status;
      }
    }
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.generation++;
    this.stopPlaybackTracking();
    this.player.setStateCallback(undefined);
    this.cleanupAfterRemoval();
  }

  private cleanupAfterRemoval(): void {
    const player: LocalAudioPreview = this.player;
    player.close().catch((error: Error): void => {
      this.onCleanupError(this.message(error), (): Promise<void> => player.close());
    });
  }

  private sourceChanged(): void {
    if (!this.visible) return;
    this.generation++;
    this.stopPlaybackTracking();
    this.playbackTime = -1;
    this.playing = false;
    this.sourceValid = false;
    this.busy = false;
    this.ready = false;
    this.previewText = '';
    this.anchorOne = undefined;
    this.anchorTwo = undefined;
    this.status = '歌曲或歌词已改变，请返回后重新进入校时。';
    this.cleanupAfterRemoval();
  }

  private isCurrent(ticket: number): boolean {
    return this.visible && this.sourceValid && ticket === this.generation && this.baseKey === this.targetKey &&
      this.baseText === this.originalText && this.basePath === this.workingPath && this.baseFilesDir === this.filesDir;
  }

  private message(error: Object): string {
    return error instanceof Error ? error.message : '操作失败，请重试。';
  }

  /** Playback and raw coordinates coincide only with absent or one zero offset. */
  private hasSafeOffset(text: string): boolean {
    let seen: boolean = false;
    const lines: string[] = text.split(/\r\n|\r|\n/);
    for (const line of lines) {
      if (!/\[\s*offset\b/i.test(line)) continue;
      const match: RegExpMatchArray | null = line.match(/^[\uFEFF \t]*\[offset:([+-]?\d+)\][ \t]*$/i);
      if (match === null || seen || !Number.isSafeInteger(Number(match[1])) || Number(match[1]) !== 0) return false;
      seen = true;
    }
    return true;
  }

  private integer(text: string, label: string): number {
    if (!/^[+-]?\d+$/.test(text.trim())) throw new Error(label + '请输入整数毫秒。');
    const value: number = Number(text.trim());
    if (!Number.isSafeInteger(value)) throw new Error(label + '超出范围。');
    return value;
  }

  private async openAudio(): Promise<void> {
    if (!this.sourceValid || this.busy) return;
    this.stopPlaybackTracking();
    this.playbackTime = -1;
    this.busy = true;
    this.ready = false;
    this.playing = false;
    const ticket: number = this.generation;
    try {
      await this.player.open(this.basePath, this.baseFilesDir);
      if (!this.isCurrent(ticket)) return;
      this.ready = true;
      this.startPlaybackTracking();
      this.playing = false;
      this.reportedPosition = '尚未读取';
      this.status = '试听已打开。选择歌词行后可定位；校准锚点需人工核对实际播放位置。';
    } catch (error) { if (this.isCurrent(ticket)) this.status = this.message(error as Object); }
    finally { if (this.isCurrent(ticket)) this.busy = false; }
  }

  private async togglePlayback(): Promise<void> {
    if (this.busy || !this.sourceValid) return;
    const ticket: number = this.generation;
    // One tap prepares and plays. openAudio synchronously sets busy, so repeated
    // taps cannot queue duplicate prepares while the first request is pending.
    if (!this.ready) await this.openAudio();
    if (!this.isCurrent(ticket) || !this.ready || this.busy) return;
    this.busy = true;
    try {
      if (this.playing) await this.player.pause(); else await this.player.play();
      if (this.isCurrent(ticket)) this.refreshPlayback();
    } catch (error) { if (this.isCurrent(ticket)) this.status = this.message(error as Object); }
    finally { if (this.isCurrent(ticket)) this.busy = false; }
  }

  private stopPlaybackTracking(): void {
    if (this.playbackTimer >= 0) clearInterval(this.playbackTimer);
    this.playbackTimer = -1;
    this.scrubbing = false;
  }

  private startPlaybackTracking(): void {
    this.stopPlaybackTracking();
    this.refreshPlayback(true);
    this.playbackTimer = setInterval((): void => { this.refreshPlayback(); }, 200);
  }

  private refreshPlayback(forceScroll: boolean = false): void {
    if (!this.visible || !this.sourceValid || !this.ready) return;
    const snapshot = this.player.snapshot();
    this.playbackPosition = snapshot.positionMs;
    this.playbackDuration = snapshot.durationMs;
    // UI guidance only: observed player time is never an editing selection or
    // a calibration anchor. Preserve every line in a same-time bilingual group.
    let current: number = -1;
    if (this.canUsePlayback) {
      for (const row of this.rows) {
        if (row.startMs <= snapshot.positionMs && row.startMs > current) current = row.startMs;
      }
    }
    this.playbackTime = current;
    const index: number = this.rows.findIndex((row: TimedLyricRow): boolean => row.startMs === current);
    if (index < 0 || !this.followPlayback || this.editingInput || this.previewText.length > 0) return;
    if (forceScroll || index !== this.lastFollowIndex) {
      this.lyricScroller.scrollToIndex(index, false, ScrollAlign.CENTER);
      this.lastFollowIndex = index;
    }
  }

  // Preview the thumb locally. Only release/click sends one player request;
  // snapshots never overwrite a finger drag or an editing/calibration field.
  private sliderChanged(value: number, mode: SliderChangeMode): void {
    if (!this.ready || this.busy || !this.sourceValid || this.playbackDuration <= 0 || !Number.isFinite(value)) return;
    this.suspendFollowing();
    this.scrubPosition = Math.round(Math.max(0, Math.min(value, this.playbackDuration)));
    this.scrubbing = true;
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.commitScrub(this.scrubPosition);
    }
  }

  private async commitScrub(position: number): Promise<void> {
    const ticket: number = this.generation;
    try { await this.seekTo(position); }
    finally {
      if (this.isCurrent(ticket)) {
        this.scrubbing = false;
        this.refreshPlayback();
      }
    }
  }

  private cancelScrub(): void {
    this.scrubbing = false;
    this.refreshPlayback();
  }

  private suspendFollowing(): void { this.followPlayback = false; }

  private resumeFollowing(): void {
    this.followPlayback = true;
    this.refreshPlayback(true);
  }

  private playbackClock(value: number): string {
    const seconds: number = Math.max(0, Math.floor(value / 1000));
    return Math.floor(seconds / 60).toString() + ':' + (seconds % 60).toString().padStart(2, '0');
  }

  private async seekTo(position: number): Promise<void> {
    if (!this.ready || this.busy || !this.sourceValid) return;
    this.busy = true;
    const ticket: number = this.generation;
    try {
      await this.player.seek(position);
      if (this.isCurrent(ticket)) this.refreshPlayback(true);
      if (!this.isCurrent(ticket)) return;
      this.status = '播放器已报告定位事件；事件可能延迟，请试听并人工核对实际位置。';
    } catch (error) { if (this.isCurrent(ticket)) this.status = this.message(error as Object); }
    finally { if (this.isCurrent(ticket)) this.busy = false; }
  }

  private selectRow(row: TimedLyricRow): void {
    if (!this.sourceValid || this.busy) return;
    this.suspendFollowing();
    this.selectedRow = row.rowIndex;
    this.anchorInput = '';
    if (this.ready && this.canUsePlayback) {
      this.seekInput = row.startMs.toString();
      this.seekTo(row.startMs);
    } else {
      this.status = this.canUsePlayback ? '已选择原始时间 ' + row.startMs.toString() + ' 毫秒的歌词行。' :
        '已选择歌词行；offset 未明确为零，不能自动定位或使用播放器时间作锚点。';
    }
  }

  private selected(): TimedLyricRow | undefined {
    return this.rows.find((row: TimedLyricRow): boolean => row.rowIndex === this.selectedRow);
  }

  private recordAnchor(first: boolean): void {
    const row: TimedLyricRow | undefined = this.selected();
    if (!this.sourceValid || !this.canUsePlayback || this.busy || row === undefined) {
      this.status = '请先选择歌词行；歌词 offset 必须明确为零或不存在。';
      return;
    }
    let playbackMs: number;
    try {
      playbackMs = this.integer(this.anchorInput, '人工确认的播放位置');
      if (playbackMs < 0) throw new Error('播放位置不能为负数。');
    } catch (error) { this.status = this.message(error as Object); return; }
    const sourceMs: number = row.startMs;
    const rowIndex: number = row.rowIndex;
    const ticket: number = this.generation;
    const input: string = this.anchorInput;
    this.getUIContext().showAlertDialog({
      title: '确认播放位置',
      message: '请确认已试听并人工核对：此歌词行的原始时间为 ' + sourceMs.toString() +
        ' 毫秒，实际播放位置为 ' + playbackMs.toString() + ' 毫秒。定位事件可能延迟，不能作为位置证明。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '确认记录', action: (): void => {
        if (!this.isCurrent(ticket) || this.busy || this.selectedRow !== rowIndex || this.anchorInput !== input) return;
        const anchor: TimedLyricPlaybackAnchor = { sourceRawMs: sourceMs, playbackMs };
        const label: string = '原始 ' + sourceMs.toString() + ' → 人工确认播放 ' + playbackMs.toString() + ' 毫秒';
        if (first) { this.anchorOne = anchor; this.anchorOneText = label; }
        else { this.anchorTwo = anchor; this.anchorTwoText = label; }
      } }
    });
  }

  private makePreview(mode: string): void {
    if (!this.sourceValid || this.busy) return;
    try {
      let result: string;
      let description: string;
      if (mode === 'drift') {
        if (!this.canUsePlayback || this.anchorOne === undefined || this.anchorTwo === undefined) {
          throw new Error('请先设置两个有效锚点；非零或不明确 offset 不支持播放器锚点校准。');
        }
        result = TimedLyricAdjuster.correctDriftFromPlayback(this.baseText, this.anchorOne, this.anchorTwo);
        description = '双锚点线性校准';
      } else {
        const amount: number = this.integer(this.shiftInput, '偏移');
        if (mode === 'all') { result = TimedLyricAdjuster.shiftAll(this.baseText, amount); description = '整首偏移'; }
        else if (mode === 'row') {
          if (this.selectedRow < 0) throw new Error('请先选择歌词行。');
          result = TimedLyricAdjuster.shiftRows(this.baseText, this.selectedRow, this.selectedRow, amount);
          description = '选中歌词行偏移';
        } else {
          if (this.firstRow < 0 || this.lastRow < this.firstRow) throw new Error('请依次设置有效的范围起点和终点。');
          result = TimedLyricAdjuster.shiftRows(this.baseText, this.firstRow, this.lastRow, amount);
          description = '所选行范围偏移';
        }
      }
      if (result === this.baseText) throw new Error('调整结果与原歌词相同。');
      this.previewText = result;
      this.previewDescription = description;
      this.status = '请核对完整预览；确认后只更新编辑区，仍需另行保存。';
    } catch (error) {
      this.previewText = '';
      this.status = this.message(error as Object);
    }
  }

  private async leave(apply: boolean): Promise<void> {
    if (this.busy) return;
    const ticket: number = this.generation;
    if (apply && (!this.isCurrent(ticket) || this.previewText.length === 0)) return;
    const result: LyricTimingResult = { targetKey: this.baseKey, originalText: this.baseText, adjustedText: this.previewText };
    this.busy = true;
    try {
      this.stopPlaybackTracking();
      await this.player.close();
      if (!this.visible || ticket !== this.generation) return;
      if (apply && this.isCurrent(ticket)) this.onApply(result); else if (!apply) this.onClose();
    } catch (error) {
      if (this.visible && ticket === this.generation) {
        this.ready = false;
        this.playing = false;
        this.status = '关闭试听失败：' + this.message(error as Object);
      }
      else this.onCleanupError(this.message(error as Object), (): Promise<void> => this.player.close());
    } finally { if (this.visible && ticket === this.generation) this.busy = false; }
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('试听校时').fontSize(20).fontWeight(FontWeight.Bold).fontColor(INK).layoutWeight(1)
        Button('返回').id('timing-back').height(36).enabled(!this.busy)
          .backgroundColor('#EAF1FF').fontColor(BLUE).onClick(() => this.leave(false))
      }.width('100%')
      Row({ space: 8 }) {
        Button(this.busy ? '处理中' : (this.playing ? '暂停' : '播放')).id('timing-play').height(34).width(76)
          .enabled(this.sourceValid && !this.busy).backgroundColor(BLUE).fontColor(Color.White)
          .onClick(() => this.togglePlayback())
        Column({ space: 3 }) {
          Text(this.playbackClock(this.scrubbing ? this.scrubPosition : this.playbackPosition) + ' / ' + this.playbackClock(this.playbackDuration))
            .fontSize(12).fontColor(INK)
          Slider({ value: this.scrubbing ? this.scrubPosition : Math.min(this.playbackPosition, this.playbackDuration),
            min: 0, max: Math.max(1, this.playbackDuration), step: 1 })
            .id('timing-progress').width('100%').height(28)
            .enabled(this.ready && this.sourceValid && !this.busy && this.playbackDuration > 0)
            .accessibilityText('播放进度，拖动或点击定位')
            .onChange((value: number, mode: SliderChangeMode) => { this.sliderChanged(value, mode); })
            .onTouch((event: TouchEvent) => { if (event.type === TouchType.Cancel) this.cancelScrub(); })
        }.layoutWeight(1)
        Button(this.followPlayback ? '跟随中' : '继续跟随').id('timing-follow').height(32).width(82).fontSize(11)
          .enabled(this.ready && this.canUsePlayback && this.rows.length > 0)
          .backgroundColor('#EAF1FF').fontColor(BLUE).onClick(() => this.resumeFollowing())
      }.width('100%').padding(8).backgroundColor(Color.White).borderRadius(12)
      Text(this.status).id('timing-status').fontSize(12).fontColor(MUTED).width('100%').lineHeight(18)
      if (this.previewText.length > 0) {
        Text('预览 · ' + this.previewDescription).fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK).width('100%')
        Scroll() {
          Text(this.previewText).id('timing-preview').fontSize(13).fontColor(INK).lineHeight(22)
            .width('100%').padding(12).textAlign(TextAlign.Start)
        }.layoutWeight(1).width('100%').backgroundColor(Color.White).borderRadius(12).align(Alignment.Top)
        Row({ space: 8 }) {
          Button('继续调整').layoutWeight(1).enabled(!this.busy).backgroundColor('#EAF1FF').fontColor(BLUE)
            .onClick(() => { this.previewText = ''; })
          Button('确认采用预览').id('timing-apply').layoutWeight(1).enabled(!this.busy && this.sourceValid)
            .backgroundColor(BLUE).fontColor(Color.White).onClick(() => this.leave(true))
        }.width('100%')
      } else {
        Column({ space: 8 }) {
            Text('歌词原始时间与播放器时间仅在 offset 不存在或为零时可以直接对应。定位事件可能延迟，校准位置需人工核对。')
              .fontSize(11).fontColor(MUTED).width('100%').lineHeight(16)
            Text('点击歌词行选择' + (this.ready && this.canUsePlayback ? '并定位' : '') + '；行号包含标题等元数据行。')
              .fontSize(11).fontColor(MUTED).width('100%')
            List({ space: 4, scroller: this.lyricScroller }) {
              ForEach(this.rows, (row: TimedLyricRow) => {
                ListItem() {
                  Text((row.rowIndex + 1).toString() + ' · ' + row.startMs.toString() + ' ms  ' + row.text)
                    .width('100%').padding(10).fontSize(12).fontColor(INK).maxLines(2)
                    .backgroundColor(this.playbackTime === row.startMs ? '#DAE8FF' : Color.White).borderRadius(10)
                    .border({ width: this.selectedRow === row.rowIndex ? 2 : 0, color: BLUE })
                    .onClick(() => this.selectRow(row))
                }
              }, (row: TimedLyricRow): string => row.rowIndex.toString())
            }.id('timing-rows').height(180).width('100%')
              .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) this.suspendFollowing(); })
            Scroll() {
              Column({ space: 10 }) {
            Text('偏移（毫秒，负数提前）').fontSize(13).fontColor(INK).width('100%')
            TextInput({ text: this.shiftInput, placeholder: '例如 -250' }).id('timing-shift-input')
              .onFocus(() => { this.editingInput = true; this.suspendFollowing(); })
              .onBlur(() => { this.editingInput = false; if (this.followPlayback) this.refreshPlayback(true); })
              .onChange((value: string) => { this.shiftInput = value; }).backgroundColor(Color.White)
            Row({ space: 6 }) {
              Button('预览整首').layoutWeight(1).enabled(this.sourceValid && !this.busy).fontSize(11)
                .onClick(() => this.makePreview('all'))
              Button('预览所选行').layoutWeight(1).enabled(this.sourceValid && !this.busy).fontSize(11)
                .onClick(() => this.makePreview('row'))
            }.width('100%')
            Row({ space: 6 }) {
              Button('设范围起点').layoutWeight(1).fontSize(11).enabled(this.selectedRow >= 0 && !this.busy)
                .onClick(() => { this.firstRow = this.selectedRow; })
              Button('设范围终点').layoutWeight(1).fontSize(11).enabled(this.selectedRow >= 0 && !this.busy)
                .onClick(() => { this.lastRow = this.selectedRow; })
            }.width('100%')
            Text('范围：' + (this.firstRow < 0 ? '未设置' : (this.firstRow + 1).toString()) + ' - ' +
              (this.lastRow < 0 ? '未设置' : (this.lastRow + 1).toString())).fontSize(11).fontColor(MUTED).width('100%')
            Button('预览范围偏移').enabled(this.sourceValid && !this.busy).onClick(() => this.makePreview('range'))
            Text('双锚点校准').fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK).width('100%')
            Text('先选择歌词行并试听；独立输入你人工核对的实际播放位置，确认后记录锚点。按时间顺序设置两个锚点。')
              .fontSize(11).fontColor(MUTED).width('100%').lineHeight(16)
            Row({ space: 8 }) {
              TextInput({ text: this.seekInput, placeholder: '播放器位置（毫秒）' }).id('timing-seek-input').layoutWeight(1)
              .onFocus(() => { this.editingInput = true; this.suspendFollowing(); })
              .onBlur(() => { this.editingInput = false; if (this.followPlayback) this.refreshPlayback(true); })
                .onChange((value: string) => { this.seekInput = value; }).backgroundColor(Color.White)
              Button('定位').enabled(this.ready && !this.busy).onClick(() => {
                try { this.seekTo(this.integer(this.seekInput, '播放器位置')); }
                catch (error) { this.status = this.message(error as Object); }
              })
            }.width('100%')
            Row({ space: 8 }) {
              Button('读取参考位置').fontSize(11).enabled(this.ready && !this.busy).onClick(() => {
                const position: number = this.player.snapshot().positionMs;
                this.reportedPosition = position.toString() + ' 毫秒（可能滞后）';
              })
              Text(this.reportedPosition).fontSize(11).fontColor(MUTED).layoutWeight(1)
            }.width('100%')
            TextInput({ text: this.anchorInput, placeholder: '人工核对的实际播放位置（毫秒）' }).id('timing-anchor-input')
              .onFocus(() => { this.editingInput = true; this.suspendFollowing(); })
              .onBlur(() => { this.editingInput = false; if (this.followPlayback) this.refreshPlayback(true); })
              .onChange((value: string) => { this.anchorInput = value; }).backgroundColor(Color.White)
            Row({ space: 6 }) {
              Button('记录锚点一').layoutWeight(1).fontSize(11).enabled(this.canUsePlayback && !this.busy)
                .onClick(() => this.recordAnchor(true))
              Button('记录锚点二').layoutWeight(1).fontSize(11).enabled(this.canUsePlayback && !this.busy)
                .onClick(() => this.recordAnchor(false))
            }.width('100%')
            Text('一：' + this.anchorOneText + '\n二：' + this.anchorTwoText).fontSize(11).fontColor(MUTED).width('100%')
            Button('预览双锚点校准').enabled(this.sourceValid && this.canUsePlayback && !this.busy)
              .onClick(() => this.makePreview('drift'))
              }.width('100%').padding({ bottom: 20 })
            }.id('timing-controls').layoutWeight(1).width('100%').align(Alignment.Top)
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').layoutWeight(1).padding({ left: 18, right: 18, bottom: 14 })
  }
}
