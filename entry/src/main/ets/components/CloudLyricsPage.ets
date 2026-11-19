import { CloudSong, CloudSongCandidate, CloudSongMatcher, LocalSongIdentity } from '../services/CloudSongMatcher';
import { CloudLyrics, CloudLyricsError, CloudLyricsService, CloudSearchResult } from '../services/CloudLyricsService';
import { BilingualLyricsResult, combineCloudLyrics } from '../services/CloudBilingualLyrics';

const BLUE: string = '#3478F6';
const INK: string = '#172B4D';
const MUTED: string = '#7A8AA8';

export type CloudLyricsKind = 'original' | 'translation' | 'bilingual';

export interface CloudLyricsSelection {
  targetKey: string;
  song: CloudSong;
  text: string;
  kind: CloudLyricsKind;
}

function songKey(song: CloudSong): string {
  return song.source + ':' + song.id;
}

function durationLabel(durationMs: number): string {
  if (!Number.isFinite(durationMs) || durationMs <= 0) return '时长未知';
  const seconds: number = Math.floor(durationMs / 1000);
  return Math.floor(seconds / 60).toString() + ':' + (seconds % 60).toString().padStart(2, '0');
}

@Component
export struct CloudLyricsPage {
  @Prop songTitle: string = '';
  @Prop artist: string = '';
  @Prop album: string = '';
  @Prop durationMs: number = 0;
  @Prop titleFromFilename: boolean = false;
  @Prop @Watch('onAudioChanged') audioKey: string = '';
  @Prop @Watch('onBackRequested') backRequest: number = 0;
  @Link previewVisible: boolean;
  onApply: (selection: CloudLyricsSelection) => void = (_selection: CloudLyricsSelection): void => {};
  onClose: () => void = (): void => {};

  @State keyword: string = '';
  @State originalKeyword: string = '';
  @State candidates: CloudSongCandidate[] = [];
  @State recommendedKey: string = '';
  @State selectedIndex: number = -1;
  @State loading: boolean = false;
  @State operation: string = '';
  @State searched: boolean = false;
  @State status: string = '';
  @State hasError: boolean = false;
  @State lyricsUnavailable: boolean = false;
  @State originalText: string = '';
  @State translatedText: string = '';
  @State translationWarning: string = '';
  @State bilingualText: string = '';
  @State bilingualWarning: string = '';
  @State bilingualError: string = '';
  @State textKind: CloudLyricsKind = 'original';

  private service: CloudLyricsService = new CloudLyricsService();
  private generation: number = 0;
  private visible: boolean = false;
  private previewAudioKey: string = '';

  aboutToAppear(): void {
    this.visible = true;
    this.resetForAudio();
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.generation++;
    this.service.cancel();
  }

  private identity(): LocalSongIdentity {
    return { title: this.songTitle, artist: this.artist, album: this.album, durationMs: this.durationMs };
  }

  private onAudioChanged(): void {
    this.resetForAudio();
  }

  private onBackRequested(): void {
    if (this.visible && this.previewVisible) this.backToCandidates();
  }

  private resetForAudio(): void {
    this.generation++;
    this.service.cancel();
    this.loading = false;
    this.operation = '';
    this.originalKeyword = CloudSongMatcher.buildKeyword(this.identity());
    this.keyword = this.originalKeyword;
    this.candidates = [];
    this.recommendedKey = '';
    this.searched = false;
    this.status = '';
    this.hasError = false;
    this.clearPreview();
  }

  private clearPreview(): void {
    this.selectedIndex = -1;
    if (this.previewVisible) this.previewVisible = false;
    this.originalText = '';
    this.translatedText = '';
    this.translationWarning = '';
    this.bilingualText = '';
    this.bilingualWarning = '';
    this.bilingualError = '';
    this.lyricsUnavailable = false;
    this.textKind = 'original';
    this.previewAudioKey = '';
  }

