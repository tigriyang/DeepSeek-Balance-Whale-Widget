import AppKit
import Foundation

/// 内置「中介」插件的安装器。
///
/// 背景：WhaleFloat 是独立程序，拿不到 DSH 的事件流。
/// 「正在等待回答/授权」「每轮消耗」都只有 DSH 内部知道，
/// 于是由两个小插件挂在 DSH 上采集、落成文件，本程序读文件。
///
/// 它们随 app 一起发布（`Contents/Resources/plugins/`），
/// 首次运行时若检测到尚未安装，就由本安装器引导装到 `~/.dsh/plugins/`
/// 并注册进 DSH 的 web profile。
@MainActor
enum PluginInstaller {
    /// 随包发布的中介插件（目录名）。
    static let bundled = ["dsh-wait-state", "dsh-turn-usage", "dsh-notify-bridge"]

    /// 插件的人类可读说明（用于安装提示）。
    static let descriptions: [String: String] = [
        "dsh-wait-state": "等用户回答 / 授权时，让浮窗冒泡提示",
        "dsh-turn-usage": "采集每轮对话消耗，供浮窗显示¥金额",
        "dsh-notify-bridge": "把对话输出推送到系统通知，并支持在通知里直接回复",
    ]

    static var pluginsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/plugins", isDirectory: true)
    }

    static var profilePackageJSON: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/profiles/web/package.json")
    }

    /// app 内置插件的来源目录。
    static var bundledDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("plugins", isDirectory: true)
    }

    /// 某个插件是否**已就位**：目录在、且 profile 里注册过。
    static func isInstalled(_ name: String) -> Bool {
        let idx = pluginsDir.appendingPathComponent("\(name)/index.js")
        guard FileManager.default.fileExists(atPath: idx.path) else { return false }
        guard let data = try? Data(contentsOf: profilePackageJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = json["dependencies"] as? [String: Any]
        else { return false }
        return deps[name] != nil
    }

    /// 还没装的中介插件。
    static func missing() -> [String] {
        bundled.filter { !isInstalled($0) }
    }

    /// 安装指定插件：从 app bundle 复制到 ~/.dsh/plugins/，再注册进 profile。
    /// 返回一段可直接展示的结果说明。
    static func install(_ names: [String]) -> String {
        guard let src = bundledDir else { return "找不到内置插件目录" }
        let fm = FileManager.default
        var copied: [String] = []
        var failed: [String] = []

        for name in names {
            let from = src.appendingPathComponent(name)
            let to = pluginsDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else {
                failed.append("\(name)（包内缺失）")
                continue
            }
            do {
                try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
                copied.append(name)
            } catch {
                failed.append("\(name)（\(error.localizedDescription)）")
            }
        }

        guard !copied.isEmpty else {
            return "复制失败：\(failed.joined(separator: "、"))"
        }

        // 注册：dsh plugin add file:...
        let reg = register(copied)
        var lines = ["已复制 \(copied.count) 个插件到 ~/.dsh/plugins/"]
        if !failed.isEmpty { lines.append("未完成：\(failed.joined(separator: "、"))") }
        lines.append(reg)
        lines.append("")
        lines.append("重启 DSH 后生效。")
        return lines.joined(separator: "\n")
    }

    /// 调 dsh CLI 把插件注册进 web profile。
    private static func register(_ names: [String]) -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        // dsh 可执行文件通常在这几处
        // 多找几处常见位置，尽量不依赖某一种安装方式
        let candidates = [
            "\(home)/.npm-global/bin/dsh",
            "\(home)/.local/bin/dsh",
            "/usr/local/bin/dsh",
            "/opt/homebrew/bin/dsh",
            "/usr/bin/dsh",
        ]
        // 没有 dsh 就静默跳过 —— 这台机器可能压根没装 DSH，
        // 那不是错误。插件文件已经复制到位，等 DSH 出现时自然可用。
        guard let dsh = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            return "插件文件已就位；这台机器上没有 dsh 命令，等 DSH 装好后重启即可生效。"
        }

        var ok = 0
        var log: [String] = []
        for name in names {
            let path = pluginsDir.appendingPathComponent(name).path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: dsh)
            p.arguments = ["plugin", "--profile", "web", "add", "file:\(path)"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 { ok += 1 }
            } catch {
                log.append("\(name): \(error.localizedDescription)")
            }
        }
        if ok == names.count { return "已注册 \(ok) 个插件进 DSH 的 web profile。" }
        return (["⚠ 注册了 \(ok)/\(names.count) 个"] + log).joined(separator: "\n")
    }

    /// 用户主动点菜单时的安装 —— 这条路径可以弹框，
    /// 因为是他自己点的，反馈是必要的。
    /// （启动时的自动补齐走 installMissingQuietly，不弹框。）
    static func installWithFeedback() {
        let missing = self.missing()
        let alert = NSAlert()
        if missing.isEmpty {
            alert.messageText = "配套插件都齐了"
            alert.informativeText = bundled
                .map { "  · \($0) —— \(descriptions[$0] ?? "")" }
                .joined(separator: "\n")
            alert.addButton(withTitle: "好")
        } else {
            alert.messageText = "安装 \(missing.count) 个配套插件"
            alert.informativeText = missing
                .map { "  · \($0) —— \(descriptions[$0] ?? "")" }
                .joined(separator: "\n")
            + "\n\n装到 ~/.dsh/plugins/，装完需要重启一次 DSH。"
            alert.addButton(withTitle: "安装")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let result = install(missing)
            let done = NSAlert()
            done.messageText = "安装结果"
            done.informativeText = result
            done.addButton(withTitle: "好")
            done.runModal()
            return
        }
        alert.runModal()
    }

    /// 启动时补齐缺失的插件。
    ///
    /// **不弹模态框**。之前这里是 runModal()，会阻塞主线程 ——
    /// 自动化流程（或任何后台操作）碰上它就停住了。
    /// 插件本来就随包发布，直接装上即可，没什么可问的。
    /// 结果记进日志，菜单里也能看到状态。
    @discardableResult
    static func installMissingQuietly() -> String? {
        let missing = self.missing()
        guard !missing.isEmpty else { return nil }
        let result = install(missing)
        NSLog("WhaleFloat: 自动安装插件 → \(result)")
        return result
    }
}