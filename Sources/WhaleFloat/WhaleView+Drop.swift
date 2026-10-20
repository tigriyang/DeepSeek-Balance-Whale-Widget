import AppKit
import Foundation

/// 拖拽诊断日志。用户说「拖上去没反应」时，先看这个文件停在哪一步。
/// 只记录事件与类型名，不记录图片内容。
func dragTrace(_ msg: String) {
    let line = String(Date().timeIntervalSince1970) + " " + msg + "\n"
    let url = URL(fileURLWithPath: "/tmp/whalefloat-drag.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 接收拖到小鲸鱼身上的东西。
///
/// 0.2.0 的 whale-study：拖一张图进来，开一轮新对话把图递过去。
/// 只认图片 —— 别的文件拖进来什么也不做，免得误触。
///
/// 图先落成 PNG 再走后面的链路：
///   · ⌘⇧4 的截图在剪贴板上是位图、没有文件名，不落盘就没有路径
///   · HEIC / WebP 这类格式 DSH 那边的附件白名单未必收，统一转 PNG 最稳
///   · 顺手把超大的图缩到长边 4096 以内，省 token 也省解码
extension WhaleView {

    /// 让这个视图能接住拖拽。
    ///
    /// **只在 WhaleView 上注册，不给子视图注册。**
    /// AppKit 把拖拽交给「光标下最深的、注册过该类型的视图」；
    /// 子视图（角色图、气泡、文字）注册了却没有实现 draggingEntered，
    /// 就会用 NSView 的默认实现直接拒绝 —— 拖到角色图上看起来毫无反应。
    /// 只注册容器后，未注册的子视图会被穿透，消息落到 WhaleView 这里。
    func enableDropTarget() {
        // 子视图显式清一遍：有的 AppKit 控件会自己注册拖拽类型（例如 web 视图），
        // 一旦它成了「最深的已注册视图」，拖拽就轮不到这里。
        func clear(_ v: NSView) {
            v.registerForDraggedTypes([])
            for sub in v.subviews { clear(sub) }
        }
        clear(self)
        registerForDraggedTypes([.fileURL, .tiff, .png])
        dragTrace("drop target registered on WhaleView (children cleared)")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = accepts(sender)
        dragTrace("entered ok=\(ok) types=\(sender.draggingPasteboard.types?.map(\.rawValue) ?? [])")
        if ok { showDropHint(true) }
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        showDropHint(false)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return accepts(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropHint(false)
        dragTrace("perform drop")
        guard let url = saveImage(from: sender) else {
            dragTrace("drop rejected: 读不出图片")
            NSSound.beep()
            return false
        }
        dragTrace("saved \(url.path)")
        onImageDropped?(url)
        return true
    }

    /// 拖到头上时给一点反馈，否则用户不知道这里能接。
    /// 只改透明度，不动 transform —— 角色镜像与按压形变都在用那一层。
    private func showDropHint(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = on ? 0.82 : 1.0
        }
    }

    /// 只接受图片：文件形式的图，或者剪贴板里的位图（⌘⇧4 是后者）。
    private func accepts(_ info: NSDraggingInfo) -> Bool {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            return Self.imageExtensions.contains(first.pathExtension.lowercased())
        }
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil { return true }
        return NSImage(pasteboard: pb) != nil
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "webp", "bmp",
    ]

    /// 把拖进来的图落成 PNG，返回路径。
    ///
    /// 落盘目录固定为 `~/.dsh/whalefloat-drops/`，不写临时目录：
    /// DSH 那边的会话是长期存的，图要能在会话里一直指得到；
    /// 而且用户看得到这个文件夹，想清理也找得到。
    private func saveImage(from info: NSDraggingInfo) -> URL? {
        let pb = info.draggingPasteboard

        var image: NSImage?
        var displayName = "drop"

        var source = "none"
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first,
           Self.imageExtensions.contains(first.pathExtension.lowercased()) {
            image = NSImage(contentsOf: first)
            displayName = first.deletingPathExtension().lastPathComponent
            source = "file:\(first.pathExtension)"
        }
        if image == nil, let data = pb.data(forType: .png) {
            image = NSImage(data: data)
            source = "png-data"
        }
        if image == nil, let data = pb.data(forType: .tiff) {
            image = NSImage(data: data)
            source = "tiff-data"
        }
        if image == nil {
            image = NSImage(pasteboard: pb)
            source = "pasteboard"
        }
        dragTrace("saveImage source=\(source) image=\(image != nil)")
        guard let src = image, let normalized = DroppedImageStore.pngData(src) else { return nil }
        return DroppedImageStore.savePNG(normalized, preferredName: displayName)
    }

}