  private accepts(requestId: number, targetKey: string): boolean {
    return this.visible && requestId === this.generation && targetKey === this.audioKey;
  }

  private changeKeyword(value: string): void {
    if (value === this.keyword) return;
    this.generation++;
    this.service.cancel();
    this.loading = false;
    this.operation = '';
    this.keyword = value;
    this.candidates = [];
    this.recommendedKey = '';
    this.searched = false;
    this.status = '';
    this.hasError = false;
    this.clearPreview();
  }

  private async search(): Promise<void> {
    if (!this.visible) return;
    const query: string = this.keyword.trim();
    if (query.length === 0 || query.length > 160) {
      this.status = query.length === 0 ? '请先填写歌曲名或歌手。' : '搜索词过长，请缩短到 160 字以内。';
      this.hasError = true;
      return;
    }
    this.getUIContext().getFocusController().clearFocus();
    this.generation++;
    const requestId: number = this.generation;
    const targetKey: string = this.audioKey;
    this.service.cancel();
    this.candidates = [];
    this.recommendedKey = '';
    this.clearPreview();
    this.loading = true;
    this.operation = 'search';
    this.searched = false;
    this.hasError = false;
    this.status = '正在搜索网易云音乐…';
    try {
      const searchResult: CloudSearchResult = await this.service.searchDetailed(query);
      if (!this.accepts(requestId, targetKey)) return;
      const result = CloudSongMatcher.rank(this.identity(), searchResult.songs,
        !this.titleFromFilename && !searchResult.incomplete && this.keyword === this.originalKeyword);
      this.candidates = result.candidates.slice(0, 20);
      if (result.automatic && this.candidates.length > 0 && this.candidates[0].song.id === result.recommendedId) {
        this.recommendedKey = songKey(this.candidates[0].song);
      }
      this.searched = true;
      this.status = this.candidates.length > 0
        ? '找到 ' + this.candidates.length.toString() + ' 个候选，' +
          (searchResult.incomplete ? '部分结果异常或不完整，已停止推荐，请手动核对。' :
            (result.automatic ? '请核对版本后预览歌词。' : '暂无可靠推荐，请核对标题、歌手和版本。'))
        : (searchResult.incomplete ? '部分结果异常或不完整，已停止推荐，请更换搜索词或稍后重试。' :
          '没有找到候选，可以缩短搜索词或补充歌手后重试。');
    } catch (error) {
      if (!this.accepts(requestId, targetKey)) return;
      this.searched = true;
      this.hasError = true;
      this.status = '搜索失败：' + this.errorMessage(error);
    } finally {
      if (this.accepts(requestId, targetKey)) {
        this.loading = false;
        this.operation = '';
      }
    }
  }

