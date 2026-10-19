#!/usr/bin/env swift
//
// make-gif.swift —— 把 AI 产出的素材收成桌宠能用的 GIF。
//
// 为什么要有这个脚本：
//   图像/视频模型给的是 mp4、mov，或者一张「精灵图」（几帧并排的图），
//   而浮窗的第三方动画通道只认 GIF / HTML。中间这一步不该每次都手搓。
//
// 本机没有 ffmpeg、也没有 brew，所以这里只用系统框架：
//   AVFoundation 抽视频帧，ImageIO 写 GIF，CoreGraphics 做缩放与裁边。
//   零安装，`swift tools/make-gif.swift` 直接跑。
//
// 用法：
//   视频转 GIF
//     swift tools/make-gif.swift video 输入.mp4 输出.gif \
//       [--fps 12] [--width 240] [--start 0] [--duration 0]
//
//   精灵图切片转 GIF（几帧并排 / 网格）
//     swift tools/make-gif.swift sprite 精灵图.png 输出.gif \
//       [--cols 4] [--rows 1] [--fps 8] [--trim]
//
// 注意：
//   · 视频没有 alpha。做「叠在角色身上」的动画时，背景要事先抠掉，
//     或者干脆用图像模型直接出透明 PNG 精灵图。
//   · GIF 的透明是 1 位，半透明边缘会变硬。描边清楚的卡通素材最合适。
//
import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - GIF 写出

struct GIFWriter {
    private let dest: CGImageDestination
    let delay: Double
    private var count = 0
    private let url: URL

    init?(url: URL, delay: Double, frames: Int, loop: Bool) {
        guard let d = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, max(1, frames), nil
        ) else { return nil }
        self.dest = d
        self.url = url
        self.delay = min(10, max(0.02, delay))
        let props: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loop ? 0 : 1,
            ] as [CFString: Any],
        ]
        CGImageDestinationSetProperties(d, props as CFDictionary)
    }

    mutating func add(_ image: CGImage) {
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
                // 2 = 回到背景色：透明帧之间不会互相拖影
                "DisposalMethod" as CFString: 2,
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(dest, image, frameProps as CFDictionary)
        count += 1
    }

    func finish() -> Bool {
        CGImageDestinationFinalize(dest)
    }

    var frameCount: Int { count }
    var outputURL: URL { url }
}

// MARK: - 工具

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8))
    exit(1)
}

func argValue(_ key: String, in args: [String], default def: String? = nil) -> String? {
    if let i = args.firstIndex(of: key), i + 1 < args.count { return args[i + 1] }
    for a in args where a.hasPrefix(key + "=") { return String(a.dropFirst(key.count + 1)) }
    return def
}

func argDouble(_ key: String, _ args: [String], _ def: Double) -> Double {
    guard let s = argValue(key, in: args), let v = Double(s) else { return def }
    return v
}

func argInt(_ key: String, _ args: [String], _ def: Int) -> Int {
    guard let s = argValue(key, in: args), let v = Int(s) else { return def }
    return v
}

/// 等比缩放到指定宽度（只缩不放）。
func scaled(_ image: CGImage, width: Int) -> CGImage {
    guard width > 0, image.width > width else { return image }
    let h = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
    guard let ctx = CGContext(
        data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: h))
    return ctx.makeImage() ?? image
}

