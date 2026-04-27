# RIPC-007 文档索引与快速导航

**最后更新**: 2026-04-27  
**RIPC-007 状态**: ✓ COMPLETED (with critical findings)  
**验证结论**: RIPC-006 Direction A 方案不可行

---

## 一、快速摘要 (2 分钟读完)

**问题**: 验证 RIPC-006 Direction A (ConvertToPlatformPath 路径归一化补丁) 是否有效

**答案**: ❌ 不可行，原因两重：
1. **技术失败**: mprotect 无法绕过 macOS hardened runtime 对签名代码的写保护
2. **功能无用**: 路径差异假设已被 PDT-007-B 验证证伪，补丁无法防止后续 fatal crash

**诊断证据**:
```json
{"event":"pdt006_ngr_convert_patch","status":"mprotect-failed","detail":"cannot make target writable"}
```

**结论**: 档案化本方案，聚焦于找到真正的 crash 根因

---

## 二、文档导航

### 根据目的快速找文档

#### 🎯 "我需要快速了解 RIPC-007 的结论"
→ 读 **RIPC-007_Summary.md** (第一部分 "执行目标" 到 "关键发现")
预计时间: 15 分钟

#### 🔍 "我需要理解为什么 mprotect 失败"
→ 读 **RIPC-007_Critical_Finding.md** (第二部分 "技术分析" → "为什么 mprotect 失败?")
预计时间: 10 分钟

#### 📊 "我需要看完整的验证过程和诊断数据"
→ 按顺序读:
1. RIPC-007_Summary.md (第二部分 "实际执行结果")
2. RIPC-007_Status_Report.md (完整验证细节)
预计时间: 30 分钟

#### 🏗️ "我需要了解代码实现"
→ 读:
1. **RIPC-007_Critical_Finding.md** (第一部分 "当前代码状态")
2. PlayLoader.m:
   - ripc006_try_normalize_pak_path(): line 2428-2443
   - pdt006_install_convert_patch_once(): line 2498-2566
   - pt_ngr_make_patch_writable(): line 1765-1789
预计时间: 20 分钟

#### 🚀 "我需要看路径差异假设为什么被证伪"
→ 读:
1. **RIPC-007_Critical_Finding.md** (第二部分 "为什么路径差异假设被证伪?")
2. PathDifferenceTrial/00-Dashboard.md (line 47-58)
预计时间: 15 分钟

---

## 三、文档清单

### 本 RIPC-007 文档组

| 文档 | 篇幅 | 用途 | 何时读 |
|---|---|---|---|
| **RIPC-007_INDEX.md** (本文) | 2 页 | 导航 | 开始前必读 |
| **RIPC-007_Summary.md** | 8 页 | 完整总结 | 了解全貌 |
| **RIPC-007_Critical_Finding.md** | 5 页 | 关键矛盾 | 理解技术细节 |
| **RIPC-007_Status_Report.md** | 6 页 | 验证细节 | 需要诊断数据 |

### 相关上游文档

| 文档 | 位置 | 用途 | 关系 |
|---|---|---|---|
| PathDifferenceTrial Dashboard | HOKCrash/PathDifferenceTrial/00-Dashboard.md | 假设证伪的原始证据 | 必读背景 |
| PDT-006 Prototype | HOKCrash/PathDifferenceTrial/PDT-006-*.md | Runtime patch 原型 | 可选深掘 |
| PDT-007-B 对照实验 | HOKCrash/PathDifferenceTrial/PDT-007B-*.md | 假设证伪详细过程 | 可选深掘 |

---

## 四、核心概念速查

### 为什么 mprotect 失败?

**链路**:
```
NGR 二进制 → code-signed → hardened runtime protection
                        ↓
                 macOS kernel
                        ↓
            __TEXT segment = write-protected
                        ↓
        mprotect(PROT_WRITE|PROT_EXEC) → FAILED
           vm_protect(VM_PROT_WRITE|...) → FAILED
                        ↓
        补丁无法写入，pdt006_convert_replacement 永不执行
```

### 为什么路径差异假设被证伪?

**对照实验**:
```
条件 A: 有 disk patch + HOK-014 auto-confirm → crash (overallPass=False)
条件 B: 无 disk patch + HOK-014 auto-confirm → crash (overallPass=False)

结论: path transformation 与 crash 无关
      crash 发生在 fatal handling path，不在 ConvertToPlatformPath
```

### 什么是兜底链路?

