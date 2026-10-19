import AppKit
import Foundation

/// 气泡当前显示的内容类型。
///
/// 设计：气泡**默认不存在**。只有「有人要说话」时才冒出来，说完过一会儿收回。
///   · 一轮对话结束 → .turn（本轮消耗）
///   · 单击鲸鱼     → .balance（余额总览）
enum BubbleKind {
    case hidden
    case balance          // 余额 + 今日已用 + 峰谷
    case turn             // 本轮消耗
    case alert            // 提醒（余额预警 / 超预算）
    case waiting          // DSH 正在等用户回答 / 授权
    case meal             // 饭点提醒（动画在角色身上，不占气泡）
    case snack            // 偷吃白饭（同上）
    case company          // 忙久了说一句加油（0.2.0 floatcompany）
    case animation        // 手动播放的一段动画（气泡里只有动画）
    case study            // 拖图给小鲸鱼后的「看图去…」

    var autoHideSeconds: TimeInterval {
        switch self {
        case .hidden: return 0
        // 默认 10 秒；实际以设置为准（见 autoHideSeconds）
        case .balance, .turn: return 10
        case .alert: return 15   // 提醒多看一会儿
        case .waiting: return 0  // 等待状态由事件解除，不靠计时
        case .meal: return 6     // 饭点提醒看一眼就够
        case .snack: return 8    // 偷吃要演完：吃、见底、打嗝
        case .company: return 6  // 一句加油，几秒就收
        case .animation: return 6
        case .study: return 5    // 「看图去」只是回执，看两眼就够
        }
    }

    /// 这一类要不要显示气泡本体。
    /// 动画现在放回气泡内部的栈里，所以吃饭/偷吃/手动播放都要显示。
    var showsBubble: Bool {
        switch self {
        case .hidden: return false
        default: return true
        }
    }
}

/// 冒泡调度器：负责「显示 → 等待 → 淡出」的时序。
///
/// 为什么要单独一个对象：气泡的出现有两个来源（点击、轮次结束），
/// 而消失只受时间控制。把时序收在一处，避免两处各自计时互相打架
/// （比如轮次泡还没消失就又点了——应当是后者接管，重置计时）。
@MainActor
final class BubblePresenter {
    private weak var view: WhaleView?
    private var hideTimer: Timer?
    private(set) var kind: BubbleKind = .hidden

    /// 自动收回秒数（来自设置；0 = 不自动收回）。
    var autoHideSeconds: Double = 10

    /// 内容变化时回调（用于填充文字）。
    var onPresent: ((BubbleKind) -> Void)?
    /// 一类泡被替换或收起时回调（用来停掉它带起的动画）。
    var onHide: ((BubbleKind) -> Void)?

    init(view: WhaleView) {
        self.view = view
    }

    /// 冒一个泡。若已有泡在显示则替换内容并重置计时。
    func show(_ newKind: BubbleKind) {
        guard newKind != .hidden else { hideNow(); return }
        // 旧的泡被顶掉时先让它收尾（比如把「干饭」动画停掉）
        if kind != .hidden, kind != newKind { onHide?(kind) }
        kind = newKind
        onPresent?(newKind)
        view?.setBubbleVisible(newKind.showsBubble)

        hideTimer?.invalidate()
        hideTimer = nil

        // 等待泡**豁免自动收回**（费扬要求）：它该持久显示，直到 DSH 的等待状态
        // 真正被解除（用户回答了 / 授权了）。
        // 注意不能靠 autoHideSeconds 的默认值来兜 —— 用户设的秒数优先级更高，
        // 会把这一豁免盖掉，于是泡在用户还在思考时就消失了。
        guard newKind != .waiting else { return }

        // 其余类型：用户设置的时长优先；未设时退回该类型的默认值
        let secs = autoHideSeconds > 0 ? autoHideSeconds : newKind.autoHideSeconds
        guard secs > 0 else { return }
        // 用 common 模式：默认模式的 Timer 在窗口拖动 / 菜单追踪期间会被挂起，
        // 那样气泡就永远不消失。
        let timer = Timer(timeInterval: secs, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    /// 立即收起。
    func hideNow() {
        let old = kind
        hideTimer?.invalidate()
        hideTimer = nil
        kind = .hidden
        if old != .hidden { onHide?(old) }
        view?.setBubbleVisible(false)
    }

    /// 当前是否有泡在显示。
    var isVisible: Bool { kind != .hidden }
}
