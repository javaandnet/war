#!/bin/sh
# 无头冒烟验证：在 macOS 上直接编译并运行 App 的逻辑层。
#
# 为什么不用 xcodebuild test：本机可能没装 iOS 模拟器运行时（下载要十几 GB），
# 而 GameStore / BoardFrame / PowerPolicy / Wallet 只依赖 SwiftUI + Combine + WarKit，
# 在 macOS 上就能真跑。渲染层（SpriteKit/UIKit）不在此列，仍需模拟器或真机看。
# Theme 也一并编进来：它只依赖 SwiftUI 常量与图标映射表，用来断言图标契约。
#
# 用法：sh tools/smoke.sh
set -eu
cd "$(dirname "$0")/.."

ARCH=$(uname -m)
OUT=.smoke-build/war-smoke
mkdir -p .smoke-build

echo "==> 编译内核（release）"
( cd WarKit && swift build -c release >/dev/null )

echo "==> 编译 App 逻辑层 + 冒烟入口"
swiftc -O -swift-version 5 \
  -target "${ARCH}-apple-macosx14.0" \
  -I WarKit/.build/release \
  -L WarKit/.build/release -lWarKit \
  War/Model/BoardFrame.swift \
  War/Model/GameSettings.swift \
  War/Model/GameStore.swift \
  War/Model/Wallet.swift \
  War/Support/PowerPolicy.swift \
  War/Support/Theme.swift \
  tools/Smoke/main.swift \
  -o "$OUT"

echo "==> 运行"
echo
exec "$OUT"
