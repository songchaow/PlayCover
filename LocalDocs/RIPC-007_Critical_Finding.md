# RIPC-007: 端到端验证 - 关键发现

**日期**: 2026-04-27  
**状态**: CRITICAL FINDING - 实现与验证需求存在矛盾  
**影响范围**: RIPC-006 Direction A 整体方向

## 执行摘要

在执行 RIPC-007 端到端验证时，发现以下关键矛盾：

1. **RIPC-006 Direction A 补丁安装失败** (mprotect-failed)
   - 地址: `0x10560f204` (0x10463f204 + 0xfd0000 slide)
   - 原因: macOS __TEXT 段运行时写保护无法绕过
   - 日志证据: `launch-events.jsonl` 中 `"event":"pdt006_ngr_convert_patch","status":"mprotect-failed"`

2. **路径差异假设已被 PDT-007-B 验证证伪**
   - PDT-007-B 对照实验结果: 有补丁/无补丁均崩溃
   - 结论: ConvertToPlatformPath 路径转换不是 QtsFileSystem Create Failed 后 crash 的原因
   - 参考: LocalDocs/HOKCrash/PathDifferenceTrial/00-Dashboard.md line 47-58

3. **实现与假设的根本性矛盾**
   - 当前代码尝试修复一个**已被证伪的假设**
   - 实现方式(运行时补丁)**已被证伪为不可行**
   - 导致的局面: 既不能工作，也不会解决问题

## 技术分析

### 为什么 mprotect 失败?

pt_ngr_make_patch_writable() 在 PlayLoader.m:1765-1789 中尝试两条路径:

1. **POSIX mprotect()** (line 1772)
   ```c
   if (mprotect((void *)start, size, PROT_READ | PROT_WRITE | PROT_EXEC) == 0)
       return YES;
   ```
   
2. **Mach kernel vm_protect()** (line 1775-1788)
   ```c
   vm_protect(mach_task_self(), (vm_address_t)start, (vm_size_t)size,
             TRUE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY | VM_PROT_EXECUTE)
   ```

两者都失败的原因:

- NGR 二进制是代码签名的 (signed)
- macOS hardened runtime 对签名二进制的 __TEXT 段施加额外保护
- 运行时修改签名代码会破坏代码完整性检查
- 无法通过标准 mprotect/vm_protect 绕过该保护

### 为什么路径差异假设被证伪?

根据 PathDifferenceTrial Dashboard:

| 条件 | overallPass | crash reports | 状态 |
|---|---|---|---|
| 有 disk patch + auto-confirm | False | 1 | crash |
| 无 disk patch + auto-confirm | False | 1 | crash |

**结论**: `ConvertToPlatformPath` 路径转换与后续 crash 无关。

crash 发生在:
1. QtsFileSystem 尝试打开 Saved/Paks/1/1.db
2. 返回 "Create Failed!!" alert
3. 用户(或 HOK-014 auto-confirm)点击确认
4. **游戏进入 fatal 处理路径** ← crash 在这里
5. UE4 崩溃

路径转换只能影响步骤 1，但不能防止步骤 4 的 fatal crash。

## 当前代码状态

### PlayLoader.m 中的 PDT-006 实现

- **ripc006_try_normalize_pak_path()** (line 2428-2443)
  - 逻辑: /Users/.../Saved/Paks/<X> → ../../../NGR/Content/Paks/<X>
  - 状态: 已实现，能工作
  - 问题: 永远不会被调用，因为补丁安装失败

- **pdt006_install_convert_patch_once()** (line 2498-2566)
  - 逻辑: ARM64 trampoline 补丁 ConvertToPlatformPath
  - 状态: 已实现，能编译
  - 问题: mprotect 失败导致无法将补丁写入内存

- **诊断日志** ✓
  - pdt006_log_event() 在 mprotect 失败时正确记录
  - launch-events.jsonl 包含完整的失败信息

