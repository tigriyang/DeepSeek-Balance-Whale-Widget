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
