// 本文件保留的是：AppInfo / ExternalLinks / ProcessManager / DSHLauncher。
// 现在菜单改成了自绘的 MenuPanel（可内嵌图表、可翻页），MenuBuilder 已废弃删除。
// 注：原先这里还有一个 MenuBuilder（用 NSMenu 搭右键菜单）。

import AppKit

/// 构建右键菜单与菜单栏菜单。
///
/// 用系统原生 NSMenu —— 自动获得 macOS 的外观、深色模式适配、键盘导航，
/// 不自己画菜单。
/// 状态栏图标的菜单。
///
/// 注意：这只是**菜单栏图标**的下拉菜单（NSMenu 就够用）。
/// 右键鲸鱼浮窗弹出的那个是自绘的 MenuPanel（要内嵌图表、要翻页）。
@MainActor
enum MenuBuilder {
    static func build(target: AppDelegate) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        add(m, "刷新余额", #selector(AppDelegate.refreshNow), target)
        m.addItem(.separator())
        add(m, "分析…", #selector(AppDelegate.openLedger), target)
        add(m, "启动 DSH GUI", #selector(AppDelegate.launchDSH), target)
        add(m, "充值 / 查看用量…", #selector(AppDelegate.openBilling), target)
        m.addItem(.separator())
        add(m, "完全退出（并关闭 DSH）", #selector(AppDelegate.quitEverything), target)
        add(m, "退出浮窗", #selector(AppDelegate.quit), target)
        return m
    }

    private static func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ target: AnyObject) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = target
        m.addItem(item)
    }
}


enum AppInfo {
    static let version = "0.1.0"
}

/// 外部链接。
enum ExternalLinks {
    /// DeepSeek 平台用量与充值页。
    static let billing = "https://platform.deepseek.com/usage"

    static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 进程清理助手：按命令行特征找进程并结束。
///
/// 用 `ps` + 匹配而不是 `pkill`：pkill 依赖进程名（截断到 16 字符），
/// 而 `dsh-launcher.sh`、`dsh web` 这类要匹配的是**完整命令行**。
@MainActor
enum ProcessManager {
    struct Proc {
        let pid: Int32
        let ppid: Int32
        let command: String
    }

    /// 取一份进程快照（含父子关系）。
    static func snapshot() -> [Proc] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        var table: [Proc] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            table.append(Proc(pid: pid, ppid: ppid, command: String(parts[2])))
        }
        return table
    }

    /// 找出命令行里含 needle 的进程 PID（排除自己）。
    static func pids(matching needle: String) -> [Int32] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        return snapshot()
            .filter { $0.pid != selfPID && $0.command.contains(needle)
                      && !$0.command.contains("WhaleFloat") }
            .map(\.pid)
    }

    /// 该命令行是否属于「要清理的那一摊」。
    ///
    /// 为什么按**命令行**匹配而不是进程名：macOS 的进程名截断到 16 字符，
    /// `dsh-launcher.sh`、`dsh web` 这类根本匹配不到 —— 这也是先前 `pkill` 清理
    /// 一个都没杀掉的真正原因。
    static func isTarget(_ cmd: String) -> Bool {
        if cmd.contains("WhaleFloat") { return false }        // 绝不杀自己
        if cmd.contains("dsh web") { return true }
        if cmd.contains("dsh-launcher") { return true }
        if cmd.contains("dsh-ptc-runtime") { return true }    // 工具执行器（跑脚本的就是它）
        if cmd.contains("/.dsh/plugins/") { return true }     // 插件
        if cmd.contains("dsh-tui") { return true }
        return false
    }

    /// 收集 roots 的整棵子树，**子在前、父在后**。
    ///
    /// 顺序很要紧：若先杀父，子进程会被 reparent 到 launchd，
    /// 就从这棵树里消失、更难追踪 —— 失控的脚本正是这样「跑掉」的。
    static func subtree(roots: [Int32], table: [Proc]) -> [Int32] {
        var childrenByParent: [Int32: [Int32]] = [:]
        for p in table {
            childrenByParent[p.ppid, default: []].append(p.pid)
        }
        var result: [Int32] = []
        var seen = Set<Int32>()
        func walk(_ pid: Int32) {
            guard seen.insert(pid).inserted else { return }
            for child in childrenByParent[pid] ?? [] { walk(child) }
            result.append(pid)          // 后序：先子后父
        }
        for r in roots { walk(r) }
        return result
    }

    /// 兜底清理：把 DSH 框架连同它派生出去的一切**连根拔起**。
    ///
    /// 用途是当紧急制动阀：网页界面被失控代码卡住时点不动了，
    /// 而本程序是独立进程、仍能响应，由它来做清场。
    ///
    /// 三步走：
    ///   1. 找根（DSH 框架 / 启动器 / 工具执行器 / 插件）
    ///   2. 连根拔 —— 整棵子树，子先父后
    ///   3. 再取一次快照补漏（失控代码在清理途中仍可能 fork 新进程），
    ///      然后 TERM 给体面、KILL 强杀
    @discardableResult
    static func cleanupAll() -> String {
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // 第一遍：整棵树
        let table = snapshot()
        let rootPIDs = table.filter { $0.pid != selfPID && isTarget($0.command) }.map(\.pid)
        var targets = subtree(roots: rootPIDs, table: table)

        // 第二遍：补上清理途中新生的、以及已被 reparent 的孤儿
        let table2 = snapshot()
        for p in table2 where p.pid != selfPID && isTarget(p.command) {
            targets.append(p.pid)
        }

        var seen = Set<Int32>()
        let unique = targets.filter { $0 != selfPID && seen.insert($0).inserted }
        guard !unique.isEmpty else { return "没有需要结束的进程" }

        // 先礼后兵
        for pid in unique { kill(pid, SIGTERM) }
        Thread.sleep(forTimeInterval: 1.2)

        // 仍活着的强杀 —— 失控代码通常收不到 TERM，或者故意忽略它
        var forced = 0
        for pid in unique where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            forced += 1
        }
        Thread.sleep(forTimeInterval: 0.3)

        // 复核，如实报告剩余
        let left = snapshot().filter { $0.pid != selfPID && isTarget($0.command) }
        let tail = left.isEmpty ? "" : "；仍有 \(left.count) 个未结束"
        return "已结束 \(unique.count) 个进程（强制 \(forced) 个）\(tail)"
    }
}

/// 启动 DSH Web GUI。
///
/// 复用现成的 dsh-launcher 脚本：它负责起 dsh web、从启动日志里抓出带 token
/// 的认证 URL、再打开浏览器。token 每个进程重新生成且事后取不回，所以不能
/// 自己拼 URL —— 必须走启动器。
@MainActor
enum DSHLauncher {
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