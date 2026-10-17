import AppKit
import Foundation

/// 程序入口。
///
/// 形态：accessory（无 Dock 图标、无菜单栏主菜单）—— 它是个「挂在系统上的
/// 小挂件」，不该占用 Dock 位置。
///
/// 支持的命令行参数：
///   --analysis    启动后直接打开分析窗口（不弹在其他窗口前面）
///   --quit        把正在跑的那一份关掉
@main
enum WhaleFloatApp {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--quit") {
            quitRunningInstance()
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        // 强引用住 delegate：NSApplication.delegate 是 weak 的
        objc_setAssociatedObject(app, "whalefloat.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        delegate.openAnalysisOnLaunch = args.contains("--analysis")
        app.run()
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
