import AppKit
import Foundation
import ImageIO

/// 动画的四个触发条件（0.2.0）。
///
/// `menuTag` 用来在菜单项里回传触发条件 —— NSMenuItem 只能存 Int/对象，
/// 用字符串枚举配合固定 tag 最省事，也不怕菜单重建后错位。
enum AnimationTrigger: String, CaseIterable {
    case meal
    case snack

    var menuTag: Int {
        switch self {
        case .meal: return 0
        case .snack: return 1
        }
    }

    var title: String {
        switch self {
        case .meal: return "饭点时"
        case .snack: return "静置时"
        }
    }
}

/// 动画清单：扫描、兼容性检查、按名字取用。
///
/// 0.2.0 起动画有两种形态：
///   · `<名字>/index.html` —— 老办法，canvas 自己画，比例由页面自己锁
///   · `<名字>.gif`        —— 新办法，用户拖一张 GIF 进目录就能用
///
/// 目录优先级：用户目录 > 包内目录；同名时 HTML > GIF。
/// 校验失败的文件**不丢**，带着原因留在清单里 —— 菜单里要能告诉用户
/// 「为什么这张 GIF 放不出来」，而不是默默消失。
struct AnimationAsset {
    enum Kind {
        case html
        case gif
    }

    enum Source {
        case builtin
        case user
    }

    /// 设置与菜单里用的稳定标识（文件名去扩展名）。
    let name: String
    let url: URL
    let kind: Kind
    let source: Source

    /// 内容像素尺寸。HTML 拿不到，按 1:1 处理 —— 页面自己会锁比例。
    let pixelSize: CGSize
    let frameCount: Int
    /// 一轮播放的时长（秒）。HTML 未知时为 0，由调用方给默认值。
    let duration: Double

    /// 兼容性检查没通过的原因；nil 表示可用。
    let problem: String?

    var isUsable: Bool { problem == nil }

    var aspect: CGFloat {
        guard pixelSize.height > 0 else { return 1 }
        return pixelSize.width / pixelSize.height
    }

    /// 菜单里显示的名字。内置三个用中文，用户放进来的用文件名。
    var title: String {
        if source == .builtin {
            switch name {
            case "hungry": return "想干饭"
            case "meal": return "偷吃白饭"
            case "company": return "探头陪着"
            default: break
            }
        }
        return name
    }
}

@MainActor
final class AnimationCatalog {
    static let shared = AnimationCatalog()

    /// 每次扫描后填充。无效项也在里面（problem 非 nil）。
    private(set) var assets: [AnimationAsset] = []

    /// 上次扫描时用户目录的修改时间，用来判断「要不要重扫」。
    private var lastUserDirStamp: Date?

    private init() {}

    var usable: [AnimationAsset] { assets.filter(\.isUsable) }
    var broken: [AnimationAsset] { assets.filter { !$0.isUsable } }
    var builtin: [AnimationAsset] { usable.filter { $0.source == .builtin } }
    var userMade: [AnimationAsset] { usable.filter { $0.source == .user } }

    /// 按名字取一个**可用**的动画。
    func asset(named name: String) -> AnimationAsset? {
        guard !name.isEmpty else { return nil }
        return assets.first { $0.name == name && $0.isUsable }
    }

    /// 强制重扫。
    @discardableResult
    func reload() -> [AnimationAsset] {
        var scanned: [AnimationAsset] = []
        var byName: [String: Int] = [:]

        func add(_ asset: AnimationAsset) {
            if let idx = byName[asset.name] {
                let old = scanned[idx]
                // 同名冲突的规则，按优先级从高到低：
                //   1. 用户目录永远压过包内 —— 放一张 company.gif 就能换掉内置的
                //   2. 同一来源里 HTML 压过 GIF（页面能自己锁比例，表现更可控）
                //   3. 其余情况保留先扫到的
                let userBeatsBuiltin = old.source == .builtin && asset.source == .user
                let htmlBeatsGif = old.source == asset.source
                    && old.kind == .gif && asset.kind == .html
                if userBeatsBuiltin || htmlBeatsGif { scanned[idx] = asset }
                return
            }
            byName[asset.name] = scanned.count
            scanned.append(asset)
        }

        // 用户目录先扫 —— 同名时它要能覆盖包内那份。
        for asset in scanUserDir() { add(asset) }
        for asset in scanBuiltinDir() { add(asset) }

        assets = scanned
        lastUserDirStamp = Self.dirStamp(Settings.animationsDir)
        return scanned
    }

