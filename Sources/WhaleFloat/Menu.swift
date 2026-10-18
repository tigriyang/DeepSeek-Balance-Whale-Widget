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
        let m = NSMenu()
        m.autoenablesItems = false

        add(m, "安装配套插件", #selector(AppDelegate.installPlugins), target, key: "1")

        // ── 桌宠设置 ──
        let pet = NSMenu()
        // 用勾选显示当前是开还是关 —— 不然只看到一句「开启/关闭」，
        // 不知道点下去会发生什么。
        add(pet, "显示桌宠", #selector(AppDelegate.toggleFloat), target,
            checked: target.floatWindow?.isVisible ?? false)
        pet.addItem(.separator())
        add(pet, "导入图片素材…", #selector(AppDelegate.importCharacter), target)
        hint(pet, "角色立绘，透明背景 PNG，建议 1024 像素以上")
        add(pet, "导入按下音效…", #selector(AppDelegate.importPressDownSound), target)
        hint(pet, "双击时按下的那一声，MP3 或 WAV")
        add(pet, "导入松开音效…", #selector(AppDelegate.importPressUpSound), target)
        hint(pet, "约 0.18 秒后松开的那一声，可以不给")
        add(pet, "获取仓库素材…", #selector(AppDelegate.openAssetSource), target)
        hint(pet, "去上游页面挑，下载后放回素材目录")
        m.addItem(submenu("桌宠设置", pet))

        // ── 高级设置 ──
        let adv = NSMenu()
        add(adv, "角色大小 100%", #selector(AppDelegate.setSizeLarge), target,
            checked: target.settings.characterSize >= AppDelegate.sizeLarge)
        add(adv, "角色大小 50%", #selector(AppDelegate.setSizeSmall), target,
            checked: target.settings.characterSize < AppDelegate.sizeLarge)
        adv.addItem(.separator())
        add(adv, "气泡停留 10s", #selector(AppDelegate.setBubbleLong), target,
            checked: target.settings.bubbleSeconds >= 7)
        add(adv, "气泡停留 5s", #selector(AppDelegate.setBubbleShort), target,
            checked: target.settings.bubbleSeconds < 7)
        adv.addItem(.separator())
        add(adv, "气泡内显示峰谷字", #selector(AppDelegate.toggleValley), target,
            checked: target.settings.showValley)
        add(adv, "气泡内显示时间", #selector(AppDelegate.toggleClock), target,
            checked: target.settings.showClock)
        add(adv, "启用事件音效", #selector(AppDelegate.toggleSound), target,
            checked: target.settings.soundOn)
        add(adv, "拖到边缘时吸附", #selector(AppDelegate.toggleSnap), target,
            checked: target.settings.snapEnabled)
        m.addItem(submenu("高级设置", adv))

        add(m, "分析…", #selector(AppDelegate.openLedger), target, key: "2")
        m.addItem(.separator())
        add(m, "启动 DSH GUI", #selector(AppDelegate.launchDSH), target, key: "3")
        add(m, "新的对话", #selector(AppDelegate.startNewConversation), target)
        add(m, "充值 / 查看用量…", #selector(AppDelegate.openBilling), target, key: "4")
        m.addItem(.separator())
        add(m, "退出浮窗", #selector(AppDelegate.quit), target, key: "5")
        add(m, "退出 DSH", #selector(AppDelegate.quitEverything), target, key: "6")
        m.addItem(.separator())
        // 卸载入口：清自启 + 摘插件 + 本体进废纸篓。
        // 拖进废纸篓也能删掉本体，但 launchd 配置和 DSH 插件会留下。
        add(m, "卸载 WhaleFloat…", #selector(AppDelegate.uninstallSelf), target)
        m.addItem(.separator())
        // 版本号：从 Info.plist 读，与 Finder 里看到的一致。
        // 原先 AppInfo.version 这个常量根本没人读，改它也不影响任何显示 ——
        // 真正决定显示版本的是 build-app.sh 写进 plist 的值。
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let verItem = NSMenuItem(title: "WhaleFloat \(ver)", action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        m.addItem(verItem)
        return m
    }

    /// 一个带子菜单的顶层项。
    /// 一行灰色说明，挂在某个操作项下面。
    ///
    /// 菜单项本身只能放一行字，说不清「这个槽位要什么文件」。
    /// 用缩进的禁用项补一句：新用户第一次打开菜单就知道该准备什么，
    /// 不用去翻文档。
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
                            key: String? = nil) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key ?? "")
        item.target = target
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
