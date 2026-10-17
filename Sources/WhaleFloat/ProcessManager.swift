import AppKit

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

        // 等 3080 真的松开。
        //
        // 进程退出与端口释放不是同一时刻：SIGKILL 之后内核还要收尾，
        // 慢的时候能拖上一两秒。这时候若马上再起一个 dsh web，
        // 就会撞上 EADDRINUSE —— 用户看到的现象是「DSH 崩了」，
        // 日志里只有一行 address already in use。
        let freed = waitForPortFree(3080, timeout: 6.0)
        let portNote = freed ? "" : "；3080 端口仍被占用"
        return "已结束 \(unique.count) 个进程（强制 \(forced) 个）\(tail)\(portNote)"
    }

    /// 轮询直到端口不再有人监听。返回是否在超时前松开。
    ///
    /// nonisolated：只跑 lsof、不碰 UI，可以从后台任务调用。
    nonisolated static func waitForPortFree(_ port: UInt16, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isPortListening(port) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !isPortListening(port)
    }

    /// 端口当前是否有进程在 LISTEN。
    nonisolated static func isPortListening(_ port: UInt16) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        p.standardOutput = Pipe()
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// 启动 DSH Web GUI。
///
/// 复用现成的 dsh-launcher 脚本：它负责起 dsh web、从启动日志里抓出带 token
/// 的认证 URL、再打开浏览器。token 每个进程重新生成且事后取不回，所以不能
/// 自己拼 URL —— 必须走启动器。
