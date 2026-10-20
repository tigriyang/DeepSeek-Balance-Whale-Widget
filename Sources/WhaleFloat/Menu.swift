// AppInfo / ExternalLinks / ProcessManager / DSHLauncher / MenuBuilder。

import AppKit

/// 状态栏图标的菜单。
///
/// 用系统原生 NSMenu —— 三个理由：
///   · 「点菜单外面自动消失」是它的固有行为，不用自己监听鼠标
///   · 二级菜单、勾选状态（NSMenuItem.state）、键盘导航都是现成的
///   · 与系统其它菜单天然同款，不会有「两套样式」的问题
///
/// 放不进菜单的东西（折线图）走独立窗口，见 AnalysisWindowController。
@MainActor
enum MenuBuilder {
    static func build(target: AppDelegate) -> NSMenu {
        // 用户可能刚往动画目录里丢了一张 GIF —— 目录变了就重扫，
        // 菜单里立刻能看到，不用重启。
        AnimationCatalog.shared.refreshIfDirectoryChanged()
        let m = NSMenu()
        m.autoenablesItems = false

        // ── 桌宠设置：显示与行为 ──
        let pet = NSMenu()
        // 用勾选显示当前是开还是关 —— 不然只看到一句「开启/关闭」，
        // 不知道点下去会发生什么。
        add(pet, "显示桌宠", #selector(AppDelegate.toggleFloat), target,
            checked: target.floatWindow?.isVisible ?? false)
        pet.addItem(.separator())
        add(pet, "角色大小 100%", #selector(AppDelegate.setSizeLarge), target,
            checked: target.settings.characterSize >= AppDelegate.sizeLarge)
        add(pet, "角色大小 50%", #selector(AppDelegate.setSizeSmall), target,
            checked: target.settings.characterSize < AppDelegate.sizeLarge)
        pet.addItem(.separator())
        add(pet, "气泡停留 10s", #selector(AppDelegate.setBubbleLong), target,
            checked: target.settings.bubbleSeconds >= 7)
        add(pet, "气泡停留 5s", #selector(AppDelegate.setBubbleShort), target,
            checked: target.settings.bubbleSeconds < 7)
        pet.addItem(.separator())
        add(pet, "气泡内显示峰谷字", #selector(AppDelegate.toggleValley), target,
            checked: target.settings.showValley)
        add(pet, "气泡内显示时间", #selector(AppDelegate.toggleClock), target,
            checked: target.settings.showClock)
        add(pet, "启用事件音效", #selector(AppDelegate.toggleSound), target,
            checked: target.settings.soundOn)
        let vol = NSMenu()
        let v = target.settings.soundVolume
        add(vol, "100%", #selector(AppDelegate.setVolume100), target, checked: v >= 0.85)
        add(vol, "60%", #selector(AppDelegate.setVolume60), target, checked: v >= 0.45 && v < 0.85)
        add(vol, "30%", #selector(AppDelegate.setVolume30), target, checked: v < 0.45)
        pet.addItem(submenu("音效音量", vol))
        add(pet, "拖到边缘时吸附", #selector(AppDelegate.toggleSnap), target,
            checked: target.settings.snapEnabled)
        m.addItem(submenu("桌宠设置", pet))

        // ── 动画（0.2.0 创意工坊 + floatcompany）──
        let anim = NSMenu()
        add(anim, "启用动画", #selector(AppDelegate.toggleAnimationOn), target,
            checked: target.settings.animationOn)
        add(anim, "忙久了说句加油", #selector(AppDelegate.toggleCompany), target,
            checked: target.settings.companyOn)
        hint(anim, "只读按键间隔，不读你打了什么")
        anim.addItem(.separator())
        for trigger in AnimationTrigger.allCases {
            let sub = NSMenu()
            addAnimationChoice(sub, trigger: trigger, target: target)
            anim.addItem(submenu(trigger.title, sub))
        }
        anim.addItem(.separator())
        let playOnce = NSMenu()
        let all = AnimationCatalog.shared.usable
        if all.isEmpty {
            hint(playOnce, "还没有可用动画")
        }
        for a in all {
            add(playOnce, a.title, #selector(AppDelegate.playAnimationOnce), target,
                key: nil, represented: a.name)
        }
        anim.addItem(submenu("播放一次", playOnce))
        add(anim, "重新检查兼容性…", #selector(AppDelegate.rescanAnimations), target)
        add(anim, "打开动画目录", #selector(AppDelegate.openAnimationDir), target)
        add(anim, "说一句加油", #selector(AppDelegate.tryCompany), target)
        m.addItem(submenu("动画", anim))

        // ── 常用动作 ──
        add(m, "看图解题…", #selector(AppDelegate.chooseImageForStudy), target)
        m.items.last?.toolTip = "也可以直接把截图拖到我身上"
        add(m, "分析…", #selector(AppDelegate.openLedger), target, key: "2")
        m.addItem(.separator())
        add(m, "启动 DSH GUI", #selector(AppDelegate.launchDSH), target, key: "3")
        add(m, "新的对话", #selector(AppDelegate.startNewConversation), target)
        add(m, "充值 / 查看用量…", #selector(AppDelegate.openBilling), target, key: "4")
        m.addItem(.separator())
        add(m, "退出浮窗", #selector(AppDelegate.quit), target, key: "5")
        add(m, "退出 DSH", #selector(AppDelegate.quitEverything), target, key: "6")
        m.addItem(.separator())

        // ── 高级设置：安装、素材、卸载 ──
        let adv = NSMenu()
        add(adv, "安装配套插件", #selector(AppDelegate.installPlugins), target, key: "1")
        adv.addItem(.separator())
        add(adv, "导入图片素材…", #selector(AppDelegate.importCharacter), target)
        hint(adv, "角色立绘，透明背景 PNG，建议 1024 像素以上")
        add(adv, "导入按下音效…", #selector(AppDelegate.importPressDownSound), target)
        hint(adv, "双击时按下的那一声，MP3 或 WAV")
        add(adv, "导入松开音效…", #selector(AppDelegate.importPressUpSound), target)
        hint(adv, "约 0.18 秒后松开的那一声，可以不给")
        add(adv, "获取仓库素材…", #selector(AppDelegate.openAssetSource), target)
        hint(adv, "去上游页面挑，下载后放回素材目录")
        add(adv, "素材来源与许可…", #selector(AppDelegate.openAssetNotice), target)
        add(adv, "屏幕录制权限…", #selector(AppDelegate.screenCapturePermission), target)
        hint(adv, "DSH 截图/OCR 用；显示已开却不生效时重置")
        adv.addItem(.separator())
        // 卸载入口：清自启 + 摘插件 + 本体进废纸篓。
        // 拖进废纸篓也能删掉本体，但 launchd 配置和 DSH 插件会留下。
        add(adv, "卸载 WhaleFloat…", #selector(AppDelegate.uninstallSelf), target)
        m.addItem(submenu("高级设置", adv))

        // 版本号：从 Info.plist 读，与 Finder 里看到的一致。
        // 原先 AppInfo.version 这个常量根本没人读，改它也不影响任何显示 ——
        // 真正决定显示版本的是 build-app.sh 写进 plist 的值。
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let verItem = NSMenuItem(title: "WhaleFloat \(ver)", action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        m.addItem(verItem)
        return m
    }

    /// 一个触发条件的动画选择子菜单。
    private static func addAnimationChoice(_ m: NSMenu, trigger: AnimationTrigger,
                                           target: AppDelegate) {
        let current = currentAnimation(trigger, target.settings)
        add(m, "不播放", #selector(AppDelegate.chooseAnimation), target,
            checked: current.isEmpty, represented: "")
        m.addItem(.separator())
        let usable = AnimationCatalog.shared.usable
        if usable.isEmpty {
            hint(m, "还没有可用动画，见「打开动画目录」")
            return
        }
        for a in usable {
            add(m, a.title, #selector(AppDelegate.chooseAnimation), target,
                checked: a.name == current, represented: a.name, tag: trigger.menuTag)
        }
        let broken = AnimationCatalog.shared.broken
        if !broken.isEmpty {
            m.addItem(.separator())
            hint(m, "有 \(broken.count) 个文件没通过兼容性检查")
        }
    }

    private static func currentAnimation(_ trigger: AnimationTrigger,
                                         _ s: Settings) -> String {
        switch trigger {
        case .meal: return s.animationMeal
        case .snack: return s.animationSnack
        }
    }

    /// 一行灰色说明，挂在某个操作项下面。
    ///
    /// 菜单项本身只能放一行字，说不清「这个槽位要什么文件」。
    /// 用缩进的禁用项补一句：新用户第一次打开菜单就知道该准备什么。
    private static func hint(_ m: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        m.addItem(item)
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func add(_ m: NSMenu, _ title: String, _ sel: Selector,
                            _ target: AnyObject, checked: Bool = false,
                            key: String? = nil,
                            represented: String? = nil, tag: Int = 0) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key ?? "")
        item.target = target
        item.representedObject = represented
        item.tag = tag
        // 勾选状态用系统的那一套，而不是自己在标题里拼「✓」
        item.state = checked ? .on : .off
        if key != nil {
            // 菜单展开时按 ⌥1…⌥8 可直接触发。
            // 注意这不同于之前的全局快捷键：那时菜单没开也生效，
            // 但靠的是全局键盘监听（需要辅助功能权限）。现在只读权限，
            // 所以退回到菜单内有效。
            item.keyEquivalentModifierMask = [.option]
        }
        m.addItem(item)
    }
}
