## Render Capture：任务 Dashboard

### 一、文档目的

每个 agent 的**统一入口**。先读它，再开始工作。主文档保持简洁，详细过程下沉到子文档。

---

### 二、最终目标

> **让原神成功执行 `capture_metal_frame`，生成非空 `.gputrace` 文件。**

QQ飞车截帧已于 2026-03-31 完全打通（413MB `.gputrace`），不再是攻坚重点。当前所有精力集中在**原神截帧**。

---

### 三、当前状态与核心问题

#### 3.1 已打通

- 截帧基础链路（QQ飞车验证通过 ✅）
- 延迟 dlopen 注入（原神正常启动 ✅）
- 启动期 DYLD_INSERT_LIBRARIES 注入（RC-014 修复 SIGABRT ✅，需关闭 MetalFX）
- NSObject compat stubs（`traceStream`/`streamReference` ✅）
- SIGSEGV guard（`stopCapture` 崩溃恢复 ✅）

#### 3.2 当前卡点：原神 trace 为空

**无论启动期注入还是延迟注入，原神的 `.gputrace` 产物始终为 0 bytes。**

关键证据（RC-014 验证，2026-04-01 00:48）：

| 指标 | QQ飞车（成功） | 原神（失败） |
|---|---|---|
| tracked queue class | `CaptureMTLCommandQueue` | `AGXG16XFamilyCommandQueue` |
| trace 产物 | 413MB | 0 bytes |
| `stopCapture` | 正常完成 | SIGSEGV（empty trace context）|

**根因推断**：`GPUToolsCapture` 未能将原神的 Metal 对象包裹为 `Capture*` 代理类。QQ飞车的 command queue 被正确包裹为 `CaptureMTLCommandQueue`（能拦截 GPU 命令流），而原神的 queue 仍是原始 `AGXG16XFamilyCommandQueue`（命令流不经过 `GPUToolsCapture`，trace context 为空）。

#### 3.3 需要回答的关键问题

| # | 问题 | 状态 |
|---|---|---|
| **Q5** | 为什么启动期注入模式下原神的 queue 仍然不是 `CaptureMTLCommandQueue`？是 PlayTools swizzle 时序问题，还是 GPUToolsCapture 对原神的 device/queue 创建路径不兼容？ | **TODO — 当前最重要** |
| **Q6** | PlayTools 的 queue discovery swizzle 是否在 GPUToolsCapture hook `newCommandQueue` **之前**安装？如果是，PlayTools 记录的是原始 queue 而非代理 queue，但 app 实际拿到的可能已是代理 queue | TODO |
| **Q7** | 能否在 `capture_metal_frame` 时动态获取 `CaptureMTLCommandQueue` 类型的 queue（而非 PlayTools tracked 的原始 queue）？ | TODO |
| **Q8** | `CaptureMTLFXSpatialScaler.encodeToCommandBuffer:` 的 MetalFX 崩溃能否通过 swizzle 绕过？ | 优先级低（可通过关闭 MetalFX 规避）|

---

### 四、当前最重要任务

> **`RC-015`：调查原神 Metal 对象未被 GPUToolsCapture 代理的原因**
>
> 核心问题：启动期注入时 `GPUToolsCapture` 已通过 `DYLD_INSERT_LIBRARIES` 在 dyld 阶段加载，按理应该 hook `MTLDevice.newCommandQueue` 返回 `CaptureMTLCommandQueue` 代理。但原神的 tracked queue class 仍是 `AGXG16XFamilyCommandQueue`。需要搞清楚是什么导致了这个不一致。
>
> 攻坚方向：
> 1. **时序问题**：PlayTools 的 swizzle 可能在 `GPUToolsCapture` hook 之前执行，记录的是原始对象
> 2. **代理穿透**：`GPUToolsCapture` 可能确实代理了 queue，但代理对象的 class 报告为原始类型
> 3. **hook 失败**：`GPUToolsCapture` 可能未能 hook 原神使用的特定 `MTLDevice` 实例的 `newCommandQueue`
> 4. **直接验证**：在启动期注入模式下，用 ObjC runtime 检查 app 实际持有的 queue 对象的 isa

