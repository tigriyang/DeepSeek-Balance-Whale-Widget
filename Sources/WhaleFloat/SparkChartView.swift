import AppKit
import Foundation

/// 多轮次消耗折线图。
///
/// 坐标约定：
///   · 横轴**固定显示最近 3 小时**（不是自适应跨度）——
///     固定窗口才能一眼比较「这会儿比刚才烧得多不多」。
///     右端对齐到整点，于是刻度天然落在整点。
///   · 纵轴**从 0 起**，到本轮最大值多一点余量。
///     从 0 起是诚实的读法：消耗从 0 涨到 1M 就是涨了 1M，
///     截断纵轴会把小波动画成剧烈起伏，那是误导。
///   · 纵轴带轴线与刻度，能读出大致数值。
final class SparkChartView: NSView {
    struct Point {
        let date: Date
        let value: Double
    }

    var points: [Point] = [] {
        didSet { needsDisplay = true }
    }

    var lineColor: NSColor = NSColor(srgbRed: 0.36, green: 0.47, blue: 0.86, alpha: 1)

    override var isFlipped: Bool { true }

    /// 横轴固定窗口：3 小时。
    private static let windowSeconds: TimeInterval = 3 * 3600
    /// 纵轴刻度条数（含 0 与顶端）。
    private static let yTickCount = 4

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 左边留 52pt 给纵轴标签，底下留 24pt 给时间标签
        let inset = NSEdgeInsets(top: 14, left: 52, bottom: 24, right: 14)
        let plot = NSRect(
            x: inset.left,
            y: inset.top,
            width: max(1, bounds.width - inset.left - inset.right),
            height: max(1, bounds.height - inset.top - inset.bottom)
        )

        guard points.count >= 2 else {
            drawEmptyAxes(plot)
            drawPlaceholder(plot)
            return
        }

        // ── 纵轴：0 到最大值（上端留 8% 余量，免得峰顶贴着上边框）──
        let dataMax = points.map(\.value).max() ?? 1
        let lo: Double = 0
        let hi = max(1, dataMax * 1.08)
        let span = max(1, hi - lo)

        // ── 横轴：固定 3 小时窗口，右端对齐到整点 ──
        let rawT1 = points.last!.date.timeIntervalSince1970
        let hour: TimeInterval = 3600
        let t1 = ceil(rawT1 / hour) * hour
        let t0 = t1 - Self.windowSeconds
        let tSpan = Self.windowSeconds

        drawYAxis(plot, lo: lo, hi: hi)
        drawGrid(plot)

        func pos(_ i: Int) -> CGPoint {
            let ti = points[i].date.timeIntervalSince1970
            let x = plot.minX + plot.width * CGFloat((ti - t0) / tSpan)
            let t = (points[i].value - lo) / span
            let y = plot.maxY - plot.height * CGFloat(t)
            return CGPoint(x: x, y: y)
        }

        // 只画落在窗口内的点（3 小时之外的不进画面）
        let visible = points.indices.filter {
            let ti = points[$0].date.timeIntervalSince1970
            return ti >= t0 && ti <= t1
        }
        let idx = visible.isEmpty ? Array(points.indices.suffix(1)) : visible

        // 填充：贴着数据本身，不贴绘图区边缘
        if let first = idx.first, let last = idx.last {
            let fill = NSBezierPath()
            fill.move(to: CGPoint(x: pos(first).x, y: plot.maxY))
            for i in idx { fill.line(to: pos(i)) }
            fill.line(to: CGPoint(x: pos(last).x, y: plot.maxY))
            fill.close()
            lineColor.withAlphaComponent(0.13).setFill()
            fill.fill()

            let line = NSBezierPath()
            line.lineWidth = 1.8
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            for (n, i) in idx.enumerated() {
                let p = pos(i)
                if n == 0 { line.move(to: p) } else { line.line(to: p) }
            }
            lineColor.setStroke()
            line.stroke()

            // 末端点
            let end = pos(last)
            lineColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)).fill()
        }

        drawTimeAxis(plot, t0: t0, t1: t1)
    }

    // MARK: - 坐标轴

    /// 纵轴：左边缘竖线 + 刻度短横线 + 数值标签。
    private func drawYAxis(_ plot: NSRect, lo: Double, hi: Double) {
        let axisColor = NSColor.separatorColor.withAlphaComponent(0.8)
        axisColor.setStroke()
        let axis = NSBezierPath()
        axis.lineWidth = 0.8
        axis.move(to: CGPoint(x: plot.minX, y: plot.minY))
        axis.line(to: CGPoint(x: plot.minX, y: plot.maxY))
        axis.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        for i in 0...Self.yTickCount {
            let frac = Double(i) / Double(Self.yTickCount)
            let v = lo + (hi - lo) * frac
            let y = plot.maxY - plot.height * CGFloat(frac)

            // 刻度短横线
            let tick = NSBezierPath()
            tick.lineWidth = 0.8
            tick.move(to: CGPoint(x: plot.minX - 3, y: y))
            tick.line(to: CGPoint(x: plot.minX, y: y))
            tick.stroke()

            // 标签右对齐贴着轴线
            let s = Self.shortNumber(v) as NSString
            let w = s.size(withAttributes: attrs).width
            s.draw(at: CGPoint(x: plot.minX - 6 - w, y: y - 5), withAttributes: attrs)
        }
    }

    /// 横轴：自下而上的水平网格线（与纵轴刻度对齐）。
    private func drawGrid(_ plot: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        let g = NSBezierPath()
        g.lineWidth = 0.5
        for i in 0...Self.yTickCount {
            let y = plot.minY + plot.height * CGFloat(i) / CGFloat(Self.yTickCount)
            g.move(to: CGPoint(x: plot.minX, y: y))
            g.line(to: CGPoint(x: plot.maxX, y: y))
        }
        g.stroke()
    }

    /// 数据不足时也要有坐标轴，不然是个空框。
    private func drawEmptyAxes(_ plot: NSRect) {
        drawYAxis(plot, lo: 0, hi: 1)
        drawGrid(plot)
    }

    /// 横轴时间刻度：3 小时窗口 → 每小时一格，共 4 个。
    private func drawTimeAxis(_ plot: NSRect, t0: TimeInterval, t1: TimeInterval) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"

        let step: TimeInterval = 3600
        var t = t0
        var lastRight: CGFloat = -.greatestFiniteMagnitude
        while t <= t1 + 1 {
            let frac = (t - t0) / max(1, t1 - t0)
            let s = fmt.string(from: Date(timeIntervalSince1970: t)) as NSString
            let w = s.size(withAttributes: attrs).width
            var x = plot.minX + plot.width * CGFloat(frac) - w / 2
            x = min(max(x, plot.minX), plot.maxX - w)
            // 太挤就跳过（首尾一定画）
            if x < lastRight + 6, lastRight > -.greatestFiniteMagnitude {
                t += step
                continue
            }
            s.draw(at: CGPoint(x: x, y: plot.maxY + 6), withAttributes: attrs)
            lastRight = x + w
            t += step
        }
    }

    private func drawPlaceholder(_ plot: NSRect) {
        let text = "还不够两轮数据" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2),
                  withAttributes: attrs)
    }

    static func shortNumber(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
}
