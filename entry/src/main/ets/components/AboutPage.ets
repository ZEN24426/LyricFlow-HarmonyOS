import { bundleManager, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
const SOURCE_URL: string = 'https://github.com/ZEN24426/LyricFlow-HarmonyOS';
@Component
export struct AboutPage {
 onClose: () => void = (): void => {};
 @State version: string = '版本信息暂不可用';
 @State document: string = '';
 @State documentTitle: string = '';
 @State message: string = '';
 @State loading: boolean = false;
 private active: boolean = false;
 private generation: number = 0;
 aboutToAppear(): void {
  this.active = true;
  try { const info = bundleManager.getBundleInfoForSelfSync(0); this.version = info.versionName + ' (' + info.versionCode.toString() + ')'; }
  catch (_) { this.message = '无法读取应用版本信息。'; }
 }
 aboutToDisappear(): void { this.active = false; this.generation++; }
 private async openDocument(file: string, title: string): Promise<void> {
  const ticket: number = ++this.generation;
  this.loading = true; this.message = '';
  try {
   const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
   const bytes = await ctx.resourceManager.getRawFileContent(file);
   if (!this.active || ticket !== this.generation) return;
   this.document = util.TextDecoder.create('utf-8').decodeWithStream(bytes);
   this.documentTitle = title;
  } catch (_) { if (this.active && ticket === this.generation) this.message = '离线文本读取失败，请重试。'; }
  finally { if (this.active && ticket === this.generation) this.loading = false; }
 }
 private async openSource(): Promise<void> {
  const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
  try { await ctx.openLink(SOURCE_URL); }
  catch (_) { if (this.active) this.message = '未能打开浏览器，可复制下方网址。'; }
 }
 build() {
  Column({ space: 12 }) {
   Row() {
    Text(this.documentTitle || '关于 LyricFlow').fontSize(21).fontWeight(FontWeight.Bold).layoutWeight(1)
    Button(this.documentTitle.length > 0 ? '返回' : '关闭').id('about-close').onClick(() => {
     if (this.documentTitle.length > 0) { this.document = ''; this.documentTitle = ''; } else this.onClose();
    })
   }.width('100%')
   if (this.documentTitle.length > 0) {
    Scroll() { Text(this.document).fontSize(13).copyOption(CopyOptions.InApp).width('100%') }
      .layoutWeight(1).width('100%').align(Alignment.Top)
   } else {
    Text('LyricFlow').fontSize(26).fontWeight(FontWeight.Bold)
    Text(this.version).id('about-version').fontSize(14)
    Text('轻量的本地音频信息与歌词编辑工具').fontSize(14)
    Button('GitHub 源代码').id('about-source').width('100%').onClick(() => this.openSource())
    Text(SOURCE_URL).fontSize(12).copyOption(CopyOptions.InApp).width('100%')
    Text('点击上方按钮才会打开外部浏览器。许可证与声明可离线查看。').fontSize(12).width('100%')
    Button('GPL v3.0 完整许可证').id('about-gpl').width('100%').enabled(!this.loading)
      .onClick(() => this.openDocument('gpl-3.0.txt', 'GNU GPL v3.0'))
    Button('第三方声明').id('about-notices').width('100%').enabled(!this.loading)
      .onClick(() => this.openDocument('third-party-notices.txt', '第三方声明'))
    Button('163MusicLyrics · Apache 2.0').width('100%').enabled(!this.loading)
      .onClick(() => this.openDocument('apache-2.0-163musiclyrics.txt', 'Apache License 2.0'))
    Blank()
   }
   if (this.message.length > 0) { Text(this.message).fontSize(12).width('100%') }
  }.padding(20).width('92%').height('86%').backgroundColor(Color.White).borderRadius(20)
 }
}
