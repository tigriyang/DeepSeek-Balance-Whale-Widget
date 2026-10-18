import AppKit
import WebKit

/// 播放一个 HTML 动画。
///
/// 为什么用 WebKit 而不是自己画：动画是要给「创意工坊」用的 ——
/// 用户拿 AI 生成一个透明背景的 HTML 丢进目录就能跑。
/// canvas 是 AI 最熟的绘图 API，比让它手写贝塞尔坐标靠谱得多。
///
/// 尺寸由外部给定（浮窗里是 40×40 点），动画自己按 200×200 画再缩放。
final class AnimationHost: NSView {
    private var webView: WKWebView?
    private var currentName: String?

    override var isFlipped: Bool { false }
    /// 跟一行 12pt 的文字并排，别画太大
    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 40) }

    /// WKWebView 不参与 Auto Layout，跟着容器走就行。
    /// 放进 NSStackView 时它拿不到合适的初始尺寸，这里每次布局都对齐一次。
    override func layout() {
        super.layout()
        webView?.frame = bounds
    }



    /// 播放目录里的某个动画。找不到就什么都不做。
    func play(_ name: String) {
        guard let url = Self.locate(name) else {
            NSLog("WhaleFloat: 找不到动画 \(name)")
            return
        }
        // 同一个动画重复播放时不用重建 WebView，直接重载页面即可
        if currentName == name, let web = webView {
            web.reload()
            return
        }
        webView?.removeFromSuperview()

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false

        let web = WKWebView(frame: bounds, configuration: config)
        // 透明背景：动画自己只画需要的东西，底色交给浮窗
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        // 不让用户拖动、选中、右键出菜单 —— 它只是个画布
        web.allowsMagnification = false
        web.isHidden = false
        addSubview(web)
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        webView = web
        currentName = name
    }

    func stop() {
        webView?.removeFromSuperview()
        webView = nil
        currentName = nil
    }

    /// 动画来源：先看用户目录，再看包内。
    ///
    /// 用户目录优先，这样创意工坊的东西可以覆盖自带的那几个，
    /// 而不必改 app 本身。
    private static func locate(_ name: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = [
            home.appendingPathComponent(".dsh/whalefloat-animations/\(name)/index.html"),
        ]
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("animations/\(name)/index.html"))
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}
