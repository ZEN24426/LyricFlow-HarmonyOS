# 第三方依赖及许可

LyricFlow 项目自身的许可证为 GPL-3.0-only，第三方项目仍依据各自的许可条款使用和分发。本仓库不包含已下载的依赖包或预编译 HAP。

## 163MusicLyrics 匹配规则参考

- 项目：<https://github.com/jitwxs/163MusicLyrics>
- 参考版本：`883e3c2507d4fa8144e531a7e9f8df7636bf53d0` 的 `LocalSongMatcher.cs`。
- 上游署名：Copyright 2017 jitwxs@foxmail.com；上游许可证为 Apache License 2.0，副本见 [LICENSES/163MusicLyrics-Apache-2.0.txt](LICENSES/163MusicLyrics-Apache-2.0.txt)。
- 本项目参考了标签打分、双时长阈值及候选分差规则，以 ArkTS 独立实现；增加版本冲突检查、艺名保护、可解释的推荐原因及显式歌词预览确认。没有引入其 C# 运行时或音乐平台客户端代码。
- 网易云接口通过平台域名直接请求，没有将第三方代理服务作为依赖。应用源码的许可证不授予第三方歌词内容的权利。

## 音频标签处理与测试工具

此源码版本已移除此前的 `@dabing/taglib_harmony` 运行时依赖；音频标签处理由项目内代码及 HarmonyOS 系统接口实现。构建与运行环境由其各自提供方授权；此说明不对以往发布的二进制包作声明。不同格式、标签和设备的兼容性及完整性仍需验证。

`tests` 的开发依赖 TypeScript 5.9.3 仅用于运行自动测试，不会打包进应用。TypeScript 使用 Apache License 2.0，见其[许可证](https://github.com/microsoft/TypeScript/blob/main/LICENSE.txt)。

WMA/ASF 实现独立设计时参考了 Mutagen（GPL-2.0-or-later）及 FFmpeg（LGPL-2.1-or-later）明确许可的公开源码；FFmpeg 仅作为可选外部测试工具，不作为应用运行时依赖。具体修订、来源、参考范围和限制见 [WMA 参考记录](docs/WMA-ASF.md)。
