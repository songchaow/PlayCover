# R0 基础参考：Replay 入口扫描 — 模块、进程、符号、文件访问

**完成时间**：2026-05-20  
**方法**：V1 静态扫描 + V2 动态观察

---

## 已确认模块（10 个）

`GPUDebugger.ideplugin` / `GPUTools.framework` / `GPUToolsServices.framework` / `GPUToolsShaderProfiler.framework` / `GPUToolsPlatform.framework` / `GPUToolsDesktopFoundation.framework` / `DVTInstrumentsFoundation.framework` / `DVTInstrumentsUtilities.framework` / `GPU.instrdst` / `GPUCounters.instrdst`

---

## 已确认进程（replay 活跃时）

| 进程 | 角色 |
|------|------|
| Xcode | 前端 |
| GPUToolsCompatService | bundle 兼容预处理 |
| GPUToolsAgentService | 设备代理 |
| GPUToolsReplayService.xpc | thin stub（进程隔离） |
| GTLLVMHelper | shader 编译辅助 |

---

## 高价值符号/字符串

- **GPUDebugger**: `com.apple.gputools.MTLReplayer`, `GTErrorKeyGputracePath`, `GPUTraceShaderProfiler*`
- **GPUToolsServices**: `ReplayerLaunch`, `DYCaptureSession._replayerLaunchDictionary`, `DYGuestAppSession._hardwareCountersConfiguration`, `DYDevice.replayerAppIdentifier`
- **GPUToolsShaderProfiler**: `derivedCountersData`, `exportDerivedCounterDataAtPath:`, `DYShaderProfilerProgramInfo`

---

## 文件访问关系

| 服务 | 打开的文件 | 结论 |
|------|-----------|------|
| CompatService | `startup-0-platform`, `store0`, `device-resources-*` | bundle 兼容读取/预处理 |
| ReplayService | `store0`, AGX 驱动, `default.metallib`, `functions.*`/`libraries.*` | 直接消费 replay 数据 + shader 缓存 |

---

## Instruments 对齐

- `GPU.instrdst` → `com.apple.gpu-tracing`（Metal System Trace, Game Performance）
- `GPUCounters.instrdst` → `com.apple.gpu-counters`（metal-gpu-counter-intervals, -profile）
