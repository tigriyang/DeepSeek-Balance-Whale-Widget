import AppKit

@MainActor
enum DSHLauncher {
    /// DSH 是否在跑：看 3080 端口有没有监听。
    ///
    /// 不打扰服务、也不需要凭据。这个方法原先在 App 和 AnalysisWindow 里
    /// 各写了一份完全一样的，合并到这里。
    static var isRunning: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:3080", "-sTCP:LISTEN"]
        p.standardOutput = Pipe()
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// 启动器脚本的位置，按优先级查找。
    ///
    /// 包内那份首选 —— 原实现写死了 ~/dsh-workspace/.dsh/skills/...，
    /// 换台机器、或用户挪过工作区，这个菜单就直接失效。
    static var scriptPath: String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates: [String] = [
            Bundle.main.resourceURL?.appendingPathComponent("dsh-launcher.sh").path ?? "",
            "\(home)/dsh-workspace/.dsh/skills/dsh-launcher/scripts/dsh-launcher.sh",
            "\(home)/.dsh/skills/dsh-launcher/scripts/dsh-launcher.sh",
        ]
        return candidates.first { !$0.isEmpty && fm.fileExists(atPath: $0) }
    }

    /// 静默启动：不弹终端窗口，由启动器自己开浏览器。
    /// 正在运行的启动器进程（用于防止重复启动）。
    private static var running: Process?

    /// 启动 DSH GUI。
    ///
    /// 覆盖的情况：
    ///   · DSH 未启动      → 启动器起新实例、抓认证 URL、开浏览器
    ///   · DSH 已启动      → 启动器复用缓存 URL，直接开浏览器（不重启）
    ///   · 端口被非 DSH 占 → 启动器报错退出，这里把原因弹给用户
    ///   · 重复点击        → 已有启动器在跑就忽略，避免起两个实例
    ///
    /// 三个必须做的处理（早先漏了，会出问题）：
    ///   1. standardInput 重定向到 /dev/null —— 脚本里有 pause_exit（read 等回车），
    ///      stdin 若继承终端会挂住不返回；
    ///   2. 捕获输出 —— 否则端口被占之类的失败用户完全看不到；
    ///   3. 记住进程 —— 启动器内部有最长约 30 秒的等待，期间重复点会起第二个。
    /// 已认证 URL 的缓存（URL 一行、PID 一行）。
    ///
    /// token 是每个进程新生成的，且只在启动输出里出现一次 —— 事后取不回。
    /// 所以缓存里连 PID 一起记：PID 对得上才说明这个 token 还属于
    /// 端口上那个进程，否则它已经作废。
    private static var urlCachePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/web.url").path
    }

    /// 端口上正在监听的进程 PID。没有则 nil。
    nonisolated static func listeningPID(_ port: UInt16) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    /// 若缓存里的 URL 仍属于端口上那个进程，返回它。
    private static func liveAuthenticatedURL() -> URL? {
        guard let text = try? String(contentsOfFile: urlCachePath, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2,
              let url = URL(string: lines[0]),
              let cachedPID = Int32(lines[1]),
              let livePID = listeningPID(3080),
              cachedPID == livePID
        else { return nil }
        return url
    }

    /// 启动 DSH。
    ///
    /// - Parameter openBrowser: 是否顺带打开浏览器。
    ///   菜单里的「启动 DSH GUI」要开；「新的对话」不要 ——
    ///   那条路是让用户在通知里聊，把浏览器拽到前台反而打断他，
    ///   而且浏览器会停在旧会话上，跟「新对话」的预期正好相反。
    static func launch(openBrowser: Bool = true) {
        if let p = running, p.isRunning {
            notify("正在启动中…", "DSH 启动器已在运行，请稍候再试。")
            return
        }

        // 智能开关的第一判断：已经在跑就只开页面。
        //
        // 这一步放在起脚本之前 —— 脚本内部其实也做了同样的判断，但那是
        // 一个 bash 进程、还有最长约 30 秒的等待。用户点一下只想要个窗口，
        // 毫秒级返回比什么都强。
        if let live = liveAuthenticatedURL() {
            NSWorkspace.shared.open(live)
            return
        }
        guard let scriptPath else {
            notify("找不到启动脚本",
                   "app 包内与工作区都没有 dsh-launcher.sh。重新运行 install.sh 可把它装进包里。")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptPath]
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(home)/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // 启动脚本认得这个变量：置 1 就只起服务、不开浏览器
        if !openBrowser {
            env["DSH_LAUNCHER_NO_OPEN"] = "1"
        }
        p.environment = env
        p.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        p.terminationHandler = { proc in
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let out = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                running = nil
                if proc.terminationStatus != 0 {
                    let lines = out.split(separator: "\n").suffix(4).joined(separator: "\n")
                    notify("启动 DSH 失败（exit \(proc.terminationStatus)）",
                           lines.isEmpty ? "启动器没有给出说明。" : lines)
                }
            }
        }

        do {
            try p.run()
            running = p
        } catch {
            notify("启动 DSH 失败", error.localizedDescription)
        }
    }

    private static func notify(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.runModal()
    }
}
