# 两种导出方法对比分析

## 1. 单曲导出 `exportAudio` (行 350-436) — ✅ 完美运行

### 完整代码

```typescript
private async exportAudio(): Promise<void> {
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
  const context = this.ctx();
  let exportPath: string = '';
  let savedUri: string | undefined = undefined;
  try {
    // 1. 创建沙箱工作副本（音频已预先导入沙箱）
    exportPath = await AudioMetadataService.makeWorkingCopy(
      this.audioWorkingPath, context.filesDir, this.audioName);

    // 2. 歌词转换（带空名称保护）
    let embeddedLyrics: string = this.lyricText;
    let lyricConversionWarning: string = '';
    const lowerLyricSource: string = this.lyricSourceName.toLowerCase();
    if (lowerLyricSource.length > 0 && !lowerLyricSource.endsWith('.lrc') && !lowerLyricSource.endsWith('.txt')) {
      const lyricDocument: LyricDocument = await parseLyricAsync(this.lyricText, this.lyricSourceName);
      const convertedLyrics = await convertToLrcAsync(lyricDocument);
      embeddedLyrics = convertedLyrics.text;
      if (convertedLyrics.warnings.length > 0)
        lyricConversionWarning = convertedLyrics.warnings.join('；');
    }

    // 3. 构建完整 AudioMetadataWriter
    const writer: AudioMetadataWriter = {
      title: this.songTitle,
      artist: this.artist,
      album: this.album,
      genre: this.genre,
      albumArtist: this.albumArtist,
      composer: this.composer,
      comment: this.comment,
      grouping: this.grouping,
      isrc: this.isrc,
      copyright: this.copyright,
      lyrics: embeddedLyrics
    };

    // 4. 数字字段验证
    if (this.year.trim().length > 0) {
      const yearValue: number = Number(this.year);
      if (!Number.isFinite(yearValue) || yearValue < 0 || yearValue > 9999)
        throw new Error('发行年份必须是 0 到 9999 的数字');
      writer.year = yearValue;
    }
    if (this.track.trim().length > 0) {
      const trackValue: number = Number(this.track);
      if (!Number.isInteger(trackValue) || trackValue < 0 || trackValue > 9999)
        throw new Error('曲目序号必须是 0 到 9999 的整数');
      writer.track = trackValue;
    }
    // disc, discTotal, trackTotal, bpm 验证
    const numericFields: NumericTagField[] = [
      { value: this.disc, label: '碟片序号', key: 'disc' },
      { value: this.discTotal, label: '碟片总数', key: 'discTotal' },
      { value: this.trackTotal, label: '专辑总曲目数', key: 'trackTotal' },
      { value: this.bpm, label: 'BPM', key: 'bpm' }
    ];
    for (let i: number = 0; i < numericFields.length; i++) {
      if (numericFields[i].value.trim().length === 0) continue;
      const numericValue: number = Number(numericFields[i].value);
      if (!Number.isInteger(numericValue) || numericValue < 0 || numericValue > 99999)
        throw new Error(numericFields[i].label + '必须是 0 到 99999 的整数');
      if (numericFields[i].key === 'disc') writer.disc = numericValue;
      if (numericFields[i].key === 'discTotal') writer.discTotal = numericValue;
      if (numericFields[i].key === 'trackTotal') writer.trackTotal = numericValue;
      if (numericFields[i].key === 'bpm') writer.bpm = numericValue;
    }

    // 5. 封面图片
    if (this.coverPixelMap !== null) writer.coverImage = this.coverPixelMap;

    // 6. 写入完整元数据
    await AudioMetadataService.write(exportPath, writer);

    // 7. 生成输出文件名并导出
    const name: string = AudioMetadataService.safeOutputName(this.audioName, this.songTitle);
    let actualName: string = name;
    const saved = await ExportService.saveAudioToDownload(context, name, exportPath);
    if (saved !== undefined) {
      savedUri = saved.uri;
      actualName = saved.name;
    }

    // 8. 双层 saved 检查
    if (savedUri === undefined) {
      this.notify('导出失败；无法获取下载目录，原始音频未修改');
    } else {
      this.notify('新音频已导出；原始音频未修改' +
        (lyricConversionWarning.length > 0 ? '。转换提示：' + lyricConversionWarning : ''));
    }
  } catch (error) {
    this.notify('音频导出失败：' + (this.describeError(error)) + '。原始音频未修改');
  } finally {
    // 9. 清理
    if (exportPath.length > 0) await AudioMetadataService.removeWorkingFile(exportPath);
    this.busy = false;
  }
}
```

---

## 2. 文件夹匹配导出 `exportConfirmedMatches` (行 575-627) — ⚠️ 需重写

### 完整代码

