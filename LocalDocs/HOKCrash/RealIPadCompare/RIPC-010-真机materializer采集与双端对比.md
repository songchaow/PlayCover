## RIPC-010 真机 materializer 采集与双端对比

> **阅读建议**：本文档沉淀 `RIPC-010` 阶段长期有效的采集方法、关键证据、
> 调试经验与对比口径。若只需了解当前主线与最高优先级，阅读
> `00-Dashboard.md` 即可；当需要复用真机 LLDB 采集、核查 `v5` 基线、
> 或继续推进 `RIPC-010-B / RIPC-010-C` 时再展开本文。**当前主线涉及
> `RIPC-010-B / RIPC-010-C1 / RIPC-010-C2` 时总是建议读取。**
>
> **维护规则**：同主题 execution note 的长期有效结论只回收到本文与
> `00-Dashboard.md`；execution note 本身不再作为事实来源。

### 当前稳定结论

- `RIPC-010-A4` **已打通**，不再是阻塞项；当前稳定真机基线是：
  - `build/ripc-010a-real-ipad-lldb-run-v5.json`
  - `build/ripc-010a-ipad-materializer-args-v5.json`
- `v5` 基线的关键结果：
  - `preInjectDelay = 5`
  - `recordCount = 71`
  - `materializer complete = 15`
- 真机 `x1` **不能再假定为 Pascal-like 小对象**；probe 必须先尝试
  **direct UTF-8 / UTF-16**，再回退到旧的 Pascal 结构解码。
- 真机成功路径已经确认包含两类 `entry_x1_text`：
  - iOS sandbox absolute path：`/var/mobile/.../Library/NGR/Saved/Paks/1/1_0.db`
  - UE4 relative pak path：`../../../NGR/Content/Paks/1/1_0.db`
- `RIPC-010-B1` 已把当前稳定矩阵固定为 **path class / caller tuple /
  return semantics** 三维比较；PlayCover 稳定 failing class 仍是
  `/Users/.../Saved/Paks/...`，而真机 accepted classes 至少包含
  `/var/mobile/.../Saved/Paks/...` 与 `../../../NGR/Content/Paks/...`。
