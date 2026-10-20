import AppKit
import Foundation
import CoreGraphics

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

    /// 由命令行参数 --analysis 置位：启动完成后直接打开分析窗口。
    var openAnalysisOnLaunch = false

    /// 由 --meal 置位：启动后立即冒一次「想干饭」，用于看效果。
    var openMealOnLaunch = false

    /// 由 --eat 置位：启动后立即演一次「偷吃白饭」。
    var openSnackOnLaunch = false

    /// 由 --company 置位：启动后演示一次陪伴（8 秒）。
    var previewCompanyOnLaunch = false

    /// 由 --play 置位：启动后播一次指定动画（自测用）。
    var playAnimationOnLaunch: String?

    /// 由 --drop 置位：启动后走一遍拖图解题流程（自测用）。
    var dropImageOnLaunch: String?

    /// 由 --drop-copy 置位：按真实拖拽的落盘链路走一遍（自测用）。
    var dropCopyOnLaunch: String?

    /// 由 --company-after 置位：把「忙多久才说一句」改成这个秒数（自测用）。
    var companyWorkSeconds: Double?

    /// 码字陪伴的感知器（0.2.0 floatcompany）：忙久了说一句加油。
    private var company: CompanyWatcher?
    private var encourageIndex = 0
    private let encourageLines = [
        "老大加油",
        "辛苦了，喝口水",
        "我在这儿，慢慢写",
        "写累了就伸个懒腰",
    ]


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

        // --meal / --eat：启动即演示，不必等到饭点或闲够半小时
        if openMealOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.presenter.show(.meal)
            }
        }
        if openSnackOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.presenter.show(.snack)
            }
        }

        // --analysis：启动即开分析窗口（截图、脚本化演示都靠它）
        if openAnalysisOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openLedger()
            }
        }

        if previewCompanyOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.showEncouragement()
            }
        }
        if let name = playAnimationOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let view = self.floatWindow?.whaleView else { return }
                guard view.playAnimation(named: name) else { return }
                self.presenter.show(.animation)
            }
        }
        if let path = dropImageOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.handleDroppedImage(URL(fileURLWithPath: path))
            }
        }
        if let path = dropCopyOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                guard let img = NSImage(contentsOfFile: path),
                      let saved = DroppedImageStore.save(img, preferredName: "自测截图") else {
                    NSLog("WhaleFloat: 自测落盘失败 \(path)")
                    return
                }
                self.handleDroppedImage(saved)
            }
        }

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
            // 先摘掉合并前的三个旧插件，再装新 helper ——
            // 否则两套并存，事件会被处理两遍。
            PluginInstaller.removeLegacy()
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
        // 0.2.0 preview：拖图到角色身上 → 开新会话把图递过去
        view.enableDropTarget()
        view.onImageDropped = { [weak self] url in
            self?.handleDroppedImage(url)
        }
        view.onDropHover = { [weak self] inside in
            guard let self else { return }
            if inside {
                // 拖拽期间提示优先：别让轮末消耗泡之类的把提示挡掉
                guard self.presenter.kind != .dropHint else { return }
                self.presenter.show(.dropHint)
                self.floatWindow?.whaleView.setSimpleText("松手，我看图")
            } else if self.presenter.kind == .dropHint {
                self.presenter.hideNow()
            }
        }

        floatWindow = win
        presenter = BubblePresenter(view: view)
        // 泡被顶掉/收起时，把它带起来的动画一起停掉 ——
        // 否则「干饭」的碗会留在脸上下不来。
        presenter.onHide = { [weak self] kind in
            guard let self else { return }
            switch kind {
            case .meal, .snack, .animation:
                self.floatWindow?.whaleView.stopAnimation()
            default:
                break
            }
        }
        presenter.onPresent = { [weak self] kind in
            guard let self else { return }
            // 换到别的内容时把上一段动画停掉（动画只属于 meal/snack/animation 三种）
            if kind != .meal, kind != .snack, kind != .animation {
                self.floatWindow?.whaleView.stopAnimation()
            }
            // 吃饭泡的内容是固定的（一碗饭 + 干饭去），不走常规的文字渲染
            if kind == .meal {
                let view = self.floatWindow?.whaleView
                view?.applyKind(.meal)
                let name = self.settings.animationMeal
                let played = self.settings.animationOn && !name.isEmpty
                    && (view?.showMeal(animated: name) ?? false)
                if !played { view?.setSimpleText("想干饭") }
                return
            }
            if kind == .snack {
                let view = self.floatWindow?.whaleView
                view?.applyKind(.snack)
                let name = self.settings.animationSnack
                let played = self.settings.animationOn && !name.isEmpty
                    && (view?.showMeal(animated: name) ?? false)
                if !played { view?.setSimpleText("偷吃一口") }
                return
            }
            self.renderBubbleContent()
        }

        // 启动时就把设置应用一遍 —— 否则视图自带的默认值会盖过配置文件，
        // 表现为「改了设置、重启后又变回去」。
        view.showsValley = settings.showValley
        view.showsClock = settings.showClock
        view.setSoundEnabled(settings.soundOn)
        view.setSoundVolume(settings.soundVolume)
        view.reloadImages(characterName: settings.characterName)
        presenter.autoHideSeconds = settings.bubbleSeconds
        win.snapEnabled = settings.snapEnabled
        win.snapMargin = settings.snapMargin
        win.applySavedPosition(settings.position)

        // 气泡默认不显示 —— 只有轮次结束或点击才冒出来
        view.setBubbleVisible(false, animated: false)
        win.orderFrontRegardless()

        // 先扫一遍动画目录：菜单里要能立刻看到内置与自定义项
        AnimationCatalog.shared.reload()
        startCompanyWatcherIfNeeded()
        noteIdentityChangeIfNeeded()
        noteVersionChangeIfNeeded()
    }

    // MARK: - 升级

    /// 签名身份变了就清掉旧的屏幕录制 TCC 条目。
    ///
    /// 不清的话，系统设置里的开关还亮着（旧身份留下的），新进程却拿不到权限，
    /// 表现为「显示已授权、实际不给 DSH」。只在身份变化且当前确实无权限时清，
    /// 有权限就不动 —— 稳定的证书重签不会触发这里。
    private func noteIdentityChangeIfNeeded() {
        let token = AppIdentity.token()
        let previous = settings.lastSigningToken
        guard token != previous else { return }
        settings.lastSigningToken = token
        settings.save()
        NSLog("WhaleFloat: 签名身份 \(previous.isEmpty ? "首次" : previous) → \(token)")
        guard !previous.isEmpty else { return }

        // 身份变了，旧身份下的所有 TCC 条目都不能再用：屏幕录制、桌面、
        // 文稿/下载、辅助功能、自动化、系统设置……一律清掉，避免
        // 「系统设置里亮着、新进程拿不到」的脏权限。稳定的证书重签不会走到这里。
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "All", "ai.dsh.whalefloat"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        NSLog("WhaleFloat: 签名身份变化，已清理旧 TCC 条目（屏幕录制/文件目录/辅助功能等）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.presenter.kind == .hidden else { return }
            self.presenter.show(.company)
            self.floatWindow?.whaleView.setCompanyCaption("系统权限需重新授权")
        }
    }

    /// 记下这次运行的版本；不是首次运行就冒一句「更新到 x」。
    ///
    /// 升级路径是「下载新 dmg，覆盖 /Applications 里的应用」：
    /// 设置、素材、账本、动画、拖图缓存都原样保留，配套插件由
    /// PluginInstaller 比对内容后自动更新。这里只负责让用户知道
    /// 「新版本已经跑起来了」，否则覆盖安装没有任何可见回执。
    private func noteVersionChangeIfNeeded() {
        let current = AppInfo.version
        let previous = settings.lastVersion
        guard previous != current else { return }
        settings.lastVersion = current
        settings.save()
        NSLog("WhaleFloat: 版本 \(previous.isEmpty ? "首次运行" : previous) → \(current)")
        guard !previous.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.presenter.kind == .hidden else { return }
            self.presenter.show(.company)
            self.floatWindow?.whaleView.setCompanyCaption("更新到 \(current)")
        }
    }

    // MARK: - 陪伴（0.2.0 floatcompany）

    /// 按设置启用/停用码字陪伴。
    func startCompanyWatcherIfNeeded() {
        guard settings.companyOn else {
            company?.stop()
            company = nil
            return
        }
        if company == nil {
            let cw = CompanyWatcher()
            cw.onEncourage = { [weak self] in self?.showEncouragement() }
            company = cw
        }
        // 自测时把门槛调到几十秒；正式使用走 20 分钟
        if let secs = companyWorkSeconds {
            company?.workTarget = max(5, secs)
            company?.breakReset = max(30, secs * 2)
            company?.cooldown = max(20, secs)
        }
        company?.start()
    }

    /// 忙久了冒一句。
    ///
    /// 为什么只是一句话：动画要摆位置，位置一按素材算就会歪，
    /// 换一张角色图就是个新 bug；一句「老大加油」没有位置问题，
    /// 而且比一双眼睛更直接。要动画的地方交给饭点/偷吃。
    func showEncouragement() {
        guard settings.companyOn else { return }
        // 正在说别的事就让一让，两分钟后再提 —— 不抢话
        guard presenter.kind == .hidden || presenter.kind == .company else {
            company?.deferEncouragement(by: 120)
            return
        }
        let text = encourageLines[encourageIndex % encourageLines.count]
        encourageIndex += 1
        presenter.show(.company)
        floatWindow?.whaleView.setCompanyCaption(text)
    }

    @objc func toggleCompany() {
        settings.companyOn.toggle()
        settings.save()
        startCompanyWatcherIfNeeded()
        if !settings.companyOn, presenter.kind == .company { presenter.hideNow() }
    }

    /// 菜单「说一句加油」：不想等 20 分钟时的预览入口。
    @objc func tryCompany() { showEncouragement() }

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

    @objc func setVolume100() { applySoundVolume(1.0) }
    @objc func setVolume60() { applySoundVolume(0.6) }
    @objc func setVolume30() { applySoundVolume(0.3) }

    private func applySoundVolume(_ v: Double) {
        settings.soundVolume = v
        settings.save()
        floatWindow?.whaleView.setSoundVolume(v)
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
    /// 音效的两个槽位。
    ///
    /// 拆开而不是「一次选 1~2 个、按顺序对应」—— 顺序靠猜容易搞反，
    /// 而且用户看不到哪个文件进了哪个槽。
    enum SoundSlot {
        case pressDown, pressUp

        var fileName: String {
            switch self {
            case .pressDown: return "press-down.mp3"
            case .pressUp: return "press-up.mp3"
            }
        }
        var panelTitle: String {
            switch self {
            case .pressDown: return "选择按下时的音效"
            case .pressUp: return "选择松开时的音效"
            }
        }
    }

    @objc func importPressDownSound() { importSound(for: .pressDown) }
    @objc func importPressUpSound() { importSound(for: .pressUp) }

    private func importSound(for slot: SoundSlot) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        panel.message = slot.panelTitle
        guard panel.runModal() == .OK, let src = panel.url else { return }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Settings.assetsDir, withIntermediateDirectories: true)
            let dst = Settings.assetsDir.appendingPathComponent(slot.fileName)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            floatWindow?.whaleView.reloadSounds()
        } catch {
            alert("导入音效失败", error.localizedDescription)
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

        // 分辨率检查：桌宠最大画到 304 点，Retina 下要 608 像素。
        // 图不够大时 100% 档会把像素拉开发虚 —— 提前说一声，
        // 而不是等用户自己发现「怎么糊了」。
        if let img = NSImage(contentsOf: src),
           let rep = img.representations.first {
            let px = rep.pixelsWide
            if px < 304 {
                alert("图片太小了",
                      "这张图只有 \(px) 像素宽。两种档位都会放大，桌宠会明显发虚。建议 1024 像素以上。",
                      style: .informational)
            } else if px < 608 {
                alert("图片偏小",
                      "这张图 \(px) 像素宽。50% 档清晰，100% 档会轻微发虚。想要大尺寸，建议 1024 像素以上。",
                      style: .informational)
            }
        }

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
            v.setSoundVolume(s.soundVolume)
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
            // 桌宠藏起来时也停掉「忙久了」的计时：看不见它说话，说了也没意义
            company?.enabled = win.isVisible
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

    /// 菜单「新的对话」：让 DSH 起一个新会话，首条发「你好」。
    ///
    /// 用户不必先打开网页 —— DSH 回完会走正常的通知链路，
    /// 那一刻就能直接在通知里接着说了。
    @objc func startNewConversation() {
        // 热启动：DSH 已经在跑，直接发。
        if DSHLauncher.isRunning {
            NotifyBridge.shared.beginNewSession()
            return
        }

        // 冷启动：先把 DSH 拉起来，等它真的能收消息了再发。
        //
        // 整个过程不弹任何框 —— 用户点这一下是想说话，不是想听进度。
        // 成功与否都有回音：成功了 DSH 会回一句并推通知，超时则明确告知。
        NSLog("WhaleFloat: 新的对话 —— DSH 未运行，先冷启动")
        // 静默拉起：不开浏览器。这条路是让用户在通知里聊，
        // 把网页拽到前台既打断人，又会停在旧会话上。
        DSHLauncher.launch(openBrowser: false)
        waitForDSHReady(timeout: 120) { [weak self] ok in
            guard let self else { return }
            if ok {
                NotifyBridge.shared.beginNewSession()
            } else {
                self.alert("DSH 没起来",
                           "等了两分钟仍连不上 3080。可以点「启动 DSH GUI」看看卡在哪。")
            }
        }
    }

    /// 轮询等 DSH 可以接消息。返回是否在超时前就绪。
    ///
    /// 端口通了还不算完：DSH 要把插件加载完才认得 reply 文件，
    /// 所以再多等两秒。宁可慢一点，也别让消息写进一个还没人的信箱。
    private func waitForDSHReady(timeout: TimeInterval,
                                 completion: @escaping @MainActor (Bool) -> Void) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if DSHLauncher.isRunning {
                    // 端口通了还不算完 —— 再给插件两秒加载时间
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    completion(true)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            completion(false)
        }
    }

    /// 一个统一的小弹窗。走 NSAlert 而不是系统通知 ——
    /// 用户刚点了菜单，视线就在这儿，弹窗比通知更近。
    private func alert(_ title: String, _ body: String,
                       style: NSAlert.Style = .warning) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = style
        a.runModal()
    }

    @objc func launchDSH() {
        DSHLauncher.launch()
    }

    /// 菜单「卸载 WhaleFloat…」。
    ///
    /// 做三件事：卸自启、摘插件、把 app 本体移进废纸篓。
    /// 设置与账本保留（重装后还能用）；要一并清掉请跑仓库里的 uninstall.sh。
    ///
    /// 为什么不只靠「拖进废纸篓」：那样 launchd 配置和 DSH 插件会留下来，
    /// 系统会一直尝试拉起一个不存在的程序。
    /// （plist 里已加 PathState 兜底，但主动清一次更干净。）
    @objc func uninstallSelf() {
        let alert = NSAlert()
        alert.messageText = "卸载小鲸鱼？"
        alert.informativeText = """
            会清掉这些东西，跟仓库里 uninstall.sh 的行为一致：
              · 开机自启配置
              · DSH 里的配套插件（引用、源码、profile 副本）
              · 应用本体
              · 设置、导入的角色、拖图缓存、自定义动画
              · 账本与状态文件
              · 缓存与日志

            想保留设置与素材（换机重装用），改用 uninstall.sh --keep-data。
            """
        alert.addButton(withTitle: "全部清掉")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // ① 自启
        let plist = home.appendingPathComponent("Library/LaunchAgents/ai.dsh.whalefloat.plist")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["unload", plist.path]
        try? p.run()
        p.waitUntilExit()
        try? fm.removeItem(at: plist)

        // ② 插件引用与源码
        PluginInstaller.removeAllQuietly()

        // ③ 设置、角色、账本与状态
        //
        // 原先这里什么都不删，跟 uninstall.sh 差了四类文件 ——
        // 用户从菜单卸载完再重装，会带着上一次的设置和账本，
        // 以为是新装的却还记着旧数据。
        for path in [
            ".dsh/whalefloat.json",
            ".dsh/whalefloat-assets",
            ".dsh/whalefloat-drops",
            ".dsh/whalefloat-animations",
            ".dsh/.whalefloat-usage.json",
            ".dsh/.whalefloat-notify.json",
            ".dsh/.whalefloat-wait.json",
            ".dsh/.whalefloat-reply.json",
        ] {
            try? fm.removeItem(at: home.appendingPathComponent(path))
        }

        // ④ 缓存与偏好
        for path in [
            "Library/Caches/ai.dsh.whalefloat",
            "Library/Preferences/ai.dsh.whalefloat.plist",
            "Library/Saved Application State/ai.dsh.whalefloat.savedState",
            "Library/HTTPStorages/ai.dsh.whalefloat",
            "Library/WebKit/ai.dsh.whalefloat",
            "Library/Application Support/ai.dsh.whalefloat",
            "Library/Containers/ai.dsh.whalefloat",
        ] {
            try? fm.removeItem(at: home.appendingPathComponent(path))
        }
        UserDefaults.standard.removePersistentDomain(forName: "ai.dsh.whalefloat")
        for f in ["whalefloat-drag.log", "whalefloat-helper.log", "whalefloat-notify.log"] {
            try? fm.removeItem(at: URL(fileURLWithPath: "/tmp/\(f)"))
        }

        // ⑤ 系统授权条目：不清的话，系统设置里会留着旧条目，
        //    重装后显示「已授权」但实际不生效 —— 正是「脏权限」。
        let tcc = Process()
        tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tcc.arguments = ["reset", "All", "ai.dsh.whalefloat"]
        tcc.standardOutput = FileHandle.nullDevice
        tcc.standardError = FileHandle.nullDevice
        try? tcc.run()
        tcc.waitUntilExit()

        // ⑥ 本体进废纸篓（最后一步：前面还要用 Bundle.main）
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
        // ③ 再等端口真的松开 —— 进程没了不等于端口没了，
        //    差这一两秒就会撞 EADDRINUSE，表现成「DSH 起不来」。
        let freed = await Task.detached {
            ProcessManager.waitForPortFree(3080, timeout: 6.0)
        }.value
        if !freed {
            NSLog("WhaleFloat: 重启 DSH 时 3080 仍被占用")
        }
        // ④ 交给启动器重新拉起（它会开浏览器）
        DSHLauncher.launch()
    }

    /// 菜单「完全退出（并关闭 DSH）」。
    ///
    /// 为什么需要：启动器（dsh-launcher）会打开浏览器页面，DSH 框架也会常驻；
    /// 它们都不属于本程序，退出浮窗时不会被带走 —— 于是出现「后台一直在冒网页」
    /// 这类残留。产品侧要求有个「退出即清场」的入口。
    ///
    /// 不做二次确认（产品侧要求「一定要简单」）：菜单项本身已经写明「并关闭 DSH」，
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
    /// 今天是否已经冒过某个饭点的泡（键形如 2026-10-18-lunch）。
    private var lastMealSlot = ""

    // MARK: - 偷吃白饭

    /// 最后一次「有动静」的时刻。点桌宠、或 DSH 来了新对话都会刷新它。
    private var lastActivityAt = Date()

    /// 已经排好的偷吃时刻。nil 表示还没排（或刚被取消）。
    private var snackScheduledAt: Date?

    /// 静置多久之后开始惦记偷吃。排期也用这个长度。
    private let snackIdle: TimeInterval = 30 * 60

    /// 记一次活动。
    ///
    /// 唯一的判据是「DSH 有没有新东西推过来」—— 不看你有没有点它。
    /// 一只宠物是因为主人一直没叫它才去翻碗柜的，不是因为你摸了它一下。
    private func noteActivity() {
        lastActivityAt = Date()
        snackScheduledAt = nil
    }

    // MARK: - 拖图解题（0.2.0 whale-study）

    /// 拖图之后的开场白。
    ///
    /// 「先思路、后答案」是刻意的：直接把答案倒出来对学习没帮助，
    /// 但真做不出来也得有个结果，所以两样都给。
    /// 图里信息不全时让它明说缺什么，而不是硬猜。
    static let studyPrompt = "说说你的看法"

    /// 收到一张拖进来的图。
    ///
    /// 开新会话而不是塞进当前对话：看图是个独立任务，
    /// 混在正在聊的内容里会把两条线索搅在一起。
    /// DSH 没在跑时先拉起来（不开浏览器），等它能收消息了再递。
    private func handleDroppedImage(_ url: URL) {
        if presenter.kind != .company { presenter.show(.study) }
        NSLog("WhaleFloat: 拖入图片 \(url.lastPathComponent)")

        let send = { [weak self] in
            guard self != nil else { return }
            NotifyBridge.shared.beginNewSession(text: Self.studyPrompt, imagePath: url.path)
        }

        if DSHLauncher.isRunning {
            send()
            return
        }
        NSLog("WhaleFloat: 拖图时 DSH 没在跑，先冷启动")
        DSHLauncher.launch(openBrowser: false)
        waitForDSHReady(timeout: 120) { [weak self] ok in
            guard let self else { return }
            if ok {
                send()
            } else {
                self.alert("DSH 没起来",
                           "图已经存在 \(url.path)，但等了两分钟仍连不上 3080。")
            }
        }
    }

    /// 菜单里的「选一张图解题…」：拖不动的时候的备用入口。
    @objc func chooseImageForStudy() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .webP, .heic]
        panel.message = "选一张截图，让小鲸鱼看看"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        // 与拖拽走同一条落盘链路，后面只有一条分支要维护
        guard let img = NSImage(contentsOf: src),
              let url = DroppedImageStore.save(img, preferredName: src.deletingPathExtension().lastPathComponent) else {
            alert("这张图读不出来", src.lastPathComponent, style: .informational)
            return
        }
        handleDroppedImage(url)
    }

    // MARK: - 动画（0.2.0）

    @objc func toggleAnimationOn() {
        settings.animationOn.toggle()
        settings.save()
        if !settings.animationOn {
            floatWindow?.whaleView.stopAnimation()
        }
    }

    /// 菜单里选某个触发条件用哪个动画（空字符串 = 不播放）。
    @objc func chooseAnimation(_ sender: NSMenuItem) {
        let name = (sender.representedObject as? String) ?? ""
        guard let trigger = AnimationTrigger.allCases.first(where: { $0.menuTag == sender.tag })
        else { return }
        switch trigger {
        case .meal: settings.animationMeal = name
        case .snack: settings.animationSnack = name
        }
        settings.save()
        NSLog("WhaleFloat: 动画触发 \(trigger.rawValue) → \(name.isEmpty ? "不播放" : name)")
    }

    /// 菜单里手动播一次。
    @objc func playAnimationOnce(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        guard floatWindow?.whaleView.playAnimation(named: name) == true else { return }
        presenter.show(.animation)
    }

    @objc func rescanAnimations() {
        let assets = AnimationCatalog.shared.reload()
        let good = assets.filter(\.isUsable)
        let bad = assets.filter { !$0.isUsable }
        var lines = ["可用 \(good.count) 个："]
        lines += good.map { "  · \($0.title)（\($0.source == .builtin ? "内置" : "自选")，\($0.kind == .gif ? "GIF" : "HTML")\($0.kind == .gif ? "，\($0.frameCount) 帧 / \(String(format: "%.1f", $0.duration)) 秒" : ""))" }
        if !bad.isEmpty {
            lines.append("")
            lines.append("不可用 \(bad.count) 个：")
            lines += bad.map { "  · \($0.name) —— \($0.problem ?? "未知原因")" }
        }
        lines.append("")
        lines.append("目录：\(Settings.animationsDir.path)")
        let a = NSAlert()
        a.messageText = "动画兼容性检查"
        a.informativeText = lines.joined(separator: "\n")
        a.addButton(withTitle: "好")
        a.runModal()
    }

    /// 菜单「屏幕录制权限…」。
    ///
    /// WhaleFloat 是 DSH 的壳：DSH 的截图/OCR 由它拉起，TCC 会把权限
    /// 记在这个壳头上。重新签名后旧条目会变成「显示已打开、实际不生效」，
    /// 这里给出申请、重置、跳系统设置三条路。
    @objc func screenCapturePermission() {
        let granted = CGPreflightScreenCaptureAccess()
        let a = NSAlert()
        a.messageText = "屏幕录制权限"
        a.informativeText = granted
            ? "当前已授权。DSH 的截图/OCR 会借用这个外壳的权限。\n如果系统设置里显示已打开、实际仍不生效，用「重置并重新申请」清掉旧签名条目。"
            : "当前未授权。DSH 的截图/OCR 需要这个外壳的屏幕录制权限。\n\n如果没有弹出系统授权框：打开的设置页里点左下角 +，选择 /Applications/WhaleFloat.app，再打开开关；完成后退出并重开 WhaleFloat。\n\n系统设置里显示已打开却仍不生效时，先「重置并重新申请」清掉旧签名条目。"
        a.addButton(withTitle: granted ? "打开系统设置" : "申请权限")
        a.addButton(withTitle: "重置并重新申请")
        a.addButton(withTitle: "取消")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if !granted {
                _ = CGRequestScreenCaptureAccess()
                _ = Self.probeScreenCapture()
            }
            openScreenCaptureSettings()
        case .alertSecondButtonReturn:
            resetScreenCapturePermission()
        default:
            break
        }
    }

    /// 真正去截一张，触发 TCC 登记。
    ///
    /// 只调 CGRequestScreenCaptureAccess() 在某些 macOS 版本上不会弹框；
    /// 让本壳跑一次 screencapture，系统才会把「谁在申请屏幕」记下来。
    static func probeScreenCapture() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let tmp = "/tmp/whalefloat-tcc-probe.png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", tmp]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(atPath: tmp)
        let ok = CGPreflightScreenCaptureAccess()
        NSLog("WhaleFloat: 屏幕探测 exit=\(p.terminationStatus) preflight=\(ok)")
        return ok
    }

    private func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 清掉这个 bundle 的旧屏幕录制条目，再让壳重新申请一次。
    private func resetScreenCapturePermission() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", "ai.dsh.whalefloat"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        _ = CGRequestScreenCaptureAccess()
        _ = Self.probeScreenCapture()
        openScreenCaptureSettings()
    }

    /// 菜单「素材来源与许可…」：优先打开包内那份，离线也能看。
    @objc func openAssetNotice() {
        if let url = Bundle.main.url(forResource: "NOTICE-assets", withExtension: "md") {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = URL(string: "https://github.com/tigriyang/DeepSeek-Balance-Whale-Widget/blob/main/NOTICE-ASSETS.md") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openAnimationDir() {
        try? FileManager.default.createDirectory(at: Settings.animationsDir,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.animationsDir)
    }

    /// 静置够久就排一次偷吃，到点再演。
    ///
    /// 为什么要随机：固定时刻看着像定时任务。落在接下来半小时里的
    /// 任意一点，才像它自己拿的主意。
    private func checkSecretSnack() {
        let idle = Date().timeIntervalSince(lastActivityAt)
        guard idle >= snackIdle else {
            snackScheduledAt = nil     // 还没闲够，之前排的作废
            return
        }

        if let at = snackScheduledAt {
            guard Date() >= at else { return }
            snackScheduledAt = nil
            lastActivityAt = Date()    // 吃完重新计时，免得紧接着又吃
            guard floatWindow != nil else { return }
            presenter.show(.snack)
            NSLog("WhaleFloat: 偷吃一顿")
            return
        }

        let delay = Double.random(in: 0...snackIdle)
        snackScheduledAt = Date().addingTimeInterval(delay)
        NSLog("WhaleFloat: 静置满 30 分钟，\(Int(delay / 60)) 分钟后偷吃")
    }

    /// 到点冒个「干饭」泡。
    ///
    /// 彩蛋不写进菜单、不做开关 —— 撞见才有意思。
    /// 12:00 与 17:30 各一次，按天去重：同一饭点内反复 tick 只冒一次。
    @discardableResult
    private func checkMealTime() -> Bool {
        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute, .day, .month, .year], from: now)
        guard let h = comps.hour, let m = comps.minute else { return false }

        let slot: String
        if h == 12 && m <= 1 {
            slot = "lunch"
        } else if h == 17 && m >= 29 && m <= 31 {
            slot = "dinner"
        } else {
            return false
        }

        // 按天去重，避免这一分钟内每秒都冒一次
        let key = "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)-\(slot)"
        guard key != lastMealSlot else { return false }
        lastMealSlot = key

        guard floatWindow != nil else { return false }
        presenter.show(.meal)
        return true
    }

    private func tick() {
        // ① DSH 等待用户交互（提问 / 授权）—— 优先级最高，独占气泡
        if checkWaitingState() { return }

        // 吃饭彩蛋：到点冒一次，冒的时候不刷新别的气泡
        if checkMealTime() { return }

        // 闲太久就偷吃：优先级低于饭点提醒，高于余额刷新
        checkSecretSnack()

        // 底行含当前时间，需要每秒走；气泡可见时刷新它。
        // 吃饭泡的内容是固定的（一碗饭），别用余额文字把它刷掉。
        // 吃饭/偷吃泡的内容是动画，别用余额文字把它刷掉
        if presenter.isVisible,
           presenter.kind != .meal,
           presenter.kind != .snack,
           presenter.kind != .animation,
           presenter.kind != .company,
           presenter.kind != .dropHint,
           presenter.kind != .study {
            renderBubbleContent()
        }

        guard let ledger = TurnLedger.load() else { return }
        let latestTS = ledger.events?.map(\.ts).max() ?? 0
        if lastSeenTurnTS == 0 {
            // 首次启动只记录基线，不为历史轮次冒泡
            lastSeenTurnTS = latestTS
            return
        }
        if latestTS > lastSeenTurnTS {
            lastSeenTurnTS = latestTS
            // 一轮刚结束 → 顺便记一次活动，并把排好的偷吃作废
            noteActivity()
            // 这个开关以前一直没被读，写进设置也不生效
            if settings.turnCostBubble { presenter.show(.turn) }
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
        // 这两种泡的内容不走余额渲染，别让 update() 把字覆盖掉
        switch presenter.kind {
        case .study:
            view.applyKind(.study)
            view.setStudyCaption("我来看看")
            return
        case .dropHint:
            view.applyKind(.dropHint)
            view.setSimpleText("松手，我看图")
            return
        case .company:
            view.applyKind(.company)
            view.setCompanyCaption(encourageLines[0])
            return
        case .animation:
            // 手动播放：气泡里只放动画，没有文字
            view.applyKind(.animation)
            return
        default:
            break
        }
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