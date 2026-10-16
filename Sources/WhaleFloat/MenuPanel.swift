import AppKit
import Foundation

/// 自绘的菜单面板 —— 全程序**唯一的悬浮窗体**。
///
/// 为什么不用 NSMenu：NSMenu 只能放静态项，既不能内嵌折线图，也不能让内容
/// 翻页（点「分析」后原地变成分析视图、再「返回」回主菜单）。
/// 所以自绘一套：外观照 macOS 菜单（圆角、材质、hover 高亮），
/// 但内容是可控的视图栈。
///
/// 页面结构：
///   主菜单 ──「分析」──→ 分析页（带返回）
///          └─「高级设置」→ 设置页（带返回）
@MainActor
final class MenuPanelController: NSObject {
    enum Page {
        case main
        case analysis
        case settings
    }

    private var panel: NSPanel?

    /// 气泡要锚定到哪个视图（由 AppDelegate 提供鲸鱼浮窗的 view）。
    var anchorViewProvider: (() -> NSView?)?

    /// 弹出方向。桌宠在桌面右侧时朝左弹，状态栏图标则要朝下弹。
    var preferredEdge: NSRectEdge = .minX
    private let stack = NSStackView()
    private var currentPage: Page = .main

    /// 主菜单项：(标题, 是否强调, 动作, 快捷键提示)。
    /// 快捷键提示显示在右侧（⌥1…⌥9），并与键盘监听对应。
    var mainItems: [(String, Bool, () -> Void, String?)] = []

    /// ⌥1…⌥9 的键盘监听（面板显示时挂上、收起时摘掉）。
    private var keyMonitor: Any?

    /// 最小宽度；实际宽度按最长菜单项自适应（够放下字就行）。
    private static let minWidth: CGFloat = 190
    /// 当前内容算出的实际宽度（每次 rebuild 后更新）。
    private var contentWidth: CGFloat = 190

    /// 主菜单算出的尺寸 —— 二级页沿用它，翻页时大小不跳。
    private var mainMenuSize: CGSize?

    /// 供子页内容取用的当前宽度（分析页的图表要对齐它）。
    var currentContentWidth: CGFloat { contentWidth }

    /// 返回按钮的边长（随字号自适应）。
    private static let backButtonSize: CGFloat = 22


    /// 一级菜单字号。
    static let mainFontSize: CGFloat = 13
    /// 二级页正文字号。全页统一用它（不另起小号、不额外加粗），
    /// 只有页面标题是 semibold —— 层级靠字重区分，而不是靠字号忽大忽小。
    static let subFontSize: CGFloat = 12

    /// 外框圆角 —— 自绘时可控，比 NSPopover 的默认值小。
    /// 玻璃层的圆角 —— 由内层反推，保证同心：
    ///   R = r + 环宽
    /// 环宽取「高亮块到**玻璃边缘**的距离」，不是到行边缘的距离 ——
    /// 高亮块的外侧就是玻璃，那段间距才是真正的环宽。
    ///   = stack 留白(5) + 高亮内缩(1) = 6
    /// 所以 R = 6 + 6 = 12。
    /// R 取 10 —— 比「r + 到玻璃距离(6)」更小。
    /// 按同心公式本应 R = 6 + 6 = 12，但 45° 方向看着仍偏厚，
    /// 说明系统渲染的玻璃圆角与假设有出入，按实际观感收敛一档。
    static let glassRadius: CGFloat = 9
    /// 高亮块到**行边缘**的距离（= 高亮内缩）。

    /// 当前页该用的字号。
    private var pageFontSize: CGFloat {
        currentPage == .main ? Self.mainFontSize : Self.subFontSize
    }

    private static let itemHeight: CGFloat = 24      // 系统菜单实测值（8×24+3×11+2×5 = 235）
    private static let dividerHeight: CGFloat = 11   // 分隔线占高（线 + 上下留白）
    /// 菜单上下内边距（系统菜单约 5）。
    /// 上下左右留白。
    /// 要让「高亮块到玻璃边缘」= R − r = 16 − 6 = 10，
    /// 而高亮自身还内缩了 highlightInset(1)，所以这里取 9。
    private static let verticalPad: CGFloat = 4
    private static let shortcutGap: CGFloat = 26