  private async previewCandidate(index: number): Promise<void> {
    if (!this.visible || index < 0 || index >= this.candidates.length) return;
    this.getUIContext().getFocusController().clearFocus();
    const candidate: CloudSongCandidate = this.candidates[index];
    this.generation++;
    const requestId: number = this.generation;
    const targetKey: string = this.audioKey;
    this.service.cancel();
    this.clearPreview();
    this.selectedIndex = index;
    this.previewVisible = true;
    this.loading = true;
    this.operation = 'lyrics';
    this.hasError = false;
    this.status = '正在获取所选歌曲的歌词…';
    try {
      const lyrics: CloudLyrics = await this.service.lyrics(candidate.song);
      if (!this.accepts(requestId, targetKey)) return;
      if (lyrics.source !== candidate.song.source || lyrics.songId !== candidate.song.id) {
        throw new Error('返回的歌曲标识不一致，请重新选择候选。');
      }
      if (lyrics.text.trim().length === 0 && lyrics.translation.trim().length === 0) {
        throw new Error('这首歌暂无可用的原文或译文歌词。');
      }
      this.originalText = lyrics.text;
      this.translatedText = lyrics.translation;
      this.translationWarning = lyrics.translationWarning;
      this.textKind = lyrics.text.trim().length > 0 ? 'original' : 'translation';
      if (lyrics.text.trim().length > 0 && lyrics.translation.trim().length > 0) {
        const combined: BilingualLyricsResult = combineCloudLyrics(lyrics.text, lyrics.translation);
        this.bilingualText = combined.text;
        this.bilingualWarning = combined.warning;
        this.bilingualError = combined.error;
      }
      this.previewAudioKey = targetKey;
      this.status = this.textKind === 'translation' ? '平台暂无可用原文；可单独预览译文，采用后仍需保存。' :
        '歌词仅用于预览；采用后仍需返回歌曲保存。';
    } catch (error) {
      if (!this.accepts(requestId, targetKey)) return;
      if (error instanceof CloudLyricsError && (error.kind === 'PURE_MUSIC' || error.kind === 'NO_LYRICS')) {
        this.lyricsUnavailable = true;
        this.hasError = false;
        this.status = error.message;
      } else {
        this.hasError = true;
        this.status = '歌词获取失败：' + this.errorMessage(error);
      }
    } finally {
      if (this.accepts(requestId, targetKey)) {
        this.loading = false;
        this.operation = '';
      }
    }
  }

  private cancelOperation(): void {
    if (!this.loading) return;
    this.generation++;
    this.service.cancel();
    this.loading = false;
    this.operation = '';
    this.hasError = false;
    this.status = '已取消。可以重新搜索或重试所选歌曲。';
  }

  private backToCandidates(): void {
    this.generation++;
    this.service.cancel();
    this.loading = false;
    this.operation = '';
    this.clearPreview();
    this.hasError = false;
    this.status = '请选择候选，预览后再决定是否采用。';
  }

  private selectedCandidate(): CloudSongCandidate | undefined {
    return this.selectedIndex >= 0 && this.selectedIndex < this.candidates.length
      ? this.candidates[this.selectedIndex] : undefined;
  }

  private selectedTitle(): string {
    const candidate: CloudSongCandidate | undefined = this.selectedCandidate();
    return candidate === undefined ? '' : candidate.song.title;
  }

  private selectedDescription(): string {
    const candidate: CloudSongCandidate | undefined = this.selectedCandidate();
    return candidate === undefined ? '' : this.songDescription(candidate.song);
  }

  private selectedEvidence(): string {
    const candidate: CloudSongCandidate | undefined = this.selectedCandidate();
    return candidate === undefined ? '' : candidate.evidence.join('；');
  }

  private selectedWarnings(): string {
    const candidate: CloudSongCandidate | undefined = this.selectedCandidate();
    return candidate === undefined ? '' : candidate.warnings.join('；');
  }

  private selectedScore(): string {
    const candidate: CloudSongCandidate | undefined = this.selectedCandidate();
    return candidate === undefined ? '' : '匹配分 ' + candidate.score.toString();
  }

  private songDescription(song: CloudSong): string {
    return (song.artists.length > 0 ? song.artists.join(' / ') : '歌手未知') + ' · ' +
      (song.album.length > 0 ? song.album : '专辑未知') + ' · ' + durationLabel(song.durationMs);
  }

  private previewText(): string {
    if (this.textKind === 'translation') return this.translatedText;
    if (this.textKind === 'bilingual') return this.bilingualText;
    return this.originalText;
  }

  private canApply(): boolean {
    return this.visible && !this.loading && !this.lyricsUnavailable && this.selectedCandidate() !== undefined &&
      this.previewAudioKey === this.audioKey &&
      this.previewAudioKey.length > 0 && this.previewText().trim().length > 0;
  }

  private applySelection(): void {
    const candidate: CloudSongCandidate | undefined = this.selectedCandidate();
    if (!this.canApply() || candidate === undefined) return;
    this.onApply({ targetKey: this.previewAudioKey, song: candidate.song, text: this.previewText(), kind: this.textKind });
  }

