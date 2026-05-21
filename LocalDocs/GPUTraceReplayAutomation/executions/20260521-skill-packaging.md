# Skill Packaging — gpu-trace-analysis

**执行时间**：2026-05-21 10:31–10:42
**任务**：用 skill-creator 把整个 GPUTraceReplayAutomation 的产出打包成一个独立的、自包含的、用于 gputrace 分析与渲染问题调查的 skill
**结论**：✅ 完成。skill 完全自包含，可在任意目录运行，端到端验证通过

---

## 1. 产出

skill 落在 `.codebuddy/skills/gpu-trace-analysis/`，结构：

```
gpu-trace-analysis/
├── SKILL.md                              # YAML frontmatter + 调查工作流
├── scripts/
│   ├── .gitignore                        # 排除构建产物
│   ├── Makefile                          # skill 内嵌构建配置
│   ├── gputrace_replay_bridge.m          # ObjC bridge 源码（拷贝自 Scripts/）
│   ├── gputrace_replay_wrapper.py        # Python wrapper（拷贝自 Scripts/）
│   ├── setup.sh                          # 幂等构建脚本（新增）
│   └── test_bridge.sh                    # 集成测试（拷贝自 Scripts/）
└── references/
    ├── cli-reference.md                  # 完整 CLI / Python API 参考
    ├── investigation-playbook.md         # 6 类常见渲染 bug 的调查模式
    └── architecture.md                   # 技术原理 + 故障恢复指南
```

总大小：3 个参考文档 ~36KB Markdown + 4 个脚本/源文件 ~80KB。

---

## 2. 关键设计决策

### 2.1 自包含性

skill 在编写时严格遵守"零外部依赖"原则：

- 所有源码、构建配置、测试脚本都拷贝（不是软链接）到 `scripts/`
- skill 内嵌的 Makefile 不引用 workspace 路径，只用相对路径和 `$(SCRIPT_DIR)`
- setup.sh 用 `cd "$(dirname "$0")"` 保证从任意目录调用都能正确定位
- Python wrapper 已设计为同目录搜索 binary，无需修改即可工作

**自包含验证**（关键的端到端测试）：
- 在 `/tmp` 下调用 `bash $SKILL_DIR/scripts/setup.sh` —— 从零构建成功
- 在 `/tmp` 下运行 `test_bridge.sh` —— 17/17 通过
- 在 `/tmp` 下用 wrapper replay 真实 trace —— 4 resources / 0.21ms 成功

### 2.2 Progressive disclosure

按 skill-creator 的三层加载模型：

| 层 | 内容 | 大小 |
|---|---|---|
| L1: Metadata | name + description（YAML frontmatter） | ~150 词 |
| L2: SKILL.md body | 工作流、首次设置、决策树、引用表 | 134 行 |
| L3: References | 详细 API、调查模式、技术原理 | 按需加载 |

### 2.3 Pushy description

description 显式枚举触发场景以对抗 LLM 的 undertriggering 倾向：

> "Use this skill whenever the user reports a rendering problem (black screen, missing geometry, wrong colors, broken material, flickering, shader issue, NaN output, validation error, GPU hang, performance regression) and provides or references a .gputrace file — even if they don't say 'replay' explicitly."

并明确指示在出现 .gputrace 路径、Xcode GPU capture、Metal frame debugger、AGX shaders 时主动触发。

### 2.4 工作流引导

SKILL.md 的核心是一个 5 步调查循环：

1. Establish a baseline（先确认 trace 自身能 replay）
2. Frame the question（按问题类型选择子命令的启发式表）
3. Drill down with the right subcommand
4. Iterate（数据驱动，不靠猜）
5. Report findings（具体 JSON 字段 + 复现命令 + 一段理论）

加 5 条 operational guardrails（read-only by default、Xcode 共存、平台限制、HW counters 出范围）。

### 2.5 投资在 references/ 上

3 个参考文档总计 ~1100 行，按"读时机"标注：

- `cli-reference.md`：何时需要精确 flag/JSON schema/Python API
- `investigation-playbook.md`：何时陷入选择困难，或需要 worked example —— 包含 6 类 bug 模式（black screen / 验证错误 / 错误材质 / 性能问题 / shader hot-replace / 双 trace 对比）
- `architecture.md`：何时需要推理 bridge 内部机制（macOS 升级后 binary 失效时的故障恢复指南）

---

## 3. 验证结果

| 验证项 | 结果 |
|---|---|
| skill 在 workspace 外的 /tmp 下完整构建 | ✅ |
| setup.sh stdout 输出 binary 绝对路径，stderr 出进度信息 | ✅ |
| help 子命令返回 5 commands JSON | ✅ |
| 集成测试套件 17/17 通过（无 GPUTRACE_PATH） | ✅ |
| Python wrapper 跑真实 trace 成功（4 resources / 0.21ms） | ✅ |
| 没有任何 skill 之外的路径依赖 | ✅ |

---

## 4. 下一步建议

如果用户希望对 skill 做更严格的质量评估，可以：

- 跑 skill-creator 的 evals 流程（编 2–3 个真实场景的 prompt，with-skill vs baseline 双跑，人评 + 量化断言）
- 跑 description optimization 流程（生成 20 条触发/不触发的 query，用 `claude -p` 自动迭代 description）

当前未跑，因为：
- 任务范围明确是"打包成 skill"，不是"质量调优"
- 完整的 evals 流程会涉及多个 subagent 并行运行实际的 .gputrace 调查，对 GPU 资源和 Xcode 状态有副作用
- 待用户后续提出明确需求时再触发
