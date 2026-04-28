# LLDB 调试会话日志与关键输出

> 本文档记录了各次 LLDB 调试会话的关键输出，供后续参考。

## Session 1: CLI LLDB batch 模式（首次尝试）

**日期**：2026-04-28 ~19:37
**PID**：2423（非 start-stopped，已在主循环）

```
(lldb) device select 00008103-0011050A0E3B001E
(lldb) device process attach -p 2423
(lldb) command script import Scripts/ripc_010a_materializer_probe.py
[ripc-010a] WARNING: Could not resolve NGR slide; using 0
[ripc-010a] Materializer probe installed:
  Entry breakpoint: 0x10432a068 (slide=0x0)
  Return breakpoint: 0x10432a31c
(lldb) continue
error: Process must be launched.
```

**结论**：batch 模式下 `device process attach` 未完成就执行了后续命令。

---

## Session 2: pexpect + start-stopped（首次 slide 正确）

**日期**：2026-04-28 ~19:38
**PID**：2428, startStopped=True

```
Process 2428 stopped
* thread #1, stop reason = signal SIGSTOP
    frame #0: 0x0000000111efb0f0 dyld`_dyld_start

image list NGR:
[  0] 6249E7CD-DED6-3A79-BACA-8DAFFF80E837 0x00000001025a0000 NGR.app/NGR

[ripc-010a] Materializer probe installed:
  Entry breakpoint: 0x1068ca068 (slide=0x25a0000)
  Return breakpoint: 0x1068ca31c

Breakpoint list:
1: address = NGR[0x000000010432a068], locations = 1, resolved = 1, hit count = 0
  1.1: where = NGR`___lldb_unnamed_symbol_10432a068, address = 0x00000001068ca068, resolved, hit count = 0
2: address = NGR[0x000000010432a31c], locations = 1, resolved = 1, hit count = 0
  2.1: where = NGR`___lldb_unnamed_symbol_10432a068 + 692, address = 0x00000001068ca31c, resolved, hit count = 0
```

**120 秒后**：断点未命中。Continue 后 "Process 2428 resuming" 出现（确认 continue 生效）。

---

## Session 3: attach 到运行态进程 + objc_msgSend 验证

**日期**：2026-04-28 ~19:47
**PID**：2432, startStopped=True（但进程在 mach_msg2_trap）

```
Process 2432 stopped
* thread #1, stop reason = signal SIGSTOP
    frame #0: 0x0000000250290cd4 libsystem_kernel.dylib`mach_msg2_trap + 8

NGR at 0x000000010407c000, slide=0x407c000

Breakpoint 1: where = NGR`___lldb_unnamed_symbol_1002adfd4 + 148, address = 0x000000010432a068
Breakpoint 2: objc_msgSend — pending (no locations)

# Continue 后 objc_msgSend 断点命中！
BREAKPOINT HIT!
2.1
frame #0: 0x000000019e7b7400 libobjc.A.dylib`objc_msgSend
frame #1: 0x00000001dbe749fc libdispatch.dylib`dispatch_data_create_subrange + 260
```

**关键发现**：
- attach 到运行态进程时断点**可以**命中
- materializer 断点未命中是因为进程已过初始化阶段
- ⚠️ 断点设置在 unslid 地址 0x10432a068（未加 slide），解析到了错误位置

---

## Session 4: start-stopped + 5 分钟等待

**日期**：2026-04-28 ~19:52
**PID**：2437, startStopped=True

```
Process 2437 stopped
* thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGSTOP
    frame #0: 0x0000000250290cd4 libsystem_kernel.dylib`mach_msg2_trap + 8
```

⚠️ 虽然用了 `--start-stopped`，但进程不在 `_dyld_start` 而在主循环。
原因：之前未杀掉旧进程，devicectl 连到了旧实例。

**image list 显示 1265 个模块**（包含 RIPCProbe.framework），
确认进程已完全初始化。

---

## Session 5: start-stopped + 正确 _dyld_start + 5 分钟等待

**日期**：2026-04-28 ~19:58
**PID**：2445, startStopped=True

```
* thread #1, stop reason = signal SIGSTOP
  * frame #0: 0x000000011467f0f0 dyld`_dyld_start  ← ✓ 正确！

