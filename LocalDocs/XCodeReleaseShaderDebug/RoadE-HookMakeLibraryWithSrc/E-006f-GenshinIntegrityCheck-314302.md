## E-006f：`原神` 进入游戏后 `31-4302` 完整性异常

## 状态：TODO（当前最高优先级）

> ⚠️ **这是当前最高优先级、且直接影响 Road E 最终落地的 blocker。** `E-006c` 已经证明登录前 / 基础 capture 阶段的源码可见链路可打通；现在的问题是：**当真正进入游戏后，原神会提示“数据异常，请完全卸载游戏，并从官方渠道重新下载安装”“错误码：31-4302”**，高度怀疑与 hook / replacement 的副作用有关。

## 问题定义

当前待解问题是：

- app：`原神`
- bundleId：`com.miHoYo.Yuanshen`
- 当前安装版本：`6.4.0`
- 现象：完成“进入游戏”后，出现：
  - `数据异常，请完全卸载游戏，并从官方渠道重新下载安装`
  - `错误码：31-4302`

这条线的关键点，不是“登录前能否看到源码”，而是**进入游戏后的完整性 / 反篡改检测**。

## 当前已知事实

### 1. 现有 Road E 基线主要覆盖登录前 / capture 阶段

当前仓库里已经有的稳定结论包括：

- `.gputrace` 源码可见链路已打通（`E-006c` 已完成阶段性里程碑）
- `ShaderCorpus` / replay / compile / diff 主回路已建立
- `launch_app -> create_session` 已具备自动化条件

但这些都**不能直接回答**“进入游戏后为什么触发 `31-4302`”。

### 2. 当前仓库中还没有 `31-4302` 的现成定位记录

在本仓库范围内，当前没有现成的：

- `31-4302` 字符串命中结果
- 对应二进制位置
- 对应调用栈 / 检测点结论

因此这条线必须从**最小自动化复现路径 + replacement `off/on` 对照**重新开始；只有当这两步仍不足以定位时，才升级到静态定位分支，而不能假设旧文档已经给出答案。

### 3. “进入游戏”这一步本身可以自动化到较轻的程度

当前 PlayCover MCP / runtime 输入能力已具备：

- `launch_app`
- `create_session`
- `tap`
- `swipe`
- `press_key`

因此：

- **进入登录/开始界面后点一下屏幕** 这类轻量操作，默认可视为 agent 可独立完成
- 但**直接对已安装 app bundle 做工作区外的 `strings` / `otool` / 反汇编分析**，不是默认日常 gate；若要正式执行，需要用户确认

## 当前优先假设（按排查顺序）

1. **最优先假设：replacement 产物或 replacement 行为被原神检测到**
   - 若 replacement `off` 时不报错，而 replacement `on` 时报错，说明问题更接近 replacement 副作用
2. **第二假设：hook / injected runtime 痕迹被检测到**
   - 即使不 replacement，只要 hook 装上或 runtime 痕迹仍在，就可能触发完整性校验
3. **第三假设：`31-4302` 与服务端校验联动，客户端只是展示错误**
   - 这时本地二进制仍可能包含错误码和分发逻辑，但真正触发条件需要通过对照实验判断

## 推荐的最小自动化复现路径

> 目标：先把“进入游戏后触发问题”稳定成 agent 可重复执行的最小步骤。

### 固定前提

- 必须使用标准脚本构建 / 安装：

```bash
./BuildScripts/build_and_install.sh
```

- 不要手写 `xcodebuild`
- 不要手工复制 `.app`

### 最小自动化步骤

1. `launch_app(bundleId=com.miHoYo.Yuanshen)`
2. `create_session(bundleId=com.miHoYo.Yuanshen)`
3. 在 `create_session` 返回 `ready` 后固定等待数秒，作为“登录 / 开始界面稳定”的默认判定窗口
4. 对屏幕中心执行 **1 次** `tap`
5. 若 session 仍存活，且 `RuntimeLaunchDiagnostics` / 运行时日志没有产生新的自动化信号，再在短等待后**最多补第 2 次** `tap`
6. 记录当前设置组合（至少区分 replacement `off/on`）、`tap` 次数、`processLaunchId`、session 状态与任何新增运行时日志

**注意**：现阶段“是否真的弹出 `31-4302` 文案”的视觉确认，不应成为日常 gate。日常推进应优先依赖：

- replacement `off/on` 对照
- `tap` 前后 session 是否断开、进程是否退出、`RuntimeLaunchDiagnostics` 是否出现新的异常模式
- `RuntimeLaunchDiagnostics`、session 状态与运行时日志的自动化结果

若当前一轮执行后**没有形成稳定的自动化信号**，只能把结论记为“进入游戏触发路径尚未稳定 / 尚未建立自动判定能力”，**不得**直接把“没看到弹窗”解释成“没有 `31-4302`”。

二进制 / 字符串静态定位仅属于**升级路径**，不属于当前日常默认 gate；只有在 `E-006f1` + `E-006f3` 仍不足以定位，且用户已确认可以做工作区外分析时，才进入该分支。

## 推荐的静态定位路径

