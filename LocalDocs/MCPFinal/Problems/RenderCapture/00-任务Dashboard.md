## Render Capture：任务 Dashboard

### 一、文档目的

每个 agent 的**统一入口**。先读它，再开始工作。主文档保持简洁，详细过程下沉到子文档。

---

### 二、最终目标

> **让原神成功执行 `capture_metal_frame`，生成非空 `.gputrace` 文件。**

**✅ 已达成**（2026-04-01 01:11）：原神截帧成功，357MB `.gputrace` 产物。

---

### 三、最终状态

#### 3.1 已打通的全部能力

- 截帧基础链路（QQ飞车验证通过 ✅）
- 延迟 dlopen 注入（原神正常启动 ✅）
- 启动期 DYLD_INSERT_LIBRARIES 注入（RC-014 修复 SIGABRT ✅，需关闭 MetalFX）
- NSObject compat stubs（`traceStream`/`streamReference` ✅）
- SIGSEGV guard（`stopCapture` 崩溃恢复 ✅）
- **原神截帧**（启动期注入 + 关闭 MetalFX → 357MB trace ✅）

#### 3.2 已回答的关键问题

| # | 问题 | 答案 |
|---|---|---|
| Q5 | 为什么之前启动期注入模式下原神的 queue 不是 `CaptureMTLCommandQueue`？ | **之前测试时 PlayTools 未正确更新到 app 中**。正确重建+重启 PlayCover 后，queue 类型为 `CaptureMTLCommandQueue`。 |
| Q6 | PlayTools 的 queue discovery swizzle 是否在 GPUToolsCapture hook 之前安装？ | 否。`GPUToolsCapture` 通过 `DYLD_INSERT_LIBRARIES` 在 dyld 阶段加载（最早），PlayTools 的 swizzle 在 `MetalCaptureService.initialize()` 中安装（更晚）。因此 PlayTools 记录的是 GPUToolsCapture 代理后的 queue。 |
| Q7 | 能否动态获取 `CaptureMTLCommandQueue` 类型的 queue？ | 不需要。启动期注入下 PlayTools 自动记录到的就是代理 queue。 |
| Q8 | MetalFX 崩溃能否绕过？ | 当前通过关闭 MetalFX 规避。优先级低。 |

---

### 四、app 兼容性矩阵（最终）

| App | 延迟注入启动 | 延迟注入截帧 | 启动期注入启动 | 启动期注入截帧 |
|---|---|---|---|---|
| QQ飞车 | ✅ | ✅ 413MB | ✅ | ✅ 124MB |
| 原神 | ✅ | 空 trace（预期） | ✅ (需关闭MetalFX) | **✅ 357MB** |

说明：原神延迟注入截帧为空 trace 是预期行为 — Metal 对象在 `GPUToolsCapture` 加载前已创建，不会被代理。

---

### 五、原神截帧操作 SOP

1. 设置 `metalCaptureEnabled=true` + `injectMetalCaptureEnvironment=true`
2. 在游戏中关闭 MetalFX（避免 `CaptureMTLFXSpatialScaler` 崩溃）
3. 启动原神
4. `create_session` → `capture_metal_frame`
5. 产物在 `~/Library/Containers/com.miHoYo.Yuanshen/Data/Documents/Captures/`

---

### 六、构建 / 安装约束

重建 PlayTools / PlayCover.app / xcframework **必须使用 `BuildScripts/` 标准脚本**：

- `BuildScripts/sync_playtools_xcframework.sh` — PlayTools xcframework
- `BuildScripts/build_and_install.sh` — PlayCover.app
- `BuildScripts/build_gui.sh` — 仅构建 GUI

**重要**：修改 PlayTools 后必须完整执行 `sync_playtools_xcframework.sh` → `build_and_install.sh` → **重启 PlayCover** → 重新启动 app。

---

### 七、双模式注入方案

| 模式 | 设置 | 机制 | 适用场景 |
|---|---|---|---|
| **延迟注入**（默认） | `metalCaptureEnabled=true` | runtime `dlopen` + compat stubs + SIGSEGV guard | 所有 app 安全启动；兼容 app（QQ飞车）可截帧 |
| **启动期注入** | + `injectMetalCaptureEnvironment=true` | `DYLD_INSERT_LIBRARIES` + early compat stubs（RC-014） | 完整 trace context；**原神必须使用此模式** |

---

### 八、任务完成状态

| ID | 状态 | 摘要 |
|---|---|---|
| RC-001 ~ RC-011 | DONE | 截帧链路打通、延迟注入方案、QQ飞车端到端验证 |
| RC-012 | DONE | 反汇编 GPUToolsCapture，定位 `traceStream`/`streamReference` 崩溃根因，实现 NSObject fallback stubs |
| RC-013 | DONE | 新增 `GuardedCapture.m`，SIGSEGV guard 保护 `stopCapture` |
| RC-014 | DONE | constructor 早期安装 compat stubs，修复启动期注入 SIGABRT；发现 MetalFX 不兼容 |
| **RC-015** | **DONE** | **原神截帧成功！** 调查发现之前 trace 为空是 PlayTools 未正确更新导致，修正后 357MB trace |

待做（非阻塞）：

| ID | 优先级 | 状态 | 任务 |
|---|---|---|---|
| RC-004 | P2 | TODO | 整理最终 SOP 与关单标准 |

---

### 九、关键代码锚点

| 文件 | 作用 |
|---|---|
| `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift` | runtime 截帧核心 + RC-015 诊断 |
| `Carthage/Checkouts/PlayTools/PlayTools/GuardedCapture.m` | SIGSEGV guard + RC-014 early compat stubs + RC-015 C 层类枚举 |
| `PlayCover/Model/PlayApp.swift` | `effectiveLaunchEnvironment()` — 启动期注入环境变量 |
| `PlayCoverMCP/HostServices/Launch/LaunchService.swift` | MCP 侧启动环境变量（镜像逻辑） |
| `PlayCover/Model/AppSettings.swift` | `metalCaptureEnabled` / `injectMetalCaptureEnvironment` 设置定义 |

---

### 十、参考

- 子文档目录：`Tasks/RC-*.md`
- QQ飞车成功截帧产物：`~/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/Captures/capture_20260331_231639.gputrace`（413MB）
- **原神成功截帧产物**：`~/Library/Containers/com.miHoYo.Yuanshen/Data/Documents/Captures/capture_20260401_011127.gputrace`（357MB）
