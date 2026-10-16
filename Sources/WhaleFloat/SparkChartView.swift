import AppKit
import Foundation

/// 多轮次消耗折线图。
///
/// 横轴按**真实时间**等距（不是按轮次索引）—— 按索引会把深夜里密集的几轮
/// 和白天的稀疏轮次画得一样宽，看不出「什么时候在烧钱」。
/// 纵轴自适应量程：消耗常在某个区间小幅波动，从 0 起会把波动压成一条直线。
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = NSEdgeInsets(top: 14, left: 52, bottom: 24, right: 14)
        let plot = NSRect(
            x: inset.left,
            y: inset.top,
            width: max(1, bounds.width - inset.left - inset.right),
            height: max(1, bounds.height - inset.top - inset.bottom)
        )
        drawGrid(plot)

        guard points.count >= 2 else {
            drawPlaceholder(plot)
            return
        }

        // ── 纵轴：自适应量程 ──
        // 取数据范围上下各留 15% 余量；只有当数据本身**不接近 0** 时才这样放大，
        // 否则仍从 0 起（避免把「从 0 涨到 1M」画成剧烈波动，那是误导）。
        let values = points.map(\.value)
        let dataMax = values.max() ?? 1
        let dataMin = values.min() ?? 0
        let range = max(1, dataMax - dataMin)
        let useZeroBase = dataMin < dataMax * 0.25
        let lo = useZeroBase ? 0 : max(0, dataMin - range * 0.15)
        let hi = dataMax + range * 0.15
        let span = max(1, hi - lo)

        // ── 横轴：范围扩展到「时辰」（2 小时）的边界 ──
        // 这样刻度正好落在整点、每格一个时辰，不用再挑步长。
        let chunk: TimeInterval = 2 * 3600
        let rawT0 = points.first!.date.timeIntervalSince1970
        let rawT1 = points.last!.date.timeIntervalSince1970
        var t0 = floor(rawT0 / chunk) * chunk
        var t1 = ceil(rawT1 / chunk) * chunk
        if t1 - t0 < chunk { t1 = t0 + chunk }   // 至少显示一个时辰
        let tSpan = max(1, t1 - t0)

        func pos(_ i: Int) -> CGPoint {
            let ti = points[i].date.timeIntervalSince1970
            let x = plot.minX + plot.width * CGFloat((ti - t0) / tSpan)
            let t = (points[i].value - lo) / span
            let y = plot.maxY - plot.height * CGFloat(t)
            return CGPoint(x: x, y: y)
        }

        // 填充：**贴着数据本身**，不是贴绘图区边缘。
        // X 轴范围可能比数据宽（对齐到时辰边界），
        // 若从 plot.minX 起填，左边会拉出一个大三角。
        let fill = NSBezierPath()
        fill.move(to: CGPoint(x: pos(0).x, y: plot.maxY))
        for i in points.indices { fill.line(to: pos(i)) }
        fill.line(to: CGPoint(x: pos(points.count - 1).x, y: plot.maxY))
        fill.close()
        lineColor.withAlphaComponent(0.13).setFill()
        fill.fill()

        // 折线
        let line = NSBezierPath()
        line.lineWidth = 1.8
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        for i in points.indices {
            let p = pos(i)
            if i == 0 { line.move(to: p) } else { line.line(to: p) }
        }
        lineColor.setStroke()
        line.stroke()

        // 末端点
        let last = pos(points.count - 1)
        lineColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)).fill()

        drawAxis(plot, lo: lo, hi: hi, zeroBased: useZeroBase, t0: t0, t1: t1)
    }

    private func drawGrid(_ plot: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let g = NSBezierPath()
        g.lineWidth = 0.5
        for i in 0...3 {
            let y = plot.minY + plot.height * CGFloat(i) / 3
            g.move(to: CGPoint(x: plot.minX, y: y))
            g.line(to: CGPoint(x: plot.maxX, y: y))
        }
        g.stroke()
    }

    private func drawAxis(_ plot: NSRect, lo: Double, hi: Double, zeroBased: Bool,
                          t0: TimeInterval, t1: TimeInterval) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        // 纵轴：顶端与底端刻度
        for (i, v) in [hi, lo].enumerated() {
            let s = Self.shortNumber(v) as NSString
            let y = plot.minY + (i == 0 ? -4 : plot.height - 4)
            s.draw(at: CGPoint(x: 4, y: y), withAttributes: attrs)
        }
        if !zeroBased {
            ("（已放大）" as NSString).draw(
                at: CGPoint(x: 4, y: plot.minY + 9), withAttributes: attrs)
        }

        // ── 横轴：按「时辰」（2 小时）对齐的刻度，最多 4 个 ──
        //
        // 之前是把时间范围四等分再往上贴标签，位置虽然均匀，
        // 但时间点是 09:37 这种零碎值，看着「刻度不均匀」；
        // 数量一多标签还会互相压。
        // 改成对齐到整点：先定步长（2h 起，超出 4 个就加 2h），
        // 再从整点开始摆，标签用 HH:mm。
        // 刻度：固定每「时辰」（2 小时）一格 —— 范围已经对齐到时辰边界，
        // 所以这里必然落在整点上。
        let step: TimeInterval = 2 * 3600

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"

        var ticks: [TimeInterval] = []
        var t = ceil(t0 / step) * step
        while t <= t1 {
            ticks.append(t)
            t += step
        }
        // 跨度太小（一个整点都没落进来）时退回首尾两点
        if ticks.count < 2 { ticks = [t0, t1] }

        // 标签放不下就隔一个画一个，避免重叠
        let sample = fmt.string(from: Date(timeIntervalSince1970: ticks[0])) as NSString
        let labelW = sample.size(withAttributes: attrs).width
        var minGap: CGFloat = labelW + 10
        if ticks.count > 1 {
            minGap = max(minGap, plot.width / CGFloat(ticks.count - 1))
        }

        var lastDrawnX: CGFloat = -.greatestFiniteMagnitude
        for tick in ticks {
            let frac = (tick - t0) / max(1, t1 - t0)
            let s = fmt.string(from: Date(timeIntervalSince1970: tick)) as NSString
            let w = s.size(withAttributes: attrs).width
            var x = plot.minX + plot.width * CGFloat(frac) - w / 2
            // 贴边不越界
            x = min(max(x, plot.minX), plot.maxX - w)
            // 与上一个标签太近就跳过（首尾除外）
            if x - lastDrawnX < labelW + 6, lastDrawnX > -.greatestFiniteMagnitude { continue }
            s.draw(at: CGPoint(x: x, y: plot.maxY + 6), withAttributes: attrs)
            lastDrawnX = x
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