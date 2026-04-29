## RIPC-010-C1 installed GUI fresh run（2026-04-29 17:35）

### 背景

本轮目标是把 `RIPC-010-C1` 的验证从“工作区临时 app 副本 + 手动替换 framework”收紧到**完整 GUI 重建 + 正式安装实例**，排除 `PlayCover.app` 首次打开时的“移动到应用程序文件夹”提示及其带来的宿主变量。

### 本轮执行

#### 1. 重新确认 GUI 构建方式

- 先验证 `PlayCover.xcodeproj` 的 `PlayCover` target 只有 `Release` / `Nightly`，没有对称的 `Debug` 配置。
- 因此本轮不再使用 `build_gui.sh Debug` 做结论性验证，而改用正式 `Release` 产物。

#### 2. 完整 GUI 重建并安装

执行：

```bash
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Release
PLAYCOVER_INSTALL_MODE=user ./BuildScripts/build_and_install.sh Release
```

结果：

- `PlayTools` 重建成功；安装后的 [PlayCover.app](/Users/songdogwang/Applications/PlayCover.app) 自带 `PlayTools.framework` 已确认包含新的 `pdt006_ngr_convert_call` 诊断标记。
- 安装路径固定为 `~/Applications/PlayCover.app`，因此后续 fresh run 不再依赖工作区副本。

#### 3. 使用已安装实例执行 fresh run

执行：

```bash
python3 Scripts/hok015_ngr_live_verify.py \
  --playcover-app-path /Users/songdogwang/Applications/PlayCover.app \
  --observe-seconds 20 \
  --poll-interval 2 \
  --output build/ripc-010c1-live-report-v2.json
```

关键产物：

- 报告：[ripc-010c1-live-report-v2.json](/Users/songdogwang/Codes/PlayCover/build/ripc-010c1-live-report-v2.json)
- 启动日志：[launch-events.jsonl](/Users/songdogwang/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl)
- 本轮 `processLaunchId`：`launch-48548-f2a3231c-a329-4b88-aca4-39a1081c7405`
- 新增 crash：`NGR-2026-04-29-173545.ips`

### 关键证据

#### 已确认出现

- `hok015_ngr_cmdline_preseed status=primed`
- `hok013_ngr_slot_preheat status=primed`
- `hok016c5_ngr_materialize_shim_installed`
- `pdt006_ngr_convert_patch status=installed`
- `hok014_ngr_alert_suppressed message="QtsFileSystem Create Failed!!"`

#### 未出现

- `pdt006_ngr_convert_call`
- `ripc006_pak_path_normalize`

### 结论

- **可以排除“工作区 app 副本 / move-to-Applications 提示”变量**：本轮验证已经改为完整 `Release` GUI 重建，并从已安装的 [PlayCover.app](/Users/songdogwang/Applications/PlayCover.app) fresh 启动。
- **`pdt006_install_convert_patch_once()` 的安装已被再次确认**：补丁安装事件稳定出现。
- **但 `C1` 仍未闭环**：同轮没有任何 `pdt006_ngr_convert_call` 或 `ripc006_pak_path_normalize`，而 `QtsFileSystem Create Failed!!` 仍然发生。
- 因此当前最准确的问题定义已经收紧为：**为什么 `ConvertToPlatformPath` replacement 没有留下调用/命中证据**。在回答这个问题之前，不应把主线切到 `RIPC-010-C2`。

### 下一步

1. 继续停留在 `RIPC-010-C1`。
2. 优先解释 `pdt006_convert_replacement()` 为什么没有产生 `pdt006_ngr_convert_call`：
   - replacement 根本未进入；或
   - `x1` 不是当前假设的 UTF-8 `/Users/...` 形态；或
   - failing 路径流量没有经过这条 `ConvertToPlatformPath` 链。
3. 只有在后续已证实 normalize 实际命中且 `QtsFS` 仍失败时，才进入 `RIPC-010-C2` 去收紧 pre-`1c8` caller / helper state。
