import AppKit
import Foundation

/// 码字陪伴的感知器（floatcompany）。
///
/// 只看「距上一次按键过去多久」—— `CGEventSource.secondsSinceLastEventType`
/// 返回的是一个时间差，拿不到键码、拿不到内容，也不需要辅助功能或输入监控权限。
/// 这是 0.2.0 里唯一一处读系统级输入状态的地方，边界就写在这里：
///
///   · 不记录任何按键，也不落盘
///   · 不区分应用 —— 在浏览器、编辑器、终端里写都算
///   · 只在「忙了很久」时说一句，不盯着每一次停顿
///
/// 呈现上也是一句话，不叠动画、不算任何位置：
/// 忙够 20 分钟冒一句「老大加油」，之后每 30 分钟再说一次，停手 5 分钟重新计时。
/// 第一版把眼睛画在立绘肩上，位置要按素材构图算 —— 换一张角色图就歪，
/// 那是开放式的 bug。说一句话没有位置问题。
@MainActor
final class CompanyWatcher {
    /// 该说一句了。
    var onEncourage: (() -> Void)?

    /// 连续忙多久才开口。太短会显得唠叨。
    var workTarget: TimeInterval = 20 * 60
    /// 开口之后的冷却。
    var cooldown: TimeInterval = 30 * 60
    /// 停手多久算「休息」，累计忙碌时间归零。
    var breakReset: TimeInterval = 5 * 60

    private let pollInterval: TimeInterval = 0.5
    private var timer: Timer?
    private var lastPoll = Date()
    /// 累计「正在写」的时间，不含长停顿。
    private(set) var busySeconds: TimeInterval = 0
    /// 下一次该开口的累计秒数。
    private var nextEncourageAt: TimeInterval
    private(set) var isBusy = false
    var enabled = true

    init() {
        nextEncourageAt = workTarget
    }

    func start() {
        timer?.invalidate()
        lastPoll = Date()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        busySeconds = 0
        nextEncourageAt = workTarget
        isBusy = false
    }

    /// 这次没接上（比如正在显示别的气泡），过一会儿再提醒。
    func deferEncouragement(by seconds: TimeInterval) {
        nextEncourageAt = busySeconds + seconds
    }

    private func poll() {
        guard enabled else { return }
        let now = Date()
        // 单次累加封顶 2 秒：机器睡眠/定时器被挂起后别把时间一次算进去
        let dt = min(2, max(0, now.timeIntervalSince(lastPoll)))
        lastPoll = now

        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .keyDown)
        guard idle.isFinite else { return }

        if advance(dt: dt, idle: idle) {
            NSLog("WhaleFloat: 连续忙了 \(Int(busySeconds / 60)) 分钟，说一句")
            onEncourage?()
        }
    }

    /// 把「一秒一秒的输入状态」折成忙碌计时。
    ///
    /// 单独拆出来是为了能离线自测：真按键需要人坐在电脑前，
    /// 而这段逻辑（累计、休息归零、冷却）才是容易写错的部分。
    /// 返回 true 表示这一刻该开口。
    func advance(dt: TimeInterval, idle: TimeInterval) -> Bool {
        if idle < 1.5 {
            busySeconds += dt
            isBusy = true
        } else {
            isBusy = false
            if idle >= breakReset {
                if busySeconds > 0 {
                    NSLog("WhaleFloat: 停手够久，忙碌计时归零（之前累计 \(Int(busySeconds / 60)) 分钟）")
                }
                busySeconds = 0
                nextEncourageAt = workTarget
            }
        }
        guard busySeconds >= nextEncourageAt else { return false }
        nextEncourageAt = busySeconds + cooldown
        return true
    }

    /// 离线自测：喂一串人造的「按键间隔」，检查什么时候开口。
    /// 返回 (是否通过, 说明)。
    static func selfTest() -> (Bool, [String]) {
        var lines: [String] = []
        let w = CompanyWatcher()
        var fired: [Double] = []

        func feed(_ seconds: Double, idle: Double) {
            var t = 0.0
            while t < seconds {
                if w.advance(dt: 0.5, idle: idle) {
                    fired.append(w.busySeconds)
                }
                t += 0.5
            }
        }

        // ① 一直写 25 分钟：只在 20 分钟时说一次
        feed(25 * 60, idle: 0.2)
        var ok = fired.count == 1 && abs(fired[0] - 20 * 60) < 2
        lines.append("\(ok ? "✓" : "✗") 连写 25 分钟 → 开口 \(fired.map { Int($0 / 60) }) 分钟（期望 [20]）")
        if !ok { return (false, lines) }

        // ② 继续写到 55 分钟：冷却 30 分钟后补一次（50 分钟）
        fired.removeAll()
        feed(30 * 60, idle: 0.2)
        ok = fired.count == 1 && abs(fired[0] - 50 * 60) < 32
        lines.append("\(ok ? "✓" : "✗") 再写 30 分钟 → 开口 \(fired.map { Int($0 / 60) }) 分钟（期望 [50]）")
        if !ok { return (false, lines) }

        // ③ 休息 6 分钟：计时归零，再写 21 分钟只开口一次
        fired.removeAll()
        feed(6 * 60, idle: 400)
        feed(21 * 60, idle: 0.2)
        ok = fired.count == 1 && abs(fired[0] - 20 * 60) < 2
        lines.append("\(ok ? "✓" : "✗") 休息后重算 → 开口 \(fired.map { Int($0 / 60) }) 分钟（期望 [20]）")
        return (ok, lines)
    }
}
