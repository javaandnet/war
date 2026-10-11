---
kind: build_system
name: 多端构建系统：XcodeGen + Swift Package + Node.js 脚本
category: build_system
scope:
    - '**'
source_files:
    - war/ios/project.yml
    - war/ios/WarKit/Package.swift
    - war/ios/tools/smoke.sh
    - war/ios/.smoke-build/meter.sh
    - war/ios/tools/Meter/main.swift
    - war/war/package.json
---

## 1. 使用的构建系统与工具

仓库包含两个独立的可编译产物，分别使用不同的构建体系：

- **iOS 端**：Swift Package Manager (SPM) + XcodeGen。`WarKit` 是纯逻辑的 Swift Package（含 `Package.swift`），`War` 是 iPhone App，通过 `project.yml` 由 XcodeGen 生成 `War.xcodeproj`。
- **JS 原型端**：Node.js 原生运行，零依赖；通过 `package.json` 中的 `scripts` 提供测试与语法检查命令。

没有发现 Dockerfile、Makefile、CI 配置文件（如 GitHub Actions / `.github/workflows`）或跨平台交叉编译脚本。

## 2. 关键文件

- `war/ios/project.yml` — XcodeGen 工程描述，定义 target、包依赖、bundle ID、部署目标 iOS 17.0、Swift 5.9、签名团队等。
- `war/ios/WarKit/Package.swift` — WarKit Swift Package 清单（无 UI 的规则与 AI 内核）。
- `war/ios/tools/smoke.sh` — 无头冒烟脚本：在 macOS 上直接 `swiftc` 编译 App 逻辑层 + `tools/Smoke/main.swift` 入口，链接已 build 的 WarKit release 产物。
- `war/ios/.smoke-build/meter.sh` — 量尺（tuning）脚本：编译 `tools/Meter/main.swift` 并执行多局对战统计。
- `war/war/package.json` — JS 端的 npm scripts：`test`、`start`、`check`。

## 3. 架构与约定

### 3.1 iOS 构建分层

`project.yml` 明确约定两层结构：
- `WarKit/` — 纯逻辑内核（Swift Package，零 UI 依赖），规则、AI、回归测试都在此。
- `War/` — iPhone App 外壳（SpriteKit 棋盘 + SwiftUI 面板），只通过公开 API 消费 WarKit。

这种分层使得 AI 决策逻辑可在 macOS 上通过 `swift test` 直接验证，无需启动 iOS 模拟器。

### 3.2 XcodeGen 生成流程

注释写明：`brew install xcodegen && cd ios && xcodegen generate`。生成的 `War.xcodeproj` 不应手改，所有工程配置集中在 `project.yml`。

### 3.3 无头冒烟与量尺工具

- `tools/smoke.sh` 绕过 `xcodebuild test`（因为本机可能没装 iOS 模拟器运行时，下载需十几 GB），改用 `swiftc -O -swift-version 5 -target ${ARCH}-apple-macosx14.0` 直接编译 macOS 可执行文件，仅包含 `BoardFrame`、`GameSettings`、`GameStore`、`Wallet`、`PowerPolicy`、`Theme` 以及 `tools/Smoke/main.swift`。
- `tools/Meter/main.swift` 是临时量尺工具（注释标注“不入库”），用于整局对局的收敛性、施流量、难度单调性、成长节奏分析。
- `.smoke-build/meter.sh` 与 `tools/smoke.sh` 风格一致：先 `cd WarKit && swift build -c release`，再用 `swiftc` 链接 `-lWarKit`。

### 3.4 JS 端构建

`war/war/package.json` 中 `private: true`，声明为私有包；`scripts.check` 逐个对 `config.js item.js field.js ai.js game.js` 执行 `node --check` 做语法检查；`scripts.test` 运行 `tests/kernel.test.mjs`；`scripts.start` 用 `serve` 启动本地静态服务器。

## 4. 约定与约束

- **版本管理**：iOS 应用版本号来自 `project.yml` 中的 `MARKETING_VERSION: "0.2.0"` 与 `CURRENT_PROJECT_VERSION: "1"`，并通过 `CFBundleShortVersionString: $(MARKETING_VERSION)` 注入 Info.plist；JS 端版本在 `war/war/package.json` 中为 `0.2.0`，两端版本同步。
- **部署目标**：iOS 最低版本锁定为 17.0（`deploymentTarget.iOS: "17.0"`），Swift 语言级别为 5.9。
- **并发模型**：`SWIFT_STRICT_CONCURRENCY: minimal`，因内核大量 struct 值类型 + 少量引用类型，暂不开严格并发。
- **设备限定**：`TARGETED_DEVICE_FAMILY: "1"` 限定 iPhone 独占，iPad 不在目标范围。
- **后台行为**：`UIRequiresFullScreen: true`，`UISupportedInterfaceOrientations` 支持竖屏与横屏左右，`UIBackgroundModes: []` 禁止后台音频以避免系统持续唤醒省电。
- **构建入口**：iOS 侧通过 `sh tools/smoke.sh` 进行无头冒烟，通过 `sh .smoke-build/meter.sh [N]` 运行量尺（默认 20 局）；JS 侧通过 `npm test` / `npm run check`。
- **无 CI/容器化**：仓库未发现任何 CI 流水线或 Docker 配置，构建仅在开发者本地 macOS 环境执行。

## 5. 缺失项

仓库未包含以下构建系统常见工件：Makefile、Dockerfile、GitHub Actions / GitLab CI 配置、发布脚本、跨平台交叉编译配置。因此该类别的证据强度为 **medium**——存在明确的本地构建脚本与工程描述，但缺乏自动化流水线与容器化支撑。