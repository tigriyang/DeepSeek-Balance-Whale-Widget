import AppKit
import Foundation

/// 摸摸头：按压时的挤压变形与音效。
///
/// 形变参数**照抄网页版原作**（whale-widget.js）：
///   SQUISH = 'scaleY(0.88) scaleX(1.05)'
///   transform-origin: 50% 100%      → 底部居中锚定，底边不动
///   transition: .22s cubic-bezier(.34,1.56,.64,1)  → 带过冲的弹性回弹
///
/// **形变作用于 WhaleView 的内容容器**（角色图与气泡文字的共同父视图）。
/// 早先只形变角色底图，结果角色压扁了、文字纹丝不动 —— 看着像文字卡住。
/// 网页版形变的是整个 `.dshwv-body`，角色与文字是一起缩放的。
@MainActor
final class TouchReaction {
    private weak var host: WhaleView?
    private var downSound: NSSound?
    private var upSound: NSSound?
    private var soundEnabled = true

    /// 幅度照原作（scaleY .88 / scaleX 1.05），略加强一点让它更容易看清。
    private let squishY: CGFloat = 0.82
    private let squishX: CGFloat = 1.12
    /// 比原作（.08s）稍慢，并在松手后定格一瞬再弹，
    /// 否则快速点击时形变一闪而过、几乎看不见。
    private let pressSeconds: TimeInterval = 0.12
    private let holdSeconds: TimeInterval = 0.25
    private let releaseSeconds: TimeInterval = 0.28

    init(host: WhaleView) {
        self.host = host
        downSound = Self.loadSound("press-down")
        upSound = Self.loadSound("press-up")
    }

    private static func loadSound(_ name: String) -> NSSound? {
        for path in AssetPaths.candidates(for: "\(name).mp3") {
            if let s = NSSound(contentsOfFile: path, byReference: true) { return s }
        }
        return nil
    }

    func setSoundEnabled(_ on: Bool) {
        soundEnabled = on
        if !on { downSound?.stop(); upSound?.stop() }
    }

    /// 重新读盘上的音效（用户导入新素材后调用）。
    func reloadSounds() {
        downSound = Self.loadSound("press-down")
        upSound = Self.loadSound("press-up")
    }

    // MARK: - 形变

    /// 按下：压扁 + 拉宽，底边不动。作用于内容容器（角色与文字一起）。
    func pressDown() {
        play(downSound)
        guard let host else { return }
        host.isSquishing = true
        scale(host.content, x: squishX, y: squishY,
              duration: pressSeconds, overshoot: false)
    }

    /// 松开：先定格一瞬，再弹回原形（过冲曲线带来 Q 弹感）。
    func pressUp() {
        play(upSound)
        guard let host else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) { [weak self] in
            guard let self, let host = self.host else { return }
            self.scale(host.content, x: 1, y: 1,
                       duration: self.releaseSeconds, overshoot: true)
            // 形变结束后再解除标记，避免中途被 layout 重置
            DispatchQueue.main.asyncAfter(deadline: .now() + self.releaseSeconds) {
                host.isSquishing = false
                host.needsLayout = true
            }
        }
    }

    /// 对视图图层做缩放。锚点定在底部中央 —— 与网页版的
    /// `transform-origin: 50% 100%` 等价，底边不动、向上压扁。
    private func scale(_ view: NSView, x: CGFloat, y: CGFloat,
                       duration: TimeInterval, overshoot: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0) {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer.position = CGPoint(x: view.frame.midX, y: view.frame.minY)
        }
        let target = CATransform3DMakeScale(x, y, 1)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: layer.transform)
        anim.toValue = NSValue(caTransform3D: target)
        anim.duration = duration
        anim.timingFunction = overshoot
            ? CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
            : CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "squish")
        layer.transform = target
    }

    private func play(_ sound: NSSound?) {
        guard soundEnabled, let s = sound else { return }
        if s.isPlaying { s.stop() }
        s.play()
    }
}