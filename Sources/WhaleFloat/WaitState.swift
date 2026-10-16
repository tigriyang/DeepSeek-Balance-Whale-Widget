import Foundation

/// DSH 的「等待用户交互」状态。
///
/// 来源：`~/.dsh/.whalefloat-wait.json`，由 DSH 侧的小插件 dsh-wait-state 维护
/// （它监听 session/event 流）。
///
/// 为什么用文件而不是 HTTP：WhaleFloat 独立于 DSH，拿不到它的认证；
/// 让 DSH 侧落一份明文，程序读文件即可 —— 与读鲸鱼账本同一模式。
enum WaitState {
    struct Pending {
        /// question（等回答）或 approval（等授权）。
        let kind: String
        let ts: Double

        /// 提示文案 —— 抄自网页版鲸鱼的出厂默认（waitDefaultLines）。
        var message: String {
            kind == "approval" ? "正在等待老大授权" : "正在等待老大回答"
        }
    }

    struct Snapshot {
        let pending: Pending?
        let sessionName: String
        let updatedAt: Double
    }

    static var fileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".dsh/.whalefloat-wait.json")
    }

    /// 读状态。文件不存在（插件未装或未重启）返回 nil。
    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var pending: Pending?
        if let p = obj["pending"] as? [String: Any], let kind = p["kind"] as? String {
            pending = Pending(kind: kind, ts: (p["ts"] as? Double) ?? 0)
        }
        return Snapshot(
            pending: pending,
            sessionName: (obj["sessionName"] as? String) ?? "",
            updatedAt: (obj["updatedAt"] as? Double) ?? 0
        )
    }
}
