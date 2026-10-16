import AppKit
import Foundation

/// 程序入口。
///
/// 形态：accessory（无 Dock 图标、无菜单栏主菜单）—— 它是个「挂在系统上的
/// 小挂件」，不该占用 Dock 位置。
@main
enum WhaleFloatApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        // 强引用住 delegate：NSApplication.delegate 是 weak 的
        objc_setAssociatedObject(app, "whalefloat.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}

/// 应用委托：持有浮窗、菜单栏项、定时刷新。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var floatWindow: FloatWindow?
    private var presenter: BubblePresenter!
    private var analysisWindow: AnalysisWindowController?
    private var menuPanel: MenuPanelController?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private let client = BalanceClient()
    private var settings = Settings.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildFloatWindow()
        startRefreshLoop()

        // 对话输出 → 系统通知（带回复框）。首次会弹一次系统授权对话框。
        NotifyBridge.shared.start()

        // 从 DMG 拖进「应用程序」的首次运行：自己把 launchd 自启装好。
        // 这样安装只需一步（拖拽），不用再跑 install.sh。
        installLaunchAgentIfNeeded()

        // 首次运行引导：缺「中介」插件时提示安装。
        // 延后一拍，等浮窗先显示出来 —— 否则弹窗会盖在还没画完的界面上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            PluginInstaller.promptIfNeeded()
        }
    }

    /// 首次运行时安装 launchd 自启。
    ///
    /// plist 模板随包（Resources/launchagent.plist），里面的 __HOME__ 在这里
    /// 替换成实际路径 —— launchd 不做变量展开，只能安装时定死。
    private func installLaunchAgentIfNeeded() {
        let fm = FileManager.default
        let label = "ai.dsh.whalefloat"
        let dst = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        // 已经装过就不动（避免覆盖用户改过的配置）
        guard !fm.fileExists(atPath: dst.path) else { return }
        guard let tpl = Bundle.main.url(forResource: "launchagent", withExtension: "plist"),
              let raw = try? String(contentsOf: tpl, encoding: .utf8) else { return }
        let home = fm.homeDirectoryForCurrentUser.path
        let content = raw.replacingOccurrences(of: "__HOME__", with: home)
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try content.write(to: dst, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["load", "-w", dst.path]
            try? p.run()
            NSLog("WhaleFloat: 已安装 launchd 自启")
        } catch {
            NSLog("WhaleFloat: 自启安装失败 \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    // MARK: - 浮窗

    private func buildFloatWindow() {
        let size = settings.characterSize
        let win = FloatWindow(size: size)
        let view = win.whaleView
// 单击浮窗 —— 出余额气泡。
        view.onSingleClick = { [weak self] in self?.showBalanceBubble() }
        // 双击保留摸摸头（形变 + 音效）
        view.onDoubleClick = { [weak self] in
            self?.floatWindow?.whaleView.poke()
        }
        view.onRightClick = { [weak self] event in self?.presentContextMenu(event) }
        win.onMoved = { [weak self] origin in
            self?.settings.position = origin
            self?.settings.save()
        }
        floatWindow = win
        presenter = BubblePresenter(view: view)
        presenter.onPresent = { [weak self] _ in self?.renderBubbleContent() }

        // 启动时就把设置应用一遍 —— 否则视图自带的默认值会盖过配置文件，
        // 表现为「改了设置、重启后又变回去」。
        view.showsValley = settings.showValley
        view.showsClock = settings.showClock
        view.setSoundEnabled(settings.soundOn)
        view.reloadImages(characterName: settings.characterName)
        presenter.autoHideSeconds = settings.bubbleSeconds
        win.snapEnabled = settings.snapEnabled
        win.snapMargin = settings.snapMargin
        win.applySavedPosition(settings.position)

        // 气泡默认不显示 —— 只有轮次结束或点击才冒出来
        view.setBubbleVisible(false, animated: false)
        win.orderFrontRegardless()
    }

    /// 单击鲸鱼 → 冒泡显示余额（10 秒后自动消失）。
    private func showBalanceBubble() {
        presenter.show(.balance)
    }

    /// 双击 → 立即收起。
    private func hideBubble() {
        presenter.hideNow()
    }

    /// 在浮窗上右键：弹出**自绘的菜单面板**（全程序唯一的悬浮窗体）。
    ///
    /// 弃用 NSMenu 的原因：它放不下折线图，也没法让内容翻页
    /// （「分析」「高级设置」要原地切到子页、再返回）。
    private func presentContextMenu(_ event: NSEvent) {
        if menuPanel == nil { buildMenuPanel() }
        menuPanel?.toggle()
    }

    // MARK: - 菜单子页内容

    /// 分析页：汇总 + 折线图 + 可用性指示灯。
    private func analysisViews(_ owner: MenuPanelController) -> [NSView] {
        let led = TurnLedger.load()
        let events = (led?.events ?? []).sorted { $0.ts < $1.ts }

        var parts: [String] = []
        if let bal = led?.lastBalance { parts.append(String(format: "余额 ¥%.2f", bal)) }
        if let used = led?.todayUsage { parts.append(String(format: "今日 ¥%.2f", used)) }
        parts.append("\(events.count) 轮")

        let summary = NSTextField(labelWithString: parts.joined(separator: "   "))
        summary.font = .monospacedDigitSystemFont(ofSize: MenuPanelController.subFontSize, weight: .regular)
        summary.alignment = .center
        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.widthAnchor.constraint(equalToConstant: owner.currentContentWidth).isActive = true

        let recent = events.suffix(40)
        let chart = SparkChartView()
        chart.points = recent.map {
            SparkChartView.Point(date: $0.date, value: Double($0.tokens))
        }
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.widthAnchor.constraint(equalToConstant: owner.currentContentWidth).isActive = true
        chart.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let total = recent.reduce(0) { $0 + $1.tokens }
        let caption = NSTextField(labelWithString:
            "最近 \(recent.count) 轮（合计 \(WhaleView.formatTokens(total))）")
        caption.font = .systemFont(ofSize: MenuPanelController.subFontSize)
        caption.textColor = .tertiaryLabelColor
        caption.alignment = .center
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.widthAnchor.constraint(equalToConstant: owner.currentContentWidth).isActive = true

        // 可用性
        let dshUp = Self.isDSHRunning()
        let apiOK = (lastError == nil && lastSnapshot != nil)
        let ok = dshUp && apiOK

        let dot = NSTextField(labelWithString: ok ? "●" : "●")
        dot.font = .systemFont(ofSize: MenuPanelController.subFontSize)
        dot.textColor = ok ? .systemGreen : .systemRed

        let statusText = NSTextField(labelWithString: ok ? "服务正常" : "服务异常")
        statusText.font = .systemFont(ofSize: MenuPanelController.subFontSize)
        statusText.textColor = ok ? .systemGreen : .systemRed

        var detail: [String] = [dshUp ? "DSH 运行中" : "DSH 未运行"]
        detail.append(apiOK ? "余额接口可达" : "余额接口不可用")
        let detailLabel = NSTextField(labelWithString: detail.joined(separator: " · "))
        detailLabel.font = .systemFont(ofSize: MenuPanelController.subFontSize)
        detailLabel.textColor = .secondaryLabelColor

        // ── 三个状态灯 + 重启 ──
        // 各自独立：服务在不在、接口通不通、账本能不能读，
        // 一个问题会牵动哪几个一目了然。
        let ledgerOK = !events.isEmpty
        let chips = NSStackView(views: [
            Self.statusChip("服务", ok: dshUp),
            Self.statusChip("接口", ok: apiOK),
            Self.statusChip("账本", ok: ledgerOK),
        ])
        chips.orientation = .horizontal
        // 间距收紧：这一行总共只有 188pt 可用，
        // 三个灯 + 按钮排不下就会把末尾的「账本」挤掉一个字。
        chips.spacing = 6

        // 右侧：重启服务 —— 一件懒人操作，省得去菜单里翻
        let restart = NSButton(title: "重启", target: nil, action: nil)
        restart.bezelStyle = .inline
        restart.font = .systemFont(ofSize: MenuPanelController.subFontSize)
        restart.contentTintColor = .controlAccentColor
        let rbox = ActionBox(button: restart) { [weak self] in
            self?.menuPanel?.hide()
            self?.restartDSH()
        }
        objc_setAssociatedObject(restart, "whalefloat.restartbox", rbox, .OBJC_ASSOCIATION_RETAIN)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // 灯的压缩阻力设为必需：空间不够时压按钮，别把「账本」截成「账」
        for chip in chips.arrangedSubviews {
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let statusRow = NSStackView(views: [chips, spacer, restart])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6
        statusRow.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.widthAnchor.constraint(equalToConstant: owner.currentContentWidth).isActive = true

        return [summary, caption, chart, statusRow]
    }

    /// 一个状态灯：圆点 + 名称。绿=正常，红=异常。
    private static func statusChip(_ name: String, ok: Bool) -> NSView {
        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: MenuPanelController.subFontSize)
        dot.textColor = ok ? .systemGreen : .systemRed
        let text = NSTextField(labelWithString: name)
        text.font = .systemFont(ofSize: MenuPanelController.subFontSize)
        text.textColor = .secondaryLabelColor
        let row = NSStackView(views: [dot, text])
        row.orientation = .horizontal
        row.spacing = 3
        return row
    }

    /// DSH 是否在跑：看 3080 端口有没有监听（不打扰服务，也不需要凭据）。
    private static func isDSHRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:3080", "-sTCP:LISTEN"]
        p.standardOutput = Pipe()
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// 设置页：紧凑的行式控件（菜单形态，不是原来的表单窗口）。
    private func settingsViews(_ owner: MenuPanelController) -> [NSView] {
        // 不再需要页首 spacer —— stack 自己的 top padding 已经提供留白，
        // 再加一个会让顶部变成 5+8=13，跟底部（5）不对称。
        var views: [NSView] = []
        views.append(Self.settingsNote("角色大小", width: owner.currentContentWidth))
        views.append(Self.sliderRow(value: settings.characterSize, min: 120, max: 360, width: owner.currentContentWidth) { [weak self] v in
            guard let self else { return }
            self.settings.characterSize = v
            self.settings.save()
            self.floatWindow?.applySize(v)
        })
        views.append(Self.settingsNote("气泡停留（秒）", width: owner.currentContentWidth))
        views.append(Self.sliderRow(value: settings.bubbleSeconds, min: 2, max: 30, width: owner.currentContentWidth) { [weak self] v in
            guard let self else { return }
            self.settings.bubbleSeconds = v
            self.settings.save()
            self.presenter.autoHideSeconds = v
        })
        views.append(Self.toggleRow("气泡内显示峰谷字", settings.showValley, width: owner.currentContentWidth) { [weak self] on in
            guard let self else { return }
            self.settings.showValley = on
            self.settings.save()
            self.floatWindow?.whaleView.showsValley = on
            self.floatWindow?.whaleView.needsLayout = true
        })
        views.append(Self.toggleRow("气泡内显示时间", settings.showClock, width: owner.currentContentWidth) { [weak self] on in
            guard let self else { return }
            self.settings.showClock = on
            self.settings.save()
            self.floatWindow?.whaleView.showsClock = on
            self.floatWindow?.whaleView.needsLayout = true
        })
        views.append(Self.toggleRow("启用事件音效", settings.soundOn, width: owner.currentContentWidth) { [weak self] on in
            guard let self else { return }
            self.settings.soundOn = on
            self.settings.save()
            self.floatWindow?.whaleView.setSoundEnabled(on)
        })
        views.append(Self.toggleRow("拖到边缘时吸附", settings.snapEnabled, width: owner.currentContentWidth) { [weak self] on in
            guard let self else { return }
            self.settings.snapEnabled = on
            self.settings.save()
            self.floatWindow?.snapEnabled = on
        })
        views.append(Self.settingsButton("导入角色图片…", width: owner.currentContentWidth) { [weak self] in
            self?.importCharacter()
        })
        return views
    }

    // MARK: - 设置页的小组件

    /// 设置页里每一行的统一高度 —— 行高一致，间距才看起来均匀。
    private static let rowHeight: CGFloat = 20

    /// 行与行之间的统一间距。
    /// 每行只设 bottom（top 一律 0），这样间距只有一个来源，不会两处相加出误差。
    private static let rowGap: CGFloat = 8

    /// 标签与它下方控件的间距（比 rowGap 小，让两者成组）。
    private static let labelGap: CGFloat = 3

    private static func settingsNote(_ text: String, width: CGFloat) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: MenuPanelController.subFontSize)
        l.textColor = .secondaryLabelColor
        let row = NSStackView(views: [l])
        // 规则：所有行的 top 一律为 0，间距只由上一行的 bottom 决定。
        // 组标签紧贴它的控件（bottom 2）。
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: Self.labelGap, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private static func sliderRow(value: Double, min lo: Double, max hi: Double,
                                  width: CGFloat,
                                  onChange: @escaping (Double) -> Void) -> NSView {
        let slider = NSSlider(value: value, minValue: lo, maxValue: hi,
                              target: nil, action: nil)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: max(60, width - 28)).isActive = true
        slider.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        let box = SliderBox(slider: slider, onChange: onChange)
        objc_setAssociatedObject(slider, "whalefloat.sliderbox", box, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [slider])
        // 滑块：下方统一留 8，与下个组分开
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: Self.rowGap, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private static func toggleRow(_ title: String, _ on: Bool, width: CGFloat,
                                  onChange: @escaping (Bool) -> Void) -> NSView {
        let btn = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        btn.state = on ? .on : .off
        btn.font = .systemFont(ofSize: MenuPanelController.subFontSize)
        // 固定行高 —— 复选框的自然高度比滑块矮，不固定的话每行高矮不一，
        // 相同的间距看起来也会不匀。
        btn.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        let box = ToggleBox(button: btn, onChange: onChange)
        objc_setAssociatedObject(btn, "whalefloat.togglebox", box, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [btn])
        // 复选框 / 按钮行：同样只靠 bottom 控制
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: Self.rowGap, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private static func settingsButton(_ title: String, width: CGFloat,
                                       onClick: @escaping () -> Void) -> NSView {
        let btn = NSButton(title: title, target: nil, action: nil)
        btn.bezelStyle = .inline
        btn.font = .systemFont(ofSize: MenuPanelController.subFontSize)
        btn.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        let box = ActionBox(button: btn, onClick: onClick)
        objc_setAssociatedObject(btn, "whalefloat.actionbox", box, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [btn])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: Self.rowGap, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    /// 装配菜单面板的主菜单项与两个子页。
    private func buildMenuPanel() {
        let panel = MenuPanelController()
        // 快捷键占用 ⌥1…⌥7（分隔线不占号）。
        // 右侧留白正好显示提示，和系统菜单一致。
        // 除「分析 / 高级设置」（原地翻页）外，执行动作前都先收起菜单 ——
        // 点菜单项后菜单还杵在那儿是不对的。
        panel.mainItems = [
            ("刷新余额", false, { [weak self] in self?.menuPanel?.hide(); self?.refreshNow() }, "⌥1"),
            ("-", false, {}, nil),
            ("分析", false, { [weak self] in self?.menuPanel?.show(.analysis) }, "⌥2"),
            ("高级设置", false, { [weak self] in self?.menuPanel?.show(.settings) }, "⌥3"),
            ("-", false, {}, nil),
            ("启动 DSH GUI", false, { [weak self] in self?.menuPanel?.hide(); self?.launchDSH() }, "⌥4"),
            ("安装配套插件…", false, { [weak self] in self?.menuPanel?.hide(); self?.installPlugins() }, "⌥5"),
            ("充值 / 查看用量…", false, { [weak self] in self?.menuPanel?.hide(); self?.openBilling() }, "⌥6"),
            ("-", false, {}, nil),
            ("完全退出（并关闭 DSH）", false, { [weak self] in self?.quitEverything() }, "⌥7"),
            ("退出浮窗", false, { [weak self] in self?.quit() }, "⌥8"),
        ]
        // 气泡锚定到鲸鱼浮窗的视图上（NSPopover 需要锚点）
        panel.anchorViewProvider = { [weak self] in
            self?.floatWindow?.whaleView
        }
        panel.analysisBuilder = { [weak self] owner in self?.analysisViews(owner) ?? [] }
        panel.settingsBuilder = { [weak self] owner in self?.settingsViews(owner) ?? [] }
        menuPanel = panel
    }

    /// 菜单「安装配套插件…」：手动触发（补装 / 重装）。
    @objc func installPlugins() {
        let missing = PluginInstaller.missing()
        if missing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "配套插件都已安装"
            alert.informativeText = PluginInstaller.bundled
                .map { "  · \($0) —— \(PluginInstaller.descriptions[$0] ?? "")" }
                .joined(separator: "\n")
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        PluginInstaller.promptIfNeeded()
    }

    /// 菜单「记账明细…」。
    @objc func openLedger() {
        if analysisWindow == nil { analysisWindow = AnalysisWindowController() }
        // 把主程序手上的可用性状态传进去，供指示灯判断
        analysisWindow?.lastBalanceOK = (lastError == nil && lastSnapshot != nil)
        analysisWindow?.lastBalanceError = lastError
        analysisWindow?.show()
    }

    /// 导入自定义角色图片：选图 → 复制到 assets 目录 → 切换角色。
    @objc func importCharacter() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif]
        panel.message = "选择一张图片作为角色（建议透明背景 PNG）"
        guard panel.runModal() == .OK, let src = panel.url else { return }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Settings.assetsDir, withIntermediateDirectories: true)
            // 统一存成 custom.png，便于设置里只记一个固定名
            let dst = Settings.assetsDir.appendingPathComponent("custom.png")
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        } catch {
            let alert = NSAlert()
            alert.messageText = "导入失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }

        settings.characterName = "custom"
        settings.save()
        floatWindow?.whaleView.reloadImages(characterName: "custom")
    }

    /// 设置变化后应用。
    private func applySettings(_ s: Settings) {
        let old = settings
        settings = s
        floatWindow?.applySize(s.characterSize)
        floatWindow?.snapEnabled = s.snapEnabled
        floatWindow?.snapMargin = s.snapMargin
        presenter.autoHideSeconds = s.bubbleSeconds
        if let v = floatWindow?.whaleView {
            v.showsValley = s.showValley
            v.showsClock = s.showClock
            v.setSoundEnabled(s.soundOn)
            // 换角色才重载素材（避免每次都读盘）
            if old.characterName != s.characterName {
                v.reloadImages(characterName: s.characterName)
            }
        }
        if presenter.isVisible { renderBubbleContent() }
    }

    /// 检查提醒阈值：余额过低 / 今日超预算。
    /// 只在「越过阈值的那一刻」提醒一次，不重复打扰。
    private var warnedLowBalance = false
    private var warnedBudget = false

    private func checkAlerts(ledger: TurnLedger.Ledger?) {
        // 余额预警
        if settings.lowBalanceWarn > 0, let bal = lastSnapshot?.total {
            if bal < settings.lowBalanceWarn, !warnedLowBalance {
                warnedLowBalance = true
                alertTitle = "余额不足"
                alertBody = String(format: "当前 ¥%.2f，低于预警线 ¥%.2f", bal, settings.lowBalanceWarn)
                presenter.show(.alert)
            } else if bal >= settings.lowBalanceWarn {
                warnedLowBalance = false
            }
        }
        // 今日预算
        if settings.dailyBudget > 0, let used = ledger?.todayUsage {
            if used > settings.dailyBudget, !warnedBudget {
                warnedBudget = true
                alertTitle = "已超今日预算"
                alertBody = String(format: "今日已用 ¥%.2f，预算 ¥%.2f", used, settings.dailyBudget)
                presenter.show(.alert)
            } else if used <= settings.dailyBudget {
                warnedBudget = false
            }
        }
    }

    /// 提醒泡的标题与正文（由 checkAlerts 填）。
    private var alertTitle = ""
    private var alertBody = ""

    // MARK: - 菜单栏

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "fish",
            accessibilityDescription: "WhaleFloat"
        )
        item.button?.image?.isTemplate = true
        item.menu = MenuBuilder.build(target: self)
        statusItem = item
    }

    /// 供菜单项调用的动作集合。
    @objc func refreshNow() {
        Task { await refreshOnce() }
    }

    @objc func toggleFloat() {
        guard let win = floatWindow else { return }
        if win.isVisible {
            win.orderOut(nil)
        } else {
            win.orderFrontRegardless()
        }
    }

    /// 菜单「显示余额」：冒一下余额泡（与单击等效）。
    @objc func showBalanceFromMenu() {
        presenter.show(.balance)
    }

    /// 菜单「充值 / 查看用量」：打开平台页面。
    @objc func openBilling() {
        ExternalLinks.open(ExternalLinks.billing)
    }

    @objc func launchDSH() {
        DSHLauncher.launch()
    }

    /// 菜单「退出浮窗」：只退本程序。
    /// plist 的 KeepAlive 已改成「仅异常退出才拉起」，所以这不会自启。
    @objc func quit() {
        NSApp.terminate(nil)
    }

    /// 分析页右侧的「重启服务」：把 DSH 重新拉起来。
    ///
    /// 用途是当界面卡住 / 插件没加载时的一键恢复 ——
    /// 不必去翻菜单或开终端。会中断当前对话（DSH 重启了），这点躲不掉。
    @objc func restartDSH() {
        Task { await restartDSHAsync() }
    }

    private func restartDSHAsync() async {
        // ① 结束现有的 dsh web
        for pid in ProcessManager.pids(matching: "dsh web") {
            kill(pid, SIGTERM)
        }
        // ② 等它退干净
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        for pid in ProcessManager.pids(matching: "dsh web") {
            kill(pid, SIGKILL)
        }
        // ③ 交给启动器重新拉起（它会开浏览器）
        DSHLauncher.launch()
    }

    /// 菜单「完全退出（并关闭 DSH）」。
    ///
    /// 为什么需要：启动器（dsh-launcher）会打开浏览器页面，DSH 框架也会常驻；
    /// 它们都不属于本程序，退出浮窗时不会被带走 —— 于是出现「后台一直在冒网页」
    /// 这类残留。费扬要求有个「退出即清场」的入口。
    ///
    /// 不做二次确认（费扬要求「一定要简单」）：菜单项本身已经写明「并关闭 DSH」，
    /// 点它就是要清场；再弹一个框反而是多一道手续。怕误点的话，「退出浮窗」就在它下面。
    @objc func quitEverything() {
        let summary = ProcessManager.cleanupAll()
        NSLog("WhaleFloat: \(summary)")
        // 稍等一拍让信号送达，再退自己
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - 数据刷新

    private var lastSnapshot: BalanceSnapshot?
    private var lastError: String?
    /// 已见过的最新一轮时间戳，用来判断「有没有新的一轮结束」。
    private var lastSeenTurnTS: Double = 0

    private func startRefreshLoop() {
        Task { await refreshOnce() }
        // 每秒：走峰谷倒计时 + 检查是否有新轮次（两者都是本地读，无网络）
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // 余额每 60 秒拉一次
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { await self?.refreshOnce() }
        }
    }

    private func refreshOnce() async {
        do {
            lastSnapshot = try await client.fetch()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 每秒的本地检查：倒计时 + 新轮次检测 + 等待状态。
    private func tick() {
        // ① DSH 等待用户交互（提问 / 授权）—— 优先级最高，独占气泡
        if checkWaitingState() { return }

        // 底行含当前时间，需要每秒走；气泡可见时刷新它
        if presenter.isVisible { renderBubbleContent() }

        guard let ledger = TurnLedger.load() else { return }
        let latestTS = ledger.events?.map(\.ts).max() ?? 0
        if lastSeenTurnTS == 0 {
            // 首次启动只记录基线，不为历史轮次冒泡
            lastSeenTurnTS = latestTS
            return
        }
        if latestTS > lastSeenTurnTS {
            lastSeenTurnTS = latestTS
            // 一轮刚结束 → 冒泡显示本轮消耗
            presenter.show(.turn)
        }
    }

    /// 上一秒的等待状态（用于检测边沿变化）。
    private var lastWaitingKind: String?

    /// 检查 DSH 是否在等用户交互。
    ///
    /// 有等待 → 冒等待泡（且不自动收回，由事件解除）；
    /// 等待结束 → 立即收回。
    /// 返回 true 表示「这一刻由等待泡接管」，调用方应跳过其它气泡逻辑。
    private func checkWaitingState() -> Bool {
        let snap = WaitState.load()
        let kind = snap?.pending?.kind

        if let k = kind {
            // 新出现的等待（或从提问变成授权）才重绘
            if lastWaitingKind != k {
                lastWaitingKind = k
                alertTitle = snap?.sessionName ?? ""
                alertBody = snap?.pending?.message ?? ""
                presenter.show(.waiting)
                if let v = floatWindow?.whaleView {
                    v.setWaiting(sessionName: alertTitle, message: alertBody)
                }
            }
            return true
        }

        // 等待结束：把 waiting 泡收回
        if lastWaitingKind != nil {
            lastWaitingKind = nil
            if presenter.kind == .waiting { presenter.hideNow() }
        }
        return false
    }

    /// 按当前气泡类型填充内容。
    private func renderBubbleContent() {
        guard let view = floatWindow?.whaleView else { return }
        let ledger = TurnLedger.load()
        let now = Date()
        let latest = ledger?.events?.max { $0.ts < $1.ts }
        // 顺序要紧：先定视图类型，再填内容（update 会据此决定填哪些行）
        view.applyKind(presenter.kind)
        view.update(with: lastSnapshot, usedToday: ledger?.todayUsage, error: lastError)
        view.setValleyBadge(peak: PeakValley.isPeak(at: now))
        view.setFooter(turn: latest, clock: now)
        // 提醒视图：标题/正文由 checkAlerts 填
        if presenter.kind == .alert {
            view.setAlert(title: alertTitle, body: alertBody, at: now)
        }
        checkAlerts(ledger: ledger)
    }
}