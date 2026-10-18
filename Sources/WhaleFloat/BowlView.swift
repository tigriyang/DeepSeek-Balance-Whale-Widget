import AppKit

/// 一碗饭，带咀嚼动画。
///
/// 纯代码绘制 —— 不依赖任何图片素材。碗身、冒尖的饭、热气、飞出的饭粒
/// 都是 NSBezierPath，跟气泡本身同一套笔触，放在一起不打架。
///
/// 动画是九帧循环：静止 → 左右各颠一下 → 饭粒飞出去 → 收尾。
/// 每帧换一次，肉眼看是「快速小抖」，就是咀嚼的节奏。
final class BowlView: NSView {
    private let ink = BubbleStyle.ink

    /// 九帧的展开表：水平偏移、饭粒（x, y, 透明度）、有没有热气。
    private struct Frame {
        let dx: CGFloat
        let crumbs: [(CGFloat, CGFloat, CGFloat)]
        let steam: Bool
    }

    private static let crumbSeed: [(CGFloat, CGFloat, CGFloat)] = [
        (-34, 14, 0.95), (30, 10, 0.85), (-18, 3, 0.70), (40, 24, 0.55), (10, -3, 0.75),
    ]

    private lazy var frames: [Frame] = [
        Frame(dx: 0, crumbs: [], steam: true),
        Frame(dx: -5, crumbs: [], steam: true),
        Frame(dx: 5, crumbs: [], steam: true),
        Frame(dx: -5, crumbs: Array(Self.crumbSeed.prefix(2)), steam: true),
        Frame(dx: 5, crumbs: Array(Self.crumbSeed.prefix(3)), steam: false),
        Frame(dx: 0, crumbs: Self.crumbSeed, steam: false),
        Frame(dx: 0, crumbs: Array(Self.crumbSeed.dropFirst()), steam: false),
        Frame(dx: 0, crumbs: [], steam: false),
        Frame(dx: 0, crumbs: [], steam: false),
    ]

    private var index = 0
    private var timer: Timer?

    override var isFlipped: Bool { false }
    // 别画太大 —— 它跟一行 12pt 的文字并排，碗比字还高就喧宾夺主了
    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 40) }

    /// 开始咀嚼。已经动着就重置到第一帧。
    func startChewing() {
        stopChewing()
        index = 0
        needsDisplay = true
        // 0.08 秒一帧 —— 再慢就没有「快速小抖」的感觉了
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.index += 1
            if self.index >= self.frames.count {
                // 一轮嚼完，稍停再来一轮；两轮之后停下
                self.chewRounds += 1
                if self.chewRounds >= 2 {
                    self.stopChewing()
                    self.index = self.frames.count - 1
                    self.needsDisplay = true
                    return
                }
                self.index = 0
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var chewRounds = 0

    func stopChewing() {
        timer?.invalidate()
        timer = nil
        chewRounds = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let f = frames[min(index, frames.count - 1)]
        let w: CGFloat = 34, h: CGFloat = 21
        let cx = bounds.midX + f.dx
        let x = cx - w / 2
        let y = bounds.midY - h * 0.55
        let topY = y + h

        // 热气（碗后面）
        if f.steam {
            for ddx in [-0.18, 0.18] {
                let sx = x + w * (0.5 + ddx)
                let s = NSBezierPath()
                s.move(to: NSPoint(x: sx, y: topY + h * 0.52))
                s.curve(to: NSPoint(x: sx, y: topY + h * 0.98),
                        controlPoint1: NSPoint(x: sx - w * 0.10, y: topY + h * 0.66),
                        controlPoint2: NSPoint(x: sx + w * 0.10, y: topY + h * 0.82))
                ink.withAlphaComponent(0.45).setStroke()
                s.lineWidth = 1.2
                s.stroke()
            }
        }

        // 碗身
        let body = NSBezierPath()
        body.move(to: NSPoint(x: x, y: topY))
        body.curve(to: NSPoint(x: x + w, y: topY),
                   controlPoint1: NSPoint(x: x + w * 0.16, y: y - h * 0.34),
                   controlPoint2: NSPoint(x: x + w * 0.84, y: y - h * 0.34))
        body.close()
        NSColor.white.setFill(); body.fill()
        ink.setStroke(); body.lineWidth = 1.8; body.stroke()

        // 碗口
        let rim = NSBezierPath(ovalIn: NSRect(x: x, y: topY - h * 0.20, width: w, height: h * 0.42))
        ink.setStroke(); rim.lineWidth = 1.5; rim.stroke()

        // 冒尖的饭
        for (i, ddx) in [-0.20, 0.0, 0.20].enumerated() {
            let bx = x + w * (0.5 + ddx)
            let by = topY + h * (i == 1 ? 0.26 : 0.14)
            let arc = NSBezierPath()
            arc.move(to: NSPoint(x: bx - w * 0.13, y: by - h * 0.14))
            arc.curve(to: NSPoint(x: bx + w * 0.13, y: by - h * 0.14),
                      controlPoint1: NSPoint(x: bx - w * 0.06, y: by + h * 0.20),
                      controlPoint2: NSPoint(x: bx + w * 0.06, y: by + h * 0.20))
            ink.setStroke(); arc.lineWidth = 1.3; arc.stroke()
        }

        // 飞出的饭粒：白芯 + 深边
        for (px, py, a) in f.crumbs {
            let d = NSBezierPath(ovalIn: NSRect(x: cx + px, y: topY + py, width: 3.6, height: 3.2))
            NSColor.white.setFill(); d.fill()
            ink.withAlphaComponent(a).setStroke(); d.lineWidth = 0.9; d.stroke()
        }
    }
}
