import AppKit
import WebKit

/// 播放一个动画：HTML 走 WebKit，GIF 走 ImageView。
///
/// 为什么 HTML 用 WebKit 而不是自己画：动画是给「创意工坊」用的 ——
/// 用户拿 AI 生成一个透明背景的 HTML 丢进目录就能跑。
/// canvas 是 AI 最熟的绘图 API，比让它手写贝塞尔坐标靠谱得多。
///
/// 为什么 GIF 不用 WebKit：一张几十帧的 GIF 塞进 WKWebView 要建一个
/// 进程级的浏览上下文，代价远大于它带来的兼容性。ImageIO 本来就会解 GIF，
/// NSImageView 也本来就会循环播放，直接用更省。
///
/// 尺寸由外面的气泡栈决定（它给多少就画多少），这里只负责填满。
final class AnimationHost: NSView {
    private var webView: WKWebView?
    private var gifView: NSImageView?
    private var currentKey: String?

    override var isFlipped: Bool { false }

    /// 子视图不进 Auto Layout，跟着 bounds 走。
    override func layout() {
        super.layout()
        webView?.frame = bounds
        gifView?.frame = bounds
    }

    /// 播一个已经过兼容性检查的动画。
    func play(_ asset: AnimationAsset) {
        guard asset.isUsable else {
            NSLog("WhaleFloat: 动画不可用 \(asset.name) —— \(asset.problem ?? "")")
            return
        }
        switch asset.kind {
        case .html: playHTML(asset)
        case .gif: playGIF(asset)
        }
    }

    private func playHTML(_ asset: AnimationAsset) {
        // 同一个动画重复播放时不用重建 WebView，直接重载页面即可
        if currentKey == asset.url.path, let web = webView {
            teardownGIF()
            web.reload()
            return
        }
        teardown()
        currentKey = asset.url.path

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false

        let web = WKWebView(frame: bounds, configuration: config)
        // 透明背景：动画自己只画需要的东西，底色交给浮窗
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        // 不让用户拖动、选中、右键出菜单 —— 它只是个画布
        web.allowsMagnification = false
        addSubview(web)
        web.loadFileURL(asset.url, allowingReadAccessTo: asset.url.deletingLastPathComponent())

        webView = web
    }

    private func playGIF(_ asset: AnimationAsset) {
        teardown()
        currentKey = asset.url.path

        let iv = NSImageView(frame: bounds)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor.clear.cgColor
        iv.animates = true
        iv.image = NSImage(contentsOf: asset.url)
        addSubview(iv)
        gifView = iv
    }

    func stop() {
        teardown()
        currentKey = nil
    }

    private func teardown() {
        webView?.removeFromSuperview()
        webView = nil
        teardownGIF()
    }

    private func teardownGIF() {
        gifView?.animates = false
        gifView?.image = nil
        gifView?.removeFromSuperview()
        gifView = nil
    }
}