    /// 当前页内容高度 —— 与宽度一样，**纯算术**，不读布局结果。
    ///
    /// 二级页严格跟随主菜单高度：绝不允许被内容撑大。
    private var contentHeight: CGFloat {
        if let m = mainMenuSize { return m.height }
        return computeHeight()
    }


    // MARK: - 显示 / 隐藏

    func toggle() {
        if isVisible {
            hide()
        } else {
            show(.main)
        }
    }

    func show(_ page: Page) {
        currentPage = page
        rebuild()

        if let p = panel, p.isVisible {
            p.setContentSize(NSSize(width: contentWidth, height: contentHeight))
            return
        }

        let host = makeHost()

        // 自绘无边框面板 —— 圆角、外壳完全由我们控制。
        // .nonactivatingPanel 保持「不抢焦点」：它不激活本 app，
        // 所以不会打断用户正在输入的东西。
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        panel = p

        position()
        p.orderFrontRegardless()
        installKeyMonitor()
    }


    /// 贴着鲸鱼浮窗弹出。
    private func position() {
        guard let p = panel else { return }

        // 有锚点就贴锚点：状态栏图标在顶栏 → 菜单朝下弹
        if let anchor = anchorViewProvider?(), let host = anchor.window {
            let inWindow = anchor.convert(anchor.bounds, to: nil)
            let onScreen = host.convertToScreen(inWindow)
            var x = onScreen.midX - p.frame.width / 2
            var y = onScreen.minY - p.frame.height - 6
            if let screen = host.screen ?? NSScreen.main {
                let v = screen.visibleFrame
                if y < v.minY + 8 { y = onScreen.maxY + 6 }   // 下方放不下就翻上去
                x = min(max(x, v.minX + 8), v.maxX - p.frame.width - 8)
            }
            p.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        // 没有锚点：退回「贴桌宠」
        let whale = NSApp.windows.first { $0 is FloatWindow }
        guard let w = whale else { p.center(); return }
        let s = w.frame
        var x = s.minX - p.frame.width - 6
        if x < 20 { x = s.maxX + 6 }
        var y = s.maxY - p.frame.height
        if y < 20 { y = 20 }
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 面板内容。
    private func makeHost() -> NSView {
        // 用 NSGlassEffectView 做底 —— 这是材质正确的关键。
        // NSVisualEffectView 是旧 API，在 Liquid Glass 下会降级成纯白。
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0,
                                                    width: contentWidth, height: contentHeight))
        glass.style = .regular
        // 玻璃层的圆角按同心关系取：R − r 应等于「高亮块到玻璃边缘的距离」。
        // 那个距离 = stack 留白(5) + 高亮内缩(1) = 6，
        // 所以 r = R − 6。R 取 12 ⇒ r = 6（高亮块的观感也正好）。
        // 若 R 取更小（如 8），r 只剩 2，高亮就成了方块 —— 反而不好看。
        glass.cornerRadius = Self.glassRadius
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }

