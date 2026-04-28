# LLDB Device 调试命令速查表

## 设备管理

```bash
# 列出设备
xcrun xctrace list devices

# 查询 App 是否安装
ios-deploy --list_bundle_id -i <UDID> | grep <bundle-id>
```

## 进程管理

```bash
# 启动 App（普通）
xcrun devicectl device process launch \
    --device <UDID> \
    --json-output /tmp/launch.json \
    <bundle-id>

# 启动 App（挂起模式，等待调试器）
xcrun devicectl device process launch \
    --device <UDID> \
    --start-stopped \
    --json-output /tmp/launch.json \
    <bundle-id>

# 杀掉 App
xcrun devicectl device process terminate \
    --device <UDID> \
    --pid <PID> --kill

# 获取 PID
python3 -c "import json; d=json.load(open('/tmp/launch.json')); \
    print(d['result']['process']['processIdentifier'])"
```

## LLDB 基本操作

```bash
# 启动 LLDB
xcrun lldb

# 选择设备
(lldb) device select <UDID>

# 附加到进程
(lldb) device process attach -p <PID>
(lldb) device process attach --name NGR --waitfor

# 查看模块列表
(lldb) image list
(lldb) image list NGR

# 查看 slide
# image list 输出中: 0x<LOAD_ADDR> → slide = LOAD_ADDR - 0x100000000

# 查看当前位置
(lldb) thread backtrace
(lldb) frame info

# 断点操作
(lldb) breakpoint set -a 0x<address>         # 地址断点
(lldb) breakpoint set -n <function_name>      # 函数名断点
(lldb) breakpoint list                         # 列出断点
(lldb) breakpoint delete <id>                  # 删除断点
(lldb) breakpoint delete -f                    # 删除所有断点

# 执行控制
(lldb) continue                                # 继续运行
(lldb) process interrupt                       # 中断（不用 Ctrl-C！）
(lldb) step                                    # 单步进入
(lldb) next                                    # 单步跳过
(lldb) finish                                  # 跳出当前函数

# 加载 Python 脚本
(lldb) command script import /path/to/script.py

# 反汇编
(lldb) disassemble -s 0x<address> -c 10

# 查看内存
(lldb) memory read 0x<address> -c 32
(lldb) x/32bx 0x<address>

# 查看寄存器
(lldb) register read
(lldb) register read x0 x1 x2

# 退出
(lldb) detach
(lldb) quit
```

## NGR 专用地址

| 名称 | Unslid 地址 | 说明 |
|---|---|---|
| Materializer entry | `0x10432A068` | QtsFileSystem materializer 入口 |
| Materializer return | `0x10432A31C` | materializer 返回点 (entry + 0x2B4) |
| __TEXT base | `0x100000000` | NGR 二进制基址 |

**运行时地址 = Unslid 地址 + ASLR Slide**

## 常用 Python 表达式 (LLDB)

```python
# 获取 slide
script target = lldb.debugger.GetSelectedTarget(); \
    m = [m for m in target.modules if m.GetFileSpec().GetFilename() == "NGR"][0]; \
    print(f"slide=0x{m.FindSection('__TEXT').GetLoadAddress(target) - 0x100000000:x}")

# 读取寄存器
script frame = lldb.debugger.GetSelectedTarget().GetProcess().GetSelectedThread().GetSelectedFrame(); \
    print(f"x0=0x{frame.FindRegister('x0').GetValue():s}")

# 读取内存字符串
script proc = lldb.debugger.GetSelectedTarget().GetProcess(); \
    err = lldb.SBError(); \
    raw = proc.ReadMemory(0xADDR, 64, err); \
    print(raw.split(b'\\x00')[0].decode('utf-8', errors='replace'))
```
