# WMA / ASF 受限副本编辑

此实现只接受经过严格结构检查的一部分单音轨 WMA/ASF，不代表一般 WMA 或受保护文件兼容。它读取有上限的 ASF 头（最多 256 KiB，整个文件最多 8 GiB），对已存在的顶层全零预留空间内的元数据进行编辑，以有界块复制并逐字节复核头后数据。无预留空间、空间不足、未知或受保护结构、索引/尾随对象、含冲突或作用域不明确的字段均可能拒绝。即使通过结构及系统媒体属性检查，也不构成完整音频比特流验证。系统提取器的时长、声道及采样率必须有效，并与支持的流头交叉核验。

支持标题、歌手、专辑、流派、评论、歌词、专辑歌手、作曲、分组、ISRC 和版权文本；年份和 BPM 仅支持 1–9999 的整数。未提供字段保持不变；空文本表示显式空值。曲目、曲目总数、碟片和碟片总数的修改，以及数值清空，当前明确拒绝；不变的已有值保留。重复字段、别名、非文本类型或其他语义冲突无法安全解释时拒绝。未知且不冲突的受支持位置的记录按原始字节保留。

封面仅对可验证的 PNG 路径进行受限处理，现有封面替换要求唯一、无描述的 type-3 前封面；其他角色、描述、多个封面或不受支持的作用域拒绝。选中的 PixelMap 仅接受有界非 HDR RGBA/BGRA，明确透明度和系统报告的 sRGB 或 Display-P3，并在编码后重新解码逐像素比对。`CUSTOM`（设备返回的值 5）及未知色域继续拒绝：名称、白点和 gamma 不足以证明完整色彩配置相同。原有封面如果无法比较，即使只改文字也可能拒绝。该检查不证明任意原始 ICC 或各播放器色彩显示一致；ImageKit 原生内存峰值及设备实际图片转换仍未测量。

导出仅先处理应用私有工作副本，核验后替换该工作副本，用户原文件不直接改写。私有暂存目录不是针对同应用恶意并发的保证；最后一次检查与替换之间仍有并发窗口，进程中断后的孤儿恢复和公共导出目标的无覆盖竞态未解决。操作可能需要多次完整文件扫描，尚无真实设备峰值内存或中断恢复证据。

## 参考和许可记录

独立设计的实现曾查阅以下明确许可的公开源码作为格式事实参考；这不是严格隔离的 clean-room 开发，也不声称法律上已完成衍生性判断。没有有意复制来源代码，若后续发现借用或改编，须补齐适用版权及许可证义务。项目按仓库 GPL-3.0-only 发布；FFmpeg 仅用于外部测试，不作为运行时依赖。

- Mutagen：Joe Wreschnig 和 Lukas Lalinsky，GPL-2.0-or-later；修订 `48b3463d0ed70ba2b797ac9cc83983066ecf076a` 的 [ASF 对象](https://github.com/quodlibet/mutagen/blob/48b3463d0ed70ba2b797ac9cc83983066ecf076a/mutagen/asf/_objects.py)及[属性编码](https://github.com/quodlibet/mutagen/blob/48b3463d0ed70ba2b797ac9cc83983066ecf076a/mutagen/asf/_attrs.py)。
- FFmpeg：Fabrice Bellard 等，LGPL-2.1-or-later；修订 `a5ed44135fa4d2b205d93795da32e449055faf0b` 的 [ASF 解复用](https://github.com/FFmpeg/FFmpeg/blob/a5ed44135fa4d2b205d93795da32e449055faf0b/libavformat/asfdec_f.c)和[标签映射](https://github.com/FFmpeg/FFmpeg/blob/a5ed44135fa4d2b205d93795da32e449055faf0b/libavformat/asf.c)。
- [Microsoft Learn 元数据属性映射](https://learn.microsoft.com/en-us/windows/win32/medfound/metadata-properties-for-media-files)仅作为属性名称的公开文档参考，文档权利不同于源码许可；未使用带源码分发限制的 ASF 规范。

## 验证范围

旧版去依赖修复在独立调试应用及一台 nova 14 Ultra 上，使用合成且带预留空间的 WMA 验证导入、修改标题后导出并重选读回，以及修改歌词后导出并读回。所选合成 PNG 报告 CUSTOM 色域并安全拒绝；封面写入没有真机成功证据。合入云端功能后的本开发版还需独立构建和真机回归。模拟 I/O、MediaKit 和 ImageKit 测试不能替代系统实测；FFmpeg 测试不能证明 HarmonyOS 解码器行为。

## 可复现验证

在 `tests` 目录运行 `npm ci` 后，按 [测试说明](../tests/asf/README.md) 设置 FFmpeg 和 FFprobe 路径，再运行 `npm run test:asf`。该脚本在系统临时目录生成合成样本并运行 ASF 测试；异常中断可能留下临时目录。其他格式及云端测试的执行命令以 `tests/package.json` 为准。ArkTS 编译在仓库根目录运行 `devecocli build --modules entry --build-mode debug`。仓库未配置签名，构建结果不能直接作为已签名安装包。
