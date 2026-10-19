import AppKit

/// 接收拖到小鲸鱼身上的东西。
///
/// 0.2.0 的 floatstudy：拖一张图进来，开一轮新对话把图递过去。
/// 只认图片 —— 别的文件拖进来什么也不做，免得误触。
///
/// 图先落成 PNG 再走后面的链路：
///   · ⌘⇧4 的截图在剪贴板上是位图、没有文件名，不落盘就没有路径
///   · HEIC / WebP 这类格式 DSH 那边的附件白名单未必收，统一转 PNG 最稳
///   · 顺手把超大的图缩到长边 4096 以内，省 token 也省解码
extension WhaleView {

    /// 让这个视图能接住拖拽。
    ///
    /// 只给 WhaleView 注册是不够的：它上面铺着一个 content 容器，
    /// 容器里还有角色图和文字。拖拽落点如果命中那些子视图，
    /// 事件不会冒泡上来 —— 得挨个注册一遍。
    func enableDropTarget() {
        registerRecursively(self)
    }

    private func registerRecursively(_ v: NSView) {
        v.registerForDraggedTypes([.fileURL, .tiff, .png])
        for sub in v.subviews { registerRecursively(sub) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = accepts(sender)
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
        guard let url = saveImage(from: sender) else {
            NSSound.beep()
            return false
        }
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

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first,
           Self.imageExtensions.contains(first.pathExtension.lowercased()) {
            image = NSImage(contentsOf: first)
            displayName = first.deletingPathExtension().lastPathComponent
        }
        if image == nil {
            image = NSImage(pasteboard: pb)
        }
        guard let src = image, let normalized = DroppedImageStore.pngData(src) else { return nil }
        return DroppedImageStore.savePNG(normalized, preferredName: displayName)
    }

}
