import AppKit
import Foundation

/// 浮窗气泡的配色与排版常量。
///
/// 数值取自网页版鲸鱼的实测计算样式（2026-10-15 用 Playwright 读取
/// `dshwv-trow` / `dshwv-amount` / `dshwv-hint` 的 computedStyle），
/// 按比例缩放到本程序的窗口尺寸，保持同样的视觉层次。
enum BubbleStyle {
    /// 靛蓝色系（网页版主色）：标题与金额。
    static let ink = NSColor(srgbRed: 83/255, green: 107/255, blue: 169/255, alpha: 1)
    /// 浅蓝灰：次要信息（今日已用）。
    static let inkSoft = NSColor(srgbRed: 159/255, green: 176/255, blue: 217/255, alpha: 1)
    /// 谷价绿（网页版「谷」徽章的绿）。
    static let valleyGreen = NSColor(srgbRed: 0.13, green: 0.66, blue: 0.29, alpha: 1)
    /// 高峰橙红（网页版「峰」徽章的色）。
    static let peakRed = NSColor(srgbRed: 0.86, green: 0.29, blue: 0.25, alpha: 1)

    /// 字号梯度：网页版为 25.2 / 46.8 / 20.5 px，比例约 1 : 1.86 : 0.81。
    /// 本程序窗口较小，等比例缩到下述点值。
    static let titleSize: CGFloat = 12
    static let amountSize: CGFloat = 21
    static let hintSize: CGFloat = 10
    static let badgeSize: CGFloat = 9.5
}

/// 浮窗里的鲸鱼视图：底图 + 气泡文字层 + 交互。
final class WhaleView: NSView {
    /// 角色素材。
    ///
    /// 两张图：带空白气泡的原版，与把气泡抹掉后的版本。
    /// 气泡隐藏时切到无泡版 —— 否则「气泡消失」只是文字没了、
    /// 手绘泡泡框还杵在那儿（那是原图的一部分，不是独立视图）。
    /// 可选角色素材（对应网页版「角色」菜单）。
    /// 文件名约定：`<角色名>.png` 为带泡原图，`<角色名>-nobubble.png` 为去泡版。
    /// 默认角色用的是**纯角色**素材（对应 Resources/role-clean.png）。
    nonisolated static let defaultCharacterName = "role-clean"
    static let altCharacterName = "DSniang1"
    /// 原图像素边长（素材固有尺寸，坐标换算的基准）。
    static let sourcePixel: CGFloat = 1026
    /// 气泡几何（画布坐标，与 BubbleShapeView 保持一致）。
    ///
    /// 文字就排在这个椭圆的中心；底色由 BubbleShapeView 绘制。
    static var bubbleCenter: CGPoint { BubbleShapeView.ellipseCenter }
    /// 气泡内某高度处的可用宽度。
    ///
    /// 椭圆是弧形的，而文字块是矩形 —— 若只按中心宽度给，上下两行会顶到弧线。
    /// 按椭圆方程算：`(w/2)²/a² + (h/2)²/b² = 1`
    /// ⇒ `w = 2a·√(1 − (h/2b)²)`，h 取文字块总高。
    /// 再乘一个安全系数留出描边与呼吸空间。
    static func bubbleInnerWidth(forTextHeight h: CGFloat) -> CGFloat {
        let a = BubbleShapeView.ellipseRadius.width
        let b = BubbleShapeView.ellipseRadius.height
        let ratio = min(0.99, (h / 2) / b)
        let halfW = a * sqrt(max(0, 1 - ratio * ratio))
        return halfW * 2 * 0.92
    }

    /// 文字块总高（估算：按当前行数与字号）。
    private var textBlockHeight: CGFloat {
        stack.layoutSubtreeIfNeeded()
        return stack.fittingSize.height
    }
    /// 气泡内可用高度。
    static var bubbleInnerHeight: CGFloat { BubbleShapeView.ellipseRadius.height * 2 * 0.84 }

    private let imageView = NSImageView()
    /// 内置的纯角色素材文件名（无气泡）。
    nonisolated static let defaultRoleFile = "role-clean.png"
    /// 气泡形状层（独立绘制，不属于角色图）。
    private let bubbleShape = BubbleShapeView()
    /// 「干饭」彩蛋里那碗饭。平时叠在栈里但隐藏。
    private let bowlView = BowlView()
    private let stack = NSStackView()
    /// 摸摸头：点击时的动画与音效。
    private var touch: TouchReaction?