```typescript
private async exportConfirmedMatches(): Promise<void> {
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
      try {
        // 1. URI 检查
        if (item.audioUri === undefined || item.lyricUri === undefined)
          throw new Error('缺少音频或歌词授权 URI');

        // 2. 从 URI 导入沙箱
        const working = await AudioMetadataService.importToSandbox(
          item.audioUri, item.audioName, context.filesDir);
        sourceWorkingPath = working.workingPath;

        // 3. 读取歌词文本
        const lyricText: string = await FileSelectionService.readUtf8Text(item.lyricUri);

        // 4. 歌词转换（❌ 缺少空名称保护）
        let embeddedLyrics: string = lyricText;
        if (!item.lyricName.toLowerCase().endsWith('.lrc') &&
            !item.lyricName.toLowerCase().endsWith('.txt')) {
          const document: LyricDocument = await parseLyricAsync(lyricText, item.lyricName);
          const converted = await convertToLrcAsync(document);
          embeddedLyrics = converted.text;
          if (converted.warnings.length > 0)
            failureNotes.push(item.audioName + '：' + converted.warnings.join('；'));
        }

        // 5. 创建工作副本
        exportPath = await AudioMetadataService.makeWorkingCopy(
          sourceWorkingPath, context.filesDir, item.audioName);

        // ❌ 6. 仅写入 { lyrics }，不写入其他元数据
        await AudioMetadataService.write(exportPath, { lyrics: embeddedLyrics });

        // 7. 输出文件名（使用原始 metadata.title）
        const baseName: string = AudioMetadataService.safeOutputName(
          item.audioName, working.metadata.title || item.audioTitle || item.audioName);

        // 8. 导出（❌ 单层 saved 检查）
        const saved = await ExportService.saveAudioToDownload(context, baseName, exportPath);
        if (saved === undefined) throw new Error('无法获取下载目录');
        savedUri = saved.uri;
        succeeded++;

      } catch (error) {
        failed++;
        failureNotes.push(item.audioName + '：' + (this.describeError(error)));
      } finally {
        // 9. 清理两个文件
        if (sourceWorkingPath.length > 0) await AudioMetadataService.removeWorkingFile(sourceWorkingPath);
        if (exportPath.length > 0) await AudioMetadataService.removeWorkingFile(exportPath);
      }
    }
    this.notify('批量导出完成：成功 ' + succeeded + ' 项，失败 ' + failed +
      ' 项。原始文件未修改。' +
      (failureNotes.length > 0 ? ' 详情：' + failureNotes.slice(0, 8).join('；') : ''));
  } catch (error) {
    this.notify('批量导出中止：' + (this.describeError(error)));
  } finally {
    this.busy = false;
  }
}
```

---

## 3. 差异对比矩阵

| 特性 | 单曲 `exportAudio` | 文件夹 `exportConfirmedMatches` |
|------|:---:|:---:|
| **前置检查** | `pendingCoverImage` + `audioWorkingPath` | 仅检查候选数 |
| **音频来源** | 已预先导入 `this.audioWorkingPath` | 实时 `importToSandbox(uri)` |
| **副本数量** | 1次 `makeWorkingCopy` | 2次（importToSandbox + makeWorkingCopy）|
| **歌词转换空名称保护** | ✅ `lowerLyricSource.length > 0` | ❌ 缺失 |
| **写入元数据** | 全量字段（title/artist/album/...）+ coverImage | ❌ 仅 `{ lyrics }` |
| **数字字段验证** | ✅ year/track/disc/discTotal/trackTotal/bpm | ❌ 不适用 |
| **产出文件名** | `safeOutputName(audioName, songTitle)` | `safeOutputName(audioName, metadata.title)` |
| **saved 检查** | ✅ 双层：`saved !== undefined` → `savedUri === undefined` | ❌ 单层：仅 `saved === undefined` |
| **错误处理** | 整体 try，整体失败 | ✅ 逐项 try，逐项继续 + 统计 |
| **失败反馈** | 无统计 | ✅ 成功/失败计数 + 前8条详情 |
| **清理文件数** | 1个（exportPath） | 2个（sourceWorkingPath + exportPath）|
| **`busy` 重置** | finally | finally |

---

## 4. 关键差异详细说明

### 4.1 歌词转换保护 ⚠️

**单曲（正确）：**
```typescript
const lowerLyricSource: string = this.lyricSourceName.toLowerCase();
if (lowerLyricSource.length > 0 && !lowerLyricSource.endsWith('.lrc') && !lowerLyricSource.endsWith('.txt'))
```

**文件夹（问题）：**
```typescript
if (!item.lyricName.toLowerCase().endsWith('.lrc') && !item.lyricName.toLowerCase().endsWith('.txt'))
```
> 如果 `item.lyricName` 为空字符串，`.toLowerCase()` 不会报错，但逻辑上对空字符串调用 `endsWith` 是冗余操作。应添加 `.length > 0` 保护。

### 4.2 写入元数据范围

- **单曲导出**：写入所有用户编辑的元数据字段 + 封面 → 覆盖原有文件的所有标签
- **文件夹导出**：仅写入 `{ lyrics: embeddedLyrics }` → 只嵌入歌词，保留原有元数据
  - 这在功能上是合理的（批量嵌入歌词不改其他标签），但结构上与单曲导出不一致

### 4.3 saved 检查层级

**单曲（正确）：**
```typescript
if (saved !== undefined) savedUri = saved.uri;  // 第一层检查
if (savedUri === undefined) {                    // 第二层检查
  this.notify('导出失败...');
} else {
  this.notify('新音频已导出...');
}
```

**文件夹（问题）：**
```typescript
if (saved === undefined) throw new Error('无法获取下载目录');
savedUri = saved.uri;
```
> 两者都能工作，但单曲的双层检查更稳健：即使 `saved` 对象存在但 `uri` 为 undefined 也能正确处理。

---

## 5. 重写建议

| # | 改动项 | 说明 |
|---|--------|------|
| 1 | 添加歌词转换空名称保护 | 对齐单曲导出的 `lowerLyricSource.length > 0` 模式 |
| 2 | 统一 `saved` 检查方式 | 使用 `saved !== undefined` + `savedUri === undefined` 双层检查 |
| 3 | 保持 `{ lyrics }` 写入设计 | 文件夹匹配的目的是嵌入歌词而非修改其他元数据，这是合理的 |
| 4 | 保持批量处理框架 | for 循环、逐项 try-catch、成功/失败统计 |
| 5 | 保持双层副本清理 | importToSandbox + makeWorkingCopy，finally 中清理两个文件 |
