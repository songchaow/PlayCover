## RIPC-003 真机启动行为基线采集

> **阅读建议**：本文档沉淀 RIPC-003 阶段的真机运行时上下文基线。
> 若只需知道真机侧已验证“无 `QtsFileSystem Create Failed`”以及关键路径/环境
> 差异，阅读 `00-Dashboard.md` 即可；当需要核查 iOS sandbox 具体返回值、
> entitlement、目录结构或与 `RIPC-010` 的真机 materializer 样本交叉验证时，
> 再展开本文。一般无需逐条通读全部表格。

### 采集方法

通过构建 `RIPCProbe.dylib`（Objective-C `__attribute__((constructor))` + 5s
延迟 `dispatch_after`），注入到重签名后的 NGR.app 中，使用 `insert_dylib`
工具添加 `LC_LOAD_DYLIB`，重新签名后部署到 iPad，通过
`xcrun devicectl device process launch --console` 捕获 NSLog 输出。

### 关键运行时上下文

所有数据以 `<UUID>` 代替实际沙盒 UUID。完整原始数据见
`build/ripc-003-ipad-baseline.json`。

#### 路径体系

| API | 真机 iPad 返回值 |
|---|---|
| `NSHomeDirectory()` | `/var/mobile/Containers/Data/Application/<UUID>` |
| `NSBundle.mainBundle.bundlePath` | `/private/var/containers/Bundle/Application/<UUID2>/NGR.app` |
| `NSBundle.mainBundle.executablePath` | `.../NGR.app/NGR` |
| `NSSearchPath(Documents)` | `/var/mobile/Containers/Data/Application/<UUID>/Documents` |
| `NSSearchPath(Library)` | `.../Library` |
| `NSSearchPath(Caches)` | `.../Library/Caches` |
| `NSSearchPath(AppSupport)` | `.../Library/Application Support` |
| `NSTemporaryDirectory()` | `/private/var/mobile/Containers/Data/Application/<UUID>/tmp/` |
| `getcwd()` | `/` |

注意：`/var/mobile` 与 `/private/var/mobile` 是 symlink 等价关系。

#### 环境变量（共 13 个）

| Key | Value |
|---|---|
| `CFFIXED_USER_HOME` | `/private/var/mobile/Containers/Data/Application/<UUID>` |
| `HOME` | `/private/var/mobile/Containers/Data/Application/<UUID>` |
| `TMPDIR` | `/private/var/mobile/Containers/Data/Application/<UUID>/tmp/` |
| `USER` | `mobile` |
| `LOGNAME` | `mobile` |
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin` |
| `SHELL` | `/bin/sh` |
| `TERM` | `xterm-256color` |
| `XPC_FLAGS` | `0x0` |
| `XPC_SERVICE_NAME` | `UIKitApplication:com.songdog.ripc.debug[aba0][rb-legacy]` |
| `__CF_USER_TEXT_ENCODING` | `0x1F5:0:0` |
| `MallocLargeCache` | `1` |
| `OSLogRateLimit` | `64` |

#### 可写性

| 路径 | 可写 |
|---|---|
| Home 目录本身 | **否** |
| Documents | 是 |
| Library | 是 |
| tmp | 是 |
| NSTemporaryDirectory | 是 |

#### stat 信息

| 路径 | uid | gid | mode |
|---|---|---|---|
| Home | 501 (mobile) | 501 | 40755 |
| Documents | 501 | 501 | 40755 |
| Library | 501 | 501 | 40755 |
| tmp | 501 | 501 | 40755 |
| Bundle (.app) | 33 (_www) | 33 | 40755 |

#### 沙盒目录结构

- **Home 根**: Documents, Library, SystemData, tmp,
  .com.apple.mobile_container_manager.metadata.plist
- **Documents**: NGRBigWorld, MGPA, bqLog, bqlog_mmap, ccs_config,
  tdm_track.dat, .qimei, logXAYY.log, ano_tmp
- **Library**: NGR, Engine, Caches, Preferences, Cookies,
  Application Support, HTTPStorages, WebKit, SplashBoard,
  Saved Application State, memory.cache, NotAllowedUnattendedBugReports

#### Entitlements

- `application-identifier`: `L7CZY6S98T.com.songdog.ripc.debug`
- `get-task-allow`: true
- `keychain-access-groups`: `L7CZY6S98T.*`

#### 启动行为确认

- **无 `QtsFileSystem Create Failed`**：真机启动成功，无此错误。
- UE4 引擎成功初始化，`LANDSCAPE mode` 正常。
- GCloud SDK、GPM、MSDK、CrashSight 等 SDK 均成功初始化。
- 唯一的 qts 相关错误是 `qts_paser_json.cpp:564 Failed to open file []`
  （空路径 hashcode 文件，非致命）和下载重试（正常网络行为）。

### 产物索引

| 文件 | 说明 |
|---|---|
| `build/ripc-003-ipad-baseline.json` | 结构化采集报告 |
| `build/ripc-003-probe-output.log` | Probe 原始 NSLog 输出 |
| `build/ripc-003-console-raw.log` | 完整控制台日志 |
| `build/ripc-003-probe/RIPCProbe.m` | Probe 源码 |
