import AppKit
import Foundation

/// 分析面板 —— 做成**菜单那种小而紧凑的形态**，而不是独立大窗口。
///
/// 尺寸与观感向右键菜单看齐：宽度固定、无标题栏、内容一屏排完。
/// 结构：
///   余额 / 今日已用 / 轮数   一行
///   token 消耗折线图
///   服务可用性指示灯
@MainActor
final class AnalysisWindowController: NSObject {
    private var panel: NSPanel?
    private let chart = SparkChartView()
    private let chartCaption = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(labelWithString: "")

    var lastBalanceOK: Bool?
    var lastBalanceError: String?

    /// 与右键菜单同宽的紧凑面板。
    private static let panelWidth: CGFloat = 300
    private static let chartHeight: CGFloat = 108
    private static let pad: CGFloat = 12

    /// 内容总高。frame 布局必须自己累加，不能靠 fittingSize。
    private static var contentHeight: CGFloat {
        pad                      // 上边距
            + 18                 // 汇总行
            + 6
            + 14                 // 图表标题
            + chartHeight        // 折线图
            + 6
            + 30                 // 可用性两行
            + pad                // 下边距
    }

    func show() {
        if let p = panel {
            refresh()
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // 高度**必须手算** —— 这里是 frame 布局，fittingSize 依赖 Auto Layout，
        // 对纯 frame 布局的视图会返回 0，结果就是面板高度为 0、内容全被裁掉。
        let height = Self.contentHeight
        let content = buildContent(height: height)

        // 菜单形态：无标题栏、圆角、带阴影。
        // 用 .borderless 而不是 .titled —— 后者会带一条标题栏，跟右键菜单不是一回事。
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.isReleasedWhenClosed = false
        p.contentView = content
        panel = p
        refresh()

        // 贴着鲸鱼浮窗弹出，而不是屏幕中央 —— 菜单的观感
        positionNearFloatWindow(p)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 内容

    private func buildContent(height: CGFloat) -> NSView {
        // 用一个普通容器承载，避免 NSStackView 直接当 contentView 时约束悬空
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: height))
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        // 菜单观感：圆角 + 半透明材质底
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        if let mat = NSVisualEffectView(frame: root.bounds) as NSVisualEffectView? {
            mat.material = .menu
            mat.blendingMode = .behindWindow
            mat.state = .active
            mat.autoresizingMask = [.width, .height]
            root.addSubview(mat)
        }

        let pad = Self.pad
        var y = pad

        func add(_ v: NSView, height h: CGFloat) {
            v.frame = NSRect(x: pad, y: y, width: Self.panelWidth - pad * 2, height: h)
            v.autoresizingMask = [.width]
            root.addSubview(v)
            y += h
        }

        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = .labelColor
        add(summaryLabel, height: 18)
        y += 6

        chartCaption.font = .systemFont(ofSize: 10, weight: .regular)
        chartCaption.textColor = .tertiaryLabelColor
        add(chartCaption, height: 14)
        add(chart, height: Self.chartHeight)
        y += 6

        // 可用性：圆点 + 两行文字
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.frame = NSRect(x: pad, y: y + 2, width: 8, height: 8)
        root.addSubview(statusDot)

        statusLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.frame = NSRect(x: pad + 14, y: y - 2, width: Self.panelWidth - pad * 2 - 14, height: 15)
        root.addSubview(statusLabel)

        statusDetail.font = .systemFont(ofSize: 10)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.frame = NSRect(x: pad + 14, y: y + 13, width: Self.panelWidth - pad * 2 - 14, height: 14)
        root.addSubview(statusDetail)

        y += 30 + pad
        root.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: y)
        return root
    }

    /// 尽量贴着鲸鱼浮窗出现。
    private func positionNearFloatWindow(_ panel: NSPanel) {
        let whale = NSApp.windows.first { $0 is FloatWindow }
        guard let w = whale else { panel.center(); return }
        let s = w.frame
        var x = s.minX - panel.frame.width - 8
        if x < 40 { x = s.maxX + 8 }
        var y = s.maxY - panel.frame.height
        if y < 40 { y = 40 }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - 刷新

    func refresh() {
        let led = TurnLedger.load()
        let events = (led?.events ?? []).sorted { $0.ts < $1.ts }

        // 汇总：挤成一行
        var parts: [String] = []
        if let bal = led?.lastBalance { parts.append(String(format: "余额 ¥%.2f", bal)) }
        if let used = led?.todayUsage { parts.append(String(format: "今日 ¥%.2f", used)) }
        parts.append("\(events.count) 轮")
        summaryLabel.stringValue = parts.joined(separator: "   ")

        // 折线：最近 40 轮
        let recent = events.suffix(40)
        chart.points = recent.map {
            SparkChartView.Point(date: $0.date, value: Double($0.tokens))
        }
        if recent.count >= 2 {
            let total = recent.reduce(0) { $0 + $1.tokens }
            chartCaption.stringValue = "最近 \(recent.count) 轮消耗（合计 \(WhaleView.formatTokens(total))）"
        } else {
            chartCaption.stringValue = "最近轮次消耗"
        }

        updateStatus()
    }

    private func updateStatus() {
        let dshUp = Self.isDSHRunning()
        let apiOK = lastBalanceOK ?? false
        let allGood = dshUp && apiOK

        statusDot.layer?.backgroundColor = (allGood ? NSColor.systemGreen : NSColor.systemRed).cgColor
        statusLabel.stringValue = allGood ? "服务正常" : "服务异常"
        statusLabel.textColor = allGood ? .systemGreen : .systemRed

        var parts: [String] = [dshUp ? "DSH 运行中" : "DSH 未运行"]
        if apiOK {
            parts.append("余额接口可达")
        } else {
            parts.append("余额接口不可用")
        }
        statusDetail.stringValue = parts.joined(separator: " · ")
    }

    private static func isDSHRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:3080", "-sTCP:LISTEN"]
        p.standardOutput = Pipe()
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