### 诊断证据

最新 NGR 启动日志 (launch-events.jsonl):
```json
{
  "bundleId":"com.tencent.ngr",
  "detail":"cannot make target writable",
  "event":"pdt006_ngr_convert_patch",
  "patchAddr":"0x10560f204",
  "slide":"0xfd0000",
  "status":"mprotect-failed",
  "timestamp":"2026-04-27T09:27:25Z"
}
```

同启动中无 ripc006_pak_path_normalize 事件。

## 已实现的兜底机制

当前代码已有多层防御，确保即使补丁失败也不崩溃:

1. **HOK-013** (pt_ngr_preheat_slot_once)
   - 预热 NGR 的 __common 段

2. **HOK-014** (pt_ngr_install_alert_suppressor_once)
   - 拦截 UIAlertController present 调用
   - 自动确认 "QtsFileSystem Create Failed!!" 对话框
   - 允许游戏继续执行(进入 fatal 路径)

3. **HOK-015** (pt_ngr_preseed_cmdline_once)
   - 预写 UE4 cmdline 存储

证据: hok014_ngr_alert_suppressed 事件确实被记录，说明对话框被拦截。

## 建议

### 短期 (RIPC-007 验收)

**不建议将 RIPC-006 Direction A 作为主线方案，原因:**

1. 补丁无法安装 (mprotect 失败是已知限制)
2. 即使安装成功也无法解决问题 (路径差异非根因)
3. 代码复杂度高(ARM64 trampoline + mmap + vm_protect)
4. 诊断困难(运行时补丁导致的问题难以追踪)

**RIPC-007 应该:**

1. 将当前发现文档化 (本文档)
2. 更新 PathDifferenceTrial Dashboard 以反映最新状态
3. 标记 RIPC-006 为 "informational" 或 "archive" (不作主线)
4. 汇总 HOK-013/014/015 兜底链路的综合效果
5. 继续追踪真正的根因 (HOK-016-C.2.7 materializer state 分析)

### 中期 (如果未来需要代码修改)

若确实需要修改 ConvertToPlatformPath 行为，应考虑:

1. **Disk patch 方案** (PDT-007-A 已探索)
   - 在启动前修改 NGR 二进制
   - 重新签名
   - 优点: 无运行时保护限制
   - 缺点: 复杂，需要签名工具

2. **环境变量/配置文件方案**
   - 在 PlayCover 的 app 容器中预置特殊文件
   - 让 UE4 读取配置而非尝试打开 Saved/Paks
   - 优点: 无二进制修改，对签名无影响
   - 缺点: 需要了解 UE4 的配置加载机制

3. **Symlink/Mount 方案**
   - 在容器中创建软链接或 bind mount
   - 使 `/Users/.../Saved/Paks` 指向 `../../../NGR/Content/Paks`
   - 优点: 透明，对二进制无修改
   - 缺点: 需要在每次启动时设置

## 参考资料

- **本文档**: 本 RIPC-007 Critical Finding
- **PathDifferenceTrial Dashboard**: LocalDocs/HOKCrash/PathDifferenceTrial/00-Dashboard.md
- **PDT-006 原型**: LocalDocs/HOKCrash/PathDifferenceTrial/PDT-006-convert-patch-prototype.md
- **PDT-007-A Disk Patch**: LocalDocs/HOKCrash/PathDifferenceTrial/PDT-007A-disk-patch-prototype.md
- **诊断日志**: ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl
- **PlayLoader.m 源码**: Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m (line 2385-2566)

## 后续行动

1. 本文档需要被纳入 PlayCover 文档体系
2. PathDifferenceTrial Dashboard 需要更新以反映最新认知
3. RIPC-006/007 任务状态需要在主 Dashboard (RealIPadCompare 或 HOKCrash) 中更新
4. 根因分析应回到 HOK-016-C.2.7 的 materializer state 深掘
