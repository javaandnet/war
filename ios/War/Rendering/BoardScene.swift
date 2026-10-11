import SpriteKit
import WarKit

/// SpriteKit 棋盘场景：只把 `BoardFrame` 画出来，不做任何规则判断。
///
/// 性能取向（iPhone 上省电的关键）：
/// - 地形层只在棋盘尺寸/地形变化时重建，平时一帧不碰；
/// - 单位节点按 id 复用，位置变化用 `SKAction.move` 补间（内核已逐格发布，
///   所以补间永远只走一格，不会出现斜穿棋盘的直线）；
/// - 帧率由 `BoardView` 按"是否在动画/是否发热"降到 30fps，静止时不空转。
final class BoardScene: SKScene {
    /// 点击某格的回调（SwiftUI 侧路由到 GameStore.handleTap）
    var onTap: ((GridPoint) -> Void)?

    private var cell: CGFloat = 24
    /// 四层全部挂在这个容器上：缩放/平移只改它一个节点的 scale/position，
    /// 网格坐标一律不动 —— 否则每次缩放都要重建地形层（耗电且会闪）。
    private let worldNode = SKNode()
    private var terrainLayer = SKNode()
    private var overlayLayer = SKNode()
    private var unitLayer = SKNode()
    private var fxLayer = SKNode()

    /// 相对“全图 fit”的倍数：1 = 整张图刚好可见
    private(set) var zoom: CGFloat = 1
    private var offset: CGPoint = .zero
    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 3

