import AppKit
import Foundation

/// 浮窗：无边框、透明、置顶、可拖动的 NSPanel。
///
/// 为什么用 NSPanel 而不是 NSWindow：
///   · NSPanel 可以设 nonactivatingPanel，点击不抢当前 app 的焦点
///   · 配合 accessory 激活策略，它就是个安静的桌面挂件
final class FloatWindow: NSPanel {
    let whaleView: WhaleView
    /// 拖动结束后回调新位置（用于持久化）。
    var onMoved: ((CGPoint) -> Void)?
    /// 松手后是否吸附到最近的屏幕边缘。
    var snapEnabled = true
    /// 吸附留白（点）。
    var snapMargin: CGFloat = 20
    /// 吸到左边缘时是否把角色水平翻转（对应网页版「吸附与翻转」）。
    var flipOnLeftSnap = true

    init(size: CGFloat) {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        // 必须在 super.init 之前初始化全部存储属性
        whaleView = WhaleView(frame: rect)
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        whaleView.autoresizingMask = [.width, .height]
        contentView = whaleView

        moveToDefaultPosition()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMove),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    /// 放到右下角（避开 Dock）。
    private func moveToDefaultPosition() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = frame.width
        let margin: CGFloat = 20
        setFrameOrigin(CGPoint(
            x: v.maxX - size - margin,
            y: v.minY + margin
        ))
    }

    /// 改变浮窗尺寸（保持右下角锚点不动）。
    func applySize(_ size: CGFloat) {
        let clamped = max(120, min(360, size))
        var f = frame
        // 以右下角为锚点缩放，避免窗口"跳"
        f.origin.x += f.width - clamped
        f.origin.y += f.height - clamped
        f.size = NSSize(width: clamped, height: clamped)
        setFrame(f, display: true, animate: false)
        whaleView.needsLayout = true
    }

    /// 按已保存的位置摆放（若在可见屏幕内）。
    func applySavedPosition(_ origin: CGPoint?) {
        guard let p = origin else { return }
        let target = NSRect(origin: p, size: frame.size)
        for screen in NSScreen.screens where screen.visibleFrame.intersects(target) {
            setFrameOrigin(p)
            return
        }
        // 保存的位置已不在任何屏幕内（换显示器了）→ 回到默认位
        moveToDefaultPosition()
    }

    @objc private func handleMove() {
        // 拖完就把窗口拉回可见区域 —— 否则能被拖到屏幕外，
        // 表现为「贴着边只剩半边」。
        clampToVisibleScreen()
        onMoved?(frame.origin)
        scheduleSnap()
    }

    /// 是否正在由吸附动画驱动（避免吸附动画又触发 didMove → 再吸附）。
    private var snapping = false

    /// 拖动结束后吸附到最近边缘。
    ///
    /// 触发方式说明（踩过坑）：最初覆盖 mouseUp，但浮窗的拖动走
    /// `performDrag(with:)`，它会接管整个拖动过程，mouseUp 不会按预期到达窗口，
    /// 结果在错误的时机吸附、把窗口甩到屏幕另一角。
    /// 改成「didMove 之后安静 0.35 秒」即视为松手 —— 拖动中每帧都会 didMove，
    /// 停下来的那一刻才触发，手感与真正松手一致。
    private var snapTimer: Timer?

    private func scheduleSnap() {
        snapTimer?.invalidate()
        guard snapEnabled else { return }
        let t = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.snapToNearestEdge() }
        }
        RunLoop.main.add(t, forMode: .common)
        snapTimer = t
    }

    /// 允许的坐标范围（可见区域内，完整放下窗口）。
    private func clampedOrigin(_ p: NSPoint) -> NSPoint {
        guard let screen = (self.screen ?? NSScreen.main) else { return p }
        let v = screen.visibleFrame
        let maxX = max(v.minX, v.maxX - frame.width)
        let maxY = max(v.minY, v.maxY - frame.height)
        return NSPoint(x: min(max(p.x, v.minX), maxX),
                       y: min(max(p.y, v.minY), maxY))
    }

    /// 从源头夹住 —— 比事后监听 didMove 可靠。
    ///
    /// performDrag 期间 didMove 通知不一定按每帧到达，所以之前
    /// 「拖到屏幕外只剩半边」的问题在拖动过程中一直存在。
    /// 重写这两个方法后，无论拖动、吸附动画还是恢复位置，都出不去。
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(clampedOrigin(point))
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var r = frameRect
        r.origin = clampedOrigin(r.origin)
        super.setFrame(r, display: flag)
    }

    /// 把窗口约束在屏幕的可见区域内（完整可见，不留半截在外面）。
    ///
    /// 只在**不吸附**时用「完整可见」；吸附时留的那点 snapMargin 是刻意的。
    private func clampToVisibleScreen() {
        guard let screen = (self.screen ?? NSScreen.main) else { return }
        let v = screen.visibleFrame
        var f = frame
        // 窗口比可见区域还大时不硬夹（夹了会抖），直接把原点对齐左上
        let maxX = max(v.minX, v.maxX - f.width)
        let maxY = max(v.minY, v.maxY - f.height)
        f.origin.x = min(max(f.origin.x, v.minX), maxX)
        f.origin.y = min(max(f.origin.y, v.minY), maxY)
        if abs(f.origin.x - frame.origin.x) > 0.5 || abs(f.origin.y - frame.origin.y) > 0.5 {
            setFrameOrigin(f.origin)
        }
    }

    private func snapToNearestEdge() {
        guard let screen = (self.screen ?? NSScreen.main) else { return }
        let v = screen.visibleFrame
        var f = frame
        // 与四条边的距离，取最近的一条吸附
        let distLeft = abs(f.minX - v.minX)
        let distRight = abs(v.maxX - f.maxX)
        let distBottom = abs(f.minY - v.minY)
        let distTop = abs(v.maxY - f.maxY)
        let nearest = min(distLeft, distRight, distBottom, distTop)
        // 离得太远就不吸附（避免用户摆在中间时被强行拽走）
        guard nearest < 90 else { return }

        var snappedLeft = false
        if nearest == distLeft { f.origin.x = v.minX + snapMargin; snappedLeft = true }
        else if nearest == distRight { f.origin.x = v.maxX - f.width - snapMargin }
        else if nearest == distBottom { f.origin.y = v.minY + snapMargin }
        else { f.origin.y = v.maxY - f.height - snapMargin }

        // 贴左边时把角色镜像 —— 让它「面朝屏幕内侧」
        if flipOnLeftSnap {
            whaleView.setCharacterFlipped(snappedLeft)
        }

        // 已经在目标位置就不动（didMove 抖动保护）
        guard abs(f.origin.x - frame.origin.x) > 0.5 || abs(f.origin.y - frame.origin.y) > 0.5 else { return }
        snapping = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(f, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.snapping = false }
        })
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 用户设置。存成一个 JSON 落在 ~/.dsh/whalefloat.json。
///
/// 字段对应网页版鲸鱼的菜单项：
///   大小 / 角色 / 气泡开关 / 按压泡泡 / 吸附翻转 / 资源管理（预警·预算）/ 音效
struct Settings: Codable {
    // ── 外观 ────────────────────────────────────────────────
    /// 角色显示边长（点）。
    ///
    /// 默认值**必须是合法档位之一**，否则首次启动会被 normalizeSettings
    /// 悄悄改掉 —— 原先写的是 220（滑块时代的中间值），于是新用户装完
    /// 看到的就是 152，跟「默认」两个字对不上。取小档，含蓄些。
    var characterSize: CGFloat = 152
    /// 角色素材名（不含扩展名）。
    /// 默认用纯角色图；带手绘气泡的旧素材会被 normalizeRoleName 映射过来，
    /// 但没必要让默认值指向它。
    var characterName: String = "role-clean"
    /// 浮窗位置；nil 表示用默认（右下角）。
    var position: CGPoint?

