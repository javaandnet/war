---
kind: error_handling
name: 错误处理：JS 原型使用 throw/Error + 返回值对象，Swift 端无自定义错误类型
category: error_handling
scope:
    - '**'
source_files:
    - war/war/item.js
    - war/war/field.js
    - war/war/game.js
    - war/war/ai.js
    - war/ios/WarKit/Tests/WarKitTests/DifficultyMeter.swift
    - war/ios/WarKit/Tests/WarKitTests/WarKitTests.swift
---

## 1. 总体方式

仓库包含两套实现，错误处理方式不同：

- **JS 原型（`war/war/`）**：采用传统 JavaScript 的 `throw new Error(...)` 与 `try/finally`；同时大量使用**返回结果对象**（如 `{ ok, reason }`、`{ rejected }`）来区分“可恢复的业务拒绝”和“真正的异常”。没有统一的错误码枚举、没有全局错误处理器、也没有中间件。
- **Swift / WarKit（`war/ios/WarKit/`）**：仅测试代码中出现 `throws` / `XCTSkip`，核心库本身没有定义任何自定义错误类型或 `Error` 协议实现。Swift 端的错误处理几乎不存在。

## 2. JS 侧的错误模式

### 2.1 构造期校验 → `throw new Error`

`war/item.js` 中 `Unit` 构造函数对配置键做白名单校验：

```js
const stats = WarConfig.unitTypes[type];
if (!stats) {
    throw new Error(`未知兵种: ${type}`);
}
```

这是仓库里唯一一处 `throw new Error`，用于捕获非法输入（未知兵种）。调用方（`Game.handlePlacementClick`）直接 `new Unit(...)`，未包裹 try/catch——意味着在浏览器中该异常会冒泡到顶层，表现为控制台报错。

### 2.2 业务拒绝 → 返回值对象（非抛错）

`Battlefield.moveAlongPath` 和 `Battlefield.attack` 不抛异常，而是返回结构化结果对象：

- `moveAlongPath` 返回 `{ ok, spent, steps, reason, origin }`，其中 `reason` 取值为 `'dead' | 'not_adjacent' | 'blocked' | 'occupied' | 'no_points'`。
- `attack` 返回 `{ attackerId, targetId, damage, killed, counterDamage, counterKilled, from, rejected }`，其中 `rejected` 取 `'not_allowed' | 'out_of_range'`。

调用方通过检查字段而非捕获异常：

```js
// game.js
const res = this.battlefield.moveAlongPath(unit, cell.path);
if (!res.ok) { this.flash(`移动失败：${res.reason}`); return; }

const r = this.battlefield.attack(unit, target);
if (r.rejected) { this.flash(`攻击失败：${r.rejected}`); return; }
```

这种设计把“玩家误操作”（不在射程、AP 不足、格子被占）与“程序 bug”（未知兵种）分开：前者是 UI 反馈，后者才是异常。

### 2.3 资源清理 → `try/finally`

`ai.js` 中的 `Lookahead.evaluate` 用 `try/finally` 保证战场快照回滚：

```js
const snap = this.bf.snapshot();
try {
    // ... 模拟走子、前瞻 rollout ...
} finally {
    this.bf.restore(snap);
}
```

这确保无论评估过程中发生什么（包括内部抛错），战场状态都能恢复到 snapshot 前。这是仓库里唯一的 `try/finally` 用法。

### 2.4 其他 JS 文件

- `game.js`、`field.js`、`config.js`、`ai.js` 中没有其他 `throw` / `catch`。
- `index.html` 作为浏览器入口，没有全局 `window.onerror` 或 `unhandledrejection` 监听器。
- Node 测试（`tests/kernel.test.mjs`）未检出有断言错误的用例。

## 3. Swift / WarKit 侧

搜索 `*.swift` 只找到两处 `throws`：

- `WarKitTests/DifficultyMeter.swift`：`throw XCTSkip(...)` 用于跳过手动量尺测试。
- `WarKitTests/WarKitTests.swift`：注释说明“写 `XCTSkipIf` 而不写 `throw XCTSkip(...)`”，因为编译器会把无条件退出视为编译期问题。

WarKit 核心源文件（`WarAI.swift`、`Battlefield.swift`、`Scorer.swift`、`Enumerator.swift`、`WarConfig.swift` 等）没有定义任何自定义错误类型，也没有 `do/try/catch`。Swift 端的错误传播基本为空。

## 4. 架构约定与约束

观察到的约定（描述性，非强制规则）：

1. **可变状态的唯一写入者是 `Battlefield`**：`field.js` 顶部注释明确声明坐标与占位只能通过 `moveAlongPath()` 改变、血量与死亡只能通过 `attack()` 改变，以此杜绝旧版双写不一致。
2. **可恢复的业务拒绝用返回值对象表达**：`moveAlongPath` 返回 `{ ok, reason }`，`attack` 返回 `{ rejected }`，由上层 UI 层转换为中文提示（`flash`）。
3. **不可恢复的非法输入用 `throw new Error`**：目前仅在 `Unit` 构造时对未知兵种抛出。
4. **需要原子性的副作用用 `snapshot()/restore()` + `try/finally`**：`Lookahead.evaluate` 是模板。
5. **Swift 端尚未建立错误体系**：核心库不抛错、不定义错误类型，依赖调用方（iOS App）的 SwiftUI 视图层自行处理（当前未见相关代码）。
6. **没有统一错误日志/上报**：JS 端没有集中式 logger，Swift 端没有日志框架引用。

## 5. 缺失项

- 没有错误码枚举或错误类层次结构。
- 没有全局错误边界（UI 层 `flash` 只是临时提示，不是错误边界）。
- 没有 panic/recover（Swift 端无 `fatalError`，JS 端无 `process.on('uncaughtException')`）。
- 没有中间件机制（本仓库为单页游戏，不涉及 HTTP 中间件）。
- Swift 侧缺少与 JS 侧同等程度的错误建模。