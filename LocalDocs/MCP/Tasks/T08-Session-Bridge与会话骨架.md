### T08 - Session Bridge 与会话骨架

## dashboard

- **任务编号**: `T08`
- **状态**: `已完成`
- **层级**: `Session MCP`
- **工作量**: `M-L`
- **推荐单次执行范围**: 一次 agent 执行完成 injected 层最小远程桥接骨架与 `session_status()` 首版
- **依赖任务**: `T01`
- **主产物**:
  - Session bridge 入口
  - Session 工具注册与分发骨架
  - Session 请求 / 响应结构
  - 基础会话标识与状态结构
  - `session_status()` 首版
- **主要风险**:
  - 直接把全部输入能力一口气做完，导致任务失控
  - 在宿主层强行实现 injected 能力
- **不包含内容**:
  - 具体 `tap` / `drag` / `pinch`
  - mode / keymap / overlay 工具

---

## 前置阅读

执行前必须阅读：

1. `LocalDocs/MCP/PlayCover-MCP-调研结论.md`
2. `LocalDocs/MCP/00-MCP-执行入口.md`
3. `LocalDocs/MCP/01-MCP-任务总表.md`
4. `LocalDocs/MCP/Tasks/T01-Host-骨架与协议.md`

---

## 背景与目标

Session 能力的关键不在于功能本身，而在于：这些功能天然发生在 injected 的目标 app 进程里。  
所以必须先建立一个最小 Session Bridge，后续 `tap`、`drag`、`session_set_mode` 才有稳定的远程调用入口。

---

## 范围（In Scope）

- 在 injected `PlayTools` 侧建立一个最小远程调用入口
- 定义 Session 工具的请求 / 响应结构
- 定义会话标识（session id）与基础状态结构
- 暴露 `session_status()` 首版
- 为后续 `T09-T11` 提供稳定注册点与调用路径

---

## 明确不做（Out of Scope）

- 不在本任务内实现 `tap`
- 不在本任务内实现 `drag` / `pinch` / `thumbstick`
- 不在本任务内实现 mode / overlay / keymap 切换
- 不在本任务内做 Host-Session 自动发现的最终收口（放到 `T12`）

---

## 主要代码入口

优先关注：

- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PlayInput.swift`
- `Carthage/Checkouts/PlayTools/AKPlugin.swift`

---

## 设计目标

本任务至少要解决：

- Session 工具入口放在哪里
- 请求如何路由到具体能力
- 返回结构如何统一
- Session 如何描述自身基础状态

建议 `session_status()` 首版包含：

- `session_id`
- `bundle_id`（如果方便）
- `mode`（如能读取）
- `has_key_window`
- `window_frame`（best-effort）
- `playtools_loaded`
- `warnings`

---

## 建议实现策略

- 做一个尽量薄的 Session bridge
- 先把调用入口和统一结果做通
- 只放 1 个或极少数真实工具验证通路，例如 `session_status()`
- 不要为了通信方式过度设计，如果现阶段只需要最小内部桥即可接受

---

## 完成标准

- injected 层已有明确的 Session 工具入口
- `session_status()` 可返回结构化结果
- 后续 `T09-T11` 不需要重新发明 Session 协议层
- 代码边界仍清楚：输入能力尚未在本任务内铺开

---

## 给 agent 的执行提示

- 本任务最关键的是“稳定桥接点”，不是“功能数量”
- 若要在通信方式上做取舍，优先选择最小可工作方案
- 保证后续任务调用路径自然，不要把所有逻辑塞进一个超大文件

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
   - `T08: add session bridge skeleton`
   - `T08: scaffold session status tool`

除非上层明确要求不要提交，否则不要把本任务留在“已改未提交”状态交付给下一位 agent。
