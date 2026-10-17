import AppKit
import Foundation

/// 应用委托：持有浮窗、菜单栏项、定时刷新。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var floatWindow: FloatWindow?
    private var presenter: BubblePresenter!
    private var analysisWindow: AnalysisWindowController?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var balanceRefreshTimer: Timer?
    private let client = BalanceClient()
    var settings = Settings.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例守卫必须放在最前面 —— 宁可什么都不做，也别多起一只鲸鱼。
        guard SingleInstance.acquire() else {
            NSLog("WhaleFloat: 已有实例在跑，本次启动退出")
            NSApp.terminate(nil)
            return
        }

        // 先把设置规范到合法档位。
        //
        // 档位从「滑块调任意值」改成「固定两档」之后，旧配置里会留下
        // 3.7、4、152 这类中间值：菜单按阈值判定它属于哪一档，
        // 实际生效的却还是那个旧值 —— 表现为「显示的和实际的不一致」。
        normalizeSettings()

        buildStatusItem()


        // 素材就绪才创建浮窗 —— 否则开箱就是一只空白方块。
        // 缺素材时退化为「只有状态栏图标」的形态：
        // 余额、分析、设置这些照常可用，等用户导入角色图再启用桌宠。
        if CharacterAssets.isReady {
            buildFloatWindow()
        } else {
            NSLog("WhaleFloat: 未找到角色素材，以「仅状态栏」模式启动")
        }
        startRefreshLoop()

        // 日历访问：用于判断「今天是不是法定假日」。
        // 不是敏感权限（只读节假日标记，不读用户自己的日程），
        // 首次会弹一次系统授权框，拒绝也不影响其它功能。
        SystemHoliday.requestAccessIfNeeded()

        // 节假日数据：内置快照已随包，这里静默检查一次更新
        // （今年与明年；明年通常在 11 月前后才公布，拉不到就跳过）。
        HolidayCalendar.refresh()

        // 对话输出 → 系统通知（带回复框）。首次会弹一次系统授权对话框。
        NotifyBridge.shared.start()
        // 点通知 → 跳到 DSH 看这条对话
        NotifyBridge.onOpenConversation = { [weak self] in self?.jumpToDSH() }

        // 从 DMG 拖进「应用程序」的首次运行：自己把 launchd 自启装好。
        // 这样安装只需一步（拖拽），不用再跑 install.sh。
        installLaunchAgentIfNeeded()

        // 补齐缺失的配套插件 —— 静默进行，不弹框。
        // 插件随包发布，装上就好；弹模态框会阻塞主线程，
        // 自动化流程碰上它就卡住了。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            PluginInstaller.installMissingQuietly()
        }
    }

    /// 首次运行时安装 launchd 自启。
    ///
    /// plist 模板随包（Resources/launchagent.plist）。路径写死为
    /// /Applications/WhaleFloat.app —— 安装位置是固定的，不需要占位符。
    private func installLaunchAgentIfNeeded() {
        let fm = FileManager.default
        let label = "ai.dsh.whalefloat"
        let dst = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        // 已经装过就不动（避免覆盖用户改过的配置）
        guard !fm.fileExists(atPath: dst.path) else { return }
        guard let tpl = Bundle.main.url(forResource: "launchagent", withExtension: "plist"),
              let raw = try? String(contentsOf: tpl, encoding: .utf8) else { return }
        // 不再需要替换占位符 —— plist 里写的是固定的 /Applications 路径
        let content = raw
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

    /// 菜单即将展开 —— 用最新的设置重建一次，勾选才是对的。
    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = MenuBuilder.build(target: self)
        // 先把项目取出来再搬运。
        // 直接 for item in fresh.items 里调 fresh.removeItem 是边遍历边改数组 ——
        // 数组缩短会让索引错位，结果是菜单项丢几个。
        let items = Array(fresh.items)
        menu.removeAllItems()
        for item in items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    /// 把设置里越界的值收拢到合法档位（老配置升级上来时会遇到）。
    func normalizeSettings() {
        var changed = false
        // 气泡停留：只有 10 与 5 两档，以 7 为界
        if settings.bubbleSeconds != 10 && settings.bubbleSeconds != 5 {
            settings.bubbleSeconds = settings.bubbleSeconds >= 7 ? 10 : 5
            changed = true
        }
        // 角色大小：只有 100%（304）与 50%（152）两档
        let large = Self.sizeLarge, small = Self.sizeSmall
        if settings.characterSize != large && settings.characterSize != small {
            let mid = (large + small) / 2
            settings.characterSize = settings.characterSize >= mid ? large : small
            changed = true
        }
        if changed {
            NSLog("WhaleFloat: 设置已规范到合法档位（气泡 \(settings.bubbleSeconds)s，尺寸 \(Int(settings.characterSize))）")
        }
        // 无论有没有改动都写回一次：解码是宽容的，缺字段会取默认值，
        // 但那只是内存里的值 —— 落盘一次，文件才是完整且与生效值一致的。
        settings.save()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    // MARK: - 浮窗

    /// 角色素材是否就绪（决定开箱是「桌宠」还是「仅状态栏」）。
    enum CharacterAssets {
        static var isReady: Bool {
            let names = [WhaleView.defaultRoleFile, "custom.png"]
            let fm = FileManager.default
            return names.contains { name in
                AssetPaths.candidates(for: name).contains { fm.fileExists(atPath: $0) }
            }
        }
    }

    private func buildFloatWindow() {
        let size = settings.characterSize
        let win = FloatWindow(size: size)
        let view = win.whaleView
// 单击浮窗 —— 出余额气泡。
        // 单击的行为分两种：
        //   · 平时            → 冒一下余额
        //   · 正在等你回答时   → 跳到 DSH 去处理（对应上游 issue #238）
        // 后者更符合直觉：气泡写着「等你回答」，点它自然是去回答。
        view.onSingleClick = { [weak self] in
            guard let self else { return }
            if self.presenter.kind == .waiting {
                self.presenter.hideNow()
                self.jumpToDSH()
                return
            }
            self.showBalanceBubble()
        }
        // 双击保留摸摸头（形变 + 音效）
        view.onDoubleClick = { [weak self] in
            self?.floatWindow?.whaleView.poke()
        }
        // 右键桌宠 = 左键桌宠 = 冒一下余额。
        // 桌宠只管当宠物；菜单统一从状态栏图标进，两处不再各有一份。
        view.onRightClick = { [weak self] _ in
            self?.showBalanceBubble()
        }
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

    /// 跳到 DSH 的界面（不负责启动）。
    ///
    /// 与 launchDSH 的分工：
    ///   · jumpToDSH  —— DSH 已经在跑，只是把浏览器切过去
    ///   · launchDSH  —— 不确定在不在跑，交给启动器处理（会复用认证 URL、必要时拉起）
    /// 通知点击、等待气泡点击走前者；状态栏左键和菜单项走后者。
    func jumpToDSH() {
        guard let url = URL(string: "http://127.0.0.1:3080") else { return }
        NSWorkspace.shared.open(url)
    }

    private func showBalanceBubble() {
        presenter.show(.balance)
    }

    /// 双击 → 立即收起。
    private func hideBubble() {
        presenter.hideNow()
    }

    // MARK: - 菜单子页内容

    /// 分析页：汇总 + 折线图 + 可用性指示灯。
    /// 一个状态灯：圆点 + 名称。绿=正常，红=异常。
    private static func statusChip(_ name: String, ok: Bool) -> NSView {
        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: AppInfo.subFontSize)
        dot.textColor = ok ? .systemGreen : .systemRed
        let text = NSTextField(labelWithString: name)
        text.font = .systemFont(ofSize: AppInfo.subFontSize)
        text.textColor = .secondaryLabelColor
        let row = NSStackView(views: [dot, text])
        row.orientation = .horizontal
        row.spacing = 3
        return row
    }

    /// 设置页：紧凑的行式控件（菜单形态，不是原来的表单窗口）。
    // MARK: - 设置页的小组件

    /// 设置页里每一行的统一高度 —— 行高一致，间距才看起来均匀。
    /// 角色尺寸的两档。
    ///
    /// 按原图 610×610 取整数比 2:1：
    ///   大 304pt → Retina 下 608px，接近 1:1 像素映射，最清晰
    ///   小 152pt → 304px，正好是原图的一半，重采样干净
    /// 都取整，避免半像素造成的模糊。
    static let sizeLarge: CGFloat = 304
    static let sizeSmall: CGFloat = 152

    /// 装配菜单面板的主菜单项与两个子页。
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
        PluginInstaller.installWithFeedback()
    }

    /// 菜单「记账明细…」。
    @objc func openLedger() {
        if analysisWindow == nil {
            let w = AnalysisWindowController()
            // 窗口里那个「重启服务」按钮接到这里 ——
            // DSH 卡住时不用去翻终端。
            w.onRestartDSH = { [weak self] in self?.restartDSH() }
            analysisWindow = w
        }
        // 把主程序手上的可用性状态传进去，供指示灯判断
        analysisWindow?.lastBalanceOK = (lastError == nil && lastSnapshot != nil)
        analysisWindow?.lastBalanceError = lastError
        analysisWindow?.show()
    }

    /// 导入自定义角色图片：选图 → 复制到 assets 目录 → 切换角色。
    /// 应用角色尺寸档位。
    ///
    /// 必须 refreshMenu —— 档位是「选中项打勾」表达的，
    /// 值改了但面板不重建，勾就还停在原来那一行。
    private func applyCharacterSize(_ v: CGFloat) {
        settings.characterSize = v
        settings.save()
        floatWindow?.applySize(v)
    }

    /// 应用气泡停留档位。同样要重建面板（理由同上）。
    private func applyBubbleSeconds(_ v: Double) {
        settings.bubbleSeconds = v
        settings.save()
        presenter.autoHideSeconds = v
    }

    // MARK: - 菜单动作（高级设置）

    @objc func setSizeLarge() { applyCharacterSize(Self.sizeLarge) }
    @objc func setSizeSmall() { applyCharacterSize(Self.sizeSmall) }
    @objc func setBubbleLong() { applyBubbleSeconds(10) }
    @objc func setBubbleShort() { applyBubbleSeconds(5) }

    @objc func toggleValley() {
        settings.showValley.toggle()
        settings.save()
        floatWindow?.whaleView.showsValley = settings.showValley
        floatWindow?.whaleView.needsLayout = true
    }

    @objc func toggleClock() {
        settings.showClock.toggle()
        settings.save()
        floatWindow?.whaleView.showsClock = settings.showClock
    }

    @objc func toggleSound() {
        settings.soundOn.toggle()
        settings.save()
        floatWindow?.whaleView.setSoundEnabled(settings.soundOn)
    }

    @objc func toggleSnap() {
        settings.snapEnabled.toggle()
        settings.save()
        floatWindow?.snapEnabled = settings.snapEnabled
    }

    /// 菜单「导入音效素材…」—— 选两个 mp3，分别作为按下 / 松开音。
    @objc func importSound() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        panel.message = "选择 1~2 个音效（第一个作按下音，第二个作松开音）"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Settings.assetsDir, withIntermediateDirectories: true)
            let names = ["press-down.mp3", "press-up.mp3"]
            for (i, src) in panel.urls.prefix(2).enumerated() {
                let dst = Settings.assetsDir.appendingPathComponent(names[i])
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
            // 只给了一个 → 松开音沿用同一个
            if panel.urls.count == 1 {
                let dst = Settings.assetsDir.appendingPathComponent("press-up.mp3")
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: panel.urls[0], to: dst)
            }
            floatWindow?.whaleView.reloadSounds()
        } catch {
            let alert = NSAlert()
            alert.messageText = "导入音效失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// 「获取角色素材…」—— 只指路，不代劳。
    ///
    /// 素材版权属于上游（其 PROVENANCE 写明「仅用于运行本插件」），
    /// 所以这里不代下载，只做两件事：
    ///   1. 打开本机的素材文件夹（用户放进去即生效）
    ///   2. 在浏览器打开上游素材页
    /// 取用是用户自己的动作。
    @objc func openAssetSource() {
        // 素材目录可能还不存在，先建出来，否则 Finder 打开会失败
        try? FileManager.default.createDirectory(at: Settings.assetsDir,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.assetsDir)
        if let url = URL(string: Settings.assetSourceURL) {
            NSWorkspace.shared.open(url)
        }
    }

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

        // 之前如果是「仅状态栏」模式，这时才把桌宠启用起来
        if floatWindow == nil {
            buildFloatWindow()
        } else {
            floatWindow?.whaleView.reloadImages(characterName: "custom")
        }
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
        statusItem = item

        // 左右键分工：
        //   左键 → 打开 DSH GUI（最常做的事，一步到位）
        //   右键 → 弹菜单
        // 所以这里**不设 item.menu** —— 一旦设了，系统会接管左键去弹菜单，
        // 我们就分不出左右键了。
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 状态栏图标被点。
    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let isRight = NSApp.currentEvent?.type == .rightMouseUp
        if isRight {
            let menu = MenuBuilder.build(target: self)
            menu.delegate = self
            // 从图标正下方弹出。popUp 是同步的（会阻塞到菜单关闭），
            // 这是 AppKit 菜单的标准行为。
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: sender.bounds.height + 4),
                       in: sender)
        } else {
            launchDSH()
        }
    }


    /// 供菜单项调用的动作集合。
    @objc func refreshNow() {
        Task { await refreshOnce() }
    }

    @objc func toggleFloat() {
        if let win = floatWindow {
            if win.isVisible {
                win.orderOut(nil)
            } else {
                win.orderFrontRegardless()
            }
            return
        }
        // 浮窗还没建（启动时缺素材）—— 素材到位了就地补建
        if CharacterAssets.isReady {
            buildFloatWindow()
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

    /// 菜单「卸载 WhaleFloat…」。
    ///
    /// 做三件事：卸自启、摘插件、把 app 本体移进废纸篓。
    /// 设置与账本保留（重装后还能用），要一并清掉请跑 uninstall.sh --purge。
    ///
    /// 为什么不只靠「拖进废纸篓」：那样 launchd 配置和 DSH 插件会留下来，
    /// 系统会一直尝试拉起一个不存在的程序。
    /// （plist 里已加 PathState 兜底，但主动清一次更干净。）
    @objc func uninstallSelf() {
        let alert = NSAlert()
        alert.messageText = "卸载小鲸鱼？"
        alert.informativeText = """
            会做三件事：
              · 移除开机自启
              · 从 DSH 里摘除配套插件
              · 把应用移进废纸篓

            设置与账本会保留。要彻底清空请运行仓库里的 uninstall.sh --purge。
            """
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // ① 自启
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/ai.dsh.whalefloat.plist")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["unload", plist.path]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: plist)

        // ② 插件引用
        PluginInstaller.removeAllQuietly()

        // ③ 本体进废纸篓
        let bundle = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([bundle]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
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

        // 两个定时器都必须加进 .common 模式。
        //
        // scheduledTimer 默认只挂 .default —— 一旦用户打开菜单或拖动窗口，
        // RunLoop 会切到 .eventTracking，定时器就停了：
        // 表现为「菜单开着的时候余额和倒计时不动」。
        // 其它几处定时器早就用了 .common，这里当时漏了。

        // 每秒：走峰谷倒计时 + 检查是否有新轮次（本地读，无网络）
        let tickTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(tickTimer, forMode: .common)
        refreshTimer = tickTimer

        // 余额每 60 秒拉一次
        let balanceTimer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { await self?.refreshOnce() }
        }
        RunLoop.main.add(balanceTimer, forMode: .common)
        balanceRefreshTimer = balanceTimer
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
