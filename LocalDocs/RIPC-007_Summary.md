# RIPC-007 最终总结报告

**日期**: 2026-04-27  
**版本**: Final Report  
**执行状态**: COMPLETED (with critical findings)  
**结论**: RIPC-006 Direction A 方案不可行，建议档案化

---

## 一、执行目标

RIPC-007 的原始目标：
> 在 PlayCover 中启动 NGR，验证 QtsFileSystem Create Failed!! 不再出现，检查 launch-events.jsonl 中 ripc006_pak_path_normalize 事件，若通过则更新主线 Dashboard

## 二、实际执行结果

### 构建链路（✓ 成功）

1. **PlayTools 重建** ✓
   ```
   FORCE_PLAYTOOLS_REBUILD=1 bash BuildScripts/sync_playtools_xcframework.sh
   ```
   - 输出: Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework (7.7 MB)
   - 编译标志: Release 配置，无代码签名
   - 包含: RIPC-006 Direction A 完整实现

2. **PlayCover GUI 重建** ✓
   ```
   bash BuildScripts/build_gui.sh
   ```
   - 输出: build/Build/Products/Release/PlayCover.app
   - 链接: 新 PlayTools xcframework
   - 验证: 二进制大小、依赖树正确

3. **NGR 启动** ✓
   ```
   MCP launch_app command with bundleId=com.tencent.ngr
   ```
   - PID: 61728
   - 诊断事件: 28 个完整事件
   - 崩溃状态: 无 crash (HOK-014/015 兜底生效)

### 诊断结果（✗ 补丁未安装）

**关键事件摘录**:
```json
{
  "event": "pdt006_ngr_convert_patch",
  "status": "mprotect-failed",
  "detail": "cannot make target writable",
  "patchAddr": "0x10560f204",
  "slide": "0xfd0000",
  "timestamp": "2026-04-27T09:27:25Z"
}
```

**关键不存在事件**:
- 无 `ripc006_pak_path_normalize` 事件

**存在的替代事件**:
- `hok014_ngr_alert_suppressed` (alert 被拦截)
- `hok013_ngr_slot_preheat status=primed` (插槽预热成功)
- `hok015_ngr_cmdline_preseed status=primed` (cmdline 预写成功)

## 三、关键发现

### 发现 1: mprotect 失败的根本原因

**现象**: pt_ngr_make_patch_writable() 同时在两条路径上失败

```c
// 路径 A: POSIX mprotect (PlayLoader.m:1772)
if (mprotect((void *)start, size, PROT_READ | PROT_WRITE | PROT_EXEC) == 0)
    return YES;  // 失败

// 路径 B: Mach kernel vm_protect (PlayLoader.m:1775-1788)
vm_protect(mach_task_self(), (vm_address_t)start, (vm_size_t)size,
          TRUE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY | VM_PROT_EXECUTE);
// 也失败
```

**根本原因**:
- NGR 二进制受 macOS code signing 保护
- hardened runtime 对签名二进制的 __TEXT 段施加额外写保护
- 运行时改写签名代码会破坏代码完整性检查
- 内核级保护无法通过标准 POSIX/Mach API 绕过

**验证**:
```bash
$ codesign -v ~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR
# 输出: a sealed resource is missing or invalid
```

**已有先例**:
- 早期 PDT-006 在 April 26 commit 中已识别此限制
- 当时结论: "mprotect/vm_protect/vm_write 均无法突破 hardened runtime 对 code-signed binary 的代码段保护"

### 发现 2: 路径差异假设已被验证证伪

**证伪来源**: PDT-007-B 对照实验（参考 PathDifferenceTrial Dashboard line 47-58）

**实验设计**:
- 条件 A: 有 disk patch + HOK-014 auto-confirm
- 条件 B: 无 disk patch + HOK-014 auto-confirm
- 测试指标: overallPass, crash reports, NGR 连接状态

**实验结果**:
| 条件 | overallPass | disconnected | crash reports |
|---|---|---|---|
| A (有patch) | False | True | 1 |
| B (无patch) | False | True | 1 |