        let container = NSView(frame: glass.bounds)
        container.autoresizingMask = [.width, .height]

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        // 下边距 = 其他边距 − 5（**有意的视觉矫正**：面板下缘有圆角，
        // 等距时看着下方会空）。别把它改成和上面一样。
        stack.edgeInsets = NSEdgeInsets(top: Self.verticalPad, left: Self.verticalPad,
                                        bottom: max(0, Self.verticalPad - 5),
                                        right: Self.verticalPad)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        glass.contentView = container
        return glass
    }

    /// 就地重建当前页（设置项改动后调用，让勾/状态跟着变）。
    func refreshCurrentPage() {
        guard isVisible else { return }
        rebuild()
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 构建

    private func rebuild() {
        for v in stack.arrangedSubviews { v.removeFromSuperview() }

        switch currentPage {
        case .main:
            buildMain()
            // 尺寸纯算术得出，不依赖布局时序 —— 首帧就是准的
            contentWidth = computeWidth()
            mainMenuSize = CGSize(width: contentWidth, height: computeHeight())
        case .analysis, .settings:
            // 二级页**跟随主菜单**：同宽，翻页时不跳
            if let m = mainMenuSize { contentWidth = m.width } else { contentWidth = computeWidth() }
            if currentPage == .analysis { buildAnalysis() } else { buildSettings() }
        }
    }

    /// 量一段文本的宽度。
    private static func textWidth(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        (s as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
        ]).width
    }

    /// 面板宽度 —— **纯算术**，不依赖任何布局结果。
    ///
    /// 之前用 fittingSize / Auto Layout 算，那些值依赖布局时序
    /// （首次弹出、翻页时都可能不准），于是出现「右边空一块 / 忽宽忽窄」。
    /// 现在只量文本：最长项 + 快捷键 + 固定留白。
    private func computeWidth() -> CGFloat {
        let size = pageFontSize
        var longest: CGFloat = 0
        for (title, _, _, shortcut) in mainItems where title != "-" {
            var w = Self.textWidth(title, size: size)
            if let sc = shortcut {
                w += Self.shortcutGap + Self.textWidth(sc, size: size)
            }
            longest = max(longest, w)
        }
        let result = max(Self.minWidth, ceil(longest) + 32)
        // 诊断：把每项的实测宽度打出来，确认算的和渲染的是否一致
        var dump: [String] = []
        for (title, _, _, shortcut) in mainItems where title != "-" {
            let tw = Self.textWidth(title, size: size)
            let sw = shortcut.map { Self.textWidth($0, size: size) } ?? 0
            dump.append("\(title)[\(Int(tw))+\(Int(sw))]")
        }
        Self.log("computeWidth longest=\(Int(longest)) result=\(Int(result)) | " + dump.joined(separator: " "))
        return result
    }

    /// 把诊断信息写到固定文件（app 无终端，只能这样看）。
    static func log(_ msg: String) {
        let line = "\(Date().timeIntervalSince1970) \(msg)\n"
        let url = URL(fileURLWithPath: "/tmp/whalefloat-menu.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 面板高度 —— 同样纯算术：逐行累加。
    private func computeHeight() -> CGFloat {
        var h = Self.verticalPad * 2
        for (title, _, _, _) in mainItems {
            h += (title == "-") ? Self.dividerHeight : Self.itemHeight
        }
        return h
    }

    private func buildMain() {
        for (title, emphasized, action, shortcut) in mainItems {
            if title == "-" { stack.addArrangedSubview(divider()); continue }
            // 主菜单用一级字号
            stack.addArrangedSubview(row(title, emphasized: emphasized,
                                         shortcut: shortcut, action: action))
        }
    }

    // MARK: - 组件

    private func divider() -> NSView {
        // 官方分隔线左右各内缩 12pt，两端不顶格
        let box = NSBox()
        box.boxType = .separator
        let wrap = NSStackView(views: [box])
        // 分隔线到面板边缘 = stack 内边距(5) + 这里(7) = 12，与系统菜单一致
        wrap.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        wrap.translatesAutoresizingMaskIntoConstraints = false
        // 必须与 computeHeight 用的 dividerHeight 一致，
        // 否则算出来的高度和实际内容不符，差额会变成底部的空档。
        wrap.heightAnchor.constraint(equalToConstant: Self.dividerHeight).isActive = true
        return wrap
    }

    /// 一行菜单项：hover 高亮、点击执行。
    func row(_ title: String, emphasized: Bool = false, tint: NSColor? = nil,
             shortcut: String? = nil,
             action: @escaping () -> Void) -> NSView {
        let btn = MenuRowButton(title: title, emphasized: emphasized, tint: tint,
                                shortcut: shortcut, fontSize: pageFontSize)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: Self.itemHeight).isActive = true
        // 宽度交给 stack.alignment = .width，不要自己加跨层级约束 ——
        // 那会和 NSStackView 内部约束冲突并抛 NSException。
        btn.onClick = { [weak self] in
            action()
            _ = self
        }
        return btn
    }

    /// 子页顶部：返回按钮 + 标题。
    func pageHeader(_ title: String) -> NSView {
        // 左上角的圆形返回按钮。
        //
        // 关键在于 **isBordered = true** —— 之前设成 false，把圆形底盘去掉了，
        // 只剩一个箭头，看不出是按钮。官方的圆形返回按钮是有底的。
        let back = NSButton()
        back.bezelStyle = .circular
        back.isBordered = true              // ← 让圆形底盘画出来
        if let img = NSImage(systemSymbolName: "chevron.backward",
                             accessibilityDescription: "返回") {
            back.image = img
            back.imagePosition = .imageOnly
        }
        back.contentTintColor = .labelColor
        back.imageScaling = .scaleProportionallyDown
        back.toolTip = "返回"
        back.translatesAutoresizingMaskIntoConstraints = false
        back.widthAnchor.constraint(equalToConstant: Self.backButtonSize).isActive = true
        back.heightAnchor.constraint(equalToConstant: Self.backButtonSize).isActive = true
        let backBox = ActionBox(button: back) { [weak self] in self?.show(.main) }
        objc_setAssociatedObject(back, "whalefloat.backbox", backBox, .OBJC_ASSOCIATION_RETAIN)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: Self.subFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor

        // 横向：返回按钮贴左、标题紧随，**剩余空间由尾部弹簧吃掉**。
        // 之前只有 [back, label] 两个视图，NSStackView 会把这组内容整体靠右摆，
        // 于是返回按钮跑到了右上角。加一个空视图兜底就不会了。
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let h = NSStackView(views: [back, label, spacer])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.distribution = .fill
        h.spacing = 8
        h.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
        h.translatesAutoresizingMaskIntoConstraints = false
        // 让弹簧吃掉所有多余宽度，其余元素自然靠左
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        return h
    }

    // MARK: - 分析页

    var analysisBuilder: ((MenuPanelController) -> [NSView])?

    private func buildAnalysis() {
        stack.addArrangedSubview(pageHeader("分析"))
        for v in analysisBuilder?(self) ?? [] { stack.addArrangedSubview(v) }
    }

    // MARK: - 设置页

    var settingsBuilder: ((MenuPanelController) -> [NSView])?

    private func buildSettings() {
        stack.addArrangedSubview(pageHeader("高级设置"))
        for v in settingsBuilder?(self) ?? [] { stack.addArrangedSubview(v) }
    }

    // MARK: - ⌥1…⌥9 快捷键

    /// 挂上键盘监听。只在面板可见时生效。
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.isVisible else { return ev }
            // 必须带 option（且不带 command/control），避免抢系统快捷键
            let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .option else { return ev }
            guard let chars = ev.charactersIgnoringModifiers,
                  let n = Int(chars), n >= 1, n <= 9 else { return ev }
            self.fireShortcut(n)
            return nil          // 吃掉这次按键
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// 执行第 n 个可点击项（跳过分隔线与子页）。
    private func fireShortcut(_ n: Int) {
        guard currentPage == .main else { return }
        var idx = 0
        for (title, _, action, shortcut) in mainItems {
            guard title != "-", shortcut != nil else { continue }
            idx += 1
            if idx == n { action(); return }
        }
    }
}

