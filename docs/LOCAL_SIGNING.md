# 本机签名配置

`release/V0.325-preflight` 的提交 `0285dfc` 移除了工程级 `build-profile.json5` 中的个人签名材料和对应引用。仓库里的默认配置因此不能直接生成可安装的签名 HAP；移除凭据不等于已完成签名迁移。

## 在 DevEco 恢复调试签名

1. 打开当前工程，连接目标设备，或按 DevEco 支持的方式在开发者平台登记调试设备。
2. 进入 **File > Project Structure > Project > Signing Configs**，选择 **Automatically generate signature**，按提示登录并完成签名配置。新版界面也可能在 Project/Product 下展示签名设置。
3. 在本机的工程级 `build-profile.json5` 中确认两项内容：
   - `app.signingConfigs` 中存在 DevEco 生成的有效方案，材料路径均指向本机可用的证书、Profile 和密钥库。
   - `app.products` 中名称为 `default` 的 product，其 `signingConfig` 与上述方案的 `name` 完全一致。方案内容和引用缺一不可。
4. 清理并重新构建，使用构建输出中的 **signed HAP** 安装，不要安装 `unsigned` 包。若仍提示 `no signature file`，先确认实际选择的安装文件和构建日志里的签名任务结果。

已有可用签名时，可在本机复用匹配当前包名和目标设备的材料，或从仓库之外的本机备份合并签名方案及 product 引用；不要直接用旧工程配置覆盖整个文件，以免退回 SDK 或构建选项。

## 本机配置与代码同步

- 证书、Profile、密钥库以及包含口令的配置只保存在本机；不要发到聊天、Issue 或 Git 仓库。
- 根目录 `build-profile.json5` 当前仍是已跟踪文件，`.gitignore` 中的证书规则不会阻止这个文件的签名字段被提交。提交源代码时检查暂存差异，不要暂存包含个人签名的修改。
- 在会重置构建配置的拉取、切分支或 CodeGenie 同步操作前，先将有效的本机签名配置备份到仓库之外。同步后按需只恢复签名方案及其引用，再重新构建。

## 发布验证

自动调试签名用于开发调试。上架或其他正式分发须使用该渠道要求的发布证书和 Profile，确认与应用包名及分发方式匹配，并在签名后的 Release 包上执行功能回归。签名成功和可安装本身不能替代发布验证。

参考：[华为官方自动签名文档](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto)、[工程级 build-profile.json5 配置](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-hmos-hvigor-build-profile-app)。
