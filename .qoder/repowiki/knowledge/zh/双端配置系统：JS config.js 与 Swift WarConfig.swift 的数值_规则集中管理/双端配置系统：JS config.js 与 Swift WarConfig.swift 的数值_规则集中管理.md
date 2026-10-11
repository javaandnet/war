---
kind: configuration_system
name: 双端配置系统：JS config.js 与 Swift WarConfig.swift 的数值/规则集中管理
category: configuration_system
scope:
    - '**'
source_files:
    - war/war/config.js
    - war/ios/WarKit/Sources/WarKit/WarConfig.swift
    - war/ios/project.yml
    - war/war/package.json
---

## 1. 采用的方式

仓库没有使用任何外部配置框架（无 `.env`、`application.properties`、YAML/TOML 解析器）。配置以**硬编码常量**的形式直接写在源码中，分为两个平行的实现：
- JS 原型：`war/war/config.js` 导出 `WarConfig` 对象与 `SeededRng`。
- iOS 内核：`war/ios/WarKit/Sources/WarKit/WarConfig.swift` 暴露 `public enum WarConfig`。

构建期配置通过 XcodeGen 的 `project.yml` 声明 bundle id、版本号、部署目标等；Swift Package 由 `war/ios/WarKit/Package.swift` 描述。运行时不加载外部配置文件。

## 2. 关键文件

- `war/war/config.js` — JS 侧唯一权威配置源（棋盘、地形、兵种、难度、评分权重、归一化标尺、默认编队）。
- `war/ios/WarKit/Sources/WarKit/WarConfig.swift` — Swift 侧等价定义，是 WarKit 公共 API 的一部分。
- `war/ios/project.yml` — XcodeGen 工程描述（bundle id、iOS 版本、target/device family、plist properties）。
- `war/ios/WarKit/Package.swift` — Swift Package 清单。
- `war/war/package.json` — Node 脚本入口（`test`、`start`、`check`），不含依赖。
- `war/war/index.html` / `war/war/game.js` — JS 原型运行时引用 `config.js`。
- `war/ios/War/Model/GameSettings.swift`、`war/ios/War/UI/SettingsView.swift` — UI 层读取 `WarConfig` 展示设置项。

## 3. 架构与设计约定

### 3.1 单一权威源（Single Source of Truth）
两处配置的注释明确表达同一原则：
- JS："所有数值只在这里出现一次，AI 与规则层不再各写一份，避免'三套难度 = 三份算法'"。
- Swift："数值与规则的唯一权威定义处（对应 JS 原型 config.js）。调参只改这里"。

这意味着新增/修改兵种、地形、难度档位、AI 权重时，需要同时维护 JS 与 Swift 两份副本，以保持双端一致。

### 3.2 配置结构映射
| 概念 | JS (`config.js`) | Swift (`WarConfig.swift`) |
|---|---|---|
| 棋盘尺寸 | `board.width/height` | `BoardSize` + `boardSizes` + `defaultBoard` |
| 地形 | `terrain` 字典 | `Terrain` struct + `terrains` 字典 + `terrainOrder` |
| 兵种 | `unitTypes` | `UnitStat` + `unitTypes` + `unitTypeOrder` |
| 难度 | `difficulty` 四档 | `Difficulty` struct + `difficulties` + `difficultyOrder` |
| AI 权重 | `weights` 对象 | `Weights` struct + `weights` 实例 |
| 归一化标尺 | `scale` 对象 | `Scale` struct + `scale` 实例 |
| 默认编队 | `defaultRoster` | `defaultRoster` |

### 3.3 难度模型：正交旋钮而非多套算法
JS 注释明确说明难度不再是"换一套打分逻辑"，而是同一打分函数下的三个正交旋钮：`temperature`（softmax 随机度）、`lookahead`（前瞻步数）、`vision`（视野范围）。Swift 在此基础上扩展为四个旋钮，并加入 `budget`（军费）和 `spellLevel`（敌方首领魔法等级）。

### 3.4 确定性随机性
JS 提供 `SeededRng`（mulberry32），注释要求 "AI 决策与地形生成都必须走这里，禁止再用 Math.random()"。Swift 侧在关卡规格 `LevelSpec` 中以 `terrainSeed`、`aiSeed` 字段固化地图与 AI 采样流，确保闯关关卡可复现。

### 3.5 纯函数派生值
Swift 侧对随时间/升级变化的数值不提供可变字段，而是通过纯函数计算：
- `unitStat(typeKey, upgrades)` 按三条独立升级线（atk/def/hp）返回新 `UnitStat`。
- `spellStat(key, level)` 按等级缩放威力/射程。
- `campaignLevel(n)` 将关数 n 映射为 `LevelSpec`（难度、敌军升级、seed、魔法等级）。
- `upgradeCost` / `spellUpgradeCost` 返回 Int.max 作为"买不起"信号，调用方据此拒绝。

### 3.6 构建期配置
`project.yml` 通过 XcodeGen 生成 `War.xcodeproj`，声明：
- `bundleIdPrefix: com.war`
- `deploymentTarget.iOS: "17.0"`
- `MARKETING_VERSION: "0.2.0"` / `CURRENT_PROJECT_VERSION: "1"`
- `TARGETED_DEVICE_FAMILY: "1"`（iPhone 独占）
- plist properties：`CFBundleDisplayName: 战棋 AI`、`LSRequiresIPhoneOS: true`、`UISupportedInterfaceOrientations` 支持横竖屏、`UIRequiresFullScreen: true`、后台模式为空数组。

## 4. 约定与约束

- **数值集中**：棋盘尺寸、地形属性、兵种参数、AI 权重、归一化标尺、难度档位全部集中在 `config.js` / `WarConfig.swift`，业务代码不得散落硬编码数值。（来源：两处文件的顶层注释）
- **双端同步**：Swift 定义的注释写明"对应 JS 原型 config.js"，新增/修改配置需同时更新两端。（来源：`WarConfig.swift` 首行注释）
- **禁用全局随机**：JS 侧强制通过 `SeededRng` 产生随机数，禁止直接使用 `Math.random()`。（来源：`config.js` 第 105–108 行注释）
- **难度为正交旋钮**：难度变化仅改变 temperature/lookahead/vision/budget/spellLevel，不改评分函数本身。（来源：`config.js` 第 4–9 行注释与 `WarConfig.swift` Difficulty 结构体注释）
- **关卡可复现**：`campaignLevel` 用关数 n 的纯函数导出 terrainSeed/aiSeed，不读玩家钱包或战绩。（来源：`WarConfig.swift` 第 393–432 行注释）
- **升级/魔法数值纯函数化**：`unitStat`、`spellStat`、`upgradeCost`、`spellUpgradeCost` 均为纯函数，保证内核结算、AI 评分、UI 面板取值一致。（来源：`WarConfig.swift` 第 236–336 行注释）
- **XcodeGen 生成的工程不可手改**：`project.yml` 顶部注释声明"不要手改生成的 War.xcodeproj"，应通过 `xcodegen generate` 重建。（来源：`project.yml` 第 1–3 行）
- **Node 语法检查**：`package.json` 的 `check` 脚本显式对 `config.js` 执行 `node --check`，作为配置文件的语法校验入口。（来源：`war/war/package.json`）

## 5. 未发现的机制

- 未发现环境变量注入、`.env` 文件、远程配置拉取、Feature Flag 系统、密钥管理系统。
- 未发现运行时配置重载能力；所有配置在模块加载时即固定。
- 未发现测试夹具中的独立配置覆盖；测试通过 `SeededRng` 与 `LevelSpec` seed 控制确定性。