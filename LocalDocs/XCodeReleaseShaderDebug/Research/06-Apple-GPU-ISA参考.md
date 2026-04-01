# 06 - Apple GPU ISA 参考（G13/M1 架构）

> 来源: dougallj/applegpu 逆向工程文档，可能有误

## 一、执行模型

- **SIMD-group** = 32 个线程（Metal 术语中的 thread）
- 每个 SIMD-group 有独立的: 栈指针(sp), 程序计数器(pc), 32位执行掩码(exec_mask)
- 最多 128 个通用寄存器

## 二、寄存器

| 寄存器 | 宽度 | 说明 |
|---|---|---|
| `r0-r127` | 32-bit | 通用寄存器 |
| `r0l-r127l` | 16-bit | 低半字 |
| `r0h-r127h` | 16-bit | 高半字 |
| `u0-u255` | 32-bit | 统一寄存器（跨线程共享） |
| `r0l` | 特殊 | 执行掩码栈跟踪 |
| `r1` | 特殊 | 链接寄存器 |

## 三、指令集分类

### 算术
| 指令 | 说明 |
|---|---|
| `IADD` | 整数加减（支持饱和、移位） |
| `IMADD` | 整数乘加 |
| `FADD` / `FADD16` | 浮点加（32/16位） |
| `FMUL` / `FMUL16` | 浮点乘 |
| `FMADD` / `FMADD16` | 浮点乘加 |
| `RCP` | 倒数 |
| `RSQRT` | 平方根倒数 |
| `SIN_PT_1/2` | 正弦（分段） |
| `LOG2` / `EXP2` | 对数/指数 |
| `DFDX` / `DFDY` | 偏导数 |

### 位操作
| 指令 | 说明 |
|---|---|
| `BFI` | 位域插入 |
| `BFEIL` | 位域提取 |
| `BITOP` | 可编程逻辑运算 |
| `POPCOUNT` | 计数1的个数 |

### 流控
| 指令 | 说明 |
|---|---|
| `RET` / `STOP` | 返回/停止 |
| `CALL` | 调用 |
| `JMP_EXEC_ANY` | 条件跳转（任意线程活跃） |
| `IF_ICMP` / `IF_FCMP` | 条件 if |
| `WHILE_ICMP` | 条件循环 |
| `POP_EXEC` | 弹出执行掩码栈 |

### 内存
| 指令 | 说明 |
|---|---|
| `DEVICE_LOAD/STORE` | 设备内存读写 |
| `THREADGROUP_LOAD/STORE` | 线程组共享内存 |
| `TEXTURE_SAMPLE` | 纹理采样 |
| `TEXTURE_LOAD` | 纹理加载 |
| `LD_TILE` / `ST_TILE` | 瓦片内存 |
| `LD_VAR` | 变量加载（插值） |
| `UNIFORM_STORE` | 统一寄存器存储 |

### SIMD
| 指令 | 说明 |
|---|---|
| `SIMD_SHUFFLE` | 组内数据重排 |
| `ICMP_BALLOT` | 比较投票（32位掩码） |

## 四、编码特点

- 变长编码：2-12 字节，2字节对齐
- 小端序
- L位（长/短编码切换）

## 五、反汇编输出示例

```asm
compute shader prolog:
   0: 0e01881900000000     isub             r0, u4, 1
   8: c500a03d00803000     uniform_store    2, i16, pair, 0, r0l_r0h, 10
  10: 8800                 stop

compute shader:
   0: f2091004             get_sr           r2.cache, sr80 (thread_position_in_grid.x)
   4: f20d1204             get_sr           r3.cache, sr82 (thread_position_in_grid.z)
   8: 3800                 wait             0
   a: 38418c4800000000     device_load      0, i32, pair, r3, [u2+r2], 0, unsigned, lsl 1
  12: 38018c0800000000     device_load      0, i32, pair, r1, [u0+r2], 0, unsigned, lsl 1
  1a: 3800                 wait             0
  1c: 0e218e0400000000     iadd             r0, r3, r1
  24: 72018c8800000000     device_store     0, i32, pair, [u4+r2], r0, 0, unsigned, lsl 1
  2c: 8800                 stop
```