/// 菜单行按钮：左对齐、hover 变底色、按下执行。
final class MenuRowButton: NSView {
    var onClick: (() -> Void)?

    /// 高亮层的内缩与圆角 —— 按同心公式取。
    ///
    /// **两个方向的内缩必须相同**，否则无法同心：
    /// 外框圆角半径 R_out、圆心在 (R_out, R_out)；
    /// 内框内缩 (dx, dy) 后圆心在 (dx + R_in, dy + R_in)。
    /// 要两点重合须 R_in = R_out − dx 且 R_in = R_out − dy ⇒ dx = dy。
    /// 之前写 insetBy(dx: 5, dy: 0)，垂直不缩，角上两段弧的间距就会变化 —— 看着不和谐。
    private static let containerRadius: CGFloat = 13     // NSPopover 实测：内容距窗口边 13pt
    /// 文字与快捷键距边的距离（系统菜单 14）。
    private static let textInset: CGFloat = 16
    /// 高亮块到行边缘的间距 —— **四边相同**。
    ///
    /// 取值直接决定高亮块高度：行高 24 − 内缩×2。
    ///   3 → 18（偏小）
    ///   2 → 20
    ///   1 → 22（当前）—— 接近占满行高，上下各留 1，与系统菜单的观感一致
    /// 四边必须同步取值，否则到面板四边的距离就不一致了。
    static let highlightInset: CGFloat = 1
    /// 圆角按水平方向算（水平内缩更大，圆弧以它为准）。
    /// 高亮块的圆角。
    ///
    /// 之前用 13（那是从「内容距窗口边 13pt」推出来的，其实那个 13 是
    /// 箭头/阴影占的位置，不是圆角半径），明显过大。
    /// 系统菜单的高亮块圆角实际约 5–6 —— 块高 22 时看着是**圆角矩形**，
    /// 不是胶囊。
    /// 高亮块的圆角 —— 用标准值 6，不跟着玻璃层走。
    static let highlightRadius: CGFloat = 6

