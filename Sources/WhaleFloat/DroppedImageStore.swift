import AppKit
import Foundation

/// 拖进来的图落到哪里、落成什么格式。
///
/// 抽成一个独立的小类型，是因为它被三条路共用：
///   · 拖拽（WhaleView+Drop）
///   · 菜单「选一张图解题…」
///   · 命令行自测（--drop-copy）
/// 三条路必须落成同一种东西，否则 DSH 那边看到的分辨率/格式会不一样。
enum DroppedImageStore {
    /// 统一转成 PNG，长边不超过 4096。
    ///
    /// 4096 是 DSH 附件上限（8192）的一半：留一半余量给不同屏幕的截图，
    /// 又不至于把 5K 截图按 1:1 塞进去 —— 那样 token 与内存都白花。
    static func pngData(_ image: NSImage, maxEdge: CGFloat = 4096) -> Data? {
        var size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        if longest > maxEdge {
            let k = maxEdge / longest
            size = NSSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        ctx.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    /// 转格式 + 落盘，一步到位。
    static func save(_ image: NSImage, preferredName: String) -> URL? {
        guard let data = pngData(image) else { return nil }
        return savePNG(data, preferredName: preferredName)
    }

    /// 字节已经是 PNG 时直接落盘。
    static func savePNG(_ data: Data, preferredName: String) -> URL? {
        let dir = Settings.dropsDir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(fileStamp())-\(sanitize(preferredName)).png")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("WhaleFloat: 图片落盘失败 \(error.localizedDescription)")
            return nil
        }
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// 文件名只留安全字符 —— 中文名保留，路径分隔符之类换掉。
    private static func sanitize(_ name: String) -> String {
        let blocked = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var out = String(name.unicodeScalars.filter { !blocked.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { out = "drop" }
        return String(out.prefix(40))
    }
}
