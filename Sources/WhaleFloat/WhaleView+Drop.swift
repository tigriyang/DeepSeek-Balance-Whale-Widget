import AppKit
import Foundation
import UniformTypeIdentifiers

/// 拖拽诊断日志。用户说「拖上去没反应」时，先看这个文件停在哪一步。
/// 只记录事件、类型名与落盘路径，不记录图片内容。
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
/// 支持三种来源：
///   · Finder 里的图片文件（public.file-url）
///   · ⇧⌘4 截图/浏览器图片（public.png / public.tiff 位图）
///   · 文件承诺（NSFilePromiseReceiver，截图缩略图、浏览器另存等）
extension WhaleView {

    /// 让这个视图能接住拖拽。
    ///
    /// **只在 WhaleView 上注册，不给子视图注册。**
    /// AppKit 把拖拽交给「光标下最深的、注册过该类型的视图」；
    /// 子视图（角色图、气泡、文字）注册了却没有实现 draggingEntered，
    /// 就会用 NSView 的默认实现直接拒绝 —— 拖到角色图上看起来毫无反应。
    /// 0.2.0-beta.1 之前踩的就是这个坑：`registerRecursively` 给每个子视图都注册了。
    func enableDropTarget() {
        refreshDropTarget(verbose: true)
    }

    /// 重新登记拖拽目的地：清掉所有子视图的注册，只留 WhaleView 自己。
    ///
    /// 要反复调：设角色图、播放动画（建 WKWebView）都可能让子视图在内部
    /// 自己注册拖拽类型，它们一旦成了「最深的已注册视图」就会把拖拽截走。
    func refreshDropTarget(verbose: Bool = false) {
        func clear(_ v: NSView) {
            v.registerForDraggedTypes([])
            for sub in v.subviews { clear(sub) }
        }
        clear(self)
        registerForDraggedTypes(Self.dropTypes)
        if verbose {
            dragTrace("drop target registered: \(Self.dropTypes.map(\.rawValue))")
        }
    }

    /// 拖拽类型表。视图与窗口共用 —— 无边框窗口有时只走窗口级目的地的路径。
    static var dropTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL, .tiff, .png, .URL,
            // public.item / public.data / public.image 用来兜底与诊断：
            // 任何拖拽进来至少能落一行日志，看得出是「类型没匹配」还是「事件没到」。
            NSPasteboard.PasteboardType("public.item"),
            NSPasteboard.PasteboardType("public.data"),
            NSPasteboard.PasteboardType("public.image"),
        ]
        // 文件承诺的类型名不能写死（com.apple.NSFilePromiseItemMetaData 等），由系统给出。
        types += NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
        return types
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = accepts(sender)
        let win = window?.frame ?? .zero
        dragTrace("entered ok=\(ok) at=\(sender.draggingLocation) window=\(win) bounds=\(bounds)")
        if ok { showDropHint(true) }
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        showDropHint(false)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = accepts(sender)
        if ok { showDropHint(true) }
        return ok ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropHint(false)
        let pb = sender.draggingPasteboard
        dragTrace("perform drop types=\(pb.types?.map(\.rawValue) ?? [])")

        if let payload = readImagePayload(from: pb) {
            return deliver(payload.image, name: payload.name)
        }
        if let receiver = filePromiseReceiver(from: pb) {
            dragTrace("file promise: \(receiver.fileTypes)")
            receive(receiver)
            return true
        }
        dragTrace("drop rejected: 读不出图片")
        NSSound.beep()
        return false
    }

    /// 拖到头上时给一点反馈，否则用户不知道这里能接。
    /// 只改透明度，不动 transform —— 角色镜像与按压形变都在用那一层。
    private func showDropHint(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = on ? 0.82 : 1.0
        }
    }

    /// 只接受图片：文件、位图、文件承诺。
    ///
    /// 这里要便宜：draggingUpdated 会高频调用，不能每次都解一张大图。
    private func accepts(_ info: NSDraggingInfo) -> Bool {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            return Self.isImageFile(first)
        }
        if pb.availableType(from: [.png, .tiff]) != nil { return true }
        return filePromiseReceiver(from: pb) != nil
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "heic", "heif", "hif", "gif",
        "tiff", "tif", "webp", "bmp", "avif",
    ]

    /// 文件是不是图片：先看白名单，再用系统 UTI 兜底（jpg/png/heic 都在 public.image 下）。
    static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return true }
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    private func filePromiseReceiver(from pb: NSPasteboard) -> NSFilePromiseReceiver? {
        (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver])?.first
    }

    /// 从剪贴板读一张图（文件 / 位图）。文件承诺不走这里。
    private func readImagePayload(from pb: NSPasteboard) -> (image: NSImage, name: String)? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first,
           Self.isImageFile(first),
           let image = NSImage(contentsOf: first) {
            dragTrace("read source=file ext=\(first.pathExtension)")
            return (image, first.deletingPathExtension().lastPathComponent)
        }
        if let data = pb.data(forType: .png), let image = NSImage(data: data) {
            dragTrace("read source=png-data bytes=\(data.count)")
            return (image, "drop")
        }
        if let data = pb.data(forType: .tiff), let image = NSImage(data: data) {
            dragTrace("read source=tiff-data bytes=\(data.count)")
            return (image, "drop")
        }
        if let image = NSImage(pasteboard: pb) {
            dragTrace("read source=pasteboard")
            return (image, "drop")
        }
        return nil
    }

    /// 文件承诺：等在后台把文件写出来，再按普通图片落盘。
    private func receive(_ receiver: NSFilePromiseReceiver) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whalefloat-promise-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        receiver.receivePromisedFiles(atDestination: dir, options: [:],
                                      operationQueue: .main) { [weak self] url, error in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: dir) }
            if let error {
                dragTrace("promise failed: \(error.localizedDescription)")
                NSSound.beep()
                return
            }
            guard let image = NSImage(contentsOf: url) else {
                dragTrace("promise unreadable: \(url.lastPathComponent)")
                NSSound.beep()
                return
            }
            _ = self.deliver(image, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    /// 转 PNG、落盘、回调。返回是否成功。
    private func deliver(_ image: NSImage, name: String) -> Bool {
        guard let png = DroppedImageStore.pngData(image),
              let url = DroppedImageStore.savePNG(png, preferredName: name) else {
            dragTrace("drop rejected: PNG 转换或落盘失败")
            NSSound.beep()
            return false
        }
        dragTrace("saved \(url.path)")
        onImageDropped?(url)
        return true
    }
}
