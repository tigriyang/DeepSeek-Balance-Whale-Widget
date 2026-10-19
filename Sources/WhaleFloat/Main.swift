import AppKit
import Foundation

/// 程序入口。
///
/// 形态：accessory（无 Dock 图标、无菜单栏主菜单）—— 它是个「挂在系统上的
/// 小挂件」，不该占用 Dock 位置。
///
/// 支持的命令行参数：
///   --analysis    启动后直接打开分析窗口（不弹在其他窗口前面）
///   --meal        启动后立即冒一次「想干饭」泡（看效果用，不必等到饭点）
///   --eat         启动后立即演一次「偷吃白饭」（看效果用，不必等它闲够半小时）
///   --company     启动后立即说一句加油（自测用）
///   --company-after 秒   把「忙多久才开口」改成这个值（自测用）
///   --company-selftest   离线跑一遍陪伴计时的断言后退出
///   --menu-report        打印右键菜单结构后退出（自测用）
///   --play NAME   启动后播一次指定动画（自测用）
///   --drop PATH   启动后走一遍拖图解题流程（自测用）
///   --drop-copy PATH  按真实落盘链路走一遍拖图解题（自测用）
///   --animations-report  打印动画清单与兼容性检查结果后退出（自测用）
///   --quit        把正在跑的那一份关掉
@main
enum WhaleFloatApp {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--quit") {
            quitRunningInstance()
            return
        }
        if args.contains("--animations-report") {
            printAnimationsReport()
            return
        }
        if args.contains("--menu-report") {
            _ = NSApplication.shared
            printMenuReport()
            return
        }
        if args.contains("--company-selftest") {
            let (ok, lines) = CompanyWatcher.selfTest()
            lines.forEach { print($0) }
            exit(ok ? 0 : 1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        // 强引用住 delegate：NSApplication.delegate 是 weak 的
        objc_setAssociatedObject(app, "whalefloat.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        delegate.openAnalysisOnLaunch = args.contains("--analysis")
        delegate.openMealOnLaunch = args.contains("--meal")
        delegate.openSnackOnLaunch = args.contains("--eat")
        delegate.previewCompanyOnLaunch = args.contains("--company")
        delegate.companyWorkSeconds = value(of: "--company-after", in: args).flatMap(Double.init)
        delegate.playAnimationOnLaunch = value(of: "--play", in: args)
        delegate.dropImageOnLaunch = value(of: "--drop", in: args)
        delegate.dropCopyOnLaunch = value(of: "--drop-copy", in: args)
        app.run()
    }

    /// 打印右键菜单结构（含子菜单与勾选），供命令行自测。
    @MainActor
    private static func printMenuReport() {
        let delegate = AppDelegate()
        let menu = MenuBuilder.build(target: delegate)
        func dump(_ m: NSMenu, _ depth: Int) {
            for item in m.items {
                if item.isSeparatorItem {
                    print(String(repeating: "  ", count: depth) + "---")
                    continue
                }
                let mark = item.state == .on ? "● " : "  "
                print(String(repeating: "  ", count: depth) + mark + item.title)
                if let sub = item.submenu { dump(sub, depth + 1) }
            }
        }
        dump(menu, 0)
    }

    /// 打印动画清单：可用 / 不可用（带原因），供命令行自测。
    @MainActor
    private static func printAnimationsReport() {
        let assets = AnimationCatalog.shared.reload()
        print("动画目录：\(Settings.animationsDir.path)")
        print("共 \(assets.count) 个，可用 \(assets.filter(\.isUsable).count) 个")
        for a in assets {
            let kind = a.kind == .gif ? "GIF" : "HTML"
            let src = a.source == .builtin ? "内置" : "自选"
            if a.isUsable {
                let detail = a.kind == .gif
                    ? "，\(Int(a.pixelSize.width))×\(Int(a.pixelSize.height))，\(a.frameCount) 帧，\(String(format: "%.2f", a.duration)) 秒"
                    : ""
                print("  ✓ \(a.name)（\(src) / \(kind)\(detail)）")
            } else {
                print("  ✗ \(a.name)（\(src) / \(kind)）—— \(a.problem ?? "未知")")
            }
        }
    }

    /// 取 `--key value` 形式参数的下一项；`--key=value` 也支持。
    private static func value(of key: String, in args: [String]) -> String? {
        if let i = args.firstIndex(of: key), i + 1 < args.count {
            let v = args[i + 1]
            return v.hasPrefix("--") ? nil : v
        }
        for a in args where a.hasPrefix(key + "=") {
            return String(a.dropFirst(key.count + 1))
        }
        return nil
    }

    /// 让正在运行的那一份退出。
    ///
    /// 用 NSRunningApplication 而不是发信号：走正常的 terminate 流程，
    /// 设置与窗口位置会被保存。命令行工具、快捷指令都能用。
    private static func quitRunningInstance() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: "ai.dsh.whalefloat")
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else {
            print("WhaleFloat 没有在运行")
            return
        }
        for app in others { app.terminate() }
        print("已请求退出 \(others.count) 个实例")
    }
}