  private close(): void {
    if (!this.visible) return;
    // Invalidate queued UI events before the parent removes this component.
    this.visible = false;
    this.generation++;
    this.service.cancel();
    this.onClose();
  }

  private errorMessage(error: Object): string {
    return error instanceof Error ? error.message : '网络或平台暂时不可用，请稍后重试。';
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 3 }) {
          Text('云端搜歌词').fontSize(20).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('网易云音乐').fontSize(11).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('返回').id('cloud-back').height(36).fontSize(12).backgroundColor('#EAF1FF').fontColor(BLUE)
          .borderRadius(12).onClick(() => this.close())
      }.width('100%').padding({ top: 2, bottom: 3 })

      if (this.selectedIndex < 0) {
        this.SearchContent()
      } else {
        this.PreviewContent()
      }
    }.padding({ left: 18, right: 18, bottom: 14 }).layoutWeight(1).width('100%')
  }

  @Builder
  private SearchContent() {
    Column({ space: 4 }) {
      Text('本地歌曲 · ' + (this.songTitle.length > 0 ? this.songTitle : '标题未知'))
        .fontSize(13).fontWeight(FontWeight.Medium).fontColor(INK).maxLines(2).width('100%')
      Text((this.artist.length > 0 ? this.artist : '歌手未知') + ' · ' +
        (this.album.length > 0 ? this.album : '专辑未知') + ' · ' + durationLabel(this.durationMs))
        .fontSize(11).fontColor(MUTED).maxLines(2).width('100%')
    }.padding(12).width('100%').backgroundColor(Color.White).borderRadius(15)

    TextInput({ text: this.keyword, placeholder: '歌曲名 歌手' }).id('cloud-keyword').height(44)
      .maxLength(160).backgroundColor(Color.White).borderRadius(12)
      .onChange((value: string) => this.changeKeyword(value))
    Row({ space: 8 }) {
      Button(this.hasError ? '重新搜索' : '搜索歌词').id('cloud-search').layoutWeight(1).height(42)
        .enabled(!this.loading && this.keyword.trim().length > 0).backgroundColor(BLUE).fontColor(Color.White)
        .borderRadius(12).onClick(() => this.search())
      if (this.loading) {
        Button('取消').id('cloud-cancel').height(42).backgroundColor('#EDF3FF').fontColor(BLUE)
          .borderRadius(12).onClick(() => this.cancelOperation())
      }
    }.width('100%')
    Text(this.titleFromFilename
      ? '搜索词及所选歌曲 ID 会发往网易云，不上传音频或本地路径。标题取自文件名，请人工核对候选。'
      : (this.keyword !== this.originalKeyword
        ? '搜索词及所选歌曲 ID 会发往网易云，不上传音频或本地路径。搜索词已修改，请人工核对候选。'
        : '搜索词及所选歌曲 ID 会发往网易云，不上传音频或本地路径。匹配分用于排序，请核对版本。'))
      .fontSize(11).fontColor(MUTED).width('100%').lineHeight(16)
    if (this.status.length > 0) {
      Text(this.status).id('cloud-status').fontSize(12).fontColor(this.hasError ? '#B84738' : MUTED)
        .width('100%').maxLines(3).lineHeight(18)
    }
    if (this.candidates.length > 0) {
      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.candidates, (candidate: CloudSongCandidate, index: number) => {
            this.CandidateCard(candidate, index)
          }, (candidate: CloudSongCandidate): string => songKey(candidate.song))
        }.width('100%').padding({ bottom: 8 })
      }.id('cloud-candidates').layoutWeight(1).width('100%').align(Alignment.Top)
    } else {
      Column({ space: 10 }) {
        if (this.loading) {
          LoadingProgress().width(32).height(32).color(BLUE)
        } else {
          Text(this.searched ? '换一个搜索词，再试一次' : '搜索后在这里选择歌曲')
            .fontSize(14).fontColor(MUTED)
          Text(this.artist.trim().length === 0 ? '本地歌手缺失时，候选需要你逐项核对。' : '选中候选后可以先查看完整歌词。')
            .fontSize(12).fontColor(MUTED).textAlign(TextAlign.Center)
        }
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center).padding(16)
    }
  }

  @Builder
  private CandidateCard(candidate: CloudSongCandidate, index: number) {
    Column({ space: 7 }) {
      Row({ space: 8 }) {
        Text(candidate.song.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK)
          .maxLines(2).layoutWeight(1)
        Text('匹配分 ' + candidate.score.toString()).fontSize(11).fontColor(BLUE)
      }.width('100%')
      Text(this.songDescription(candidate.song)).fontSize(12).fontColor(MUTED).maxLines(3).width('100%')
      if (this.recommendedKey === songKey(candidate.song)) {
        Text('推荐候选 · 请预览并确认').fontSize(11).fontColor(BLUE).width('100%')
      }
      if (candidate.evidence.length > 0) {
        Text(candidate.evidence.join('；')).fontSize(11).fontColor(MUTED).maxLines(3).width('100%')
      }
      if (candidate.warnings.length > 0) {
        Text(candidate.warnings.join('；')).fontSize(11).fontColor('#A86523').maxLines(3).width('100%')
      }
      Row() {
        Text('ID ' + candidate.song.id).fontSize(10).fontColor(MUTED).layoutWeight(1)
        Button('预览歌词').id('cloud-candidate-' + index.toString()).height(36).fontSize(12)
          .backgroundColor('#EDF3FF').fontColor(BLUE).borderRadius(11)
          .onClick(() => this.previewCandidate(index))
      }.width('100%')
    }.padding(14).width('100%').backgroundColor(Color.White).borderRadius(17)
      .border({ width: this.recommendedKey === songKey(candidate.song) ? 1 : 0, color: '#AFCBFF' })
  }

  @Builder
  private PreviewContent() {
    Row() {
      Button('‹ 候选结果').id('cloud-results-back').height(34).fontSize(12).backgroundColor('#EDF3FF')
        .fontColor(BLUE).borderRadius(10).onClick(() => this.backToCandidates())
      Blank()
      Text(this.selectedScore()).fontSize(11).fontColor(MUTED)
    }.width('100%')
    Column({ space: 5 }) {
      Text(this.selectedTitle()).id('cloud-selected-title').fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(INK).maxLines(2).width('100%')
      Text(this.selectedDescription()).fontSize(11).fontColor(MUTED).maxLines(2).width('100%')
      if (this.selectedEvidence().length > 0) {
        Text(this.selectedEvidence()).fontSize(11).fontColor(MUTED).maxLines(3).width('100%')
      }
      if (this.selectedWarnings().length > 0) {
        Text(this.selectedWarnings()).fontSize(11).fontColor('#A86523').maxLines(3).width('100%')
      }
    }.padding(12).width('100%').backgroundColor(Color.White).borderRadius(15)
    if (this.loading) {
      Column({ space: 12 }) {
        LoadingProgress().width(32).height(32).color(BLUE)
        Text('正在获取歌词…').fontSize(12).fontColor(MUTED)
        Button('取消').id('cloud-preview-cancel').height(38).backgroundColor('#EDF3FF').fontColor(BLUE)
          .borderRadius(12).onClick(() => this.cancelOperation())
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    } else if (this.originalText.trim().length > 0 || this.translatedText.trim().length > 0) {
      Row({ space: 8 }) {
        Button(this.originalText.trim().length > 0 ? '原文' : '暂无原文').id('cloud-original').layoutWeight(1).height(36).fontSize(12)
          .enabled(this.originalText.trim().length > 0)
          .backgroundColor(this.textKind === 'original' ? BLUE : Color.White)
          .fontColor(this.textKind === 'original' ? Color.White : BLUE).borderRadius(11)
          .onClick(() => { this.textKind = 'original'; })
        Button(this.translatedText.trim().length > 0 ? '译文' : '暂无译文').id('cloud-translation')
          .layoutWeight(1).height(36).fontSize(12).enabled(this.translatedText.trim().length > 0)
          .backgroundColor(this.textKind === 'translation' ? BLUE : Color.White)
          .fontColor(this.textKind === 'translation' ? Color.White : BLUE).borderRadius(11)
          .onClick(() => { this.textKind = 'translation'; })
        Button('原文+译文').id('cloud-bilingual')
          .layoutWeight(1).height(36).fontSize(12).enabled(this.bilingualText.length > 0)
          .backgroundColor(this.textKind === 'bilingual' ? BLUE : Color.White)
          .fontColor(this.textKind === 'bilingual' ? Color.White : BLUE).borderRadius(11)
          .onClick(() => { this.textKind = 'bilingual'; })
      }.width('100%')
      if (this.originalText.trim().length === 0) {
        Text('平台暂无可用原文，当前仅能预览和采用译文。').fontSize(11).fontColor('#A86523').width('100%')
      }
      if (this.translationWarning.length > 0) {
        Text(this.translationWarning).id('cloud-translation-warning').fontSize(11).fontColor('#A86523')
          .width('100%').maxLines(3).lineHeight(16)
      }
      if (this.bilingualError.length > 0) {
        Text(this.bilingualError).id('cloud-bilingual-error').fontSize(11).fontColor('#A86523')
          .width('100%').lineHeight(16)
      } else if (this.textKind === 'bilingual' && this.bilingualWarning.length > 0) {
        Text(this.bilingualWarning).id('cloud-bilingual-warning').fontSize(11).fontColor('#A86523')
          .width('100%').lineHeight(16)
      }
      Scroll() {
        Text(this.previewText()).id('cloud-lyrics-preview').fontSize(13).fontColor(INK).lineHeight(22)
          .width('100%').padding(14).textAlign(TextAlign.Start)
      }.layoutWeight(1).width('100%').backgroundColor(Color.White).borderRadius(15).align(Alignment.Top)
    } else {
      Column({ space: 12 }) {
        Text(this.status).id('cloud-preview-status').fontSize(13).fontColor(this.hasError ? '#B84738' : MUTED)
          .width('100%').textAlign(TextAlign.Center).lineHeight(20)
        if (this.lyricsUnavailable) {
          Button('返回候选').id('cloud-unavailable-back').height(40).backgroundColor('#EDF3FF').fontColor(BLUE)
            .borderRadius(12).onClick(() => this.backToCandidates())
        } else {
          Button('重试获取歌词').id('cloud-retry-lyrics').height(40).backgroundColor('#EDF3FF').fontColor(BLUE)
            .borderRadius(12).onClick(() => this.previewCandidate(this.selectedIndex))
        }
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center).padding(14)
    }
    if (this.originalText.trim().length > 0 || this.translatedText.trim().length > 0) {
      Text(this.textKind === 'translation'
        ? '当前预览为译文，采用后会使用译文替换编辑区歌词。'
        : (this.textKind === 'bilingual' ? '当前预览为原文加译文，采用后载入编辑区。' :
          '采用后载入编辑区，返回歌曲保存时才会写入音频。'))
        .fontSize(11).fontColor(MUTED).width('100%').lineHeight(16)
    }
    Button(this.textKind === 'translation' ? '采用这份译文' :
      (this.textKind === 'bilingual' ? '采用原文+译文' : '采用这份歌词')).id('cloud-apply')
      .width('100%').height(46).enabled(this.canApply()).backgroundColor(BLUE).fontColor(Color.White)
      .borderRadius(15).onClick(() => this.applySelection())
  }
}
