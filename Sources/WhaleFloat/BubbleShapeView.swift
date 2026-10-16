import AppKit
import Foundation

/// 气泡形状 —— 照网页版原作的思路：**气泡是独立绘制的层**，不属于角色图。
///
/// 原作里气泡由 SVG 画（`dshwv-shapewrap` 内的 path/ellipse），角色图本身是纯角色。
/// 本程序同样分层：角色用纯角色素材，气泡用 NSBezierPath 画。
/// 这样显示/隐藏只需控制这一层的可见性，不存在「从角色图里抠气泡」的像素难题。
///
/// 几何照 `DSniang02.png` 实测比例（画布 1026 见方）：
///   椭圆中心 (453, 255)，半径 (365, 240)
///   三个递减圆点由气泡底部指向角色头顶
final class BubbleShapeView: NSView {
    /// 设计画布边长（与原素材一致，便于照抄几何比例）。
    static let canvas: CGFloat = 1026

    /// 椭圆的中心与半径（画布坐标，原点左上）。文字层按这个中心对齐。
    static let ellipseCenter = CGPoint(x: 453, y: 255)
    static let ellipseRadius = CGSize(width: 365, height: 240)
    private var ellipseCenter: CGPoint { Self.ellipseCenter }
    private var ellipseRadius: CGSize { Self.ellipseRadius }

    /// 三个圆点：中心 + 半径（依次向角色头顶递减）。
    private let dots: [(CGPoint, CGSize)] = [
        (CGPoint(x: 372, y: 512), CGSize(width: 48, height: 24)),
        (CGPoint(x: 362, y: 570), CGSize(width: 38, height: 19)),
        (CGPoint(x: 445, y: 648), CGSize(width: 22, height: 13)),
    ]

    /// 描边与填充（取自原图采样）。
    private let strokeColor = NSColor(srgbRed: 48/255, green: 62/255, blue: 112/255, alpha: 1)
    private let fillColor = NSColor.white
    private let lineWidth: CGFloat = 13

    override var isFlipped: Bool { true }   // 用「左上原点」的思路写坐标，与原图测量一致

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let s = bounds.width / Self.canvas   // 画布 → 视图的缩放
        guard s > 0 else { return }

        // 先画填充（所有形状），再统一描边 —— 避免描边被后画的填充压住
        let path = NSBezierPath()
        path.appendOval(in: rect(center: ellipseCenter, radius: ellipseRadius, scale: s))
        for (c, r) in dots {
            path.appendOval(in: rect(center: c, radius: r, scale: s))
        }

        fillColor.setFill()
        path.fill()

        strokeColor.setStroke()
        path.lineWidth = lineWidth * s
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func rect(center: CGPoint, radius: CGSize, scale: CGFloat) -> NSRect {
        NSRect(
            x: (center.x - radius.width) * scale,
            y: (center.y - radius.height) * scale,
            width: radius.width * 2 * scale,
            height: radius.height * 2 * scale
        )
    }
}
