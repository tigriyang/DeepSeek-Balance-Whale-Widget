import AppKit
import WebKit

/// 动画自测（`--animation-selftest`）。
///
/// 为什么要它：动画是彩蛋，靠时机触发；等不到的时候，分不清是
/// 「时机没到」还是「画面根本画不出来」。这里绕开触发，直接问渲染层：
///   · GIF  → ImageIO 解首帧，数非透明像素
///   · HTML → 建一个离屏 WKWebView，加载页面后 takeSnapshot，数非透明像素
/// 全是自动判据，不依赖屏幕录制权限，也不用人盯屏幕。
@MainActor
enum AnimationSelfTest {
    /// 非透明像素占比低于这个数，就算「画不出东西」。
    private static let minOpaque = 0.01

    static func run() -> Int32 {
        let assets = AnimationCatalog.shared.reload()
        print("动画目录：\(Settings.animationsDir.path)")
        guard !assets.isEmpty else {
            print("✗ 一个动画都没有 —— 检查包内 Resources/animations 与用户目录")
            return 1
        }
        var failed = 0
        for a in assets {
            guard a.isUsable else {
                print("✗ \(a.name)：不可用 —— \(a.problem ?? "未知")")
                failed += 1
                continue
            }
            switch a.kind {
            case .gif:
                let ratio = opaqueRatio(loadGIF(a.url))
                report(a, ratio: ratio, detail: "\(a.frameCount) 帧 / \(String(format: "%.2f", a.duration)) 秒")
                if ratio < minOpaque { failed += 1 }
            case .html:
                let (ratio, note) = renderHTML(a.url)
                report(a, ratio: ratio, detail: note)
                if ratio < minOpaque { failed += 1 }
            }
        }
        print(failed == 0 ? "✓ 全部动画都能画出内容" : "✗ \(failed) 个动画画不出内容")
        return failed == 0 ? 0 : 1
    }

    private static func report(_ a: AnimationAsset, ratio: Double, detail: String) {
        let kind = a.kind == .gif ? "GIF" : "HTML"
        let pct = String(format: "%.1f%%", ratio * 100)
        let mark = ratio >= minOpaque ? "✓" : "✗"
        print("\(mark) \(a.name)（\(kind)\(detail.isEmpty ? "" : "，\(detail)")）非透明像素 \(pct)")
    }

    // MARK: - 渲染与统计

    private static func loadGIF(_ url: URL) -> NSImage? {
        NSImage(contentsOf: url)
    }

    /// 非透明像素占比。取 CGImage 而不是 NSImage 的 tiff —— 少一层重编码。
    private static func opaqueRatio(_ image: NSImage?) -> Double {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return 0 }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return 0 }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hit = 0
        for i in stride(from: 3, to: data.count, by: 4) where data[i] > 8 { hit += 1 }
        return Double(hit) / Double(w * h)
    }

    /// 渲染一个 HTML 动画页，返回画布非透明像素占比与说明。
    ///
    /// 判据用**页面自己的 canvas 像素**，不靠窗口截图：离屏窗口常常拿不到
    /// WebKit 的合成结果，截出来是空的 —— 那是测法的问题，不是动画的问题。
    /// 截图只作为附加信息，不参与判定。
    private static func renderHTML(_ url: URL) -> (Double, String) {
        let side: CGFloat = 180
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // 放进屏幕右下角：WebKit 会暂停「不可见窗口」的 requestAnimationFrame，
        // 放到屏幕外测出来的就是一片空白 —— 那是测法的问题。自测只闪一秒。
        if let frame = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.maxX - side - 8, y: frame.minY + 8))
        }

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        web.setValue(false, forKey: "drawsBackground")
        window.contentView = web
        window.orderFront(nil)
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        spin(1.2)   // 给页面加载与首帧绘制留时间

        var shot: NSImage?
        var done = false
        web.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in
            shot = image
            done = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !done && Date() < deadline { spin(0.05) }

        // 画布自述：先让页面主动画一帧（不依赖 rAF 是否被节流），再数非透明像素。
        let js = """
        (() => {
          const c = document.querySelector('canvas');
          if (!c) return -1;
          if (typeof render === 'function') { try { render(0); } catch (e) {} }
          try {
            const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
            let hit = 0;
            for (let i = 3; i < d.length; i += 4) if (d[i] > 8) hit++;
            return hit / (c.width * c.height);
          } catch (e) { return -2; }
        })()
        """
        var canvasRatio: Double?
        var jsDone = false
        web.evaluateJavaScript(js) { value, _ in
            if let n = value as? NSNumber { canvasRatio = n.doubleValue }
            jsDone = true
        }
        let jsDeadline = Date().addingTimeInterval(3)
        while !jsDone && Date() < jsDeadline { spin(0.05) }

        window.orderOut(nil)

        // 截图只作参考：命令行进程里 WebKit 的合成层常常拿不到，0% 属正常。
        let shotRatio = shot.map { opaqueRatio($0) } ?? -1
        let note = shotRatio >= 0.001 ? String(format: "截图 %.1f%%", shotRatio * 100) : "截图不可用"

        guard let r = canvasRatio else { return (0, "读不到画布（\(note)）") }
        if r < 0 { return (0, "画布不可用（\(Int(r))，\(note)）") }
        return (r, note)
    }

    /// 转一小圈 RunLoop：WebKit 的回调都在主线程上，阻塞等待会把它们一起卡死。
    private static func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
