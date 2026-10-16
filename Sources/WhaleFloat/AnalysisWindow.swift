import AppKit
import Foundation

/// 用量窗口：汇总 + 消耗折线图 + 三个状态灯。
///
/// 图表放不进 NSMenu（那里面只能放菜单项），所以它是个独立窗口。
/// 既然是独立窗口就按标准窗口来：有标题栏与红绿灯，能拖能缩放。
///
/// 布局用 Auto Layout 而不是手算 frame —— 手算在窗口缩放后必然错位。
@MainActor
final class AnalysisWindowController: NSObject {
    private var panel: NSWindow?

    private let summaryLabel = NSTextField(labelWithString: "")
    private let chartCaption = NSTextField(labelWithString: "")
    private let chart = SparkChartView()
    private let restartButton = NSButton()

    /// 三个状态灯：服务（DSH 在不在）、接口（余额接口通不通）、账本（有没有数据）
    private let svc = StatusChip(title: "服务")
    private let api = StatusChip(title: "接口")
    private let led = StatusChip(title: "账本")

    var lastBalanceOK: Bool?
    var lastBalanceError: String?
    var onRestartDSH: (() -> Void)?

    private static let minWidth: CGFloat = 320
    private static let minHeight: CGFloat = 250

    func show() {
        if let p = panel {
            refresh()
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let p = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.minHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        p.title = "用量"
        p.isReleasedWhenClosed = false
        p.contentView = buildContent()
        p.minSize = NSSize(width: Self.minWidth, height: Self.minHeight)
        panel = p
        refresh()
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 界面

    private func buildContent() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = .labelColor

        chartCaption.font = .systemFont(ofSize: 10)
        chartCaption.textColor = .tertiaryLabelColor

        restartButton.title = "重启服务"
        restartButton.bezelStyle = .rounded
        restartButton.controlSize = .small
        restartButton.target = self
        restartButton.action = #selector(restartTapped)
        restartButton.setContentHuggingPriority(.required, for: .horizontal)

        // 状态行：三个灯在左，重启按钮在右
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusRow = NSStackView(views: [svc, api, led, spacer, restartButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10
        // 灯的内容不能被压缩，空间不够时让按钮先挤
        for chip in [svc, api, led] {
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let stack = NSStackView(views: [summaryLabel, chartCaption, chart, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(10, after: chart)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),

            chart.heightAnchor.constraint(equalToConstant: 130),
            chart.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return root
    }

    @objc private func restartTapped() {
        onRestartDSH?()
    }

    // MARK: - 刷新

    func refresh() {
        let ledger = TurnLedger.load()
        let events = (ledger?.events ?? []).sorted { $0.ts < $1.ts }

        var parts: [String] = []
        if let bal = ledger?.lastBalance { parts.append("余额 " + AppInfo.money(bal)) }
        if let used = ledger?.todayUsage { parts.append("今日 " + AppInfo.money(used)) }
        parts.append("\(events.count) 轮")
        summaryLabel.stringValue = parts.joined(separator: "   ")

        // 折线：最近 40 轮（X 轴会再按 3 小时窗口裁一次）
        let recent = events.suffix(40)
        chart.points = recent.map {
            SparkChartView.Point(date: $0.date, value: Double($0.tokens))
        }
        if recent.count >= 2 {
            let total = recent.reduce(0) { $0 + $1.tokens }
            chartCaption.stringValue = "最近 \(recent.count) 轮（合计 \(WhaleView.formatTokens(total))）"
        } else {
            chartCaption.stringValue = "最近轮次消耗"
        }

        // 三个灯各自独立：出问题时一眼看出卡在哪一环。
        let dshUp = DSHLauncher.isRunning
        svc.set(ok: dshUp, detail: dshUp ? "DSH 在跑" : "DSH 没起来")

        let apiOK = lastBalanceOK ?? false
        api.set(ok: apiOK,
                detail: apiOK ? "余额接口正常" : (lastBalanceError ?? "余额接口不可达"))

        let hasLedger = !events.isEmpty
        led.set(ok: hasLedger,
                detail: hasLedger ? "\(events.count) 条记录" : "还没有记录")
    }

}

/// 一个状态灯：圆点 + 名称。悬停能看到细节。
@MainActor
final class StatusChip: NSStackView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4

        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 3.5
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        label.stringValue = title
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        addArrangedSubview(dot)
        addArrangedSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(ok: Bool, detail: String) {
        dot.layer?.backgroundColor = (ok ? NSColor.systemGreen : NSColor.systemRed).cgColor
        toolTip = detail
    }
}