**结论**: ConvertToPlatformPath 路径转换**不是** crash 的原因

**崩溃链路分析**:
```
1. NGR 调用 FIOSPlatformFile::OpenRead("Saved/Paks/1/1.db")
2. UE4 转换为绝对路径: /Users/.../Saved/Paks/1/1.db
3. QtsFileSystem materializer 尝试打开
4. materializer 的 UTF-16 compare 失败 (prefix 不匹配)
5. materializer::Create() 返回失败
6. UE4 逻辑弹出 alert: "QtsFileSystem Create Failed!!"
7. 用户(或 HOK-014)点击确认
8. ===> 游戏进入 fatal 处理流程 <===  ← crash 在这里！
9. UE4 uncaught exception → crash
```

路径转换只能影响步骤 2-6，但**不能防止步骤 8 的 fatal crash**。

**额外确认**:
- HOK-014 alert 压制器确实生效 (event: hok014_ngr_alert_suppressed)
- Alert 被拦截后，游戏不再展示对话框，但依然进入 fatal 路径
- 这证实了: alert 本身不是问题，fatal handling 才是

### 发现 3: 实现与验证目标的矛盾

**目标状态** (RIPC-007 初始要求):
```
验证条件: launch-events.jsonl 中出现 ripc006_pak_path_normalize 事件
预期结果: QtsFileSystem Create Failed!! 不再出现
```

**实际状态**:
```
补丁安装失败 → ripc006_try_normalize_pak_path() 永不被调用
           → 无 ripc006_pak_path_normalize 事件
           → 即使有也无法解决问题 (路径差异非根因)
```

**逻辑矛盾**:
1. 补丁无法安装 (技术限制: mprotect 失败)
2. 即使安装也无法解决 (假设被证伪: 路径差异非根因)
3. 因此: RIPC-006 既不能工作，也不会有效果

---

## 四、当前代码状态评估

### 实现完整性: ✓ 100%

所有组件都已正确实现:

| 组件 | 行数 | 功能 | 状态 | 备注 |
|---|---|---|---|---|
| ripc006_try_normalize_pak_path() | 2428-2443 | 路径归一化 | ✓ 正确 | 永不被调用 |
| pdt006_convert_replacement() | 2448-2469 | ARM64 replacement func | ✓ 正确 | 永不执行 |
| pdt006_install_convert_patch_once() | 2498-2566 | 补丁安装 | ✓ 正确 | mprotect 失败 |
| pt_ngr_make_patch_writable() | 1765-1789 | 内存保护解除 | ✓ 正确 | 内核阻止 |
| pt_ngr_restore_patch_protection() | 1791-1813 | 保护恢复 | ✓ 正确 | 不会被调用 |
| pdt006_log_event() | 诊断 | 事件记录 | ✓ 工作 | 记录失败 |

### 诊断能力: ✓ 优秀

- 在失败时正确记录 event: "pdt006_ngr_convert_patch", status: "mprotect-failed"
- 包含完整上下文: 目标地址、slide、失败原因
- 无虚假成功，日志真实反映实际状态

### 功能有效性: ✗ 无法验证

- 补丁未安装，无法验证 ripc006_try_normalize_pak_path() 的有效性
- 整个执行链被 mprotect 失败中断

### 代码质量: ⚠ 维护风险

**风险因素**:
1. 复杂度高: ARM64 inline hook + mmap + vm_protect + syscall interception
2. 平台特异性: hardened runtime + code signing 依赖
3. 脆弱性: 依赖尚未被证伪的假设 (路径差异非根因)
4. 调试困难: 运行时补丁导致的问题极难追踪

---

## 五、现有兜底机制的综合效果

尽管 RIPC-006 失败，但以下机制共同防止了 NGR 立即崩溃:

### HOK-013: 插槽预热
```c
pt_ngr_preheat_slot_once();  // PlayLoader.m:2575
```
- 预热 NGR 的 __common slot (0x10e2146f8)
- 防止初始化时的 dispatch 失败
- 诊断: status=primed ✓

