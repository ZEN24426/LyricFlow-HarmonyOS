# 第三方依赖及许可

LyricFlow 项目自身源码和自有资源按 GPL-3.0-only 发布，完整协议见 LICENSE。

本源码版本已移除此前的 @dabing/taglib_harmony 运行时依赖；音频标签处理由项目内代码及 HarmonyOS 系统接口实现。构建与运行环境由其各自提供方授权。本文件不对此前发布的二进制包作声明。

此替换版目前仍需完成不同格式、标签和设备的兼容性与完整性验证。

## 测试工具

`tests` 的开发依赖 TypeScript 5.9.3 仅用于运行自动测试，不会打包进应用。TypeScript 使用 Apache License 2.0，见 <https://github.com/microsoft/TypeScript/blob/main/LICENSE.txt>。
