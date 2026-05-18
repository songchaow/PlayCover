## 根因确认：PlayLoader.m 被删除导致 PlayTools 运行时入口丢失

### 日期：2026-05-17 21:53

---

### 一、根本原因

**LYSK（以及所有注入了 PlayTools 的 app）不显示"已连接"状态和截帧按钮的根本原因是：`PlayLoader.m` 被从项目中删除了。**

`PlayLoader.m` 是 PlayTools.framework 的**唯一运行时入口文件**。它包含：

1. **`__attribute__((constructor)) initialize()`**——dyld 加载 PlayTools.framework 时自动执行的 constructor 函数，是整个 PlayTools 运行时的启动入口
2. **`[PlayCover launch]` 调用**——在 constructor 中调用，启动所有子系统（输入、屏幕、MetalCapture、BridgeListener 等）
3. **16 个 `DYLD_INTERPOSE` 宏**——hook 系统函数实现 iOS 平台伪装、设备型号伪造、Keychain 拦截、文件路径重定向等

文件被删除后：

| 子系统 | 影响 |
|--------|------|
| `[PlayCover launch]` | ❌ **永远不会被调用** |
| `BridgeListener.start()` | ❌ 不会启动 → runtime session 无法注册回 GUI |
| `RuntimeLaunchDiagnostics` | ❌ 不会记录任何诊断事件 |
| `MetalCaptureService.initialize()` | ❌ 不会初始化 |
| `PlayInput` / `PlayScreen` / `AKInterface` | ❌ 不会初始化 |
| iOS 平台伪装 (`dyld_get_active_platform`) | ❌ DYLD_INTERPOSE 丢失 |
| 设备型号伪造 (`uname` / `sysctl`) | ❌ DYLD_INTERPOSE 丢失 |
| Keychain 拦截 (`SecItem*`) | ❌ DYLD_INTERPOSE 丢失 |
| 文件路径重定向 (`open` / `stat` / `access`) | ❌ DYLD_INTERPOSE 丢失 |

当前仅存活的 constructor 是：
- `GuardedCapture.m` 的 `guardedCapture_earlyInit()` → 只安装 GPUToolsCapture 兼容 stub
- `PlayShadow.m` 的 `+load` → 只做反越狱检测 swizzle

这两个都**不会调用** `[PlayCover launch]`。

---

### 二、因果链

```
PlayLoader.m 从磁盘删除
  → 1954c7f3 把 pbxproj 引用也清掉（"Remove unused PlayLoader.m which cause compiling error"）
    → 编译通过，但 PlayTools.framework 中不再包含 initialize() constructor
      → dyld 加载 PlayTools 时不会执行 [PlayCover launch]
        → BridgeListener.start() 不会启动
          → runtime session 不会注册到 GUI 的 52741 端口
            → MCPManager.runtimeSessions 为空
              → sessionIndicatorStatus 不是 "ready"
                → CaptureButton 不显示
                → SessionIndicatorView 不显示"已连接"
```

---

### 三、删除经过

| 时间线 | 事件 |
|--------|------|
| commit `a87ebf07` | PlayLoader.m 最后一次在主仓库 git 中存在（2990 行） |
| 某次工作树操作 | PlayLoader.m 和 PlayLoader.h 从磁盘删除（未通过 git commit）。极可能是之前"把 PlayTools checkout 重新对齐到 Cartfile.resolved 锁定版本"时，checkout 操作重置了 PlayTools 目录，而 PlayLoader.m 是自定义增量（原始上游不含），所以被丢弃 |
| commit `1954c7f3` (2026-05-17 18:06) | 以 "Remove unused PlayLoader.m and PlayLoader.h which cause compiling error" 为由，从 `PlayTools.xcodeproj/project.pbxproj` 中清除了 PlayLoader.m/h 的 8 行引用。此后构建不再报错，但 PlayTools 运行时入口彻底丢失 |

关键 diff（`1954c7f3`）：
```diff
-  AA71970B287A44D200623C15 /* PlayLoader.m in Sources */
-  AA71970E287A44D200623C15 /* PlayLoader.h in Headers */
-  AA719702287A44D200623C15 /* PlayLoader.m */
-  AA719705287A44D200623C15 /* PlayLoader.h */
```

---

### 四、验证证据

1. **磁盘确认**：`ls Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.*` → `no matches found`
2. **Xcode 项目确认**：`grep PlayLoader project.pbxproj` → 0 结果
3. **Git 确认**：`git diff a87ebf07 HEAD -- .../PlayLoader.m` → `deleted file mode 100644`
4. **编译产物确认**：`otool -l` 检查 PlayTools.framework 中没有 `__mod_init_func` 段（只有 `__init_offsets` 对应 GuardedCapture 和 PlayShadow）
5. **运行时确认**：
   - 52741 端口无 LYSK 连接
   - 无 `RuntimeLaunchDiagnostics/com.papegames.lysk/` 目录
   - GUI 中不显示连接状态和截帧按钮

---

### 五、与交接文档假设的对应

交接文档§5.2 列出了 4 种可能原因：

> 1. `LYSK` 虽然加载了 `PlayTools.framework`，但没有真正执行到 `PlayCover.launch()`
> 2. `PlayCover.launch()` 进入了，但 `RuntimeLaunchDiagnostics` 没成功写盘
> 3. `BridgeListener.start()` 没触发，或很早就异常返回
> 4. 注册 listener 使用了不同 bundleId / 不同诊断路径

**答案是第 1 种，但原因比预想的更根本**——不是"某个条件分支绕过了 launch()"，而是**调用 `[PlayCover launch]` 的唯一代码（`PlayLoader.m` 的 constructor）整个被删除了**，所以 `launch()` 从未被调用。

---

### 六、修复方案

**恢复 `PlayLoader.m` 和 `PlayLoader.h` 到磁盘，并恢复 pbxproj 中的引用。**

具体步骤：

```bash
# 1. 从 git 历史恢复文件
cd /Users/songdogwang/Codes/PlayCover
git show a87ebf07:Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m \
  > Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m
git show a87ebf07:Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.h \
  > Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.h

# 2. 恢复 pbxproj 中的引用（revert 1954c7f3 对 pbxproj 的修改）
cd Carthage/Checkouts/PlayTools
git checkout 1954c7f3~1 -- PlayTools.xcodeproj/project.pbxproj

# 3. 重新构建并安装
cd /Users/songdogwang/Codes/PlayCover
# 使用标准构建脚本
```

恢复后，PlayTools.framework 将重新包含：
- `initialize()` constructor → dyld 加载时自动执行
- `[PlayCover launch]` 调用 → 启动所有子系统
- 16 个 `DYLD_INTERPOSE` → 恢复 iOS 平台伪装和系统 hook

---

### 七、一句话结论

> **`PlayLoader.m` 是 PlayTools 的唯一运行时入口（包含 constructor + `[PlayCover launch]` 调用 + 16 个 DYLD_INTERPOSE hook）。该文件在工作树对齐操作中从磁盘丢失后，commit `1954c7f3` 以"消除编译错误"为由把 Xcode 项目引用也删除了。这直接导致 PlayTools 被注入但不会初始化——BridgeListener 不启动、runtime session 不注册、GUI 自然不显示连接状态和截帧按钮。修复方法是从 git 历史（`a87ebf07`）恢复 PlayLoader.m/h 并还原 pbxproj 引用。**
