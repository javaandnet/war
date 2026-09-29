import SwiftUI
import SpriteKit
import WarKit

/// SKView 的 SwiftUI 外壳 + 缩放/平移手势。
///
/// 手势分工（用户明确要求）：**缩放只归双指捏合**，任何点击/双击都不改动缩放；
/// 单指在地图上就是点格子，放大后才兼作拖动；回全图走棋盘角落的按钮。
///
/// 帧率策略：静止时压到 30fps（回合制大部分时间棋盘不动，空转纯属耗电），
/// 有动画/自动对战时按功耗策略给到 60fps。低电量模式下由 `PowerPolicy` 封顶 30fps。
/// 缩放/平移只改场景里一个容器节点的 transform，不触发任何重建。
struct BoardView: UIViewRepresentable {
    @EnvironmentObject private var store: GameStore

    func makeUIView(context: Context) -> SKView {
        let view = SKView(frame: .zero)
        view.ignoresSiblingOrder = true
        view.isMultipleTouchEnabled = true          // 双指缩放必须开多指
        let scene = BoardScene(size: CGSize(width: 420, height: 420))
        scene.scaleMode = .aspectFit
        scene.onTap = { point in store.handleTap(point) }
        view.presentScene(scene)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1              // 第二根手指留给 pinch
        [pinch, pan].forEach {
            $0.delegate = context.coordinator
            view.addGestureRecognizer($0)
        }
        context.coordinator.gestures = [pinch, pan]
        return view
    }

    func updateUIView(_ view: SKView, context: Context) {
        guard let scene = view.scene as? BoardScene else { return }
        // 场景尺寸不自动跟随容器（转屏/分屏），这里显式同步
        if scene.size != view.bounds.size {
            scene.size = view.bounds.size
        }
        scene.render(store.frame)

        // 默认缩放：首次建好棋盘时套用；设置里改了也立即生效
        let wantZoom = CGFloat(store.settings.boardZoom)
        if context.coordinator.appliedZoom != wantZoom, scene.zoomReady, store.frame.width > 0 {
            context.coordinator.appliedZoom = wantZoom
            scene.setZoom(wantZoom)
        }
        // 「全图」按钮：只消费递增令牌，避免在 updateUIView 里反向持有 scene
        if context.coordinator.appliedResetTick != store.viewResetTick {
            context.coordinator.appliedResetTick = store.viewResetTick
            scene.resetView()
        }
        // 选中单位时把它带到视野中心（放大后不跟丢）；只在 id 真变化时做一次
        let selected = store.frame.units.first { $0.selected }
        if let selected {
            if context.coordinator.lastSelectedId != selected.id {
                context.coordinator.lastSelectedId = selected.id
                scene.centerOn(GridPoint(x: selected.x, y: selected.y))
            }
        } else {
            context.coordinator.lastSelectedId = nil
        }

        let animating = store.busy || store.autoRunning
        view.preferredFramesPerSecond = animating
            ? store.power.preferredFPS
            : min(30, store.power.preferredFPS)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var gestures: [UIGestureRecognizer] = []
        var appliedZoom: CGFloat?
        var appliedResetTick = 0
        var lastSelectedId: Int?
        private var lastPan: CGPoint = .zero

        private var skView: SKView? { gestures.first?.view as? SKView }
        private var scene: BoardScene? { skView?.scene as? BoardScene }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let scene, let view = skView else { return }
            let p = CGPoint(x: g.location(in: view).x,
                            y: view.bounds.height - g.location(in: view).y)   // 翻到 SK 的左下原点
            scene.setZoom(scene.zoom * g.scale, anchor: p)
            g.scale = 1
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let scene, let view = skView else { return }
            let t = g.translation(in: view)
            switch g.state {
            case .began:
                lastPan = .zero
            case .changed:
                let delta = CGSize(width: t.x - lastPan.x, height: -(t.y - lastPan.y))
                scene.pan(by: delta)
                lastPan = t
            default:
                lastPan = .zero
            }
        }

        // 缩放/平移与棋盘自身的点击互不阻塞
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UIPanGestureRecognizer {
                return (scene?.canPan) ?? false     // 全图模式下不吞掉点击
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// 棋盘容器：铺满可用空间（不再钉死正方形），棋盘按较短边 fit 后居中，
/// 放大时超出部分靠平移查看。
struct BoardPanel: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        BoardView()
            .environmentObject(store)
            .background(Theme.boardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
