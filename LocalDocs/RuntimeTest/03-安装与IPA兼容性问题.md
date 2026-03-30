# 安装与 IPA 兼容性问题

## RT08：给定 `QQ飞车` IPA 安装失败，报 `No ARM64 architecture found in fat binary`

### 测试对象

- 目标 app：`QQ飞车`
- bundle：`com.tencent.tmgp.speedmobile`
- IPA 路径：`/Users/songdogwang/Downloads/NSS_Debug_Test_DB_1.55.0.36877_1828878_12136_enterprise_sign_forpay.ipa`

### 前置背景

本轮测试中，`QQ飞车` 已按允许范围完成卸载测试；随后尝试用给定 IPA 重新安装，以验证 PlayCover MCP 的安装链路。

### 现象

安装分别测试了两条路径：

1. `injectPlayTools = true`
2. `injectPlayTools = false`

两条路径最终都未成功恢复安装。

通过底层 `tasks/get` 查询后台任务后，已拿到明确失败原因：

> `MachO conversion failed: No ARM64 architecture found in fat binary`

### 影响

- 给定 IPA 当前无法通过 PlayCover MCP 安装成功
- `QQ飞车` 在本轮测试结束时未能恢复为已安装状态
- 也导致后续无法基于这个 app 继续做更深的 runtime / PlayTools 注入验证

### 过程观察

1. 开启 `injectPlayTools=true` 时，很快失败
2. 关闭 `injectPlayTools=false` 后，任务一度进入 `running` 并推进到 `unzip`
3. 但最终仍未形成成功安装结果
4. 问题根因仍指向 Mach-O / 架构兼容性，而不是单纯的任务调度问题

### 初步判断（历史）

此前一度倾向于认为：当前给定 IPA 的二进制架构不满足 PlayCover 安装链路要求；至少在执行 Mach-O 转换时，**未找到可用 ARM64 架构**。

### 2026-03-30 夜间新增证据

当晚再次通过当前可用的 `playcover` MCP 端点执行 `install_ipa`：

- IPA：`/Users/songdogwang/Downloads/NSS_Debug_Test_DB_1.55.0.36877_1828878_12136_enterprise_sign_forpay.ipa`
- 返回：`task-1`
- `get_task(task-1)` 最终状态：`failed`
- 错误码：`-32015`
- 错误信息：`MachO conversion failed: No ARM64 architecture found in fat binary`

但同一轮测试中，用户明确反馈：**相同 IPA 通过 PlayCover 图形化界面安装是可以成功的**。

这意味着此前“该 IPA 本身不兼容 / 不含 ARM64”的结论已经**不足以单独成立**。当前更合理的判断是：

1. **MCP 安装路径与 GUI 安装路径存在行为差异**
2. 问题可能位于 `PlayCoverMCP/HostServices/Install/InstallerService.swift` 与 GUI 原生 `PlayCover/AppInstaller/Installer.swift` 的预检 / Mach-O 转换 / 注入分支差异
3. 给定 IPA 不能再被简单视为“稳定负例样本”

### 当前结论

RT08 当前应视为：**MCP 安装链路与 GUI 安装链路不一致**。在未完成两条路径对比前，不能再把该问题简单归类为“IPA 本身无 ARM64 架构”。

### 建议排查

1. 对比 `PlayCoverMCP` 与 GUI 原生安装流程是否走了不同的 Mach-O 转换 / 预检逻辑
2. 先确认 GUI 成功安装时是否对同一 IPA 做了额外容错、跳过某些预检，或使用了不同可执行文件定位规则
3. 抓取 GUI 成功安装时的关键日志，与 MCP `task-1` 的失败日志并排比较
4. 在确认两条安装路径语义前，不再把该 IPA 作为“必然无 ARM64 的稳定负例”

---

## 补充：与 task 能力联动暴露出的可观测性问题

虽然 RT08 的根因最终通过底层 `tasks/get` 找到了，但普通 MCP tool 使用路径存在两个额外阻碍：

1. `install_ipa` 返回 task ID 后，tool 层没有对应 task 查询工具
2. 调用方必须改走原始 HTTP JSON-RPC，才能看到真实失败原因

这意味着：

- **安装失败并不是最先暴露出来的问题**
- 更早暴露的是“任务结果不易获取”

因此 RT08 实际上与 `02-任务与协议问题.md` 中的 RT05 / RT06 / RT07 强相关。