    /// 用户目录变了才重扫。菜单每次展开都会调用，不能每次都读全部 GIF。
    func refreshIfDirectoryChanged() {
        let stamp = Self.dirStamp(Settings.animationsDir)
        guard stamp != lastUserDirStamp else { return }
        reload()
    }

    private static func dirStamp(_ url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    // MARK: - 扫描

    private func scanBuiltinDir() -> [AnimationAsset] {
        guard let base = Bundle.main.resourceURL?
            .appendingPathComponent("animations", isDirectory: true) else { return [] }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        return names.sorted().compactMap { name -> AnimationAsset? in
            let dir = base.appendingPathComponent(name, isDirectory: true)
            let html = dir.appendingPathComponent("index.html")
            guard fm.fileExists(atPath: html.path) else { return nil }
            return inspectHTML(name: name, url: html, source: .builtin)
        }
    }

    /// 用户目录：子目录里的 index.html，以及平铺的 *.gif。
    private func scanUserDir() -> [AnimationAsset] {
        let fm = FileManager.default
        let base = Settings.animationsDir
        guard let entries = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        var result: [AnimationAsset] = []
        for entry in entries.sorted() {
            if entry.hasPrefix(".") { continue }
            let path = base.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let html = path.appendingPathComponent("index.html")
                if fm.fileExists(atPath: html.path) {
                    result.append(inspectHTML(name: entry, url: html, source: .user))
                }
            } else if entry.lowercased().hasSuffix(".gif") {
                let name = String(entry.dropLast(4))
                result.append(inspectGIF(name: name, url: path, source: .user))
            }
        }
        return result
    }

    // MARK: - 兼容性检查

    /// HTML 动画：能读到、不太大、里面有东西。
    private func inspectHTML(name: String, url: URL, source: AnimationAsset.Source) -> AnimationAsset {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var problem: String?
        if size == 0 {
            problem = "文件是空的"
        } else if size > 2 * 1024 * 1024 {
            problem = "文件 \(Self.mb(size))，超过 2 MB"
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            if !text.contains("<canvas") && !text.contains("<svg") && !text.contains("<body") {
                problem = "没找到 canvas / svg / body，可能不是动画页"
            }
        } else {
            problem = "读不出文本内容（不是 UTF-8？）"
        }
        // 页面自己的画布尺寸就是动画比例。拿不到时按 1:1 兜底 ——
        // 这里是「显示比例」的唯一来源，不靠外部再配一份。
        let canvas = Self.htmlCanvasSize(in: url) ?? CGSize(width: 200, height: 200)
        return AnimationAsset(
            name: name,
            url: url,
            kind: .html,
            source: source,
            pixelSize: canvas,
            frameCount: 0,
            duration: 0,
            problem: problem
        )
    }

