## RIPC-010 真机 materializer 采集与双端对比

> **阅读建议**：本文档沉淀 RIPC-010 阶段长期有效的采集方法、关键证据、
> 调试经验与对比口径。若只需了解当前主线与最高优先级，阅读
> `00-Dashboard.md` 即可；当需要复用真机 LLDB 采集、核查 `v5` 产物、
> 或继续推进 `RIPC-010-B / RIPC-010-C` 时再展开本文。一般无需逐条回看
> 历史会话。

### 当前稳定结论

- `RIPC-010-A4` **已打通**，不再是阻塞项。早先“dyld 完成后断点变为 unresolved”是真实现象，但它描述的是一种早期调试姿势失效，不代表 materializer 在真机上不可采集。
- 当前稳定真机基线是：
  - `build/ripc-010a-real-ipad-lldb-run-v5.json`
  - `build/ripc-010a-ipad-materializer-args-v5.json`
- `v5` 基线的关键结果：
  - `preInjectDelay = 5`
  - `recordCount = 71`
  - `materializer complete = 15`
- 真机 `x1` **不能再假定为 Pascal-like 小对象**；实测经常直接指向 path string buffer。probe 现在必须先尝试 **direct UTF-8 / UTF-16**，再回退到旧的 Pascal 结构解码。
- 真机成功路径已经确认包含两类 `entry_x1_text`：
  - iOS sandbox absolute path：`/var/mobile/.../Library/NGR/Saved/Paks/1/1_0.db`
  - UE4 relative pak path：`../../../NGR/Content/Paks/1/1_0.db`
