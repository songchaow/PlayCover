# HOK-015 附录：验证口径与边界

> 本文是 `HOK-015-cmdline-preseed.md` 的附录，沉淀四轮 live 验证口径、
> 与 HOK-014/016 的联动归属规则、以及 HOK-015 的非目标 / 边界。
>
> **何时读**：
>
> - 需要真正跑一轮 HOK-015 验证；
> - 判断一次 `hok014_ngr_alert_suppressed = 1` 是 HOK-015 回归还是
>   HOK-016 残留；
> - 考虑把 HOK-015 推广到其它 UE4 app；
> - 日常阅读 HOK-015 主文档不必进入本文。
>
> **相关文档**：
>
> - 主文档：`HOK-015-cmdline-preseed.md`；
> - alert 压制与归属规则：`HOK-014-alert-suppressor.md`；
> - QtsFS 独立 alert 路径：`HOK-016-qts-fs-create-failed.md`；
> - seed 实验证伪：`HOK-016-appendix-CX.md`。

## 验证口径

### 第一轮：静态分析 + 写入落地（HOK-015 专属判据）

前置：HOK-013、HOK-014 保持 apply；plist `rootWorkDir=1`；候选 E 保
持 revert。

1. 跑 `python3 Scripts/hok015_ngr_cmdline_locator.py
   --output build/hok-015-cmdline-slots.json`；核对 `bInitializedAddr`
   与 `cmdlineBufferAddr` 在合理 `__common` / `__data` 范围。
2. 按扫描结果写入 `PlayLoader.m` 宏；重建 PlayTools xcframework +
   重装 PlayCover。
3. 自由启动 NGR（`launch_app`，不带 LLDB），等 60s。
4. **HOK-015 判据**（全部满足才视为 HOK-015 自身闭合）：
   - `launch-events.jsonl` 出现 `hok015_ngr_cmdline_preseed
     status=primed`，details 里 `bInitializedBefore=0` /
     `bInitializedAfter=1` /
     `cmdlinePreview="../../../NGR/NGR.uproject"`；
   - 子进程 stderr / dyld log 里**不再出现** `Attempting to get the
     command line but it hasn't been initialized yet` 与
     `[UE4] Fatal error: [File:Unknown] [Line: 34]` 任何一条；
   - `Scripts/hok016_ngr_qts_reporter_trace.py` / HOK-016-B 的寄存器
     证据仍显示 reporter `x2 = 0x10e20107a`（即 HOK-015 preseed 的
     CmdLine buffer），证明后续 QtsFS 路径继续消费的正是同一块
     已初始化存储；
   - **不要求**当前 `hok014_ngr_alert_suppressed = 0`，因为在 HOK-016
     闭合前这 1 次 alert 仍可能由 QtsFS 独立路径稳定触发；
   - **不要求**当前 `%CPU/RSS/窗口可见性` 达到最终目标，这些是 HOK-016-D
     的 pass 条件，不是 HOK-015 的专属 pass 条件。

### 第二轮：与 HOK-016 的联动验证

HOK-015 闭合后，接下来的 live run 应满足：

1. `hok015_ngr_cmdline_preseed status=primed` 仍然存在；
2. `Attempting to get the command line ...` fatal 仍保持 **0**；
3. 若 `hok014_ngr_alert_suppressed = 1` 且 message =
   `"QtsFileSystem Create Failed!!"`，则归入 HOK-016，**不**回退 HOK-015；
4. 若重新出现 UE4 cmdline fatal，才视为 HOK-015 回归。

### 第三轮：HOK-014 降级为冷备（依赖 HOK-016-D）

只有在 HOK-016-D 通过、`hok014_ngr_alert_suppressed` 真正归零之后：

1. 把 Dashboard TODO 表里 HOK-014 的状态描述改成"DONE（冷备安全网）"；
   代码不动。
2. 若后续某轮再次出现 `hok014_ngr_alert_suppressed > 0`，先按 message
   内容判断归属：
   - UE4 cmdline fatal → 视为 HOK-015 回归；
   - `QtsFileSystem Create Failed!!` 或其它 NGR 业务 alert → 视为
     HOK-016 / 后续新任务的输入材料。

### 第四轮：bundle-scoped gate 不影响其它 bundle

- 其它已安装 bundle 的 `launch-events.jsonl` 里**不**出现
  `hok015_ngr_cmdline_preseed` 事件；
- 快捷检查：
  ```
  grep -l "hok015_ngr" \
    ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/*/launch-events.jsonl
  ```
  应只返回 `com.tencent.ngr` 的子目录。

## 非目标 / 边界

- **HOK-015 不解决** UE4 主循环进入后的业务逻辑错误（例如登录、网
  络、账号、MSDK 初始化失败等）。这些属于 HOK-009 范畴，需要用户
  介入。
- **HOK-015 不改** UE4 cmdline 的语义——它只是把 `FCommandLine::Set`
  发生的**时机**提前；UE4 自己后续 `Set()` 调用仍然走正常路径（要么
  覆盖为同值 no-op、要么写新值）。
- **HOK-015 不适用于其它 UE4 app**。别的 bundle 的 `__common` 布局
  不一样、cmdline 值不一样；推广需要重做 HOK-015-A 静态定位 +
  bundle gate。