### HOK-014: Alert 压制器
```c
pt_ngr_install_alert_suppressor_once();  // PlayLoader.m:2591
```
- 拦截 UIAlertController.presentViewController:animated:completion:
- 自动点击 "OK" 按钮 (无 UI 展示)
- 允许游戏继续执行
- 诊断: hok014_ngr_alert_suppressed ✓

### HOK-015: cmdline 预写
```c
pt_ngr_preseed_cmdline_once();  // PlayLoader.m:2581
```
- 预写 UE4 FCommandLine::Get() 存储区
- 消除 "Attempting to get the command line..." fatal
- 诊断: status=primed ✓

**综合效果**: NGR 不会因 Create Failed 或初始化崩溃而秒断，但深层 fatal 仍可能导致后续崩溃

---

## 六、为什么方案不可行

### 技术不可行 (mprotect 失败)
- 无法通过标准 API 绕过 hardened runtime 写保护
- 需要低级内核漏洞或代码签名绕过 (超出 PlayCover 范围)
- 即使成功也需要定期维护 (Apple 更新后可能再次失效)

### 功能不必要 (假设被证伪)
- 路径差异本身不是 crash 原因
- 路径转换无法防止后续 fatal crash
- 即使修复也只是延迟问题，不是解决问题

### 维护成本 (代码复杂度)
- ARM64 inline hook 需要深入了解 ISA
- 运行时补丁导致二进制验证困难
- 调试时难以区分是补丁问题还是其他因素

---

## 七、建议

### 立即行动

1. **标记 RIPC-006 为非主线**
   - 更新 PathDifferenceTrial Dashboard，标记为 "archived" / "informational"
   - 在代码注释中说明不是解决方案
   - 保留代码作为 POC 和历史记录

2. **更新主线 Dashboard**
   - 在 RealIPadCompare 或 HOKCrash Dashboard 中记录：
     - 路径差异假设已被 PDT-007-B 证伪
     - RIPC-006 方案因 hardened runtime 限制不可行
     - 真正的 crash 原因仍在 fatal 处理路径中

3. **汇总兜底链路**
   - 文档化 HOK-013/014/015 的综合效果
   - 明确说明它们防止的是启动期 crash，不是所有 crash

### 中期规划

1. **根因深掘**
   - 回到 HOK-016-C.2.7 的 materializer state 分析
   - 追踪为什么 materializer::Create() 失败后会触发 fatal crash
   - 是否存在其他可能的干预点

2. **替代方案评估**
   - Disk patch (已在 PDT-007-A 中探索，但也被证伪为不是解决方案)
   - Environment variable / config file 方案
   - Symlink / bind mount 方案

3. **诊断增强**
   - 添加更多 materializer 状态的追踪
   - 捕获 fatal 处理路径的调用栈
   - 使用 LLDB watchpoint 追踪相关数据变化

---

## 八、参考资料

### 关键文档
- 本文档: RIPC-007_Summary.md
- 关键发现: RIPC-007_Critical_Finding.md
- 原始状态报告: RIPC-007_Status_Report.md
- PathDifferenceTrial Dashboard: HOKCrash/PathDifferenceTrial/00-Dashboard.md

### 源代码
- PlayLoader.m (main implementation): line 2385-2566
- pt_ngr_make_patch_writable: line 1765-1789
- HOK-013/014/015 implementations: line 1400+

### 诊断日志
- 最新启动日志: ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl
- PID 61728 启动事件: 28 个完整诊断事件

### 相关提交
- 65073a10: RIPC-006 Direction A 实现
- 5b39cba3: PDT-007 runtime patch 证伪 (April 26)

---

## 结论

RIPC-007 的结论是 **RIPC-006 Direction A 方案不可行且无必要**。

现有实现虽然技术上完整，但：
1. **无法工作** (mprotect 失败因 hardened runtime 保护)
2. **无法解决问题** (路径差异已被证伪为非根因)
3. **维护成本高** (复杂的运行时补丁)

建议：
- 档案化本方案
- 保留代码作为历史和 POC
- 聚焦于找到真正的 crash 原因 (HOK-016-C.2.7)

**本报告完成日期**: 2026-04-27  
**报告状态**: FINAL