    /// GIF：逐项卡兼容性。
    ///
    /// 这些上限不是拍脑袋来的：
    ///   · 8 MB —— 一张 2048×2048 的 120 帧 GIF 已经接近这个量级，
    ///     再大 WKWebView/ImageIO 解码会明显掉帧，桌宠卡住比不播更糟
    ///   · 2048 px / 400 万像素 —— 桌宠最大只画 304 点，再大纯属浪费内存
    ///   · 600 帧 / 60 秒 —— 一帧 0.1 秒也有整整一分钟，够任何反应动画了
    private func inspectGIF(name: String, url: URL, source: AnimationAsset.Source) -> AnimationAsset {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        let bad: (String) -> AnimationAsset = { reason in
            AnimationAsset(name: name, url: url, kind: .gif, source: source,
                           pixelSize: .zero, frameCount: 0, duration: 0, problem: reason)
        }

        guard bytes > 0 else { return bad("文件是空的") }
        guard bytes <= 8 * 1024 * 1024 else { return bad("文件 \(Self.mb(bytes))，超过 8 MB") }

        // 按文件头判断，不看扩展名 —— 改个扩展名不能骗过检查
        guard let head = Self.head(of: url, count: 6),
              let magic = String(data: head, encoding: .ascii),
              magic.hasPrefix("GIF87a") || magic.hasPrefix("GIF89a")
        else { return bad("不是真正的 GIF（扩展名对不上文件头）") }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return bad("ImageIO 打不开这个文件")
        }
        let count = CGImageSourceGetCount(src)
        guard count >= 1 else { return bad("一帧都没有") }
        guard count <= 600 else { return bad("\(count) 帧，超过 600 帧") }

        // 首帧必须真的能解出来，光有头不算
        guard let frame = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return bad("首帧解码失败")
        }
        let w = frame.width, h = frame.height
        guard w >= 16, h >= 16 else { return bad("尺寸 \(w)×\(h) 太小（至少 16×16）") }
        guard w <= 2048, h <= 2048 else { return bad("尺寸 \(w)×\(h)，超过 2048 上限") }
        guard w * h <= 4_000_000 else { return bad("\(w)×\(h) 超过 400 万像素") }

        var duration = 0.0
        for i in 0..<count {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                  let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { continue }
            let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            // 有的编码器把 0 当「用默认 0.1 秒」，照规范补上
            duration += delay > 0 ? delay : 0.1
        }
        guard duration <= 60 else { return bad(String(format: "总时长 %.1f 秒，超过 60 秒", duration)) }

        return AnimationAsset(
            name: name, url: url, kind: .gif, source: source,
            pixelSize: CGSize(width: w, height: h),
            frameCount: count,
            duration: duration,
            problem: nil
        )
    }

    /// 从 HTML 里读 canvas 的 width/height；读不到再看 aspect-ratio。
    private static func htmlCanvasSize(in url: URL) -> CGSize? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if let start = text.range(of: "<canvas") {
            let rest = text[start.lowerBound...]
            if let end = rest.range(of: ">") {
                let tag = String(rest[..<end.lowerBound])
                let w = Self.number(after: "width", in: tag)
                let h = Self.number(after: "height", in: tag)
                if let w, let h, w > 0, h > 0 {
                    return CGSize(width: CGFloat(w), height: CGFloat(h))
                }
            }
        }
        // CSS 写法：aspect-ratio: 180 / 92
        if let r = text.range(of: "aspect-ratio") {
            let tail = text[r.upperBound...].prefix(40)
            let parts = tail.split(whereSeparator: { !$0.isNumber && $0 != "/" })
            if parts.count == 1 {
                let nums = parts[0].split(separator: "/").compactMap { Int($0) }
                if nums.count == 2, nums[0] > 0, nums[1] > 0 {
                    return CGSize(width: CGFloat(nums[0]), height: CGFloat(nums[1]))
                }
            }
        }
        return nil
    }

    private static func number(after key: String, in tag: String) -> Int? {
        guard let r = tag.range(of: key) else { return nil }
        let tail = tag[r.upperBound...]
        guard let quote = tail.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let quoteChar = tail[quote]
        let rest = tail[tail.index(after: quote)...]
        guard let close = rest.firstIndex(of: quoteChar) else { return nil }
        return Int(rest[..<close])
    }

    private static func head(of url: URL, count: Int) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        return try? fh.read(upToCount: count)
    }

    private static func mb(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