---

### 五、Agent 工作流（强约束）

每个 agent **只做一个任务**。

1. 先读取本 Dashboard
2. 只领取一个当前最重要的任务
3. 过大则拆分，本轮只完成一个子任务
4. 详细过程写入子文档
5. 收尾时更新 Dashboard 状态 + 子文档结论
6. **整理已有内容**，删掉过时、合并重复、移出不重要信息

---

### 六、构建 / 安装约束

重建 PlayTools / PlayCover.app / xcframework **必须使用 `BuildScripts/` 标准脚本**：

- `BuildScripts/sync_playtools_xcframework.sh` — PlayTools xcframework
- `BuildScripts/build_and_install.sh` — PlayCover.app
- `BuildScripts/build_gui.sh` — 仅构建 GUI

---

### 七、双模式注入方案

| 模式 | 设置 | 机制 | 适用场景 |
|---|---|---|---|
| **延迟注入**（默认） | `metalCaptureEnabled=true` | runtime `dlopen` + compat stubs + SIGSEGV guard | 所有 app 安全启动；兼容 app（QQ飞车）可截帧 |
| **启动期注入** | + `injectMetalCaptureEnvironment=true` | `DYLD_INSERT_LIBRARIES` + early compat stubs（RC-014） | 理论上完整 trace context；**原神攻坚应使用此模式** |

---

### 八、app 兼容性矩阵

| App | 延迟注入启动 | 延迟注入截帧 | 启动期注入启动 | 启动期注入截帧 |
|---|---|---|---|---|
| QQ飞车 | ✅ | ✅ 413MB | ✅ | ✅ 124MB |
| 原神 | ✅ | 空 trace | ✅ (需关闭MetalFX) | 空 trace — **攻坚中** |

---

### 九、任务 TODO 状态

已完成任务（详细过程见各子文档）：

| ID | 状态 | 摘要 |
|---|---|---|
| RC-001 ~ RC-011 | DONE | 截帧链路打通、延迟注入方案、QQ飞车端到端验证 |
| RC-012 | DONE | 反汇编 GPUToolsCapture，定位 `traceStream`/`streamReference` 崩溃根因，实现 NSObject fallback stubs |
| RC-013 | DONE | 新增 `GuardedCapture.m`，SIGSEGV guard 保护 `stopCapture` |
| RC-014 | DONE | constructor 早期安装 compat stubs，修复启动期注入 SIGABRT；发现 MetalFX 不兼容 |

进行中 / 待做：

| ID | 优先级 | 状态 | 任务 |
|---|---|---|---|
| **RC-015** | **P0** | **TODO** | 调查原神 Metal 对象未被 GPUToolsCapture 代理的原因（Q5 ~ Q7） |
| RC-004 | P1 | TODO | 整理最终 SOP 与关单标准（在原神攻坚完成后） |

---

### 十、关键代码锚点

| 文件 | 作用 |
|---|---|
| `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift` | runtime 截帧核心，`ensureGPUToolsCaptureLoaded()` 延迟 dlopen |
| `Carthage/Checkouts/PlayTools/PlayTools/GuardedCapture.m` | SIGSEGV guard + RC-014 early compat stubs constructor |
| `PlayCover/Model/PlayApp.swift` | `effectiveLaunchEnvironment()` — 启动期注入环境变量 |
| `PlayCoverMCP/HostServices/Launch/LaunchService.swift` | MCP 侧启动环境变量（镜像逻辑） |
| `PlayCover/Model/AppSettings.swift` | `metalCaptureEnabled` / `injectMetalCaptureEnvironment` 设置定义 |

---

### 十一、参考

- 子文档目录：`Tasks/RC-*.md`、`Refs/01-验证入口与代码锚点.md`
- QQ飞车成功截帧产物：`~/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/Captures/capture_20260331_231639.gputrace`（413MB）