- `2026-04-29` 的 **完整 `Release` GUI 重建 + 已安装 `~/Applications/PlayCover.app` fresh run** 已作为长期有效结论并入本文：
  - `build/ripc-010c1-live-report-v2.json` 选中 `processLaunchId=launch-48548-f2a3231c-a329-4b88-aca4-39a1081c7405`
  - 同轮出现 `pdt006_ngr_convert_patch status=installed`
  - 但没有任何 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize`
  - 同轮仍出现 `hok014_ngr_alert_suppressed message="QtsFileSystem Create Failed!!"`
- `2026-04-30` 的离线 installed-binary 复核已把 `C1` 的第一分叉进一步收紧：`Scripts/pdt005_ngr_convert_to_platform_path_locator.py` 对当前已安装 `NGR` 生成 `build/pdt-005-current-installed.json`，其中 `/var/` 字面量窗口落在 `0x107d009c4`；与此同时，对旧锚点 `0x10463f204` 的反汇编显示其首条指令立即 branch 到 `0x1000a4a08` 的 `/Users/` fast-path helper。这说明当前 `pdt006_ngr_convert_patch status=installed` **只能证明旧锚点地址可写并已打补丁，尚不能单独证明 failing flow 一定进入当前 replacement 覆盖范围**。
- 因此当前待解释的问题已进一步收紧为：**为什么 `ConvertToPlatformPath` replacement 没有留下调用 / 命中证据**，而且第一优先级要先回答这是否属于**旧锚点覆盖范围不足**。这一步完成前，不应把默认主线切到 `RIPC-010-C2`。
- 进一步说，当前 `C1` 的**唯一最高优先级子任务**应固定为：先证明 failing `/Users/.../Saved/Paks/1/1.db` 流量到底有没有进入旧锚点 `0x10463f204` / `0x1000a4a08` 所覆盖的 `ConvertToPlatformPath` 路径；只有覆盖范围成立后，才继续判断 `x1` 到达 `pdt006_convert_replacement()` 时到底是什么形态。

### A4 打通后的长期有效结论

- 早期 `0-hit` 现象已经完成去伪存真：问题不在“真机无法采到 materializer”，而在 **immediate injection 容易 miss window** 以及早期产物隔离不充分。
- 当前长期有效的默认口径只有两条：
  - 默认使用 `--pre-inject-delay 5`
  - 默认以 `build/ripc-010a-real-ipad-lldb-run-v5.json` / `build/ripc-010a-ipad-materializer-args-v5.json` 作为真机稳定基线
- 若只是在推进 `RIPC-010-B / RIPC-010-C`，无需再按时间顺序回看 `v3` / `v4` 的会话演进；只有在怀疑采集链本身再次失稳时，才需要回溯这些早期样本。

### 当前 real-device baseline（`v5`）

#### 已确认的 path class

| Path class | 例子 | 当前解读 |
|---|---|---|
| iOS absolute Saved/Paks | `/var/mobile/.../Library/NGR/Saved/Paks/1/1_0.db` | 真机 accepted class |
| UE4 relative pak | `../../../NGR/Content/Paks/1/1_0.db` | 真机 accepted class |
| iOS absolute Watchdog | `/var/mobile/.../Library/NGR/Saved/Paks/main/Watchdog/*.db` | 说明同一轮 vcall 里存在非 materializer 的其它路径流量，做对比时要分开 |

#### 当前最重要的直接含义

- `materializer` 在真机上**不是**只接受相对路径。
- 当前也**不能**再把修复方向粗暴表述成“绝对路径 vs 相对路径”。
- 真正需要比较的是：
  1. **path class**（`/var/mobile/...` / `../../../...` / `/Users/...`）
  2. **caller tuple**（如 `entryX2`、backtrace class、helper state）
  3. **return semantics**（至少比较 nullability / downstream side effects，而不是执着于精确指针值）

### 当前最重要的工作：`RIPC-010-B`

#### `RIPC-010-B1` 已完成的矩阵结论

`build/ripc-010b-diff.json` 已落盘，当前矩阵按 **path class / caller tuple / return semantics** 汇总后的稳定结论如下：

1. **真机 accepted path classes 已闭合**
   - iOS absolute Saved/Paks：`/var/mobile/.../Library/NGR/Saved/Paks/...`
   - UE4 relative pak：`../../../NGR/Content/Paks/...`
   - 两类在真机 `v5` 中都对应 non-null materializer return，说明问题不能再表述成“绝对路径 vs 相对路径”。
2. **PlayCover success control sample 已闭合**
   - path class：`../../../NGR/Content/Paks/1/1.db`
   - caller tuple：`entryX2=0x10aa5264a`
   - target-side pre-`1c8` state：`x22=0x21 -> 0x3`
   - route：`0x10432a2c8 -> 0x10432a2e0 -> 0x10432a31c`
   - caller-side 语义：success 返 non-null，并写回 `helper+0x18`
3. **PlayCover stable failing class 已闭合**
   - path class：`/Users/.../Saved/Paks/1/1.db`
   - caller tuple：`entryX2=0x10aa4678c`
   - target-side pre-`1c8` state：`x22=0x31 -> 0x4`
   - route：`0x10432a224 -> 0x10432a31c`
   - caller-side 语义：`materializer return = 0`、`helper+0x18 = 0`、`x30=0x100122f88`、`errValue=0x9000b`
4. **post-`1c8` pair 不是当前主分叉解释**
   - `HOK-016-C.2.7` 已表明 observed success / fail hits 在 post-`1c8` 读到同一组 pair；剩余机制差异更像是 pre-`1c8` compare / caller-helper state。

#### `B1` 对决策的直接含义

- **可操作结论**：当前证据已足够把默认主线从“继续补采”切到 **`RIPC-010-C` 修复闭环验证**。
- **代码侧复核结果**：`PlayLoader.m` 已经存在 bundle-scoped 的 `Saved/Paks` 归一化实现与安装调用链：`ripc006_try_normalize_pak_path()`、`pdt006_convert_replacement()`、`pdt006_install_convert_patch_once()`。因此 `C` 阶段的真实首任务不是“重想一遍 remap 方向”，而是验证这条现有链是否真的安装并命中 `/Users/.../Saved/Paks/...` failing class。
- **installed GUI fresh run 的直接含义已经固定**：它已经足够排除“工作区 app 副本 / move-to-Applications 提示”变量，也足够再次证明 patch installed；但它**没有**证明 replacement 已被进入。
- **默认优先顺序**：
  1. `RIPC-010-C1`：先证明 failing `/Users/.../Saved/Paks/1/1.db` 是否进入 `ConvertToPlatformPath`，以及进入时 `x1` 的真实形态；
  2. `RIPC-010-C2`：仅当 `C1` 已证实 normalize 命中但 QtsFS 仍 fail，再转向 pre-`1c8` caller/helper state。
- **残余不确定性**：矩阵仍未证明“只有 path text 一项差异”；更准确的说法是：**path class 已足以支撑验证优先级，而 pre-`1c8` caller/helper state 仍是机制层面的 residual uncertainty。**
- **因此 `B2` 不再是默认下一步**：只有当 `C1/C2` 验证后仍暴露新的未闭合 path class / caller tuple 时，才回到定向补采。
- **阅读建议**：当前只要任务涉及 `RIPC-010-B` 证据解释、`RIPC-010-C1/C2` 方向判断、或修复验证口径，**总是建议读取本文**。

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

- `RIPC-010-B1` 已经落盘为 `build/ripc-010b-diff.json`，当前不再缺“统一 diff”；剩余问题首先转为：**现有 `RIPC-006` normalize 链为什么没有产生 replacement 调用证据**。
- `2026-04-29` 的 installed GUI fresh run 已再次确认：
  - `pdt006_ngr_convert_patch status=installed`
  - 无 `pdt006_ngr_convert_call`
  - 无 `ripc006_pak_path_normalize`
  - `QtsFileSystem Create Failed!!` 仍发生
- `2026-04-30` 的 installed-binary 复核又把这个问题进一步拆成了更具体的三分叉：
  1. failing `/Users/.../Saved/Paks/...` 根本未进入 `ConvertToPlatformPath`；
  2. failing flow 进入了 `ConvertToPlatformPath`，但并**不**经过旧锚点 `0x10463f204` / `0x1000a4a08` 所覆盖的路径；
  3. failing flow 进入了旧锚点覆盖范围，但 `x1` 参数并非当前假设的 UTF-8 `/Users/...` 文本。
- **因此当前 `C1` 的判读顺序必须先看“锚点覆盖范围”，再看 `pdt006_ngr_convert_call` 字段**：
  - 若尚未证明旧锚点覆盖范围成立，则 `pdt006_ngr_convert_patch status=installed` 不能推出 replacement 必然应有调用证据；
  - 若旧锚点覆盖范围成立但仍完全没有 `pdt006_ngr_convert_call`，才优先判断 failing path 根本未经过 replacement；
  - 若有 `pdt006_ngr_convert_call` 但 `matchesUsers=false` / `looksUtf16UsersPrefix=true`，优先怀疑 `x1` 形态与当前 UTF-8 `/Users/...` 假设不一致；
  - 若已有 `normalize-hit` 但 QtsFS 仍 fail，才把主分叉升级为 `RIPC-010-C2` 的 pre-`1c8` caller/helper state。
- **因此当前最该做的事不是泛化 `C1`，而是把它压缩成一条更窄的问题链**：
  1. failing `/Users/.../Saved/Paks/1/1.db` 有没有进入旧锚点 `0x10463f204` / `0x1000a4a08` 覆盖的 `ConvertToPlatformPath` 路径；
  2. 若有，`x1` 到达 replacement 时究竟是 UTF-8、UTF-16，还是别的结构；
  3. 只有在这两点已回答后，才讨论是否还需要新的 remap 或升级到 `C2`。
- `v5` 中仍有部分 `materializer` 记录呈现 `return_orphaned`，但它们当前不足以阻塞 `RIPC-010-C1/C2`。只有当验证后仍出现未闭合分叉时，才回到 `RIPC-010-B2` 做围绕缺失 path class / caller tuple 的定向补采。

### 产物与脚本索引

| 路径 | 说明 |
|---|---|
| `Scripts/ripc_010a_materializer_probe.py` | 真机 materializer / vcall LLDB probe |
| `Scripts/ripc_010a_real_ipad_lldb_driver.py` | 真机 attach + delayed injection driver |
| `LocalDocs/XCodeOperation/ripc_010a_xcode_debug_automation.py` | Xcode GUI 自动化协调脚本 |
| `build/ripc-010a-real-ipad-lldb-run-v5.json` | 当前稳定 run 摘要 |
| `build/ripc-010a-ipad-materializer-args-v5.json` | 当前稳定真机基线 |
| `build/ripc-010a-real-ipad-lldb-run-v4.json` | immediate injection 的 0-hit 对照样本 |
| `build/ripc-010a-real-ipad-lldb-run-v3.json` | 早期 stale-output 混淆样本 |