    // ── 气泡 ────────────────────────────────────────────────
    /// 气泡自动收回秒数（0 = 不自动收回）。对应网页版的自动关闭时长。
    var bubbleSeconds: Double = 10
    /// 单击是否冒泡余额。对应「气泡全局开关」。
    var bubbleOn: Bool = true
    /// 按压鲸鱼时是否冒泡。对应「按压泡泡设置」。
    var pressBubble: Bool = false
    /// 每轮对话结束是否冒泡显示消耗。
    var turnCostBubble: Bool = true
    /// 气泡内是否显示峰谷标记（一个字：「峰」或「谷」）。
    var showValley: Bool = true
    /// 气泡内是否显示当前时间。
    var showClock: Bool = true

    // ── 吸附 ────────────────────────────────────────────────
    /// 松手后是否吸附到最近的屏幕边缘。对应「吸附与翻转」。
    var snapEnabled: Bool = true
    /// 吸附留白（点）。
    var snapMargin: CGFloat = 20

    // ── 提醒（资源管理）────────────────────────────────────
    /// 余额低于此值冒泡提醒；0 = 关闭。
    var lowBalanceWarn: Double = 0
    /// 今日消耗超过此值冒泡提醒；0 = 关闭。
    var dailyBudget: Double = 0

    // ── 音效（音效与提示）──────────────────────────────────
    /// 事件音效总开关。
    var soundOn: Bool = true
    /// 音量 0…1。
    var soundVolume: Double = 0.9

    static let fileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".dsh/whalefloat.json")
    }()

    /// 导入的自定义角色图片存放目录。
    /// 素材的上游位置 —— 供「获取角色素材…」在浏览器打开。
    /// 选择让用户自己去取，而不是程序代下载：上游对该目录的授权是
    /// 「仅用于运行本插件」，程序代取会越过那条线。
    static let assetSourceURL =
        "https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget/tree/HEAD/assets"

    static let assetsDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".dsh/whalefloat-assets", isDirectory: true)
    }()

    /// 宽容解码：**每个字段缺失都退回默认值**，而不是让整份配置解不出来。
    ///
    /// Swift 自动合成的解码器要求所有字段都在 —— 哪怕属性写了默认值。
    /// 那样一来，将来新增一个字段，老配置文件就会整体解码失败，
    /// 用户的全部设置被重置成出厂状态。这里逐个字段给兜底。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        characterSize = get(.characterSize, 152)
        characterName = get(.characterName, "role-clean")
        position = try? c.decodeIfPresent(CGPoint.self, forKey: .position)
        bubbleSeconds = get(.bubbleSeconds, 10)
        bubbleOn = get(.bubbleOn, true)
        pressBubble = get(.pressBubble, false)
        turnCostBubble = get(.turnCostBubble, true)
        showValley = get(.showValley, true)
        showClock = get(.showClock, true)
        snapEnabled = get(.snapEnabled, true)
        snapMargin = get(.snapMargin, 20)
        lowBalanceWarn = get(.lowBalanceWarn, 0)
        dailyBudget = get(.dailyBudget, 0)
        soundOn = get(.soundOn, true)
        soundVolume = get(.soundVolume, 0.9)
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        do {
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            // 写失败不该静默 —— 至少留个痕，否则用户会以为设置生效了
            NSLog("WhaleFloat: 设置写入失败 \(error.localizedDescription)")
        }
    }
}

// CGPoint 的 Codable 由 CoreGraphics 自带，格式同为 {x, y}。
// 不需要自己实现 —— 自己写会和它的 conformance 撞车，编译器会警告。