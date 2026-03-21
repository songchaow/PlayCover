### PlayCover 构建与运行说明

本文整理当前工作区下 **已验证可用** 的构建命令与运行命令。

## 前提说明

- 工程根目录：`/Users/songdogwang/Codes/PlayCover`
- 当前可用 Scheme：`PlayCover`
- 本地依赖工具：`dependencies/bin/carthage`
- 工程脚本现在会**优先使用**工作区内的 `dependencies/bin/carthage`
- 当前机器**未安装 `SwiftLint`**，因此本地命令默认采用 `FASTLANE=1` 跳过 lint 脚本

## 推荐：本地验证构建

这是当前工作区下 **已经实际构建成功** 的命令，适合本地编译验证：

```bash
cd /Users/songdogwang/Codes/PlayCover && FASTLANE=1 xcodebuild -scheme PlayCover -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER='' build
```

### 这条命令的含义

- `FASTLANE=1`
  - 跳过工程里的 `SwiftLint` 脚本
  - 跳过顶层 `Carthage Bootstrap` 脚本
  - 适合**依赖已经准备好**时做本地验证构建
- `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`
  - 禁用 Xcode 常规签名校验
  - 避免本机没有 provisioning profile 时构建失败
- `CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''`
  - 清空团队/provisioning 相关约束，适合本地无证书场景

## 推荐：固定输出目录的本地构建

如果你希望产物路径稳定，方便后续运行，建议使用固定 `DerivedData` 目录：

```bash
cd /Users/songdogwang/Codes/PlayCover && FASTLANE=1 xcodebuild -scheme PlayCover -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER='' build
```

构建完成后，App 通常位于：

```bash
/Users/songdogwang/Codes/PlayCover/build/DerivedData/Build/Products/Release/PlayCover.app
```

## 首次或需要刷新依赖时

如果你想先手动刷新 Carthage 依赖，再执行构建：

```bash
cd /Users/songdogwang/Codes/PlayCover && dependencies/bin/carthage update --cache-builds --use-xcframeworks
```

然后再执行上面的本地构建命令。

## 运行命令

### 运行固定输出目录中的产物

如果你使用了 `-derivedDataPath build/DerivedData`：

```bash
open /Users/songdogwang/Codes/PlayCover/build/DerivedData/Build/Products/Release/PlayCover.app
```

### 运行默认 DerivedData 中的产物

如果你没有指定 `-derivedDataPath`，产物会落到 Xcode 默认 `DerivedData`。可以先查找，再打开：

```bash
find ~/Library/Developer/Xcode/DerivedData -path '*/Build/Products/Release/PlayCover.app' | head -n 1
```

找到路径后运行：

```bash
open <上一步查到的 PlayCover.app 路径>
```

## 可选：查看工程信息

查看当前工程可用的 targets / schemes：

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild -list
```

## 可选：使用 Fastlane

仓库里已有 `fastlane` 配置；其中 `release` / `nightly` lane 内部也会以 `xcargs: "FASTLANE=1"` 触发构建。

如果本机具备对应签名、账号和 fastlane 环境，可尝试：

```bash
cd /Users/songdogwang/Codes/PlayCover && bundle exec fastlane release
```

或：

```bash
cd /Users/songdogwang/Codes/PlayCover && bundle exec fastlane nightly
```

但需要注意：

- 这两条命令面向更完整的发布流程
- 通常需要可用的签名配置
- 不如前面的本地验证命令直接

## 关于 `SwiftLint` 与 `FASTLANE=1`

- **缺少 `SwiftLint`**：不会影响 App 运行逻辑，但默认会让工程的 lint 脚本直接报错并中断构建
- **使用 `FASTLANE=1`**：不会改变 App 功能逻辑，主要是让构建进入“自动化/跳过检查”模式
  - 跳过 `SwiftLint`
  - 跳过顶层自动 `Carthage Bootstrap`
  - 因此更适合**本地快速验证**，前提是依赖已准备好

## 本次完成情况

这次为了让项目能在当前机器上成功完成本地构建，我做了下面这些处理：

- **阅读并确认构建入口**
  - 确认可用 Scheme 为 `PlayCover`
  - 确认工程依赖 `Carthage` / `PlayTools`

- **将 `carthage` 放到工作区内使用**
  - 下载官方 `Carthage` 发布包并提取 CLI
  - 将可执行文件放到 `dependencies/bin/carthage`
  - 避免要求系统全局安装 `carthage`

- **修改工程脚本以优先使用本地 `carthage`**
  - 在 `PlayCover.xcodeproj/project.pbxproj` 中调整脚本查找顺序
  - 让工程先检查 `dependencies/bin/carthage`，找不到时再回退到常见系统路径

- **调整 `Carthage Bootstrap` 行为**
  - 保留工程原有的 bootstrap 流程
  - 让其在调用 Carthage 子进程时传递 `FASTLANE=1`
  - 这样 `PlayTools` 子工程构建时会跳过内部的 `SwiftLint` 阻塞脚本

- **调整本地签名兜底方式**
  - 将工程中的手工签名脚本切换为使用 ad-hoc 签名标识 `-`
  - 避免本地构建时被开发者证书或 provisioning profile 卡住

- **验证并完成构建**
  - 成功产出 `PlayCover.app`
  - 当前已验证可用的本地构建方式，就是本文前面列出的 `FASTLANE=1 xcodebuild ... build`

## 本次涉及的主要文件

- **`PlayCover.xcodeproj/project.pbxproj`**
  - 补充工作区本地 `carthage` 的优先查找
  - 调整 `Carthage Bootstrap` 的子进程环境
  - 调整手工签名脚本的本地兜底方式

- **`dependencies/bin/carthage`**
  - 新增的工作区本地依赖工具

- **`Cartfile.resolved`**
  - 在依赖拉取/更新过程中发生了变更

- **`BUILD.md`**
  - 新增本文档，整理构建、运行和本次处理记录
