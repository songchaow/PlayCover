# R3 技术参考：Headless Replay 完整验证

**完成时间**：2026-05-20  
**方法**：V3 最小样本测试 + V4 动态验证 + 反汇编分析  
**结论**：✅ Headless replay 完整成功；CLI 路径仅做 replay 验证，不产出数据

---

## 1. 核心结论

| 阶段 | 结论 |
|------|------|
| R3.1 | dlopen+dlsym 可行，无 SIP/entitlement 限制，APR bootstrap 已解决 |
| R3.2 | options +0x28/+0x30 必须非 NULL，填入后 GTMTLReplay_CLI 返回 0 |
| R3.3 | completionCallback 为 dead code，profilingFlags 不被访问，CLI 仅做 replay 验证 |

---

## 2. APR Bootstrap 方案

### 问题
`GTMTLReplay_CLI` 内部第一步调用 `apr_pool_create_ex()`，依赖已初始化的全局 pool（正常由 GPUToolsReplayService.xpc 的 main() 初始化）。

### 解决方案
通过导出符号 `GT_ENV` 定位全局 pool 指针位置（GT_ENV - 0x30），手动构造：
1. **allocator 结构体**（0xC8 bytes）：max_index=20, max_free_index=20, 其余置零
2. **fake global pool**（0x80 bytes）：`pool[0x00] = pool[0x30] = allocator`
3. 将 global pool 指针写入框架 BSS 段：`*(void**)(GT_ENV - 0x30) = pool`

### 关键偏移量（macOS 26.4.1, GPUToolsReplay 314.12）

| 全局变量 | 位置 | 含义 |
|---------|------|------|
| global_pool_ptr | `&GT_ENV - 0x30` | APR 全局 pool 指针 |
| GT_ENV | 导出符号 | 框架全局环境变量 |
| g_runningInCI | 导出符号 | CI 模式标志（仅影响日志格式） |

---

## 3. Options 结构体完整布局

### 已确认字段（R3.1 + R3.2 验证）

| 偏移 | 大小 | 名称 | 值 | 状态 |
|------|------|------|------|------|
| +0x08 | ptr | device? | NULL | 可选（使用默认 device） |
| +0x18 | int32 | loopCount | 1 | ✅ 必填 |
| +0x25 | uint8 | waitForCompletion | 0 | 可选 |
| +0x28 | ptr | errorLogPath | `/dev/null` | ✅ 必填（非 NULL） |
| +0x30 | ptr | saveDestination | `/tmp/replay_output` | ✅ 必填（非 NULL） |
| +0xa4 | int32 | gpuStateLevel | 0 | 可选（CLI 中不被访问） |
| +0xb8 | uint32 | profilingFlags | 0 | 可选（CLI 中不被访问） |
| +0xba | uint8 | optimizeRestoresFlags | 0 | 可选 |
| +0x318 | ptr | 子对象指针 | NULL | 可选（NULL 时跳过相关逻辑） |

### 真实大小
- 实际结构体 **≥ 0x320 字节**（函数访问 options[0x318]）
- R1.2 估计的 "~0xC0" 是低估（基于部分分析）
- 当 options[0x318] = NULL 时函数通过 NULL check 安全跳过

---

## 4. CLI 路径能力边界（R3.3 反汇编确认）

### 方法
在运行时通过 dlsym 获取函数地址，直接扫描 ARM64 机器码（函数体 45484 字节，~11000 条指令）。

### Callback (x2 → x20) 生命周期
```
入口: MOV x20, x2 (+40) — callback 保存
使用: MOV x0, x20 → BL objc_retain/release (×9)
覆盖: LDR x20, [x8, #3920] (+4104) — x20 被重用
结论: callback 只被 retain/release，从未被 BLR 调用
```

### Options 实际访问模式
函数在 +2508 处将 x23 (options) 重定向到 options[0x318] 子对象，后续仅读取子对象偏移 +0x00/+0x04/+0x08/+0x0C/+0x30。

**关键结论**：options +0xa4 (gpuStateLevel) 和 +0xb8 (profilingFlags) **在此函数中从不被访问**。

### 能力对比表

| 能力 | CLI 路径 | XPC 路径 |
|------|---------|---------|
| 基础 replay 执行 | ✅ | ✅ |
| 返回成功/失败码 | ✅ | ✅ |
| completionCallback | ❌ (dead code) | N/A |
| Profiling 输出 | ❌ (不读 profilingFlags) | ✅ |
| Fetch 数据 | ❌ | ✅ |
| Shader 替换 | ❌ | ✅ |

### 策略影响
- CLI 路径价值：**replay 健康检查**（确认数据源完整、Metal pipeline 可编译）
- 数据获取需通过：① Harvester API ② GTMTLReplayHost_* ③ XPC proxy

---

## 5. 验证日志（R3.2 成功输出）

```
[INFO] .gputrace path: .../capture_20260518_110050.gputrace
[INFO] Metal device: Apple M4 Pro
[INFO] dlopen GPUToolsReplay success
[APR-INIT] GT_ENV at: 0x2a57843a8
[APR-INIT] Global pool pointer at: 0x2a5784378
[APR-INIT] *global_pool_ptr = 0x105347c30
[INFO] dlsym GTMTLReplay_CLI success: 0x257f1f76c
[INFO] Options fields set:
  +0x18 loopCount    = 1
  +0x28 errorLogPath = /dev/null
  +0x30 saveDest     = /tmp/replay_output
[INFO] Calling GTMTLReplay_CLI(...)
[RESULT] GTMTLReplay_CLI returned: 0
[SUCCESS] Headless replay completed successfully!
```

---

## 6. 探针使用

```bash
cd Scripts/
clang -framework Foundation -framework Metal -ldl -o replay_probe replay_probe.m
./replay_probe /path/to/real.gputrace
```