    private let label = NSTextField(labelWithString: "")
    private var hovered = false

    /// 右侧快捷键提示（如 ⌥1）—— 菜单右边的留白正好放它。
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let baseTint: NSColor

    /// 高亮层：官方菜单的高亮是**内缩的圆角矩形**，不是铺满整行的方块。
    /// 左右各内缩 5pt、圆角 4pt —— 这是 macOS 菜单的既定观感。
    private let highlight = NSView()

    init(title: String, emphasized: Bool, tint: NSColor?, shortcut: String? = nil,
         fontSize: CGFloat = 13) {
        baseTint = tint ?? .labelColor
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = title
        label.font = .systemFont(ofSize: fontSize, weight: emphasized ? .semibold : .regular)
        label.textColor = baseTint
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        shortcutLabel.stringValue = shortcut ?? ""
        shortcutLabel.font = .systemFont(ofSize: fontSize)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)

        highlight.wantsLayer = true
        // 抄系统的作业：macOS 的圆角是**连续曲率**（squircle），不是四分之一圆弧。
        // 只设 cornerRadius 画出来是普通圆弧，和 NSPopover 的连续圆角放在一起
        // 就会「不和谐」—— 曲线的曲率变化对不上。
        // cornerCurve = .continuous 让 CoreAnimation 用系统同款曲线。
        highlight.layer?.cornerRadius = Self.highlightRadius
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(highlight, positioned: .below, relativeTo: nil)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.textInset),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 左右各内缩 5pt —— 官方菜单就是留这点边
        // 四边等距
        highlight.frame = bounds.insetBy(dx: Self.highlightInset, dy: Self.highlightInset)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        label.textColor = .white
        shortcutLabel.textColor = NSColor.white.withAlphaComponent(0.8)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        highlight.layer?.backgroundColor = NSColor.clear.cgColor
        label.textColor = baseTint
        shortcutLabel.textColor = .tertiaryLabelColor
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// 数值输入框的回调包装：回车或失焦时提交。
///
/// 注意 popover 是 .transient 的 —— 焦点真离开时整个菜单会关，
/// 所以对「结束编辑」的处理要宽容：能提交就提交，不依赖它一定被调用。
@MainActor
final class FieldBox: NSObject, NSTextFieldDelegate {
    private let onCommit: (String) -> Void
    private weak var field: NSTextField?

    init(field: NSTextField, onCommit: @escaping (String) -> Void) {
        self.field = field
        self.onCommit = onCommit
        super.init()
        field.delegate = self
        field.target = self
        field.action = #selector(commit)
    }

    @objc private func commit() {
        onCommit(field?.stringValue ?? "")
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commit()
    }
}

/// 包装 NSSlider 的回调（NSSlider 的 target/action 需要 selector，
/// 用一个小对象接住，避免给每个滑块都写一个 @objc 方法）。
@MainActor
final class SliderBox: NSObject {
    private let onChange: (Double) -> Void
    init(slider: NSSlider, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init()
        slider.target = self
        slider.action = #selector(fire(_:))
    }
    @objc private func fire(_ s: NSSlider) { onChange(s.doubleValue) }
}

/// 包装 NSButton(checkbox) 的回调。
@MainActor
final class ToggleBox: NSObject {
    private let onChange: (Bool) -> Void
    init(button: NSButton, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init()
        button.target = self
        button.action = #selector(fire(_:))
    }
    @objc private func fire(_ b: NSButton) { onChange(b.state == .on) }
}

/// 包装普通按钮的点击。
@MainActor
final class ActionBox: NSObject {
    private let onClick: () -> Void
    init(button: NSButton, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init()
        button.target = self
        button.action = #selector(fire(_:))
    }
    @objc private func fire(_ b: NSButton) { onClick() }

    /// 供「整行可点」的手势识别器调用（那种场景没有 NSButton 参数）。
    @objc func trigger() { onClick() }}