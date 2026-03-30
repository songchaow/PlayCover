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

### 初步判断

当前给定 IPA 的二进制架构不满足 PlayCover 安装链路要求；至少在执行 Mach-O 转换时，**未找到可用 ARM64 架构**。

### 建议排查

1. 先确认该 IPA 主程序与关键可执行文件是否包含 ARM64 slice
2. 明确当前安装器对 fat binary / thin binary / enterprise 签名包的兼容边界
3. 区分“安装器自身限制”和“该 IPA 本身不兼容”两种结论
4. 如果需要恢复 `QQ飞车` 测试环境，应提供一个确认含 ARM64 架构、可被 PlayCover 接受的 IPA

---

## 补充：与 task 能力联动暴露出的可观测性问题

虽然 RT08 的根因最终通过底层 `tasks/get` 找到了，但普通 MCP tool 使用路径存在两个额外阻碍：

1. `install_ipa` 返回 task ID 后，tool 层没有对应 task 查询工具
2. 调用方必须改走原始 HTTP JSON-RPC，才能看到真实失败原因

这意味着：

- **安装失败并不是最先暴露出来的问题**
- 更早暴露的是“任务结果不易获取”

因此 RT08 实际上与 `02-任务与协议问题.md` 中的 RT05 / RT06 / RT07 强相关。