/// 一帧的透明包围盒；全透明时返回 nil。
func alphaBounds(_ image: CGImage) -> CGRect? {
    let w = image.width, h = image.height
    guard w > 0, h > 0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        let row = y * w * 4
        for x in 0..<w {
            if pixels[row + x * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func crop(_ image: CGImage, to rect: CGRect) -> CGImage {
    let r = rect.integral
    guard r.width >= 1, r.height >= 1 else { return image }
    return image.cropping(to: r) ?? image
}

// MARK: - 视频

func runVideo(_ args: [String]) {
    guard args.count >= 2 else { fail("用法：make-gif.swift video 输入.mp4 输出.gif") }
    let input = URL(fileURLWithPath: args[0])
    let output = URL(fileURLWithPath: args[1])
    let fps = max(1, min(30, argDouble("--fps", args, 12)))
    let width = Int(argDouble("--width", args, 0))
    let start = max(0, argDouble("--start", args, 0))
    var duration = max(0, argDouble("--duration", args, 0))
    let loop = argValue("--loop", in: args, default: "1") != "0"

    guard FileManager.default.fileExists(atPath: input.path) else {
        fail("找不到输入文件 \(input.path)")
    }
    let asset = AVURLAsset(url: input)
    let total = CMTimeGetSeconds(asset.duration)
    guard total.isFinite, total > 0 else { fail("读不出视频时长") }
    if duration <= 0 { duration = total - start }
    duration = min(duration, max(0, total - start))
    let frames = max(1, Int((duration * fps).rounded(.down)))
    guard frames <= 600 else { fail("\(frames) 帧太多（GIF 上限 600）") }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    if width > 0 {
        generator.maximumSize = CGSize(width: width, height: width * 4)
    }

    guard var writer = GIFWriter(url: output, delay: 1 / fps, frames: frames, loop: loop) else {
        fail("创建 GIF 失败 \(output.path)")
    }

    for i in 0..<frames {
        let t = CMTime(seconds: start + Double(i) / fps, preferredTimescale: 600)
        do {
            var actual = CMTime.zero
            let cg = try generator.copyCGImage(at: t, actualTime: &actual)
            let frame = width > 0 ? scaled(cg, width: width) : cg
            writer.add(frame)
        } catch {
            fail("抽第 \(i) 帧失败：\(error.localizedDescription)")
        }
    }
    guard writer.finish() else { fail("写 GIF 失败") }
    report(writer, note: "视频 \(frames) 帧 / \(String(format: "%.2f", duration)) 秒")
}

// MARK: - 精灵图

func runSprite(_ args: [String]) {
    guard args.count >= 2 else { fail("用法：make-gif.swift sprite 精灵图.png 输出.gif") }
    let input = URL(fileURLWithPath: args[0])
    let output = URL(fileURLWithPath: args[1])
    let cols = max(1, argInt("--cols", args, 1))
    let rows = max(1, argInt("--rows", args, 1))
    let fps = max(1, min(30, argDouble("--fps", args, 8)))
    let trim = args.contains("--trim")
    let loop = argValue("--loop", in: args, default: "1") != "0"

    guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
          let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("读不出图片 \(input.path)")
    }
    let total = cols * rows
    let cw = sheet.width / cols
    let ch = sheet.height / rows
    guard cw > 0, ch > 0 else { fail("切片尺寸算出来是 0") }

    var frames: [CGImage] = []
    for r in 0..<rows {
        for c in 0..<cols {
            let rect = CGRect(x: c * cw, y: r * ch, width: cw, height: ch)
            if let f = sheet.cropping(to: rect) { frames.append(f) }
        }
    }
    guard frames.count == total else { fail("切片失败（\(frames.count)/\(total)）") }

    if trim {
        // 用所有帧的并集包围盒，而不是每帧各裁各的 ——
        // 后者会让眼睛在气泡里跳来跳去。
        var union = CGRect.null
        for f in frames where alphaBounds(f) != nil {
            union = union.union(alphaBounds(f)!)
        }
        if !union.isNull, union.width >= 2, union.height >= 2 {
            frames = frames.map { crop($0, to: union) }
        }
    }

    guard var writer = GIFWriter(url: output, delay: 1 / fps, frames: frames.count, loop: loop) else {
        fail("创建 GIF 失败 \(output.path)")
    }
    for f in frames { writer.add(f) }
    guard writer.finish() else { fail("写 GIF 失败") }
    report(writer, note: "精灵图 \(cols)×\(rows)")
}

// MARK: - 报告

func report(_ writer: GIFWriter, note: String) {
    let attrs = try? FileManager.default.attributesOfItem(atPath: writer.outputURL.path)
    let bytes = (attrs?[.size] as? Int) ?? 0
    let kb = Double(bytes) / 1024
    print("✓ \(writer.outputURL.path)")
    print("  \(note)，\(writer.frameCount) 帧，\(String(format: "%.2f", writer.delay * Double(writer.frameCount))) 秒，\(String(format: "%.1f", kb)) KB")
    print("  放进 ~/.dsh/whalefloat-animations/ 后，在「动画」菜单里重新检查兼容性即可。")
}

// MARK: - 入口

let all = Array(CommandLine.arguments.dropFirst())
guard let mode = all.first else {
    print("""
    用法：
      make-gif.swift video  输入.mp4 输出.gif [--fps 12] [--width 240] [--start 0] [--duration 0] [--loop 0|1]
      make-gif.swift sprite 精灵图.png 输出.gif [--cols 4] [--rows 1] [--fps 8] [--trim] [--loop 0|1]
    """)
    exit(0)
}
switch mode {
case "video": runVideo(Array(all.dropFirst()))
case "sprite": runSprite(Array(all.dropFirst()))
default: fail("不认识的模式 \(mode)")
}
