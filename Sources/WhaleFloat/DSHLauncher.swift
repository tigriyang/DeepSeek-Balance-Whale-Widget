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
    static func launch() {
        if let p = running, p.isRunning {
            notify("正在启动中…", "DSH 启动器已在运行，请稍候再试。")
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
