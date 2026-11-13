# LyricFlow WRITE_AUDIO 原地写入实验

> 历史资料：本文的权限、能力和测试状态可能已经过时。当前实现及发布限制请以根目录 README.md 和 RELEASE_CHECKLIST.md 为准。

> 历史实验记录：当前直写实现已改用 DocumentViewPicker 临时授权，不再声明或申请 `WRITE_AUDIO`。请以 [当前架构](ARCHITECTURE_1.799.325.md) 为准。

> 此文记录父分支 `experiment/acl-write-audio` 的最早单歌词实验。**`1.799.325` 当前实现已升级为统一标签写入（歌名、封面、歌词等），请优先阅读 [最新架构文档](ARCHITECTURE_1.799.325.md)。**

> 分支：`experiment/acl-write-audio`（基于 `V0.325`）。
> 仅作为 HarmonyOS 7 / API 26 的技术验证，不可视为已获得发布授权或通过真机测试。

## 为什么做这个实验

稳定版流程是 `DocumentViewPicker.select()` → 只读导入应用沙箱 → `@dabing/taglib_harmony` 写入沙箱副本 → `DocumentViewPicker.save(DOWNLOAD)` 导出新文件。源文件不动。

本分支单独研究 `ohos.permission.WRITE_AUDIO` 是否让 TagLib **直接修改已有的用户公共目录音频文件**。该权限为 `system_basic` + `user_grant`，且属受限开放权限。ACL 声明不等于授权；调试签名、AGC Profile 和运行时用户授权是三个不同环节。正式上架必须符合华为规定的申请场景。官方通常推荐非克隆、备份或同步场景使用 AudioPicker。

- 官方权限列表：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/restricted-permissions
- 官方申请指引：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/declare-permissions-in-acl
- 官方 Picker API：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-picker

## 已修改代码（尚未真机验证）

1. `entry/src/main/module.json5` 声明 `ohos.permission.WRITE_AUDIO`。
2. `DirectAudioWriteService.ets` 请求用户授权、探测 Picker URI 的 `READ_WRITE` 打开、测试 TagLib 原路径读取。
3. 编辑页面增加两个明确标注为实验的按钮：“权限及可写性检测”和“直接写回源文件”。
4. 写入仅限单曲 `MP3` / `FLAC` 的**内嵌歌词**，不动歌曲标题、封面等其他字段，也不修改文件夹匹配/批量流程。
5. 写入前重新从选中的原始 URI 完整备份至应用私有空间，检查备份大小与可解析性；必须经过确认弹框才尝试 TagLib 原路径写入。
6. 写入后回读标签并核对歌词；出错会尽力从备份恢复原始 URI。无论成功还是失败，备份均保留在应用私有目录，以供复核。

**风险边界：** 文件系统、权限或原生 TagLib 的限制可能导致直接写入失败。验证前不能保证崩溃/断电后完整恢复；因此只能用测试音频，不得使用唯一的原始歌曲。恢复失败时请停止重试，保留私有目录备份。卸载应用可能会删除沙箱内备份。

## DevEco Studio 签名配置

需要一个具备该受限 ACL 的合法调试 Profile，不能把个人 `.p12`、`.p7b`、签名路径等提交到仓库。直接向 `module.json5` 添加权限本身不保证 App 可以安装，或系统会授予权限。请按照最新 AGC 和 DevEco Studio 的受限权限申请流程配置调试证书并申请权限；如当前设备/账号不能获批，实验到此停止，稳定副本导出仍能使用。

## 测试顺序

1. 重新用测试设备可用的签名构建，先确认安装不报 ACL/签名错误。
2. 通过界面选择**专门复制的** MP3 测试歌，在设置中确保备份空间足够。
3. 点击“权限及可写性检测”；记录权限弹窗、授权结果、`READ_WRITE` 可用性与原路径 TagLib 读取结果。该操作不写入文件。
4. 填入短 LRC 歌词并点击“直接写回源文件”，阅读二次确认；让应用创建完整备份后尝试实际修改。
5. 关闭应用，用系统音乐应用播放**原路径**文件，重新导入检查歌词。确认无损坏，并记录是否真正修改了原文件（而不是新副本）。
6. 再测试拒绝授权、只读目录、权限撤销、非 MP3/FLAC、写入失败/恢复等分支。
7. 若希望正式发布，需要先验证权限申请业务场景是否获得 AGC 认可。实验成功并不代表符合应用市场审核条件。

## 与普通 Picker 的对照实验

Picker 选择的 URI 可能自带针对该 URI 的临时读写访问能力，这与全局 `WRITE_AUDIO` ACL 不同；本实验特意把 `READ_WRITE` 的 URI 探测与 TagLib 的**原始路径写入**分开。因此授权成功、fd 可读写都**不能直接证明**第三方原生 TagLib 可按路径写入。

后续可以在另一个无 ACL 的对照实验里检查 Picker URI 的临时读写权限及 TagLib 是否支持传入 fd，可能是更符合正式上架条件的方式。

## 未做的事情

- 未在当前环境运行 HarmonyOS 7 / API 26 编译、设备安装或真机写入测试。
- 未添加本地/个人签名材料；未更改 `main`、`V0.325` 或 `release/V0.325-preflight`。
- 未申请或宣称已获得 AGC 受限权限审批，也未启用任意路径写入。

