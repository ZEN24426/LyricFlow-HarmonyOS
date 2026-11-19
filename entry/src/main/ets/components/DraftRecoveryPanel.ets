import { common } from '@kit.AbilityKit';
import { AudioMetadataService } from '../services/AudioMetadataService';
import { CorruptDraftSummary, DraftCommitResult, DraftRestore, DraftService, DraftSession, DraftSummary } from '../services/DraftService';

const DRAFT_BLUE: string = '#3478F6';
const DRAFT_INK: string = '#172B4D';
const DRAFT_MUTED: string = '#7A8AA8';

/**
 * Parent contract:
 * - increment editGeneration whenever the editor text/metadata/target changes;
 * - onRestore runs synchronously inside commitRestore, must recheck the editor,
 *   call claim() BEFORE taking ownership of the supplied working copy, then return true;
 * - begin autosaving the new session only after onCommitted;
 * - a false result before claim leaves the editor untouched and releases the copy;
 * - onRecoveryIssue must retain/resolve a copy whose ownership is uncertain.
 * This panel never writes audio or applies a draft to the editor itself.
 */
@Component
export struct DraftRecoveryPanel {
  @Prop editGeneration: number = 0;
  onRestore: (result: DraftRestore, editGeneration: number, claim: () => void) => boolean =
    (_result: DraftRestore, _generation: number, _claim: () => void): boolean => false;
  onCommitted: (session: DraftSession) => void = (_session: DraftSession): void => {};
  onRecoveryIssue: (result: DraftRestore, state: string, warning: string) => void =
    (_result: DraftRestore, _state: string, _warning: string): void => {};
  onLater: () => void = (): void => {};
  onDeleted: () => void = (): void => {};

  @State mode: string = 'loading';
  @State busy: boolean = false;
  @State confirmingDelete: boolean = false;
  @State pendingReady: boolean = false;
  @State sourceName: string = '';
  @State savedAt: number = 0;
  @State coverNeedsReselection: boolean = false;
  @State status: string = '';
  private revision: string = '';
  private corruptToken: string = '';
  private generation: number = 0;
  private visible: boolean = false;
  private pending: DraftRestore | undefined = undefined;
  private pendingEditGeneration: number = 0;
  private committing: boolean = false;

