# R0 基础参考：Replay 入口扫描 — 模块与进程

**状态**：✅ 完成（基线建立）  
**后续覆盖**：详细 API/符号在 R1.1 中完整记录

---

## 已确认模块（10 个）

`GPUDebugger.ideplugin` / `GPUTools.framework` / `GPUToolsServices.framework` / `GPUToolsShaderProfiler.framework` / `GPUToolsPlatform.framework` / `GPUToolsDesktopFoundation.framework` / `DVTInstrumentsFoundation.framework` / `DVTInstrumentsUtilities.framework` / `GPU.instrdst` / `GPUCounters.instrdst`

## 已确认进程（replay 活跃时）

| 进程 | 角色 |
|------|------|
| Xcode | 前端 |
| GPUToolsCompatService | bundle 兼容预处理 |
| GPUToolsAgentService | 设备代理 |
| GPUToolsReplayService.xpc | thin stub（进程隔离） |
| GTLLVMHelper | shader 编译辅助 |
