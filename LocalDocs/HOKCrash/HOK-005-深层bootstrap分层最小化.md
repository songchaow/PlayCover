## HOK-005 深层 bootstrap 分层最小化

> 本文只沉淀 HOK-005 各子层（A/B/C/D）的**分层策略**、**代码落点**与**诊断事件语义**。任务状态、live 结果与是否仍然是主线以 `00-Dashboard.md` 为准。
>
> **何时读**：需要调整 `com.tencent.ngr` 的 `DiscordIPC` / `PlayInput` / `PlayScreen` / `AKInterface` 四层 skip 或延迟策略、或需要新增一层 bootstrap 抑制时读；日常 HOK-016 系列工作不需要进入。
>
> **相关文档**：
>
> - 启动 runner 与 settle window：`HOK-004-启动验证与settle-window.md`；
> - compat event 收集点：`00-Dashboard.md` 的"构建与验证"章节；
> - 兜底链路实现：`HOK-013-slot-preheat.md` / `HOK-014-alert-suppressor.md` / `HOK-015-cmdline-preseed.md`。

### 目标

- 在保留 `com.tencent.ngr` 现有最小兼容启动 gate 的前提下，继续按层压低更深一层 early bootstrap 副作用。
- 每次只动一层，并继续复用 `Scripts/hok004_ngr_startup_runner.py` 作为唯一 live 验证入口，判断 session 状态、launch diagnostics 与 crash window 是否发生实质变化。

### 分层顺序（从浅到深）

- `HOK-005A`：跳过 `DiscordIPC` 的 host/runtime 启动面。
- `HOK-005B`：跳过 `PlayInput.shared.initialize()`。
- `HOK-005C`：跳过 `PlayScreen.shared.initialize()`。
- `HOK-005D`：在确认上面三层都无效后，再尝试延迟 `AKInterface.initialize()`，避免直接硬禁用导致下游强制解包崩溃。

### HOK-005A 代码落点

- host 侧：`PlayCover/Utils/Extensions/PlayAppExtensions.swift` 对 `com.tencent.ngr` 直接跳过 `loadDiscordIPC()`，不再为该 app 建立 Discord IPC socket symlink。
- host 侧 bundle gate 复用：`PlayCover/Model/PlayApp.swift` 把 `minimalStartupCompatBundleIdentifiers` 提升为同类型可复用，避免在 extension 中再维护一份并行名单。
- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` 对 `com.tencent.ngr` 跳过 `DiscordIPC.shared.initialize()`，并发 `playcover_discord_skipped` 诊断事件；其他 app 仍保持原有 `playcover_discord_initialized` 路径。

### HOK-005B 代码落点

- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` 对 `com.tencent.ngr` 跳过 `PlayInput.shared.initialize()`，并发 `playcover_input_skipped` 诊断事件；其他 app 仍保持原有 `playcover_input_initialized` 路径。
- 验证侧：`Scripts/hok004_ngr_startup_runner.py` 将 `playcover_input_skipped` 纳入 required compat events，将 `playcover_input_initialized` 纳入 forbidden compat events。

### HOK-005C 代码落点

- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` 对 `com.tencent.ngr` 跳过 `PlayScreen.shared.initialize()`，并发 `playcover_screen_skipped` 诊断事件；其他 app 仍保持原有 `playcover_screen_initialized` 路径。
- 验证侧：`Scripts/hok004_ngr_startup_runner.py` 将 `playcover_screen_skipped` 纳入 required compat events，将 `playcover_screen_initialized` 纳入 forbidden compat events；`Scripts/test_hok004_ngr_startup_runner.py` 同步覆盖这组 gate。

### HOK-005D 代码落点

- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift` 为 `com.tencent.ngr` 新增唯一一条 `AKInterface` 延迟配置，固定为 `1.0s`，覆盖已知 `0.20s-0.61s` crash window，同时改动最小且可逆。
- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` 仅对 `com.tencent.ngr` 把 `AKInterface.initialize()` 改为延迟调度，并发 `playcover_akinterface_delayed`、`playcover_akinterface_initialize_started`、`playcover_akinterface_initialized` 三个诊断事件区分"已计划延迟"与"实际开始/完成初始化"；其他 bundle 继续走原有即时初始化路径。
- runtime 侧：关闭窗口时若 `com.tencent.ngr` 还处于延迟窗口、`AKInterface.shared` 尚未建立，则不再触发 app-scoped 的强制解包终止路径，而是记录 `playcover_akinterface_terminate_skipped`，避免把新的 pre-init race 误引入 close path。
- 验证侧：`Scripts/hok004_ngr_startup_runner.py` 的结构化报告新增 `diagnostics.akInterface` 字段，直接写入本轮 launch 中 `AKInterface` 的 `scheduled` / `initializeStarted` / `initialized` 三态；`Scripts/test_hok004_ngr_startup_runner.py` 同步补充离线覆盖。

### 诊断事件速查

| 分层 | required 事件 | forbidden 事件 |
|---|---|---|
| A | `playcover_discord_skipped` | `playcover_discord_initialized` |
| B | `playcover_input_skipped` | `playcover_input_initialized` |
| C | `playcover_screen_skipped` | `playcover_screen_initialized` |
| D | `playcover_akinterface_delayed` | `playcover_akinterface_initialize_started` / `playcover_akinterface_initialized`（仅在延迟窗口内被视为 forbidden；延迟窗口过后出现属于预期）|

### 口径说明

- 仅凭 runtime `playcover_*_skipped` 事件判定某一层是否真正被压低；不要以"窗口看起来不崩了"作为通过判据。
- `AKInterface` 改动的可逆性由"延迟而非禁用"保证；回滚只需把延迟改回 `0`。