  aboutToAppear(): void {
    this.visible = true;
    this.refresh();
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.generation++;
    if (!this.committing) this.releasePending();
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private current(generation: number): boolean {
    return this.visible && generation === this.generation;
  }

  private async dispose(result: DraftRestore): Promise<void> {
    DraftService.abandonRestore(result.session);
    if (result.audio.metadata.coverImage !== undefined) {
      try { await result.audio.metadata.coverImage.release(); } catch (_error) {}
    }
    await AudioMetadataService.removeWorkingFile(result.audio.workingPath);
  }

  private async releasePending(): Promise<void> {
    const current: DraftRestore | undefined = this.pending;
    this.pending = undefined;
    this.pendingReady = false;
    if (current !== undefined) await this.dispose(current);
  }

  private async refresh(): Promise<void> {
    if (this.busy) return;
    const request: number = ++this.generation;
    this.busy = true;
    this.mode = 'loading';
    this.status = '';
    this.confirmingDelete = false;
    this.revision = '';
    this.corruptToken = '';
    try {
      const summary: DraftSummary | undefined = await DraftService.inspect(this.context());
      if (!this.current(request)) return;
      if (summary === undefined) {
        this.mode = 'empty';
      } else {
        this.revision = summary.revision;
        this.sourceName = summary.sourceName;
        this.savedAt = summary.savedAt;
        this.coverNeedsReselection = summary.coverNeedsReselection;
        this.mode = 'available';
      }
    } catch (_error) {
      if (!this.current(request)) return;
      try {
        const corrupt: CorruptDraftSummary = await DraftService.inspectCorrupt(this.context());
        if (!this.current(request)) return;
        this.corruptToken = corrupt.token;
        this.mode = 'corrupt';
      } catch (_nestedError) {
        if (!this.current(request)) return;
        this.mode = 'error';
        this.status = '暂时无法检查草稿，请稍后重试。';
      }
    } finally {
      if (this.current(request)) this.busy = false;
    }
  }

  private async beginRestore(): Promise<void> {
    if (this.busy || this.mode !== 'available' || this.revision.length === 0 || this.pending !== undefined) return;
    const request: number = ++this.generation;
    const expectedEditGeneration: number = this.editGeneration;
    this.busy = true;
    this.status = '请选择原音频，正在准备核对文件内容。';
    try {
      const result: DraftRestore | undefined = await DraftService.restore(this.context(), this.revision);
      if (result === undefined) {
        if (this.current(request)) this.status = '已取消选择，草稿仍然保留。';
        return;
      }
      if (!this.current(request) || this.editGeneration !== expectedEditGeneration) {
        await this.dispose(result);
        if (this.current(request)) this.status = '当前编辑已变化，请重新检查后再恢复。';
        return;
      }
      this.pending = result;
      this.pendingEditGeneration = expectedEditGeneration;
      this.pendingReady = true;
      this.status = '音频已核对。确认载入后才会替换当前编辑内容，原音频不会被写入。';
    } catch (_error) {
      if (this.current(request)) this.status = '音频核对未完成，请重新选择原音频；草稿仍然保留。';
    } finally {
      if (this.current(request)) this.busy = false;
    }
  }

  private async confirmRestore(): Promise<void> {
    if (this.busy || !this.pendingReady || this.pending === undefined) return;
    if (this.editGeneration !== this.pendingEditGeneration) {
      await this.releasePending();
      this.status = '当前编辑已变化，未载入草稿。';
      return;
    }
    const result: DraftRestore = this.pending;
    const expectedEditGeneration: number = this.pendingEditGeneration;
    const request: number = ++this.generation;
    this.busy = true;
    this.committing = true;
    let outcome: DraftCommitResult = { state: 'rejected', editorAccepted: false, warning: '' };
    try {
      outcome = await DraftService.commitRestore(this.context(), result.session, (claim: () => void): boolean => {
        if (!this.current(request) || this.editGeneration !== expectedEditGeneration) return false;
        return this.onRestore(result, expectedEditGeneration, claim);
      });
    } catch (_error) {
      outcome = { state: 'rejected', editorAccepted: false, warning: '草稿未载入，请重新检查。' };
    }
    this.pending = undefined;
    this.pendingReady = false;
    this.committing = false;
    if (outcome.state === 'rejected') {
      await this.dispose(result);
      if (this.visible) this.status = outcome.warning.length > 0 ? outcome.warning : '未载入草稿，当前编辑保持不变。';
    } else if (outcome.state === 'uncertain') {
      try { this.onRecoveryIssue(result, outcome.state, outcome.warning); } catch (_error) {}
      if (this.visible) { this.mode = 'notice'; this.status = outcome.warning; }
    } else {
      let warning: string = outcome.warning;
      if (outcome.editorAccepted) {
        try { this.onCommitted(result.session); } catch (_error) {
          warning += (warning.length > 0 ? ' ' : '') + '草稿已载入，但编辑会话通知失败，请检查当前编辑。';
        }
      } else {
        warning += (warning.length > 0 ? ' ' : '') + '编辑尚未完成接收，自动保存已暂停。';
      }
      if (warning.length > 0) {
        try { this.onRecoveryIssue(result, outcome.state, warning); } catch (_error) {}
        if (this.visible) { this.mode = 'notice'; this.status = warning; }
      } else if (this.visible) {
        this.visible = false;
        this.generation++;
        this.onLater();
      }
    }
    if (this.visible) this.busy = false;
  }

  private async cancelRestore(): Promise<void> {
    if (this.busy) return;
    await this.releasePending();
    if (this.visible) this.status = '已取消载入，草稿仍然保留。';
  }

  private askDelete(): void {
    if (this.busy || this.pendingReady || (this.mode !== 'available' && this.mode !== 'corrupt')) return;
    this.confirmingDelete = true;
    this.status = '';
  }

  private async confirmDelete(): Promise<void> {
    if (this.busy || !this.confirmingDelete) return;
    const currentMode: string = this.mode;
    const identifier: string = currentMode === 'corrupt' ? this.corruptToken : this.revision;
    if ((currentMode !== 'available' && currentMode !== 'corrupt') || identifier.length === 0) return;
    const request: number = ++this.generation;
    this.busy = true;
    this.confirmingDelete = false;
    try {
      if (currentMode === 'corrupt') await DraftService.discardCorrupt(this.context(), identifier);
      else await DraftService.discard(this.context(), identifier);
      if (!this.current(request)) return;
      this.mode = 'empty';
      this.status = '草稿已删除，音频文件没有修改。';
      this.revision = '';
      this.corruptToken = '';
      this.onDeleted();
    } catch (_error) {
      if (this.current(request)) this.status = '删除未完成，草稿可能已变化，请重新检查。';
    } finally {
      if (this.current(request)) this.busy = false;
    }
  }

  private async later(): Promise<void> {
    if (this.busy) return;
    this.visible = false;
    this.generation++;
    await this.releasePending();
    this.onLater();
  }

  build() {
    Column({ space: 12 }) {
      Text('编辑草稿').fontSize(20).fontWeight(FontWeight.Bold).fontColor(DRAFT_INK).width('100%')
      if (this.mode === 'loading') {
        Text('正在检查草稿…').fontSize(13).fontColor(DRAFT_MUTED).width('100%')
      } else if (this.mode === 'available') {
        Text('找到一份未完成的编辑').fontSize(15).fontColor(DRAFT_INK).width('100%')
        Text(this.sourceName).fontSize(13).fontColor(DRAFT_MUTED).width('100%').maxLines(2)
        Text('保存时间：' + new Date(this.savedAt).toLocaleString()).fontSize(11).fontColor(DRAFT_MUTED).width('100%')
        if (this.coverNeedsReselection) {
          Text('封面未保存在草稿中，恢复后请重新选择。').fontSize(12).fontColor('#A86523').width('100%')
        }
      } else if (this.mode === 'corrupt') {
        Text('草稿已损坏，无法恢复。你可以稍后处理，或确认删除这份损坏草稿。')
          .fontSize(13).fontColor('#A86523').width('100%').lineHeight(20)
      } else if (this.mode === 'empty') {
        Text('当前没有可恢复的草稿。').fontSize(13).fontColor(DRAFT_MUTED).width('100%')
      } else if (this.mode === 'notice') {
        Text('草稿处理结果').fontSize(13).fontColor(DRAFT_INK).width('100%')
      } else {
        Text('暂时无法检查草稿。').fontSize(13).fontColor(DRAFT_MUTED).width('100%')
      }
      if (this.status.length > 0) {
        Text(this.status).id('draft-recovery-status').fontSize(12).fontColor(DRAFT_MUTED).width('100%').lineHeight(18)
      }
      if (this.pendingReady) {
        Text('载入会替换当前编辑内容；请先确认当前编辑已妥善保留。')
          .fontSize(12).fontColor('#A86523').width('100%').lineHeight(18)
        Button('确认载入草稿').id('draft-confirm-restore').width('100%').height(42).enabled(!this.busy)
          .backgroundColor(DRAFT_BLUE).fontColor(Color.White).onClick(() => { this.confirmRestore(); })
        Button('取消载入').id('draft-cancel-restore').width('100%').height(40).enabled(!this.busy)
          .onClick(() => { this.cancelRestore(); })
      } else if (this.confirmingDelete) {
        Text(this.mode === 'corrupt' ? '确认删除这份损坏草稿？此操作无法撤销。' : '确认删除这份草稿？此操作无法撤销。')
          .fontSize(12).fontColor('#A86523').width('100%').lineHeight(18)
        Button('确认删除草稿').id('draft-confirm-delete').width('100%').height(42).enabled(!this.busy)
          .backgroundColor('#B84738').fontColor(Color.White).onClick(() => { this.confirmDelete(); })
        Button('保留草稿').id('draft-cancel-delete').width('100%').height(40).enabled(!this.busy)
          .onClick(() => { this.confirmingDelete = false; })
      } else {
        if (this.mode === 'available') {
          Button('恢复草稿').id('draft-restore').width('100%').height(42).enabled(!this.busy)
            .backgroundColor(DRAFT_BLUE).fontColor(Color.White).onClick(() => { this.beginRestore(); })
        }
        if (this.mode === 'available' || this.mode === 'corrupt') {
          Button('删除草稿').id('draft-delete').width('100%').height(40).enabled(!this.busy)
            .onClick(() => { this.askDelete(); })
        }
        if (this.mode === 'error') {
          Button('重新检查').id('draft-retry').width('100%').height(40).enabled(!this.busy)
            .onClick(() => { this.refresh(); })
        }
      }
      Button('稍后').id('draft-later').width('100%').height(40).enabled(!this.busy)
        .backgroundColor(Color.White).fontColor(DRAFT_BLUE).onClick(() => { this.later(); })
    }.width('100%').padding(18).backgroundColor(Color.White).borderRadius(18)
  }
}
