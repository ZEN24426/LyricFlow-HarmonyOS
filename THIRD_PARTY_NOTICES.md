# 第三方依赖及许可

LyricFlow 项目自身的许可证为 GPL-3.0-only，第三方项目仍依据各自的许可条款使用和分发。本仓库不包含已下载的依赖包或预编译 HAP。

## TagLib Harmony

- 依赖：`@dabing/taglib_harmony` 1.1.2，由 OHPM 下载。
- 项目及源码：<https://gitcode.com/dabing518/taglib_harmony>
- 该适配包的包元数据声明 Apache License 2.0：<https://www.apache.org/licenses/LICENSE-2.0>

## TagLib

TagLib Harmony 的说明称其封装了 TagLib；依赖包文档对其版本有 2.3 和 2.3.1 两种表述，准确版本及完整对应源码仍需在分发二进制之前核实。TagLib 本身的许可与适配包的声明不同：上游采用 LGPL 2.1 或 MPL 1.1 双许可，详见其源码与许可证：

- 源码：<https://github.com/taglib/taglib>
- LGPL 2.1：<https://github.com/taglib/taglib/blob/master/COPYING.LGPL>
- MPL 1.1：<https://github.com/taglib/taglib/blob/master/COPYING.MPL>

如果分发含原生库的安装包，发布者需要核实实际依赖版本、对应源代码、链接方式以及适用的许可和通知义务；此文件不表示这些二进制分发检查已经完成。
