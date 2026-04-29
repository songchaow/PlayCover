## RIPC-010 真机 materializer 采集与双端对比

> **阅读建议**：本文档沉淀 RIPC-010 阶段长期有效的采集方法、关键证据、
> 调试经验与对比口径。若只需了解当前主线与最高优先级，阅读
> `00-Dashboard.md` 即可；当需要复用真机 LLDB 采集、核查 `v5` 产物、
> 或继续推进 `RIPC-010-B / RIPC-010-C` 时再展开本文。一般无需逐条回看
> 历史会话。

### 当前稳定结论

- `RIPC-010-A4` **已打通**，不再是阻塞项。早先“dyld 完成后断点变为
  unresolved”是真实现象，但它描述的是一种早期调试姿势失效，不代表
  materializer 在真机上不可采集。
- 当前稳定真机基线是：
  - `build/ripc-010a-real-ipad-lldb-run-v5.json`
  - `build/ripc-010a-ipad-materializer-args-v5.json`
- `v5` 基线的关键结果：
  - `preInjectDelay = 5`
  - `recordCount = 71`
  - `materializer complete = 15`
- 真机 `x1` **不能再假定为 Pascal-like 小对象**；实测经常直接指向 path
  string buffer。probe 现在必须先尝试 **direct UTF-8 / UTF-16**，再回退到
  旧的 Pascal 结构解码。
- 真机成功路径已经确认包含两类 `entry_x1_text`：
  - iOS sandbox absolute path：
    `/var/mobile/.../Library/NGR/Saved/Paks/1/1_0.db`
  - UE4 relative pak path：`../../../NGR/Content/Paks/1/1_0.db`
- 因此当前待解释的问题已经从“真机到底是相对路径还是绝对路径”收紧为：
  **PlayCover failing `/Users/.../Saved/Paks/...` path class 及其 caller /
  helper state，与真机 accepted path classes 到底差在哪一层。**

### A4 从“阻塞”到“打通”的最小结论链

#### `v3`：0-hit，但仍混有 stale artifact 风险

- 现象：只看到断点安装，`recordCount = 0`。
- 问题：当时 probe JSON / log 仍可能复用共享默认路径，不能完全排除旧产物
  被误读为新结果。
- 阅读建议：只在需要复盘“为什么当时会误判为 blocked”时按需读取；一般无
  需读取。

#### `v4`：artifact isolation 后，证明 immediate injection 确实会 miss window

- 现象：per-run artifact isolation 补齐后，`preInjectDelay = 0` 仍是
  `recordCount = 0`。
- 结论：这次 0-hit 是**真实结果**，而不是旧 JSON 混入导致的假阴性。
- 阅读建议：需要论证“为什么默认值必须是 delayed injection”时按需读取；
  一般无需读取。

#### `v5`：延迟注入 + 新解码口径后，形成稳定真机基线

- 使用 `--pre-inject-delay 5` 后，真机稳定抓到 materializer 相关记录。
- 关键产物：
  - `build/ripc-010a-real-ipad-lldb-run-v5.json`
  - `build/ripc-010a-ipad-materializer-args-v5.json`
- 这轮结果足以支撑 `RIPC-010-B`，不应再把“能否采到 materializer”当作
  当前主问题。
- 阅读建议：**当前主线涉及 `RIPC-010-B / RIPC-010-C` 时总是建议读取。**

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
  3. **return semantics**（至少比较 nullability / downstream side effects，
     而不是执着于精确指针值）

### 当前最重要的工作：`RIPC-010-B`

#### `RIPC-010-B1` 已完成的矩阵结论

`build/ripc-010b-diff.json` 已落盘，当前矩阵按 **path class / caller tuple /
return semantics** 汇总后的稳定结论如下：

1. **真机 accepted path classes 已闭合**
   - iOS absolute Saved/Paks：`/var/mobile/.../Library/NGR/Saved/Paks/...`
   - UE4 relative pak：`../../../NGR/Content/Paks/...`
   - 两类在真机 `v5` 中都对应 non-null materializer return，说明问题不能再表述成
     “绝对路径 vs 相对路径”。
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
   - caller-side 语义：`materializer return = 0`、`helper+0x18 = 0`、
     `x30=0x100122f88`、`errValue=0x9000b`
4. **post-`1c8` pair 不是当前主分叉解释**
   - `HOK-016-C.2.7` 已表明 observed success / fail hits 在 post-`1c8` 读到同一组
     pair；剩余机制差异更像是 pre-`1c8` compare / caller-helper state。

#### `B1` 对决策的直接含义

- **可操作结论**：当前证据已足够把默认主线从“继续补采”切到
  **`RIPC-010-C` 修复方向选择**。
- **默认优先修复方向**：对 `com.tencent.ngr` 做 **bundle-scoped
  iOS-semantic path remap / normalization**，只处理
  `/Users/.../Saved/Paks/...` 这一稳定 failing class。
- **残余不确定性**：矩阵仍未证明“只有 path text 一项差异”；更准确的说法是：
  **path class 已足以支撑修复优先级，而 pre-`1c8` caller/helper state`
  仍是机制层面的 residual uncertainty。**
- **因此 `B2` 不再是默认下一步**：只有当 `RIPC-010-C` 的 remap / normalization
  方案失败，或暴露出新的未闭合 path class / caller tuple 时，才回到定向补采。

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
2. Attach 到真机进程后，不要执着于“越早越好”；当前默认做法是先让进程运行
   到 NGR 模块装载可见，再做 delayed injection。
3. Debug Console 中导入 probe：
   `command script import /Users/songdogwang/Codes/PlayCover/Scripts/ripc_010a_materializer_probe.py`
4. Address breakpoint 仍必须通过 LLDB 命令设置；Breakpoint Navigator 的 `+`
   菜单没有 Address Breakpoint。

### 长期有效的调试经验

- **先杀旧进程再重启**：否则 `--start-stopped` 可能连到旧实例，导致对启动期
  所在阶段的判断失真。
- **不要用 Ctrl-C 杀 LLDB**：若需中断，优先用 `process interrupt`。
- **检查时间戳，不只看文件存在性**：判断一次运行是否真的生成了新结果，至少要
  同时看路径、修改时间与 `recordCount`。
- **zero-hit 不等于 target path 不存在**：可能是 timing miss、decoder 错、
  stale output 或 target 确实未执行，必须逐项排除。
- **优先用 module-relative identity 做比较**：避免把某次 session 的 runtime
  address 当成稳定锚点。
- **不要过拟合 `_dyld_start`**：对当前任务来说，“早到 dyld”不是目标，
  “稳定拿到 materializer 的真实参数”才是目标。

### 当前仍待闭合的问题

- `RIPC-010-B1` 已经落盘为 `build/ripc-010b-diff.json`，当前不再缺“统一 diff”；
  剩余问题转为：**bundle-scoped iOS-semantic path remap / normalization**
  是否足以消除 `/Users/.../Saved/Paks/...` 这条稳定 failing class。
- `v5` 中仍有部分 `materializer` 记录呈现 `return_orphaned`，但它们当前不足以阻塞
  `RIPC-010-C`。只有当修复验证后仍出现未闭合分叉时，才回到 `RIPC-010-B2`
  做围绕缺失 path class / caller tuple 的定向补采。

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