    private let titleLabel = WhaleView.makeLabel()
    private let amountLabel = WhaleView.makeLabel()
    private let usedLabel = WhaleView.makeLabel()
    private let badgeLabel = WhaleView.makeLabel()
    private let countdownLabel = WhaleView.makeLabel()
    /// 峰谷那一行（徽章 + 倒计时），供按类型显隐。
    private var badgeRow: NSStackView!
    private var stackWidthConstraint: NSLayoutConstraint?
    private var badgeWidthConstraint: NSLayoutConstraint?
    private var badgeHeightConstraint: NSLayoutConstraint?
    /// 「上一轮」行：token 数 + 金额。
    private let lastTurnLabel = WhaleView.makeLabel()

    /// 由控制器注入的动作。
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    private var lastClickAt: TimeInterval = 0

    /// 内容容器：角色图与气泡文字都装在它里面。
    ///
    /// 为什么需要它：按压形变要**连文字一起**缩放（网页版形变的是整个
    /// `.dshwv-body`）。早先只形变角色底图，结果角色压扁了、文字纹丝不动，
    /// 看着像文字「卡住」。把两者放进同一容器，对容器做一次变换即可。
    let content = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 容器铺满自身，并随尺寸自适应
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        addSubview(content)
        buildImage()
        buildBubbleText()
    }

    required init?(coder: NSCoder) { fatalError("不支持 nib 加载") }

    // MARK: - 构建

    /// 角色层：只放**纯角色**（不含气泡）。
    ///
    /// 这是照原作的分层做法：原作角色图本身就是纯角色，气泡由 SVG 单独画。
    /// 早先从「气泡+角色」的合成图里抠气泡，因为描边与呆毛像素紧邻而无法完美分离。
    private func buildImage() {
        imageView.imageScaling = .scaleAxesIndependently
        reloadImages(characterName: Self.defaultCharacterName)
        content.addSubview(imageView)
        layoutImageView()
    }

    /// 把角色摆到右下角，占窗口宽度的 ~70%（与合成图里的比例一致）。
    private func layoutImageView() {
        let w = bounds.width * Self.roleWidthRatio
        let h = bounds.height * Self.roleWidthRatio
        imageView.frame = NSRect(
            x: bounds.width - w,
            y: 0,                 // NSView 原点左下 → 贴底
            width: w,
            height: h
        )
    }

    /// 角色占窗口宽度的比例。
    static let roleWidthRatio: CGFloat = 0.70

    /// 旧版用过「气泡+角色」的合成图当角色；那套改名后旧配置会指向不存在的语义。
    /// 这里把它们统一映射到纯角色，避免升级后加载到带气泡的旧素材导致「两个气泡」。
    private static func normalizeRoleName(_ name: String) -> String {
        switch name {
        case "DSniang02", "whale-bubble", "DSniang02-nobubble", "whale-nobubble":
            return defaultCharacterName        // → role-clean
        default:
            return name
        }
    }

    /// 重新加载角色素材（切换角色时调用）。
    func reloadImages(characterName: String) {
        let name = Self.normalizeRoleName(characterName)
        imageView.image = AssetPaths.load("\(name).png")
            // 兜底：素材缺失时回到内置默认角色，避免整只鲸鱼消失
            ?? AssetPaths.load(Self.defaultRoleFile)
    }

    /// 气泡文字：四行，垂直紧凑排布，整块在气泡内居中。
    ///
    /// 为什么用 NSStackView 而不是手算 y 偏移：网页版是 flex 布局，行高随
    /// 字号自适应；栈视图能复现同样的「紧贴」效果，且增删行不用重算全部坐标。
    private func buildBubbleText() {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        // 手动设 frame（见 positionBubbleStack），所以关掉 autoresizing 转换
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.autoresizingMask = []

        // 层级（自下而上）：角色 → 气泡形状 → 文字
        bubbleShape.frame = bounds
        bubbleShape.autoresizingMask = [.width, .height]
        bubbleShape.wantsLayer = true
        content.addSubview(bubbleShape, positioned: .above, relativeTo: imageView)
        content.addSubview(stack, positioned: .above, relativeTo: bubbleShape)

        titleLabel.stringValue = "DeepSeek 余额"
        titleLabel.font = scaledFont(size: BubbleStyle.titleSize, weight: .bold)
        titleLabel.textColor = BubbleStyle.ink
        allowShrink(titleLabel)

        amountLabel.font = scaledFont(size: BubbleStyle.amountSize, weight: .heavy, mono: true)
        amountLabel.textColor = BubbleStyle.ink
        // 金额位数多变（¥8.20 到 ¥12345.67），单行放不下时自动降字号，
        // 否则会横向撑破气泡。
        amountLabel.usesSingleLineMode = true
        amountLabel.cell?.truncatesLastVisibleLine = false
        amountLabel.cell?.wraps = false
        allowShrink(amountLabel)

        usedLabel.font = scaledFont(size: BubbleStyle.hintSize, weight: .regular)
        usedLabel.textColor = BubbleStyle.inkSoft
        allowShrink(usedLabel)

        // 峰谷行：绿色/橙色徽章 + 倒计时，横向排列
        badgeLabel.font = scaledFont(size: BubbleStyle.badgeSize, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 4
        badgeLabel.layer?.masksToBounds = true
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        // 保存引用：尺寸要随窗口缩放更新，重复加约束会冲突
        badgeWidthConstraint = badgeLabel.widthAnchor.constraint(equalToConstant: 20)
        badgeHeightConstraint = badgeLabel.heightAnchor.constraint(equalToConstant: 14)
        badgeWidthConstraint?.isActive = true
        badgeHeightConstraint?.isActive = true

        // 徽章用固定尺寸的容器，避免 Auto Layout 在横向栈里给它算出 0 宽。
        badgeLabel.frame = NSRect(x: 0, y: 0, width: 22, height: 15)
        // 「谷/峰」徽章 + 时间放同一行（费扬要求），省一行高度
        countdownLabel.isHidden = true
        let valleyRow = NSStackView(views: [badgeLabel, lastTurnLabel])
        valleyRow.orientation = .horizontal
        valleyRow.spacing = 6
        valleyRow.alignment = .centerY
        badgeRow = valleyRow

        lastTurnLabel.font = scaledFont(size: BubbleStyle.hintSize, weight: .regular, mono: true)
        lastTurnLabel.textColor = BubbleStyle.inkSoft
        allowShrink(lastTurnLabel)

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(amountLabel)
        stack.addArrangedSubview(usedLabel)
        stack.addArrangedSubview(valleyRow)   // 含「谷/峰」徽章与时间

        // 吃饭彩蛋用：平时藏着
        bowlView.isHidden = true
        stack.addArrangedSubview(bowlView)

        // 栈宽不超过气泡内宽 —— 手动布局下这里只用于 initial fittingSize，
        // 真正的宽度在 positionBubbleStack 里夹取。
        // 栈宽锁定在气泡内宽 —— 超出的行会被压缩而不是撑破气泡
        stackWidthConstraint = stack.widthAnchor.constraint(equalToConstant: 200)
        stackWidthConstraint?.isActive = true
        touch = TouchReaction(host: self)
    }

    /// 重新加载音效（用户导入后调用）。
    func reloadSounds() {
        touch?.reloadSounds()
    }

    /// 触发一次摸摸头（形变 + 音效）—— 供外部调用（如双击）。
    func poke() {
        touch?.pressDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.touch?.pressUp()
        }
    }

    /// 音效开关（由设置驱动）。
    func setSoundEnabled(_ on: Bool) {
        touch?.setSoundEnabled(on)
    }

    /// 角色水平镜像（贴左吸附时朝向屏幕内侧）。
    ///
    /// 只翻角色底图，**不动文字** —— 文字反着读没法看。
    /// 网页版是整体翻转（文字同步反向），这里按可读性做了取舍。
    func setCharacterFlipped(_ flipped: Bool) {
        guard characterMirrored != flipped else { return }
        characterMirrored = flipped
        imageView.wantsLayer = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            imageView.animator().layer?.transform = flipped
                ? CATransform3DMakeScale(-1, 1, 1)
                : CATransform3DIdentity
        }
    }

    /// 不能叫 isFlipped —— 那是 NSView 的既有属性（坐标系方向），会冲突。
    private var characterMirrored = false

    /// 字号的设计基准窗口边长（点）。
    /// BubbleStyle 里的字号都是按这个尺寸定的；实际窗口更小/更大时按比例缩放。
    static let designBase: CGFloat = 220

    /// 当前字号缩放系数。
    ///
    /// 为什么需要：角色图会随窗口尺寸缩放（imageView 铺满 bounds），
    /// 但 `NSTextField` 的字号是固定值 —— 缩窗口后角色小了、文字却不变，
    /// 看起来就是「文字没跟着缩放」。
    var fontScale: CGFloat {
        let s = bounds.width / Self.designBase
        return max(0.5, min(2.0, s))
    }

    /// 按当前窗口尺寸取一个缩放后的字号。
    func scaledFont(size: CGFloat, weight: NSFont.Weight, mono: Bool = false) -> NSFont {
        let s = size * fontScale
        return mono
            ? .monospacedDigitSystemFont(ofSize: s, weight: weight)
            : .systemFont(ofSize: s, weight: weight)
    }

    /// 把气泡文字块摆到角色自带气泡的中心。
    ///
    /// 在 layout() 里做而不是建视图时做：bounds 到那时才是最终值，
    /// 否则换算用的还是初始 frame，位置会算偏。
    private func positionBubbleStack() {
        stack.layoutSubtreeIfNeeded()
        var size = stack.fittingSize
        // 夹到气泡内宽，避免长行顶出泡泡。
        //
        // 吃饭泡例外：它是横排（碗 + 文字），高度只有一行，
        // 照椭圆高度反推出来的内宽装不下「碗 + 想干饭」，会被夹成一个字。
        let maxW: CGFloat = currentKind == .meal ? bounds.width * 0.74 : bubbleWidth
        if size.width > maxW {
            stack.setFrameSize(NSSize(width: maxW, height: size.height))
            stack.layoutSubtreeIfNeeded()
            size = stack.fittingSize
            size.width = min(size.width, maxW)
        }
        let fx = Self.bubbleCenter.x / Self.sourcePixel
        let fy = Self.bubbleCenter.y / Self.sourcePixel
        // 原图 y 向下、视图 y 向上 → 翻转
        let cx = bounds.width * fx
        let cy = bounds.height * (1 - fy)
        stack.frame = NSRect(
            x: cx - size.width / 2,
            y: cy - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// 上一次布局时的窗口宽度，用于检测尺寸变化。
    private var lastLaidOutWidth: CGFloat = 0

    override func layout() {
        super.layout()
        // 窗口尺寸变了 → 字号要跟着重算（否则缩小后文字不缩）
        if abs(bounds.width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = bounds.width
            applyFontScale()
        }
        // 形状层铺满、栈宽跟随气泡内宽（不同尺寸下都要贴合）
        bubbleShape.frame = bounds
        // 按文字块高度算该处的椭圆可用宽度，再换算到视图坐标
        let hPx = textBlockHeight / max(0.01, bounds.width / Self.sourcePixel)
        let innerW = Self.bubbleInnerWidth(forTextHeight: hPx)
        let w = bounds.width * (innerW / Self.sourcePixel)
        if abs((stackWidthConstraint?.constant ?? 0) - w) > 0.5 {
            stackWidthConstraint?.constant = w
        }
        autofitLabels()
        // 形变（按压）期间不要重置角色 frame —— 否则每次布局都会把 squash 抹掉。
        if !isSquishing {
            layoutImageView()
        }
        // 布局不影响已设的镜像变换，这里无需重设
        positionBubbleStack()
    }

    /// 是否正在按压形变中（由 TouchReaction 控制）。
    var isSquishing = false

    /// 让标签在内容过宽时自动缩小字号而不是溢出。
    /// NSTextField 的 `adjustsFontSizeToFitWidth` 只对单行 cell 生效。
    private func allowShrink(_ label: NSTextField) {
        label.usesSingleLineMode = true
        if let cell = label.cell as? NSTextFieldCell {
            cell.truncatesLastVisibleLine = false
            cell.wraps = false
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    /// 让单个标签在自己的可用宽度内自动缩字（放不下就降字号，而不是截断）。
    ///
    /// macOS 的 NSTextField 没有 iOS 那种 adjustsFontSizeToFitWidth，
    /// 只能自己量：逐档调小直到文字宽度落进 maxWidth。
    private func autofit(_ label: NSTextField, baseSize: CGFloat, weight: NSFont.Weight,
                         mono: Bool, maxWidth: CGFloat, minSize: CGFloat = 6) {
        let text = label.stringValue
        guard !text.isEmpty, maxWidth > 0 else {
            label.font = mono ? .monospacedDigitSystemFont(ofSize: baseSize * fontScale, weight: weight)
                              : .systemFont(ofSize: baseSize * fontScale, weight: weight)
            return
        }
        var size = baseSize * fontScale
        while size > minSize {
            let f = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                         : NSFont.systemFont(ofSize: size, weight: weight)
            let w = (text as NSString).size(withAttributes: [.font: f]).width
            if w <= maxWidth {
                label.font = f
                return
            }
            size -= 0.5
        }
        label.font = mono ? .monospacedDigitSystemFont(ofSize: minSize, weight: weight)
                          : .systemFont(ofSize: minSize, weight: weight)
    }

    /// 对所有标签做一次自适应缩字（内容或尺寸变化后调用）。
    func autofitLabels() {
        let maxW = bubbleWidth - 6
        guard maxW > 10 else { return }
        autofit(titleLabel, baseSize: BubbleStyle.titleSize, weight: .bold, mono: false, maxWidth: maxW)
        autofit(amountLabel, baseSize: BubbleStyle.amountSize, weight: .heavy, mono: true, maxWidth: maxW)
        autofit(usedLabel, baseSize: BubbleStyle.hintSize, weight: .regular, mono: false, maxWidth: maxW)
        autofit(lastTurnLabel, baseSize: BubbleStyle.hintSize, weight: .regular, mono: true, maxWidth: maxW)
    }

    /// 把各标签的字号按 fontScale 重算一遍。
    private func applyFontScale() {
        titleLabel.font = scaledFont(size: BubbleStyle.titleSize, weight: .bold)
        amountLabel.font = scaledFont(size: BubbleStyle.amountSize, weight: .heavy, mono: true)
        usedLabel.font = scaledFont(size: BubbleStyle.hintSize, weight: .regular)
        lastTurnLabel.font = scaledFont(size: BubbleStyle.hintSize, weight: .regular, mono: true)
        badgeLabel.font = scaledFont(size: BubbleStyle.badgeSize, weight: .bold)
        // 徽章尺寸跟着缩（更新已有约束的 constant，不新增约束）
        badgeWidthConstraint?.constant = 20 * fontScale
        badgeHeightConstraint?.constant = 14 * fontScale
        badgeLabel.layer?.cornerRadius = 4 * fontScale
        needsLayout = true
    }

    /// 当前文字块高度下，气泡内可用的视图宽度。
    private var bubbleWidth: CGFloat {
        let scale = bounds.width / Self.sourcePixel
        let hPx = textBlockHeight / max(0.01, scale)
        return Self.bubbleInnerWidth(forTextHeight: hPx) * scale
    }

    private var bubbleHeight: CGFloat {
        Self.bubbleInnerHeight / Self.sourcePixel * bounds.height
    }

    private static func makeLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.alignment = .center
        l.isEditable = false
        l.isSelectable = false
        l.drawsBackground = false
        l.isBezeled = false
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    // MARK: - 更新

    /// 按气泡类型决定显示哪些行。
    ///
    /// · .balance —— 余额 + 今日已用 + 峰谷（隐藏「上轮」行）
    /// · .turn    —— 只显示本轮消耗（余额那几行隐藏）
    func applyKind(_ kind: BubbleKind) {
        currentKind = kind
        switch kind {
        case .hidden:
            break
        case .balance:
            // 余额视图：标题 / 余额 / 已用 /「谷 23:37」一行
            // 峰谷只显示一个字，且与时间同行 —— 省下来的高度给文字留横向空间。
            titleLabel.isHidden = false
            amountLabel.isHidden = false
            usedLabel.isHidden = false
            badgeRow.isHidden = !(showsValley || showsClock)
            badgeLabel.isHidden = !showsValley
            lastTurnLabel.isHidden = !showsClock
        case .turn:
            // 本轮消耗视图：标题/金额/token/时间（无峰谷徽章）
            titleLabel.isHidden = false
            amountLabel.isHidden = false
            usedLabel.isHidden = false
            badgeRow.isHidden = false
            badgeLabel.isHidden = true        // 不显示峰谷
            lastTurnLabel.isHidden = false    // 只显示时间
        case .alert:
            // 提醒视图：标题 + 正文 + 时间
            titleLabel.isHidden = false
            amountLabel.isHidden = false
            usedLabel.isHidden = true
            badgeRow.isHidden = false
            badgeLabel.isHidden = true
            lastTurnLabel.isHidden = false
        case .waiting:
            // 等待视图：对话名 + 提示语，两行（不带时间）
            titleLabel.isHidden = false
            amountLabel.isHidden = false
            usedLabel.isHidden = true
            badgeRow.isHidden = true
            lastTurnLabel.isHidden = true
        case .meal:
            // 吃饭视图：只有一碗饭和一句「干饭去」，其余全藏。
            // 具体摆位在 showMeal() 里做，这里只负责把行隐藏掉。
            titleLabel.isHidden = false
            amountLabel.isHidden = true
            usedLabel.isHidden = true
            badgeRow.isHidden = true
            lastTurnLabel.isHidden = true
        }
        needsLayout = true
    }

    /// 更新底行：当前时间 + 上一轮消耗。
    ///
    /// 两者合成一行，避免气泡再长一行（放在角色自带的泡泡里，空间有限）。
    func setFooter(turn: TurnLedger.Event?, clock: Date = Date()) {
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let clockText = tf.string(from: clock)
        switch currentKind {
        case .alert:
            // 提醒的正文由 setAlert 填，这里只保证时间在走
            lastTurnLabel.font = scaledFont(size: BubbleStyle.hintSize, weight: .regular, mono: true)
            lastTurnLabel.textColor = BubbleStyle.inkSoft
            lastTurnLabel.stringValue = clockText
        case .turn:
            // 本轮消耗视图：标题「本轮消耗」+ 金额大号 + token/时间小字
            titleLabel.stringValue = "本轮消耗"
            if let t = turn {
                amountLabel.stringValue = String(format: "¥%.4f", t.cost)
                usedLabel.stringValue = "\(Self.formatTokens(t.tokens)) tokens"
            } else {
                amountLabel.stringValue = "—"
                usedLabel.stringValue = " "
            }
            lastTurnLabel.font = scaledFont(size: BubbleStyle.hintSize, weight: .regular, mono: true)
            lastTurnLabel.textColor = BubbleStyle.inkSoft
            lastTurnLabel.stringValue = clockText
        default:
            // 余额视图的底行只放时间 —— 上轮消耗属于轮次泡，不在这里重复
            lastTurnLabel.font = scaledFont(size: BubbleStyle.hintSize, weight: .regular, mono: true)
            lastTurnLabel.textColor = BubbleStyle.inkSoft
            lastTurnLabel.stringValue = clockText
        }
        // 文字刚变过，按当前内容重算自适应字号（layout 时机早于这里，单靠它不够）
        autofitLabels()
    }

    /// 记住当前视图类型（决定底行怎么渲染）。
    private(set) var currentKind: BubbleKind = .hidden

    /// 等待泡：第一行 [ 对话名 ]，第二行提示语。
    /// 文案与排版都照网页版鲸鱼的出厂默认（waitDefaultLines）。
    func setWaiting(sessionName: String, message: String) {
        titleLabel.stringValue = sessionName.isEmpty ? "[ 对话 ]" : "[ \(sessionName) ]"
        titleLabel.font = scaledFont(size: BubbleStyle.titleSize - 1, weight: .bold)
        titleLabel.textColor = BubbleStyle.ink
        amountLabel.font = scaledFont(size: BubbleStyle.titleSize, weight: .bold)
        amountLabel.textColor = BubbleStyle.ink
        amountLabel.stringValue = message
        usedLabel.stringValue = " "
        lastTurnLabel.stringValue = " "
        autofitLabels()
    }

    /// 提醒泡：标题 + 正文 + 时间。
    func setAlert(title: String, body: String, at date: Date = Date()) {
        titleLabel.stringValue = title
        // 正文比金额长，字号收小才放得进气泡
        amountLabel.font = scaledFont(size: BubbleStyle.titleSize, weight: .medium)
        amountLabel.textColor = BubbleStyle.ink
        amountLabel.stringValue = body
        usedLabel.stringValue = " "
        autofitLabels()
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        lastTurnLabel.stringValue = f.string(from: date)
    }

    /// token 数简写：1.2M / 4.3K。
    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// 用一份数据刷新气泡文字。
    func update(with snapshot: BalanceSnapshot?, usedToday: Double?, error: String?) {
        if let err = error {
            titleLabel.stringValue = "余额不可用"
            amountLabel.stringValue = "—"
            usedLabel.stringValue = err
            setValleyBadge(peak: nil)
            return
        }
        // turn / alert 视图的内容另有来源，这里只管余额视图
        guard currentKind != .turn, currentKind != .alert else { return }
        titleLabel.stringValue = "DeepSeek 余额"
        // 余额用大号字（alert 视图会把它改小，切回来要复原）
        amountLabel.font = .monospacedDigitSystemFont(
            ofSize: BubbleStyle.amountSize, weight: .heavy)
        amountLabel.textColor = BubbleStyle.ink
        if let s = snapshot {
            amountLabel.stringValue = AppInfo.money(s.total, symbol: s.symbol)
            // 账户被停用时余额本身可能还显示得出来，但那没意义 ——
            // 明确说清楚，免得用户以为只是数字难看。
            if !s.isAvailable {
                titleLabel.stringValue = "账户不可用"
                usedLabel.stringValue = "余额已停用，请检查账户状态"
                setValleyBadge(peak: nil)
                autofitLabels()
                return
            }
        } else {
            amountLabel.stringValue = "—"
        }
        if let used = usedToday {
            usedLabel.stringValue = "今日已用 " + AppInfo.money(used, symbol: snapshot?.symbol ?? "¥")
        } else {
            usedLabel.stringValue = " "
        }
        autofitLabels()
    }

    /// 是否显示当前时间行（由设置驱动）。
    var showsClock = true
    /// 是否显示峰谷行（由设置驱动）。
    var showsValley = true

    /// 气泡可见性。用透明度动画做淡入淡出，避免生硬突变。
    private(set) var bubbleVisible = true

    /// 切换气泡显隐。
    ///
    /// 分层之后逻辑很直接：气泡 = **形状层 + 文字层**，两者一起淡入淡出，
    /// 角色层完全不受影响 —— 这正是原作的做法（气泡由 SVG 画，与角色图无关）。
    /// 早先从合成图里抠气泡时，才会遇到「背景先没了、文字还在淡出」这类错序。
    /// 冒个「干饭」泡：气泡里换成一碗饭加一句「干饭去」，饭在嚼。
    ///
    /// 彩蛋不占菜单、不打扰流程，撞见才有意思。所以这里只负责把画面摆好，
    /// 什么时候该冒由 AppDelegate 按时间决定。
    func showMeal() {
        restoreBubbleLayout()
        titleLabel.stringValue = "想干饭"
        amountLabel.isHidden = true
        usedLabel.isHidden = true
        badgeRow?.isHidden = true
        bowlView.isHidden = false
        // 横排：碗在左，文字在右
        stack.orientation = .horizontal
        stack.spacing = 8
        bowlView.startChewing()
        setBubbleVisible(true)
    }

    /// 把气泡恢复成「竖排四行」的常规样子。
    ///
    /// 吃饭彩蛋把栈改成了横排、藏了几行，下一次冒普通泡之前必须还原，
    /// 否则余额泡会长成一只碗加一个数字。
    private func restoreBubbleLayout() {
        bowlView.stopChewing()
        bowlView.isHidden = true
        amountLabel.isHidden = false
        usedLabel.isHidden = false
        badgeRow?.isHidden = false
        stack.orientation = .vertical
        stack.spacing = 1
    }

    /// 收起吃饭泡时调用，确保下次布局是干净的。
    func endMealIfNeeded() {
        guard !bowlView.isHidden else { return }
        restoreBubbleLayout()
    }

    func setBubbleVisible(_ visible: Bool, animated: Bool = true) {
        guard bubbleVisible != visible || stack.alphaValue != (visible ? 1 : 0) else { return }
        bubbleVisible = visible

        let fadeSeconds: TimeInterval = 0.2
        let target: CGFloat = visible ? 1 : 0

        // 形状层与文字层一起走；形状先于文字一步，视觉上"泡泡框先浮现"
        bubbleShape.isHidden = false
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fadeSeconds
                ctx.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
                bubbleShape.animator().alphaValue = target
                stack.animator().alphaValue = target
            }
        } else {
            bubbleShape.alphaValue = target
            stack.alphaValue = target
        }
        if !visible {
            // 完全透明后彻底藏起来，省得它继续吃事件；
            // 顺便把吃饭彩蛋改过的布局还原 —— 碗必须跟着文字一起走，
            // 否则泡收了，碗还挂在头顶上。
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeSeconds + 0.05) { [weak self] in
                guard let self, !self.bubbleVisible else { return }
                self.bubbleShape.isHidden = true
                self.restoreBubbleLayout()
            }
        }
    }

    /// 更新峰谷标记。
    ///
    /// 只显示一个字「峰」或「谷」—— 费扬定的：倒计时太占地方，
    /// 余额泡里给个状态字就够。peak 为 nil 时整行隐藏。
    func setValleyBadge(peak: Bool?) {
        guard let isPeak = peak else {
            badgeLabel.stringValue = ""
            badgeLabel.layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        badgeLabel.stringValue = isPeak ? "峰" : "谷"
        badgeLabel.layer?.backgroundColor = (isPeak ? BubbleStyle.peakRed : BubbleStyle.valleyGreen).cgColor
    }

    // MARK: - 交互

    // MARK: - 按压反馈

    /// 点击分两段（费扬定）：
    ///   · 气泡**没显示**时 → 第一次点击出气泡（余额 / 已用 / 时间）
    ///   · 气泡**已在显示**时 → 这次点击做按压形变，作为交互反馈的补充
    /// 双击仍然是「立刻收起」。
    /// 单击出余额、双击摸头。
    ///
    /// 单击**不延迟**：气泡是主要交互，晚 0.3 秒出现会显得卡。
    /// 代价是双击时气泡会先冒一下 —— 可接受。
    override func mouseDown(with event: NSEvent) {
        let now = Date().timeIntervalSince1970
        let isDouble = now - lastClickAt < 0.3

        if isDouble {
            onDoubleClick?()
            lastClickAt = 0
        } else {
            lastClickAt = now
            onSingleClick?()
        }

        // performDrag 会阻塞到松手，且会吞掉 mouseUp —— 回弹放在它返回之后。
        window?.performDrag(with: event)
        if isSquishing {
            touch?.pressUp()
            releaseSquashIfNeeded()
        }
    }

    /// 兜底：若 mouseUp 能到达（非拖动路径），也做回弹。
    override func mouseUp(with event: NSEvent) {
        guard isSquishing else { return }
        touch?.pressUp()
        releaseSquashIfNeeded()
    }

    /// 形变标记复位（动画结束后才真正解除，避免中途被 layout 抹掉）。
    private func releaseSquashIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.isSquishing = false
            self?.needsLayout = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

/// 素材路径解析：优先插件自带，回退 DSH 鲸鱼素材目录（原图在那里）。
enum AssetPaths {
    /// 按文件名加载：先在 app bundle 的 Resources 找，再找开发目录。
    static func load(_ name: String) -> NSImage? {
        for path in candidates(for: name) {
            if let img = NSImage(contentsOfFile: path) { return img }
        }
        return nil
    }

    static func candidates(for name: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list: [String] = []
        if let base = Bundle.main.resourcePath {
            list.append("\(base)/\(name)")
        }
        list.append("\(home)/.dsh/plugins/whalefloat/Resources/\(name)")
        // 用户导入的自定义角色（优先级高于内置，但仍低于 app bundle）
        list.append("\(home)/.dsh/whalefloat-assets/\(name)")
        // 原图上游（我们只生成了默认角色的去泡版）
        if name == "\(WhaleView.defaultCharacterName).png" {
            list.append("\(home)/.dsh/profiles/web/node_modules/dsh-whale-widget/assets/\(name)")
        }
        return list
    }
}