**当前生效的防御**:
1. **HOK-013**: 预热 NGR __common slot → 防止初始化 dispatch 失败
2. **HOK-014**: 拦截 UIAlertController → 自动确认 "QtsFileSystem Create Failed!!" 对话框
3. **HOK-015**: 预写 cmdline 存储 → 消除 "Attempting to get command line" fatal

**综合效果**: NGR 不因启动期错误立即崩溃，但深层 fatal 仍可导致后续崩溃

---

## 五、关键数据点

### 诊断日志位置
```
~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl
```

### 最新诊断事件 (PID 61728)
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

### 地址计算
```
target = PDT006_CONVERT_FUNC_UNSLID + slide
       = 0x10463f204 + 0xfd0000
       = 0x10560f204
```

### NGR 路径信息
```
Binary: ~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR
重建后符号: /Users/songdogwang/Codes/PlayCover/Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework
```

### 代码实现位置
```
File: Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m
Components:
  - ripc006_try_normalize_pak_path(): line 2428-2443
  - pdt006_convert_replacement(): line 2448-2469
  - pdt006_install_convert_patch_once(): line 2498-2566
  - pt_ngr_make_patch_writable(): line 1765-1789
```

---

## 六、关键提交

| Hash | 日期 | 内容 | 状态 |
|---|---|---|---|
| 65073a10 | Apr 27 10:15 | RIPC-006 Direction A: normalize pak-path | 已合并，不可行 |
| 5b39cba3 | Apr 26 18:39 | PDT-007: runtime patch 证伪 | 历史背景 |
| 360876aa | Apr 27 11:30 | docs(RIPC-007): Critical finding | 本次验证 |
| 8a4006c2 | Apr 27 11:35 | docs(RIPC-007): Summary report | 本次验证 |

---

## 七、建议行动列表

### ✅ 立即执行

- [ ] 读完 RIPC-007_Summary.md
- [ ] 确认对 mprotect 失败原因的理解
- [ ] 确认对路径差异假设被证伪的理解
- [ ] 决定是否档案化 RIPC-006 代码

### ⏱️ 本周执行

- [ ] 更新 PathDifferenceTrial Dashboard 标记本方案为 "archived"
- [ ] 在代码中添加注释说明 PDT-006 为何不作主线
- [ ] 汇总 HOK-013/014/015 兜底链路的文档

### 📋 后续规划

- [ ] 回到 HOK-016-C.2.7 的 materializer state 分析
- [ ] 评估替代方案 (env var / config file / symlink)
- [ ] 增强诊断能力 (更多 materializer 追踪)

---

## 八、常见问题

**Q: 为什么代码已经合并了还说不可行?**

A: RIPC-006 是在 Apr 27 10:15 合并的，而我们的发现是在 Apr 27 11:00+ 完成验证时发现的。时间非常接近。合并时可能还没有进行完整的端到端验证。

**Q: 能否通过其他方式绕过 mprotect 失败?**

A: 理论上可以尝试：
1. Kernel exploit / vulnerability (超出 PlayCover 范围)
2. Disable code signing enforcement (安全风险)
3. Disk patch 方式修改二进制 (已在 PDT-007-A 探索，但也不解决问题)

现实中都不可行。

**Q: HOK-014 alert suppressor 既然能工作，为什么还说 RIPC-006 不可行?**

A: HOK-014 确实有效，它拦截了对话框。但问题不在对话框本身，而在对话框后面的 fatal crash。HOK-014 不能阻止 fatal，只能延迟。

**Q: 路径差异假设被证伪是什么意思?**

A: 指通过受控实验 (with patch / without patch) 证明了路径差异与 crash 无直接因果关系。即使完美修复路径问题，crash 仍然会发生。

**Q: 那下一步应该做什么?**

A: 继续深掘真正的 crash 原因。根据诊断，crash 发生在 materializer::Create() 返回失败后的 fatal handling path。需要追踪为什么 UE4 在这条路上选择 fatal 而不是其他处理。

---

## 九、相关资源

### 内部
- PlayLoader.m 源代码
- launch-events.jsonl 诊断日志
- PathDifferenceTrial Dashboard

### 外部参考
- [macOS hardened runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Code signing on macOS](https://developer.apple.com/support/code-signing/)
- [Mach kernel vm_protect API](https://apple.github.io/darwin-xnu/)

---

## 十、文档版本历史

| 版本 | 日期 | 变更 | 作者 |
|---|---|---|---|
| 1.0 | 2026-04-27 | 初始完成 | Claude |

---

**本索引最后更新**: 2026-04-27  
**预计阅读时间**: 5-30 分钟 (根据详细程度选择)  
**下一步**: 选择上面第二部分的相应文档开始阅读
