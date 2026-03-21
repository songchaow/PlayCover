### T09 - Session 基础触控

## dashboard

- **任务编号**: `T09`
- **状态**: `已完成`
- **层级**: `Session MCP`
- **工作量**: `M`
- **推荐单次执行范围**: 一次 agent 执行完成 pointer 基础语义与最小触控闭环
- **依赖任务**: `T08`
- **主产物**:
  - `tap(x, y)`
  - `pointer_down(id, x, y)`
  - `pointer_move(id, x, y)`
  - `pointer_up(id, x, y)`
- **主要风险**:
  - 坐标系定义不清，导致后续手势全混乱
  - 直接跳到高级手势，导致基础 pointer 语义不稳定
- **不包含内容**:
  - `drag` / `swipe` / `pinch` / `thumbstick`
  - mode / overlay / keymap

---

## 前置阅读

执行前必须阅读：

1. `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
2. `LocalDocs/MCP/00-MCP-执行入口.md`
3. `LocalDocs/MCP/01-MCP-任务总表.md`
4. `LocalDocs/MCP/Tasks/T08-Session-Bridge与会话骨架.md`

---

## 背景与目标

PlayCover 已有完整的 fake touch 注入链路。  
本任务的目标不是再发明一套输入系统，而是把现有触摸注入能力整理成最基本、最稳定的 MCP 输入原语。

---

## 范围（In Scope）

- 暴露 `tap(x, y)`
- 暴露 `pointer_down(id, x, y)`
- 暴露 `pointer_move(id, x, y)`
- 暴露 `pointer_up(id, x, y)`
- 明确坐标语义
- 明确 pointer id / touch id 的最小管理策略
- 对越界坐标或非法参数进行结构化报错

---

## 明确不做（Out of Scope）

- 不实现复合手势编排器
- 不实现 `drag` / `swipe` / `pinch`
- 不实现摇杆或按钮抽象
- 不实现 mode / overlay / keymap 控制

---

## 主要代码入口

优先复用：

- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Toucher.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.m`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/Additions/UITouch-KIFAdditions.m`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/Additions/IOHIDEvent+KIF.m`
- 如有需要，可参考 `FakeMouseAction`

---

## 必须先定义清楚的内容

在实现前，请明确以下语义：

- 坐标使用哪套空间：
  - 逻辑屏幕坐标
  - 当前 window 内坐标
  - 是否以左上角为原点
- `tap(x, y)` 是否等价于：
  - down -> up 的快速组合
- `pointer_down/move/up` 的 `id` 是否直接映射到 touch id
- 当 `move/up` 找不到对应 id 时如何返回错误

如果这些语义不清楚，后续 `T10` 会很容易跑偏。

## 已落地语义约定

- 坐标空间使用 **当前 key `UIWindow` 坐标系**。
- 原点在 **左上角**，`x` 向右增长，`y` 向下增长。
- `tap(x, y)` 语义为：**`pointer_down` 后等待约 30ms，再执行 `pointer_up`**。
- `pointer_down/move/up` 的外部 `id` 由调用方提供，Session 层将其 **1:1 映射到内部 fake touch 状态**，直到 `pointer_up` 成功结束。
- 当 `pointer_move` 或 `pointer_up` 找不到对应 `id` 时，返回结构化 `preconditionFailed` 错误。
- 当坐标越过当前 key `UIWindow` 边界时，返回结构化 `invalidArguments` 错误。

---

## 完成标准

- `tap` 可通过 Session bridge 触发真实 touch 注入
- `pointer_down/move/up` 可形成稳定最小序列
- 坐标语义已在代码或文档中明确
- 基础 pointer 行为可被后续手势任务复用

---

## 给 agent 的执行提示

- 本任务优先交付“可靠原语”，而不是功能数量
- 坐标和 pointer id 语义请明确写在结果里
- 如果需要做少量适配层，优先包在 Session bridge 附近，不要大改底层 fake touch 实现

---

## 最后一步（必须执行）

在本任务相关修改完成后，最后必须补做一次提交收尾：

1. 检查本任务涉及的修改是否齐全
2. 将当前 task 的全部修改一起纳入本次提交，但不要混入其他 task 的无关变更：
   - 代码
   - 文档
   - 如有必要的配置 / 工程文件
3. 执行一次 `git commit`，为当前 task 形成独立提交
4. 提交信息建议包含任务编号，例如：
   - `T09: add session basic touch tools`
   - `T09: implement pointer primitives`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