- `2026-04-29` 的 **完整 `Release` GUI 重建 + 已安装 `~/Applications/PlayCover.app` fresh run** 已并入长期维护结论：
  - `build/ripc-010c1-live-report-v2.json` 选中
    `processLaunchId=launch-48548-f2a3231c-a329-4b88-aca4-39a1081c7405`
  - 同轮出现 `pdt006_ngr_convert_patch status=installed`
  - 但没有任何 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize`
  - 同轮仍出现 `hok014_ngr_alert_suppressed message="QtsFileSystem Create Failed!!"`
  - 这已经足够排除“工作区 app 副本 / move-to-Applications”变量
- `2026-04-30` 的 **installed-binary anchor revalidation** 进一步收紧了 `C1`：
  - `Scripts/pdt005_ngr_convert_to_platform_path_locator.py` 对当前已安装 binary 生成 `build/pdt-005-current-installed.json`
  - 当前 `/var/` 字面量窗口落在 `0x107d009c4`
  - 旧硬编码锚点 `0x10463f204` 首条指令立即 branch 到 `0x1000a4a08` 的 `/Users/` fast-path helper
  - 因此当前 `pdt006_ngr_convert_patch status=installed` **只能证明旧锚点地址可写并已打补丁，不能单独证明 failing flow 必然进入当前 replacement 覆盖范围**
- 因此当前 `C1` 的默认问题链应固定为：**先把 `PDT-006` 从 stale hardcoded anchor（`0x10463f204`）升级为 runtime-located coverage probe / patch point，并重跑 installed GUI verify；只有在当前热路径 coverage 建立后，`pdt006_ngr_convert_call` 的字段才有解释价值。**

### A4 打通后的长期有效结论

- 早期 `0-hit` 现象已经完成去伪存真：问题不在“真机无法采到 materializer”，
  而在 **immediate injection 容易 miss window** 以及早期产物隔离不充分。
- 当前长期有效的默认口径只有两条：
  - 默认使用 `--pre-inject-delay 5`
  - 默认以 `build/ripc-010a-real-ipad-lldb-run-v5.json` /
    `build/ripc-010a-ipad-materializer-args-v5.json` 作为真机稳定基线
- 若只是在推进 `RIPC-010-B / RIPC-010-C`，无需再按时间顺序回看 `v3` / `v4`
  的会话演进；只有在怀疑采集链本身再次失稳时，才需要回溯这些早期样本。

### 当前 real-device baseline（`v5`）

#### 已确认的 path class

| Path class | 例子 | 当前解读 |
|---|---|---|
| iOS absolute Saved/Paks | `/var/mobile/.../Library/NGR/Saved/Paks/1/1_0.db` | 真机 accepted class |
| UE4 relative pak | `../../../NGR/Content/Paks/1/1_0.db` | 真机 accepted class |
| iOS absolute Watchdog | `/var/mobile/.../Library/NGR/Saved/Paks/main/Watchdog/*.db` | 属于同轮其它路径流量，对比时需与 materializer 主样本分开 |

#### 当前最重要的直接含义

- `materializer` 在真机上**不是**只接受相对路径。
- 当前也**不能**再把修复方向粗暴表述成“绝对路径 vs 相对路径”。
- 真正需要比较的是：
  1. **path class**（`/var/mobile/...` / `../../../...` / `/Users/...`）
  2. **caller tuple**（如 `entryX2`、backtrace class、helper state）
  3. **return semantics**（至少比较 nullability / downstream side effects）

### 当前最重要的工作：`RIPC-010-B`

#### `RIPC-010-B1` 已完成的矩阵结论

`build/ripc-010b-diff.json` 已落盘，当前矩阵按 **path class / caller tuple /
return semantics** 汇总后的稳定结论如下：

1. **真机 accepted path classes 已闭合**
   - iOS absolute Saved/Paks：`/var/mobile/.../Library/NGR/Saved/Paks/...`
   - UE4 relative pak：`../../../NGR/Content/Paks/...`
   - 两类在真机 `v5` 中都对应 non-null materializer return，说明问题不能再表述成“绝对路径 vs 相对路径”。
2. **PlayCover success control sample 已闭合**
   - path class：`../../../NGR/Content/Paks/1/1.db`
   - caller tuple：`entryX2=0x10aa5264a`
   - target-side pre-`1c8` state：`x22=0x21 -> 0x3`
   - route：`0x10432a2c8 -> 0x10432a2e0 -> 0x10432a31c`
   - caller-side语义：success 返 non-null，并写回 `helper+0x18`
3. **PlayCover stable failing class 已闭合**
   - path class：`/Users/.../Saved/Paks/1/1.db`
   - caller tuple：`entryX2=0x10aa4678c`
   - target-side pre-`1c8` state：`x22=0x31 -> 0x4`
   - route：`0x10432a224 -> 0x10432a31c`
   - caller-side语义：`materializer return = 0`、`helper+0x18 = 0`、`x30=0x100122f88`、`errValue=0x9000b`
4. **post-`1c8` pair 不是当前主分叉解释**
   - `HOK-016-C.2.7` 已表明 observed success / fail hits 在 post-`1c8` 读到同一组 pair；剩余机制差异更像是 pre-`1c8` compare / caller-helper state。

#### `B1` 对决策的直接含义

- 当前证据已足够把默认主线从“继续补采”切到 **`RIPC-010-C` 修复闭环验证**。
- 代码侧复核已确认 `PlayLoader.m` 中存在现成链路：
  `ripc006_try_normalize_pak_path()` → `pdt006_convert_replacement()` →
  `pdt006_install_convert_patch_once()`。
- 因此当前并不缺“修法候选”，缺的是 **replacement coverage / call evidence**。
- `B2` 不再是默认下一步：只有当 `C1/C2` 验证后仍暴露新的未闭合 path class /
  caller tuple 时，才回到定向补采。

### 稳定采集方法

#### 默认方法：driver + delayed injection

```bash
python3 Scripts/ripc_010a_real_ipad_lldb_driver.py \
  --pre-inject-delay 5 \
  --wait-seconds 60 \
  --output build/ripc-010a-real-ipad-lldb-run-vN.json \
  --transcript build/ripc-010a-real-ipad-lldb-transcript-vN.log
```

- `Scripts/ripc_010a_materializer_probe.py` 现已支持：
  - direct UTF-8 / UTF-16 优先解码
  - Pascal fallback
  - entry / return / vcall 采集
  - per-run 输出路径覆盖
- 每次运行都必须隔离：
  - run report
  - transcript
  - probe JSON
  - probe log

#### Xcode 手动 / GUI 自动化 fallback

1. 确保真机 NGR 已重新启动，且旧 PID 已终止并等待 3~5 秒。
2. Attach 到真机进程后，不要执着于“越早越好”；当前默认做法是先让进程运行到 NGR 模块装载可见，再做 delayed injection。
3. Debug Console 中导入 probe：
   `command script import /Users/songdogwang/Codes/PlayCover/Scripts/ripc_010a_materializer_probe.py`
4. Address breakpoint 仍必须通过 LLDB 命令设置；Breakpoint Navigator 的 `+` 菜单没有 Address Breakpoint。

### 长期有效的调试经验

- **先杀旧进程再重启**：否则 `--start-stopped` 可能连到旧实例，导致对启动期所在阶段的判断失真。
- **不要用 Ctrl-C 杀 LLDB**：若需中断，优先用 `process interrupt`。
- **检查时间戳，不只看文件存在性**：判断一次运行是否真的生成了新结果，至少要同时看路径、修改时间与 `recordCount`。
- **zero-hit 不等于 target path 不存在**：可能是 timing miss、decoder 错、stale output 或 target 确实未执行，必须逐项排除。
- **优先用 module-relative identity 做比较**：避免把某次 session 的 runtime address 当成稳定锚点。
- **不要过拟合 `_dyld_start`**：对当前任务来说，“早到 dyld”不是目标，“稳定拿到 materializer 的真实参数”才是目标。

### 当前仍待闭合的问题

- `RIPC-010-B1` 已经落盘为 `build/ripc-010b-diff.json`，当前不再缺“统一 diff”；剩余问题首先转为：**现有 normalize 链为什么没有留下 replacement 调用证据**。
- `2026-04-29` 的 installed GUI fresh run 已固定为长期证据：
  - `pdt006_ngr_convert_patch status=installed`
  - 无 `pdt006_ngr_convert_call`
  - 无 `ripc006_pak_path_normalize`
  - `QtsFileSystem Create Failed!!` 仍发生
- `2026-04-30` 的 installed-binary anchor revalidation 之后，当前 `C1` 必须按以下更具体的顺序推进：
  1. **先把 stale hardcoded anchor 升级为 runtime-located coverage probe / patch point**：优先复用 `Scripts/pdt005_ngr_convert_to_platform_path_locator.py` 提供的当前热路径窗口信息，使 patch / probe 能覆盖当前 binary 的真实 `ConvertToPlatformPath` 热路径；
  2. **重跑 installed GUI verify**：重新观察是否出现 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize`；
  3. **只有 coverage 建立后，才读 `pdt006_ngr_convert_call` 字段**：`pathPreview`、`pathBytesHex`、`matchesUsers`、`containsSavedPaks`、`looksUtf16UsersPrefix`、`normalized`；
  4. **若 coverage 建立后仍完全没有 `pdt006_ngr_convert_call`，优先把探针 / hook 前移到当前热路径上游 caller**；
  5. **只有 normalize-hit 但 QtsFS 仍 fail，才升级到 `RIPC-010-C2`**。
- 因此当前最该做的事已经固定为：**先用 runtime-located coverage probe / re-anchor 替代 `0x10463f204`，再重跑 live verify，之后才解释 `x1` 形态或考虑 `C2`。**
- `v5` 中仍有部分 `materializer` 记录呈现 `return_orphaned`，但它们当前不足以阻塞 `RIPC-010-C1/C2`；只有当验证后仍出现新的未闭合分叉时，才回到 `RIPC-010-B2` 做定向补采。

### 产物与脚本索引

| 路径 | 说明 |
|---|---|
| `Scripts/ripc_010a_materializer_probe.py` | 真机 materializer / vcall LLDB probe |
| `Scripts/ripc_010a_real_ipad_lldb_driver.py` | 真机 attach + delayed injection driver |
| `LocalDocs/XCodeOperation/ripc_010a_xcode_debug_automation.py` | Xcode GUI 自动化协调脚本 |
| `build/ripc-010a-real-ipad-lldb-run-v5.json` | 当前稳定 run 摘要 |
| `build/ripc-010a-ipad-materializer-args-v5.json` | 当前稳定真机基线 |
| `build/ripc-010b-diff.json` | `RIPC-010-B1` 双端对比矩阵 |
| `build/ripc-010c1-live-report-v2.json` | installed GUI `C1` live verify 结果 |
| `build/pdt-005-current-installed.json` | installed-binary anchor revalidation 结果 |
| `build/ripc-010a-real-ipad-lldb-run-v4.json` | immediate injection 的 0-hit 对照样本 |
| `build/ripc-010a-real-ipad-lldb-run-v3.json` | 早期 stale-output 混淆样本 |
