---
kind: dependency_management
name: 双语言依赖管理：Swift Package Manager + 零依赖 Node.js
category: dependency_management
scope:
    - '**'
source_files:
    - war/ios/WarKit/Package.swift
    - war/war/package.json
---

## 1. 使用的系统/方法

仓库包含两个独立的前端实现，各自采用不同的依赖管理策略：

- **iOS/Swift 侧**：使用 Swift Package Manager（SPM），通过 `war/ios/WarKit/Package.swift` 声明包。工具链版本锁定为 `swift-tools-version:5.9`，目标平台限定 `.iOS(.v17)` 与 `.macOS(.14)`。
- **JS 原型侧**：`war/war/package.json` 明确标注 `"private": true` 且描述为「纯前端，零依赖」——没有 `dependencies` / `devDependencies` 字段，所有运行时逻辑直接以原生 JS 模块（`config.js`、`field.js`、`ai.js`、`game.js`、`item.js`）组织，不引入任何 npm 包。

## 2. 关键文件

- `war/ios/WarKit/Package.swift`：WarKit Swift Package 的 SPM 清单，定义 product `WarKit`、target `WarKit` 与测试 target `WarKitTests`。
- `war/war/package.json`：仅用于脚本入口（`test`、`start`、`check`），无第三方依赖声明。
- `war/ios/project.yml`：Xcode 工程配置（由 XcodeGen 生成），引用 WarKit 作为子包。

## 3. 架构与约定

- **内核与 UI 解耦**：`Package.swift` 的注释明确说明 WarKit 是「零 UI 依赖（不 import SpriteKit / UIKit）」，因此可在 macOS 上直接 `swift test` 跑回归测试，无需模拟器；同时被 iPhone App target 复用同一份规则与 AI 决策逻辑。
- **JS 侧零依赖设计**：`package.json` 的 `description` 写明「AI 内核无 DOM 依赖，可直接移植到 iOS/Swift」，JS 原型与 Swift 实现共享同一套战棋规则语义，但通过完全独立的代码库（JS 原型 vs Swift 移植）维护。
- **无 vendoring / 私有注册表**：未发现 `vendor/`、`Pods/`、`Carthage/`、`.swiftpm/configuration/` 中的私有源配置或 lockfile（如 `Package.resolved`、`yarn.lock`、`package-lock.json`）。SPM 依赖解析结果未随仓提交。

## 4. 约定与约束

- **SPM 工具链版本固定**：`Package.swift` 首行 `// swift-tools-version:5.9` 强制构建时使用 Swift 5.9 工具链。
- **平台下限固定**：`platforms: [.iOS(.v17), .macOS(.14)]` 在包清单中声明最低支持版本。
- **JS 项目禁止发布**：`package.json` 中 `"private": true` 阻止 `npm publish`。
- **JS 侧无第三方依赖**：`package.json` 不含 `dependencies` / `devDependencies`，`scripts.start` 通过 `npx --yes serve` 临时拉取静态服务器，而非将其列为依赖。
- **语法检查脚本**：`scripts.check` 对 `config.js item.js field.js ai.js game.js` 逐个执行 `node --check`，作为 JS 源码的轻量 lint 约束。
- **测试入口**：JS 侧通过 `node tests/kernel.test.mjs` 运行内核回归测试；Swift 侧通过 SPM 的 `tests` target 运行 `WarKitTests`。

## 5. 观察到的缺失

- 未见任何私有 registry / GOPRIVATE / NPM_TOKEN 等认证配置。
- 未见依赖升级自动化（如 Dependabot、Renovate）配置文件。
- 未见锁文件（`Package.resolved`、`yarn.lock`、`package-lock.json`）随仓提交，依赖版本处于可浮动状态。