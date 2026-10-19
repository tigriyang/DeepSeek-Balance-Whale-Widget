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
    /// 随包发布的中介插件。
    ///
    /// 原先三者独立（wait-state / turn-usage / notify-bridge），
    /// 但它们订阅的是同一条 session/event 事件流 —— 合并成一个
    /// helper 后只订阅一次，profile 里也只留一个条目。
    static let bundled = ["dsh-whalefloat-helper"]

    /// 已废弃的旧插件名。启动时顺手摘掉，避免用户升级后两套并存。
    static let legacy = ["dsh-wait-state", "dsh-turn-usage", "dsh-notify-bridge"]

    /// 插件的人类可读说明（用于安装提示）。
    static let descriptions: [String: String] = [
        "dsh-wait-state": "等用户回答 / 授权时，让浮窗冒泡提示",
        "dsh-turn-usage": "采集每轮对话消耗，供浮窗显示¥金额",
        "dsh-whalefloat-helper": "等待提示 / 每轮消耗 / 系统通知 / 拖图解题，四合一中介",
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

    /// 需要（重新）安装的插件：没装，或者装的那份与本版不同。
    ///
    /// 只看「有没有」是不够的 —— app 升级后包内的插件换了，
    /// 而 ~/.dsh 里那份还是旧的，只要路径在就永远不会更新。
    /// 表现就是：新功能明明做了，用户那边却「点了没反应」。
    static func outdated() -> [String] {
        bundled.filter { name in
            guard let base = bundledDir else { return false }
            let from = base.appendingPathComponent(name)
            let to = pluginsDir.appendingPathComponent(name)
            let fm = FileManager.default
            guard fm.fileExists(atPath: to.path) else { return true }
            return !sameContents(from, to, fm)
        }
    }

    /// 两份插件目录内容是否一致（逐文件比字节）。
    private static func sameContents(_ a: URL, _ b: URL, _ fm: FileManager) -> Bool {
        guard let namesA = try? fm.contentsOfDirectory(atPath: a.path),
              let namesB = try? fm.contentsOfDirectory(atPath: b.path),
              Set(namesA) == Set(namesB)
        else { return false }
        for name in namesA {
            guard let da = try? Data(contentsOf: a.appendingPathComponent(name)),
                  let db = try? Data(contentsOf: b.appendingPathComponent(name)),
                  da == db
            else { return false }
        }
        return true
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

                // 还要更新 DSH profile 里的那份。
                //
                // profile 的 package.json 用 "file:..." 引用这个目录，
                // pnpm 装的时候是**复制**而不是软链 —— 只改源目录，
                // DSH 加载的还是旧副本。这个坑让「新功能点了没反应」
                // 多绕了好几圈。
                let homeDir = fm.homeDirectoryForCurrentUser
                let profileCopy = homeDir
                    .appendingPathComponent(".dsh/profiles/web/node_modules")
                    .appendingPathComponent(name)
                if fm.fileExists(atPath: profileCopy.path) {
                    try? fm.removeItem(at: profileCopy)
                    try? fm.copyItem(at: from, to: profileCopy)
                }

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
                else {
                    // 失败时必须把子进程的输出留下 ——
                    // 之前只看 exit status，失败时什么都不记，
                    // 排查时完全不知道 dsh 报了什么。
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    log.append("\(name): 退出码 \(p.terminationStatus)"
                        + (out.isEmpty ? "" : " — \(out.prefix(400))"))
                }
            } catch {
                log.append("\(name): \(error.localizedDescription)")
            }
        }
        if ok == names.count { return "已注册 \(ok) 个插件进 DSH 的 web profile。" }
        return (["⚠ 注册了 \(ok)/\(names.count) 个"] + log).joined(separator: "\n")
    }

    /// 摘掉已废弃的旧插件（升级时清理用）。
    static func removeLegacy() {
        guard let dsh = dshExecutable else { return }
        for name in legacy where isInstalled(name) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: dsh)
            p.arguments = ["plugin", "--profile", "web", "remove", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            // 源码目录也删掉，避免两套并存
            try? FileManager.default.removeItem(
                at: pluginsDir.appendingPathComponent(name))
            NSLog("WhaleFloat: 已移除旧插件 \(name)")
        }
    }

    /// dsh 可执行文件的位置（摘插件时要调它）。
    private static var dshExecutable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.npm-global/bin/dsh",
            "\(home)/.local/bin/dsh",
            "/usr/local/bin/dsh",
            "/opt/homebrew/bin/dsh",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 从 DSH 的 profile 里摘除本程序带的插件（卸载时用）。
    static func removeAllQuietly() {
        guard let dsh = dshExecutable else { return }
        for name in bundled {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: dsh)
            p.arguments = ["plugin", "--profile", "web", "remove", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
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
        // 用 outdated 而不是 missing：app 升级后包内的插件可能变了，
        // 而 ~/.dsh 里那份还是旧的 —— 只看「装没装」永远不会更新它。
        let missing = self.outdated()
        guard !missing.isEmpty else { return nil }
        let result = install(missing)
        NSLog("WhaleFloat: 自动安装插件 → \(result)")
        return result
    }
}