NGR load=0x102f3c000 slide=0x2f3c000

Probe loaded, slide=0x2f3c000
2 resolved breakpoint locations
Process running!

# 5 分钟后：
Process 2456 stopped
* thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGSTOP
    frame #0: 0x0000000250290cd4 libsystem_kernel.dylib`mach_msg2_trap + 8
```

**5 分钟后断点列表**：
```
1: address = NGR[0x000000010432a068], locations = 1
  1.1: where = NGR`___lldb_unnamed_symbol_10432a068, address = NGR[0x000000010432a068],
       unresolved, hit count = 0
```

★ **核心发现**：断点从 `resolved` 变为 `unresolved`！
dyld 完成链接后，之前设置的断点失效了。

---

## Session 6: 运行态 attach + 断点验证

**日期**：2026-04-28 ~20:15
**PID**：2456（已在主循环运行）

```
NGR load=0x102f3c000 slide=0x2f3c000

# 反汇编 materializer 地址：
NGR`___lldb_unnamed_symbol_10432a068:
    0x107266068 <+0>:  stp    x24, x23, [sp, #-0x40]!
    0x10726606c <+4>:  stp    x22, x21, [sp, #0x10]
    0x107266070 <+8>:  stp    x20, x19, [sp, #0x20]
    0x107266074 <+12>: stp    x29, x30, [sp, #0x30]
    0x107266078 <+16>: add    x29, sp, #0x30

# 断点设置：
1.1: where = NGR`___lldb_unnamed_symbol_10432a068, address = 0x0000000107266068,
     resolved, hit count = 0

# Image lookup:
Address: NGR[0x000000010432a068] (NGR.__TEXT.__text + 70410344)
Summary: NGR`___lldb_unnamed_symbol_10432a068
```

★ **确认**：代码确实存在于 materializer 地址，函数 prologue 正常。
断点在运行态下是 resolved 的。

---

## Session 7: 两阶段策略尝试

**日期**：2026-04-28 ~20:33
**PID**：2470, startStopped=True

**Phase 1**（在 dyld 之前设置 main/UIApplicationMain 断点）：
```
Breakpoint 1 (main): no locations (pending)
Breakpoint 2 (UIApplicationMain): no locations (pending)
Breakpoint 3 (_dyld_start): no locations (pending)
```

**Continue 后命中**（thread #3 at `__workq_kernreturn`）：
说明一个 pending 断点在 dyld 过程中 resolve 并命中了。

**Phase 2**（在命中后设置 materializer 断点）：
```
NGR load=0x104bc8000 slide=0x4bc8000
entry=0x108ef2068 return=0x108ef231c

4 resolved breakpoint locations
```

**5 分钟后**：断点仍未命中。hit counts 为空。

**分析**：Phase 1 命中的是 worker thread，不是 main thread。
materializer 在 main thread 的 UE4 初始化中调用。
5 分钟内 materializer 断点未命中，可能是：
- 断点在 dyld 过程中又变为了 unresolved
- 或 NGR 的 UE4 初始化在 5 分钟内还未到达 materializer 调用点

---

## 关键数据汇总

### NGR 模块 UUID（所有 session 一致）

```
6249E7CD-DED6-3A79-BACA-8DAFFF80E837
```

### ASLR Slide 历史记录

| Session | PID | Load Address | Slide |
|---|---|---|---|
| 2 | 2428 | 0x1025a0000 | 0x25a0000 |
| 3 | 2432 | 0x10407c000 | 0x407c000 |
| 5 | 2445 | 0x102f3c000 | 0x2f3c000 |
| 6 | 2456 | 0x102f3c000 | 0x2f3c000 |
| 7 | 2470 | 0x104bc8000 | 0x4bc8000 |

Slide 每次不同（ASLR 正常行为），但 UUID 始终一致。