> ⚠️ **这是一条专项分支，不属于当前日常默认 gate。** 只有在 `E-006f1` 的最小自动化触发与 `E-006f3` 的 replacement `off/on` 对照仍不足以定位，且用户已确认可以做工作区外分析时，才进入这条路径。
>
> 目标：尽快找到“谁负责抛出 / 分发 `31-4302`”。

### 第一层：字符串与资源定位

优先查找以下目标：

- `31-4302`
- `314302`
- `数据异常，请完全卸载游戏，并从官方渠道重新下载安装`
- 该中文提示的短片段

优先排查位置：

1. 主可执行文件
2. app 内附带的动态库 / framework
3. 本地化字符串资源 / 文本资源包

### 第二层：xref / 调用链定位

若字符串命中后，下一步要分清：

- 这是**本地直接构造的错误提示**
- 还是**服务端返回码被本地映射成文案**

重点要找：

- 哪个函数读取了该字符串 / 错误码
- 哪个条件分支决定弹出该错误
- 它依赖的是本地完整性检查结果、网络返回、还是两者结合

### 第三层：与 replacement 对照合并判断

静态定位结果必须和下面的动态对照合并看：

| Case | `metalCaptureEnabled` | `shaderSourceReplacementEnabled` | 目的 |
|---|---|---|---|
| A | false | false | 纯基线 |
| B | true | false | 看 hook / capture 痕迹是否足以触发 |
| C | true | true | 当前问题态 |

若后续需要进一步隔离“hook 已安装但不做 replacement”与“真正发生 replacement”的差异，可在代码侧补更细粒度开关，但在当前阶段，`B` vs `C` 已足够先判断大方向。

## 当前 TODO 拆分

> 补充说明：虽然编号上 `E-006f2` 早于 `E-006f3`，但 `E-006f2` 是需要用户确认的工作区外专项分支；默认执行顺序仍为 **`E-006f1 -> E-006f3 -> E-006f2 -> E-006f4`**。

| # | 子任务 | 状态 | 说明 |
|---|---|---|---|
| E-006f1 | 自动化“进入游戏”最小触发路径（`launch_app -> create_session -> tap`） | TODO（先做） | 先把问题稳定成可重复的最小 live 序列，并固化 `processLaunchId / tapCount / sessionAlive / processAlive / runtime diagnostics delta` 这组最小自动化证据；只有建立了至少一种**不依赖人工看弹窗**的自动判定信号后，才进入 `E-006f3` 的 replacement `off/on` 对照 |
| E-006f3 | 做 replacement `off/on` 对照，判断触发点更接近 hook 痕迹还是 replacement 副作用 | TODO（默认第二步） | 先用最小设置矩阵缩小问题面，不默认进入工作区外分析 |
| E-006f2 | 在原神二进制 / 资源中定位 `31-4302` / 对应字符串与引用链 | TODO（专项分支，执行前需用户确认工作区外分析） | 仅在 `E-006f1` + `E-006f3` 仍不足以定位时启用 |
| E-006f4 | 设计并验证绕过方案：检测点 patch / selective bypass / 保持截帧有效的替代方案 | TODO | 目标是“保住 Road E”，不是简单关功能绕过 |

## 候选解决方向

### 方向 A：定位检测点后做定点 patch / bypass

思路：

- 找到触发 `31-4302` 的本地条件分支
- 定点 patch 返回值、错误码或弹窗分发路径

优点：

- 一旦定位准确，往往是最直接的解决方法

风险：

- 需要足够明确的静态定位结果
- 若属于服务端联动校验，仅 patch 本地提示未必足够

### 方向 B：尽量让 app 看不到 replacement 带来的可观测变化

思路：

- 研究是否能在**保留截帧 / attribution 有效**的前提下，减少 app 可见的 replacement 痕迹
- 例如：只为 capture / attribution 保留 shadow 路径，而执行仍尽量返回 original library（需验证是否可行）

优点：

- 如果 `31-4302` 真由 replacement 副作用触发，这条线可能比 patch 更稳

风险：

- 需要确认不会把 Road E 退化成“表面有源码，实际没替换价值”

### 方向 C：选择性旁路

思路：

- 对特定 bundle / selector / module key 暂时绕开最敏感的 replacement 路径
- 仅在确认为少量热点点位时考虑

优点：

- 工程上落地快，可先恢复大部分能力

风险：

- 只是折中方案；必须明确哪些 shader / 场景因此失去源码 attribution 或替换能力

## 关单标准

满足以下条件后，`E-006f` 才可视为完成：

1. `原神` 在“进入游戏”后不再出现 `31-4302`
2. 解决方案明确解释了：到底是 hook 痕迹、replacement 副作用、还是完整性检测点本身导致的问题
3. Road E 的最终目标仍被保留：不能简单退化为“关闭 replacement 才能正常进游戏”
4. 日常复测仍可由 agent 独立完成到“启动 -> 进入游戏触发 -> 记录结果”的程度；若涉及工作区外静态分析或二进制 patch 落地，需要用户单独确认

## 参考锚点

- `README-MCP.md`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`
- `Scripts/runtime_launch_diagnostics_summary.py`
- `00-Dashboard.md`