    private var builtTerrain: [[String]] = []
    private var builtGrid: CGSize = .zero        // 已建地形层的格数 (width, height)
    private var builtSceneSize: CGSize = .zero   // 已建时的场景尺寸（转屏要重算 cell）
    private var gridHeight = 0
    private var unitNodes: [Int: SKNode] = [:]
    private var lastRevision = -1
    /// 补间时长：必须明显短于内核发布的节拍，否则动画会"追不上"状态
    private let tweenDuration: TimeInterval = 0.09
    /// 按下时的位置与是否多指：用来区分“点一格”和“拖地图/双指缩放”
    private var touchOrigin: CGPoint?
    private var touchMultiFinger = false

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.09, green: 0.11, blue: 0.10, alpha: 1)
        anchorPoint = .zero
        scaleMode = .aspectFit
        [terrainLayer, overlayLayer, unitLayer, fxLayer].forEach { worldNode.addChild($0) }
        fxLayer.zPosition = 30
        unitLayer.zPosition = 20
        overlayLayer.zPosition = 10
        addChild(worldNode)
        applyViewTransform()
    }

    // MARK: - 主入口

    func render(_ frame: BoardFrame) {
        guard frame.width > 0, frame.height > 0 else { return }
        let needTerrain = builtTerrain.isEmpty
            || builtTerrain != frame.terrain
            || builtGrid != CGSize(width: frame.width, height: frame.height)
            || builtSceneSize != size
        if needTerrain {
            gridHeight = frame.height
            builtGrid = CGSize(width: frame.width, height: frame.height)
            layout(for: frame)
            drawTerrain(frame)
            builtTerrain = frame.terrain
            builtSceneSize = size
            lastRevision = -1                     // 重建后必须重画叠层与单位
            // 单格边长可能跟着变了，单格内的方块/字号必须重做（留着会按旧尺寸画）
            unitNodes.values.forEach { $0.removeFromParent() }
            unitNodes = [:]
        }
        guard frame.revision != lastRevision else { return }
        lastRevision = frame.revision
        drawOverlays(frame)
        syncUnits(frame)
        playEffects(frame)
    }

    /// 根据可用尺寸重算单格边长（保持正方形网格）；场景尺寸由 BoardView 同步
    private func layout(for frame: BoardFrame) {
        let byWidth = size.width / CGFloat(frame.width)
        let byHeight = size.height / CGFloat(frame.height)
        cell = max(8, floor(min(byWidth, byHeight)))
        clampOffset()                         // 可视区变了，旧偏移可能已越界（转屏典型）
        applyViewTransform()
    }

    // MARK: - 视图变换（缩放 / 平移）

    private var worldSize: CGSize {
        CGSize(width: CGFloat(builtGrid.width) * cell * zoom,
               height: CGFloat(builtGrid.height) * cell * zoom)
    }

    /// 地形层已建好（缩放基准可用）
    var zoomReady: Bool { builtGrid.width > 0 }
    /// 只有图比屏大才允许单指拖动：全图模式下单指应留给点格子，不该被 pan 吃掉
    var canPan: Bool { worldSize.width > size.width + 1 || worldSize.height > size.height + 1 }

    private func applyViewTransform() {
        worldNode.xScale = zoom
        worldNode.yScale = zoom
        worldNode.position = offset
    }

    /// 把偏移夹到合法区间：比屏小的图居中锁定（拖不动），比屏大的图不允许拖出空白边
    private func clampOffset() {
        let w = worldSize
        if w.width > size.width {
            offset.x = min(0, max(size.width - w.width, offset.x))
        } else {
            offset.x = (size.width - w.width) / 2
        }
        if w.height > size.height {
            offset.y = min(0, max(size.height - w.height, offset.y))
        } else {
            offset.y = (size.height - w.height) / 2
        }
    }

    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        guard builtGrid.width > 0 else { return }
        let clamped = min(Self.maxZoom, max(Self.minZoom, newZoom))
        guard clamped != zoom else { return }
        // 保锚点：锚点处的网格内容缩放前后停在同一个视图位置
        let pivot = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let local = CGPoint(x: (pivot.x - offset.x) / zoom, y: (pivot.y - offset.y) / zoom)
        zoom = clamped
        offset = CGPoint(x: pivot.x - local.x * zoom, y: pivot.y - local.y * zoom)
        clampOffset()
        applyViewTransform()
    }

    func pan(by delta: CGSize) {
        offset = CGPoint(x: offset.x + delta.width, y: offset.y + delta.height)
        clampOffset()
        applyViewTransform()
    }

    func resetView() {
        zoom = Self.minZoom
        offset = .zero
        clampOffset()
        applyViewTransform()
    }

    /// 把某个网格点移到视图中央（选中单位/动画跟随时用）
    func centerOn(_ p: GridPoint) {
        guard builtGrid.width > 0 else { return }
        let local = center(of: p)                    // worldNode 局部坐标
        offset = CGPoint(x: size.width / 2 - local.x * zoom,
                         y: size.height / 2 - local.y * zoom)
        clampOffset()
        applyViewTransform()
    }

    /// 网格 y 向下、场景 y 向上，这里做唯一一次翻转
    private func center(of p: GridPoint) -> CGPoint {
        CGPoint(x: (CGFloat(p.x) + 0.5) * cell,
                y: (CGFloat(gridHeight - 1 - p.y) + 0.5) * cell)
    }

    // MARK: - 图标纹理
    //
    // 内核只给字母（I/C/A）与 ASCII 地形符号，在手机上跟“一个方块”没区别，
    // 所以单位和地形都改用 SF Symbol 矢量图。取不到图标时必须退回字母（不能空白）。

    /// 「名称@整数pt」→ 纹理。纹理本身只有一份白图，上色由节点的 `color` +
    /// `colorBlendFactor` 完成（同一形状只生成一份位图）；
    /// 尺寸只随地形重建变几档，缓存量极小（重复生成 UIImage 才是真耗电）。
    private static var textureCache: [String: SKTexture] = [:]
    /// 生成失败的 symbol：记下后不再重试，也只提醒一次
    private static var missingSymbols: Set<String> = []

    private static func texture(symbol name: String, pointSize: CGFloat) -> SKTexture? {
        let pts = max(6, Int(pointSize.rounded()))
        let key = "\(name)@\(pts)"
        if let hit = textureCache[key] { return hit }
        let config = UIImage.SymbolConfiguration(pointSize: CGFloat(pts), weight: .bold)
        guard let base = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal),
              let cg = base.cgImage else {
            if !missingSymbols.contains(name) {
                missingSymbols.insert(name)
                print("[BoardScene] SF Symbol unavailable, fallback to letter glyph: \(name)")
            }
            return nil
        }
        let tex = SKTexture(cgImage: cg)
        textureCache[key] = tex
        return tex
    }

    /// 按纹理宽高比把图标缩进单格（限幅，避免长条形 symbol 顶出格子）
    private func scaledSize(_ tex: SKTexture, height h: CGFloat) -> CGSize {
        let ratio = tex.size().width / max(1, tex.size().height)
        return CGSize(width: h * min(1.4, max(0.6, ratio)), height: h)
    }

    // MARK: - 地形层

    private func drawTerrain(_ frame: BoardFrame) {
        terrainLayer.removeAllChildren()
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let key = frame.terrain[y][x]
                let terrain = WarConfig.terrains[key] ?? WarConfig.terrains[WarConfig.defaultTerrainKey]!
                let point = GridPoint(x: x, y: y)
                let tile = SKSpriteNode(color: BoardScene.skColor(terrain.colorRGB, alpha: 1),
                                        size: CGSize(width: cell - 1, height: cell - 1))
                tile.position = center(of: point)
                tile.zPosition = 0
                terrainLayer.addChild(tile)

                if !terrain.symbol.isEmpty {
                    addTerrainMark(at: center(of: point), key: key, terrain: terrain)
                }
            }
        }
    }

    /// 地形标记：优先图标，取不到则退回内核 ASCII 符号
    private func addTerrainMark(at position: CGPoint, key: String, terrain: WarConfig.Terrain) {
        let alpha: CGFloat = terrain.impassable ? 0.62 : 0.34
        if let name = Theme.terrainIconName(for: key),
           let tex = Self.texture(symbol: name, pointSize: cell * 0.46) {
            let mark = SKSpriteNode(texture: tex)
            mark.size = scaledSize(tex, height: cell * 0.44)
            mark.position = CGPoint(x: position.x, y: position.y - cell * 0.04)
            mark.alpha = alpha
            terrainLayer.addChild(mark)
            return
        }
        let mark = SKLabelNode(text: terrain.symbol)
        mark.fontName = "Menlo-Bold"
        mark.fontSize = cell * 0.42
        mark.fontColor = SKColor(white: 1, alpha: terrain.impassable ? 0.55 : 0.22)
        mark.position = CGPoint(x: position.x, y: position.y - cell * 0.18)
        terrainLayer.addChild(mark)
    }

    // MARK: - 叠层（可达域 / 威胁图 / AI 落点 / 出生区）

    private func drawOverlays(_ frame: BoardFrame) {
        overlayLayer.removeAllChildren()

        if let camp = frame.deployZoneCamp {
            for y in 0..<frame.height {
                for x in frame.deployZone(of: camp) {
                    fill(GridPoint(x: x, y: y), color: SKColor(red: 0.30, green: 0.60, blue: 1.0, alpha: 0.16))
                }
            }
        }

        // 待施法：把内核算出的合法目标格涂紫。这一份名单与 `Battlefield.castSpell`
        // 同一口径（射程 + 视线 + 阵营），所以不会出现“亮了却放不出去”的误导高亮。
        // Set 本身无序，按 (y,x) 排一下 —— 叠层子节点的叠加顺序也得是定的。
        if !frame.spellTargets.isEmpty {
            for p in frame.spellTargets.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
                fill(p, color: SKColor(red: 0.72, green: 0.45, blue: 1.0, alpha: 0.38))
            }
        }

        if let threat = frame.threat {
            for y in 0..<frame.height where y * frame.width < threat.count {
                for x in 0..<frame.width {
                    let v = threat[y * frame.width + x]
                    let alpha = Theme.threatOpacity(v)
                    if alpha > 0.03 {
                        fill(GridPoint(x: x, y: y), color: SKColor(red: 1, green: 0.25, blue: 0.22, alpha: alpha))
                    }
                }
            }
        }

        for (p, cost) in frame.reach.sorted(by: { ($0.key.y, $0.key.x) < ($1.key.y, $1.key.x) }) {
            fill(p, color: SKColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 0.26))
            let badge = SKLabelNode(text: "\(cost)")
            badge.fontName = "HelveticaNeue-Bold"
            badge.fontSize = cell * 0.34
            badge.fontColor = SKColor(white: 0.95, alpha: 0.85)
            badge.position = CGPoint(x: center(of: p).x, y: center(of: p).y - cell * 0.16)
            overlayLayer.addChild(badge)
        }

        for (p, mark) in frame.bestMarks {
            let label = SKLabelNode(text: mark)
            label.fontName = "HelveticaNeue"
            label.fontSize = cell * 0.55
            label.fontColor = SKColor(red: 1, green: 0.85, blue: 0.30, alpha: 0.9)
            label.position = CGPoint(x: center(of: p).x, y: center(of: p).y + cell * 0.1)
            overlayLayer.addChild(label)
        }

        if let objective = frame.objective {
            let ring = SKShapeNode(circleOfRadius: cell * 0.42)
            ring.position = center(of: objective)
            ring.strokeColor = SKColor(red: 1, green: 0.85, blue: 0.30, alpha: 0.7)
            ring.lineWidth = 1.5
            ring.fillColor = .clear
            overlayLayer.addChild(ring)
        }
    }

    private func fill(_ p: GridPoint, color: SKColor) {
        let node = SKSpriteNode(color: color, size: CGSize(width: cell - 1, height: cell - 1))
        node.position = center(of: p)
        overlayLayer.addChild(node)
    }

    // MARK: - 单位层

    private func syncUnits(_ frame: BoardFrame) {
        var alive: Set<Int> = []
        for unit in frame.units {
            alive.insert(unit.id)
            if let existing = unitNodes[unit.id] {
                move(existing, to: unit)
            } else {
                let node = makeUnitNode(unit)
                unitLayer.addChild(node)
                unitNodes[unit.id] = node
            }
        }
        for (id, node) in unitNodes where !alive.contains(id) {
            node.run(.sequence([.group([.fadeOut(withDuration: 0.18),
                                        .scale(to: 0.5, duration: 0.18)]), .removeFromParent()]))
            unitNodes.removeValue(forKey: id)
        }
    }

    private func move(_ node: SKNode, to unit: BoardFrame.UnitView) {
        let target = center(of: GridPoint(x: unit.x, y: unit.y))
        if node.position != target {
            node.removeAction(forKey: "slide")
            node.run(.move(to: target, duration: tweenDuration), withKey: "slide")
        }
        decorate(node, with: unit)
    }

    private func makeUnitNode(_ unit: BoardFrame.UnitView) -> SKNode {
        // 只负责把骨架搭出来；所有会变的可见字段（文字/颜色/透明度）统一由
        // decorate 刷，否则新增一个字段就会漏更新（曾经就漏过 hp 与 AP 文本）。
        let node = SKNode()
        node.position = center(of: GridPoint(x: unit.x, y: unit.y))

        let body = SKShapeNode(rectOf: CGSize(width: cell * 0.78, height: cell * 0.78), cornerRadius: cell * 0.16)
        body.name = "body"
        body.lineWidth = 1.2
        node.addChild(body)

        let glyph = SKLabelNode()
        glyph.name = "glyph"
        glyph.fontName = "HelveticaNeue-Bold"
        glyph.fontSize = cell * 0.42
        glyph.verticalAlignmentMode = .center
        node.addChild(glyph)

        // 兵种图标（与 glyph 二选一，取不到图标就退回字母）
        let icon = SKSpriteNode()
        icon.name = "icon"
        icon.size = CGSize(width: cell * 0.5, height: cell * 0.5)
        icon.position = CGPoint(x: 0, y: cell * 0.05)
        node.addChild(icon)
        applyUnitIcon(icon, glyph: glyph, unit: unit)

        let hp = SKLabelNode()
        hp.name = "hp"
        hp.fontName = "HelveticaNeue-Bold"
        hp.fontSize = cell * 0.28
        hp.verticalAlignmentMode = .center
        hp.position = CGPoint(x: 0, y: -cell * 0.30)
        node.addChild(hp)

        let ap = SKLabelNode()
        ap.name = "ap"
        ap.fontName = "HelveticaNeue"
        ap.fontSize = cell * 0.22
        ap.verticalAlignmentMode = .center
        ap.position = CGPoint(x: 0, y: cell * 0.42)
        node.addChild(ap)

        // 施法徽标：右上角一枚魔法图标 + 本局剩余发数（只给首领填）。
        // 与 hp/ap 一样是“一次搭建、每次 decorate 刷字段”，不随帧新增节点。
        let spellIcon = SKSpriteNode()
        spellIcon.name = "spellIcon"
        spellIcon.position = CGPoint(x: cell * 0.30, y: cell * 0.30)
        spellIcon.isHidden = true
        node.addChild(spellIcon)

        let spellCount = SKLabelNode()
        spellCount.name = "spellCount"
        spellCount.fontName = "HelveticaNeue-Bold"
        spellCount.fontSize = cell * 0.22
        spellCount.verticalAlignmentMode = .center
        spellCount.position = CGPoint(x: cell * 0.30, y: cell * 0.12)
        spellCount.isHidden = true
        node.addChild(spellCount)

        // 成长角标：左上 = 战场等级，左下 = 可转职的金色 ↑（右上角留给魔法图标）。
        // 两者都靠 `decorate` 刷隐现，小格上直接不画（同 spellIcon 的约定）。
        let levelTag = SKLabelNode()
        levelTag.name = "levelTag"
        levelTag.fontName = "HelveticaNeue-Bold"
        levelTag.fontSize = cell * 0.22
        levelTag.verticalAlignmentMode = .center
        levelTag.position = CGPoint(x: -cell * 0.33, y: cell * 0.32)
        levelTag.isHidden = true
        node.addChild(levelTag)

        let promoteTag = SKLabelNode(text: "↑")
        promoteTag.name = "promoteTag"
        promoteTag.fontName = "HelveticaNeue-Bold"
        promoteTag.fontSize = cell * 0.28
        promoteTag.verticalAlignmentMode = .center
        promoteTag.position = CGPoint(x: -cell * 0.32, y: -cell * 0.36)
        promoteTag.isHidden = true
        node.addChild(promoteTag)

        decorate(node, with: unit)
        return node
    }

    /// 兵种图标：棋盘与面板共用 `Theme.unitIcons`，保证同一个兵种到处同形。
    /// 读的是**当前生效兵种**（`typeKey`）：转职后那个子就该换成 branch 的形状，
    /// 而基础兵种（价目/升级账）仍留在 `type` 里，两者在 `UnitView` 上是两个字段。
    private func applyUnitIcon(_ icon: SKSpriteNode, glyph: SKLabelNode, unit: BoardFrame.UnitView) {
        guard let name = Theme.unitIconName(for: unit.typeKey),
              let tex = Self.texture(symbol: name, pointSize: cell * 0.60) else {
            icon.isHidden = true
            glyph.isHidden = false
            return
        }
        icon.texture = tex
        icon.size = scaledSize(tex, height: cell * 0.56)
        icon.isHidden = false
        glyph.isHidden = true
    }

    private func decorate(_ node: SKNode, with unit: BoardFrame.UnitView) {
        // 阵营原色 = 本回合还能行动；行动完成后整块换成灰调。
        // 只靠透明度分不开“动完了”与“还没动”，所以颜色才是主信号。
        let live = unit.camp == 0
            ? SKColor(red: 0.25, green: 0.52, blue: 0.95, alpha: 1)
            : SKColor(red: 0.92, green: 0.34, blue: 0.28, alpha: 1)
        let done = unit.camp == 0
            ? SKColor(red: 0.30, green: 0.36, blue: 0.44, alpha: 1)
            : SKColor(red: 0.44, green: 0.33, blue: 0.31, alpha: 1)
        (node.childNode(withName: "body") as? SKShapeNode)?.fillColor = unit.spent ? done : live
        (node.childNode(withName: "body") as? SKShapeNode)?.strokeColor =
            unit.selected ? SKColor.white : SKColor(white: 0, alpha: 0.35)
        (node.childNode(withName: "body") as? SKShapeNode)?.lineWidth = unit.selected ? 2.2 : 1.2

        (node.childNode(withName: "glyph") as? SKLabelNode)?.text = unit.symbol
        (node.childNode(withName: "glyph") as? SKLabelNode)?.fontColor = .white
        // 图标每次刷：转职会换兵种形状，而节点不重建（纹理走 `textureCache`，不掏新资源）
        if let icon = node.childNode(withName: "icon") as? SKSpriteNode,
           let glyph = node.childNode(withName: "glyph") as? SKLabelNode {
            applyUnitIcon(icon, glyph: glyph, unit: unit)
        }

        if let hp = node.childNode(withName: "hp") as? SKLabelNode {
            hp.text = "\(unit.hp)"
            hp.fontColor = unit.hp * 3 <= unit.maxHp
                ? SKColor(red: 1, green: 0.45, blue: 0.4, alpha: 1) : .white
        }
        if let ap = node.childNode(withName: "ap") as? SKLabelNode {
            ap.text = "\(unit.remainingMove)⚡\(unit.remainingAttacks)⚔"
            ap.fontColor = SKColor(white: 1, alpha: 0.8)
            ap.isHidden = cell < 20      // 小格上这行会跟邻居压字，不如不画
        }

        node.alpha = unit.spent ? 0.72 : 1.0
        node.zPosition = unit.selected ? 25 : 20

        // 首领：常驻金环。它同时是斩首判据与全场唯一能施法的人，必须在一堆
        // 方块里被一眼认出来。用独立子节点而不改 body 描边：选中态已占那条描边。
        let chiefRingName = "chiefRing"
        node.childNode(withName: chiefRingName)?.removeFromParent()
        if unit.isChief {
            let ring = SKShapeNode(rectOf: CGSize(width: cell * 0.92, height: cell * 0.92),
                                   cornerRadius: cell * 0.19)
            ring.name = chiefRingName
            ring.strokeColor = SKColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 0.95)
            ring.lineWidth = 2
            ring.fillColor = .clear
            ring.zPosition = 1
            node.addChild(ring)
        }

        // 冰冻：蓝色遮罩盖住身体。被冻就是这一回合什么都做不了，得看得出来。
        let frostName = "frost"
        node.childNode(withName: frostName)?.removeFromParent()
        if unit.stunned {
            let frost = SKShapeNode(rectOf: CGSize(width: cell * 0.78, height: cell * 0.78),
                                    cornerRadius: cell * 0.16)
            frost.name = frostName
            frost.fillColor = SKColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 0.45)
            frost.strokeColor = SKColor(red: 0.80, green: 0.95, blue: 1.0, alpha: 0.95)
            frost.lineWidth = 1.2
            frost.zPosition = 2
            node.addChild(frost)
        }

        // 施法徽标：图标取本局第一种还有发的魔法，数字是**总**剩余发数
        //（逐 kind 的明细在面板上，格子上只回答“它还能放几次”）。
        let chargeTotal = unit.spellCharges.values.reduce(0, +)
        let spellKey = WarConfig.spellOrder.first { (unit.spellCharges[$0] ?? 0) > 0 }
        if let spellIcon = node.childNode(withName: "spellIcon") as? SKSpriteNode,
           let spellCount = node.childNode(withName: "spellCount") as? SKLabelNode {
            if chargeTotal > 0, let key = spellKey, let name = Theme.spellIconName(for: key),
               let tex = Self.texture(symbol: name, pointSize: cell * 0.30) {
                spellIcon.texture = tex
                spellIcon.size = scaledSize(tex, height: cell * 0.26)
                spellIcon.color = SKColor(red: 0.86, green: 0.70, blue: 1.0, alpha: 1)
                spellIcon.colorBlendFactor = 1.0   // 白图 × 紫色 = 紫色，保留图标自己的透明轮廓
                spellIcon.isHidden = cell < 26
                spellCount.text = "\(chargeTotal)"
                spellCount.fontColor = SKColor(red: 0.86, green: 0.70, blue: 1.0, alpha: 1)
                spellCount.isHidden = cell < 26      // 小格上这两个图字会跟邻居压字
            } else {
                spellIcon.isHidden = true
                spellCount.isHidden = true
            }
        }

        // 可被当前选中单位打击 → 黄圈提示
        let haloName = "halo"
        node.childNode(withName: haloName)?.removeFromParent()
        if unit.targetable {
            let halo = SKShapeNode(circleOfRadius: cell * 0.5)
            halo.name = haloName
            halo.strokeColor = SKColor(red: 1, green: 0.85, blue: 0.30, alpha: 0.9)
            halo.lineWidth = 2
            halo.fillColor = .clear
            node.addChild(halo)
        }

        // 成长角标：等级数字只在**真升过级**时画（开局人人 1 级，满屏“1”是噪声），
        // 可转职时多一枚金色 ↑ —— 它是“只差你点一下”的提醒，不提醒就会有人卡在 10 级。
        if let levelTag = node.childNode(withName: "levelTag") as? SKLabelNode {
            levelTag.text = "\(unit.level)"
            levelTag.fontColor = unit.canPromote
                ? SKColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 1) : SKColor(white: 1, alpha: 0.85)
            levelTag.isHidden = cell < 26 || unit.level <= 1
        }
        if let promoteTag = node.childNode(withName: "promoteTag") as? SKLabelNode {
            promoteTag.fontColor = SKColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 1)
            promoteTag.isHidden = cell < 26 || !unit.canPromote
        }
    }

    // MARK: - 飘字

    private func playEffects(_ frame: BoardFrame) {
        for effect in frame.effects {
            let label = SKLabelNode(text: effect.text)
            label.fontName = "HelveticaNeue-Bold"
            label.fontSize = cell * 0.42
            switch effect.kind {
            case .damage: label.fontColor = SKColor(red: 1, green: 0.85, blue: 0.30, alpha: 1)
            case .counter: label.fontColor = SKColor(red: 1, green: 0.55, blue: 0.25, alpha: 1)
            case .kill: label.fontColor = SKColor(red: 1, green: 0.3, blue: 0.25, alpha: 1)
            case .spell: label.fontColor = SKColor(red: 1, green: 0.45, blue: 0.15, alpha: 1)
            case .heal: label.fontColor = SKColor(red: 0.45, green: 0.95, blue: 0.55, alpha: 1)
            case .freeze: label.fontColor = SKColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 1)
            case .promote: label.fontColor = SKColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 1)
            }
            let start = center(of: GridPoint(x: effect.x, y: effect.y))
            label.position = CGPoint(x: start.x, y: start.y + cell * 0.3)
            fxLayer.addChild(label)
            label.run(.sequence([
                .group([.moveBy(x: 0, y: cell * 0.9, duration: 0.55),
                        .fadeOut(withDuration: 0.55)]),
                .removeFromParent(),
            ]))
        }
    }

    // MARK: - 触摸
    //
    // 点一格与拖地图/双指缩放共用同一个视图，所以按下不立即生效：
    // 抬起时确认“没拖动过、没第二根手指”才当成点击（否则缩放手势会把相邻格子误点）。

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard builtGrid.width > 0 else { return }
        if (event?.allTouches?.count ?? touches.count) > 1 || touches.count > 1 {
            touchMultiFinger = true
            touchOrigin = nil
            return
        }
        guard !touchMultiFinger, let touch = touches.first else { return }
        touchOrigin = touch.location(in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 拖动由 BoardView 的 pan 手势接管，这里只需保证位移过大时取消点击
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { touchOrigin = nil; touchMultiFinger = false }
        guard !touchMultiFinger, let start = touchOrigin, let touch = touches.first else { return }
        let end = touch.location(in: self)
        guard hypot(end.x - start.x, end.y - start.y) < max(12, cell * 0.45) else { return }
        // 视图坐标 → worldNode 局部坐标（自动含缩放/平移）→ 网格坐标
        let local = worldNode.convert(end, from: self)
        let gx = Int(floor(local.x / cell))
        let gyFromBottom = Int(floor(local.y / cell))
        guard gx >= 0, gx < Int(builtGrid.width),
              gyFromBottom >= 0, gyFromBottom < Int(builtGrid.height) else { return }
        onTap?(GridPoint(x: gx, y: Int(builtGrid.height) - 1 - gyFromBottom))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOrigin = nil
        touchMultiFinger = false
    }

    // MARK: - 颜色转换

    static func skColor(_ rgb: (red: Double, green: Double, blue: Double), alpha: CGFloat) -> SKColor {
        SKColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: alpha)
    }
}

/// `BoardFrame` 的便利扩展：场景里要知道出生区范围，但不想把内核规则抄一份
private extension BoardFrame {
    func deployZone(of camp: Int) -> Range<Int> {
        camp == 0 ? 0..<WarConfig.deployColumnCount
                  : (width - WarConfig.deployColumnCount)..<width
    }
}
