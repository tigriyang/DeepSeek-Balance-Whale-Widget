import AppKit
import Foundation
import UserNotifications

/// 把 DSH 的对话输出推到系统通知，并支持在通知里直接回复。
///
/// 分工：
///   · DSH 侧插件 dsh-notify-bridge 负责写「有什么新回复」、
///     以及接收「用户回复了什么」（它才有对话的读写权限）；
///   · 本文件负责系统通知这一端 —— 发通知、收用户在通知里的输入，
///     再写回一个文件给插件。
///
/// 用的都是官方 API：UNUserNotificationCenter + UNTextInputNotificationAction，
/// 所以回复框是系统原生的（展开通知即可输入）。
@MainActor
final class NotifyBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifyBridge()

    /// 点通知本体时调用（由 App 注入）。
    /// 这里不直接碰 UI 层 —— 通知模块只管通知。
    static var onOpenConversation: (() -> Void)?

    private static let categoryID = "DSH_REPLY"
    private static let replyActionID = "DSH_REPLY_ACTION"

    private var seen = Set<String>()
    private var replySeq = 0
    private var pollTimer: Timer?

    private static var notifyFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/.whalefloat-notify.json")
    }
    private static var replyFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/.whalefloat-reply.json")
    }

    /// 诊断输出（NSLog 走系统日志，这里额外落个文件方便排查）。
    /// nonisolated —— 调用它的地方多在 URLSession 回调里，
    /// 那些不是主线程，标成 MainActor 会触发隔离违规。
    /// 它只往文件追加一行，不碰 UI，本来也不需要主线程。
    nonisolated static func trace(_ msg: String) {
        let line = String(Date().timeIntervalSince1970) + " " + msg + "\n"
        let url = URL(fileURLWithPath: "/tmp/whalefloat-notify.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 启动：注册类别 + 申请权限 + 开始轮询。
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // 带文本输入的「回复」动作 —— 通知里能打字的关键
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionID,
            title: "回复",
            options: [],
            textInputButtonTitle: "发送",
            textInputPlaceholder: "回复 DSH…"
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        // 请求授权（首次会弹系统对话框，只能由用户同意）
        center.requestAuthorization(options: [.alert, .sound]) { granted, err in
            Self.trace("授权结果 granted=\(granted) err=\(err?.localizedDescription ?? "无")")
        }
        // 顺便读一下当前设置（被拒绝时不会再弹框，只会静默失败）
        center.getNotificationSettings { st in
            Self.trace("通知设置 authorizationStatus=\(st.authorizationStatus.rawValue) alertSetting=\(st.alertSetting.rawValue)")
        }

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// 看一眼插件写来的新回复，有就推送。
    private func poll() {
        guard let data = try? Data(contentsOf: Self.notifyFile),
              let box = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = box["items"] as? [[String: Any]] else { return }

        for item in items {
            guard let id = item["id"] as? String, !seen.contains(id) else { continue }
            seen.insert(id)
            Self.trace("准备推送 id=\(id)")
            push(id: id,
                 title: (item["title"] as? String) ?? "DSH",
                 body: (item["text"] as? String) ?? "",
                 sessionId: (item["sessionId"] as? String) ?? "")
        }
        if seen.count > 500 { seen.removeAll() }
    }

    /// 把 Markdown 标记剥成纯文本。
    ///
    /// 通知栏不解析 Markdown，原样送过去会在正文里冒出 `**`、`#`、`|` 这些符号，
    /// 读起来很怪。这里只做「去标记」，不做渲染。
    ///
    /// 正则一律用原始字符串（#"..."#）—— 否则反斜杠要双写，可读性极差。
    static func plainText(from markdown: String) -> String {
        var t = markdown

        // 代码围栏：去掉围栏那一行，保留里面的代码
        t = t.replacingOccurrences(of: #"(?m)^\s*```[a-zA-Z]*\s*$"#,
                                   with: "", options: .regularExpression)
        // 行内代码的反引号
        t = t.replacingOccurrences(of: "`", with: "")

        // 粗体 / 斜体 / 删除线
        t = t.replacingOccurrences(of: "**", with: "")
        t = t.replacingOccurrences(of: "__", with: "")
        t = t.replacingOccurrences(of: "~~", with: "")

        // 图片 ![alt](url) → alt
        t = t.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#,
                                   with: "$1", options: .regularExpression)
        // 链接 [text](url) → text
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#,
                                   with: "$1", options: .regularExpression)

        // 标题开头的 #
        t = t.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#,
                                   with: "", options: .regularExpression)
        // 引用开头的 >
        t = t.replacingOccurrences(of: #"(?m)^\s*>\s?"#,
                                   with: "", options: .regularExpression)
        // 无序列表 → ·
        t = t.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#,
                                   with: "· ", options: .regularExpression)

        // 表格分隔行整行丢掉，数据行的 | 换成两空格
        t = t.replacingOccurrences(of: #"(?m)^\s*\|?[\s:|-]+\|\s*$"#,
                                   with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*\|\s*"#,
                                   with: "  ", options: .regularExpression)

        // 压成单行：换行一律变空格，连续空格归一。
        // 通知栏最多显示两三行，留换行只会让内容更早被截断。
        t = t.replacingOccurrences(of: #"\s*\n+\s*"#, with: " ",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ",
                                   options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func push(id: String, title: String, body: String, sessionId: String) {
        let content = UNMutableNotificationContent()
        // 标题必须有 —— macOS 的通知在 title 为空时**不显示**，
        // 而 add() 仍会返回成功，于是日志里全是「推送成功」但屏幕上什么都没有。
        // 上一轮为了去掉「DSH · DSH」这个重复，把标题清空了，踩的就是这个坑。
        // 现在用 app 名，简短且不重复。
        content.title = "小鲸鱼"
        content.body = Self.plainText(from: body)
        content.categoryIdentifier = Self.categoryID
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]

        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            Self.trace(err == nil ? "推送成功 id=\(id)" : "推送失败 id=\(id) err=\(err!.localizedDescription)")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        // ① 用户在通知里输入了回复
        if let textResponse = response as? UNTextInputNotificationResponse {
            let text = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let sessionId = (response.notification.request.content.userInfo["sessionId"] as? String) ?? ""
            Task { @MainActor in Self.shared.writeReply(text: text, sessionId: sessionId) }
            return
        }

        // ② 直接点通知本体 → 去 DSH 看这条对话
        // 之前只处理了文本回复，点通知本身毫无反应。
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == UNNotificationDismissActionIdentifier {
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
            Task { @MainActor in Self.onOpenConversation?() }
        }
    }

    /// 把回复写回文件，DSH 侧插件轮询到后会注入对话。
    /// 起一次新对话：给插件一条 text，让它建新会话再投进去。
    ///
    /// 首条用「你好」—— 它不是给用户看的，作用只是让 DSH 开口。
    /// 等 DSH 回完，正常的通知链路就接上了，用户可以直接在通知里回。
    func beginNewSession(text: String = "你好") {
        writeReply(text: text, sessionId: "", newSession: true)
    }

    /// 下一个序号。
    ///
    /// 必须从文件里读现值 —— replySeq 是内存变量，程序重启归零，
    /// 而插件那边记着上次处理到哪。若这里从 1 重新发，
    /// 插件会认为「比处理过的还小」，直接丢弃，表现成回复没反应。
    private func nextSeq() -> Int {
        var onDisk = 0
        if let data = try? Data(contentsOf: Self.replyFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let n = obj["seq"] as? Int {
            onDisk = n
        }
        replySeq = max(replySeq, onDisk) + 1
        return replySeq
    }

    private func writeReply(text: String, sessionId: String, newSession: Bool = false) {
        let payload: [String: Any] = [
            "seq": nextSeq(),
            "text": text,
            "sessionId": sessionId,
            "newSession": newSession,
            "ts": Date().timeIntervalSince1970 * 1000,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: Self.replyFile)
            NSLog("WhaleFloat: 回复已写入 session=" + sessionId)
        } catch {
            NSLog("WhaleFloat: 回复写入失败 " + error.localizedDescription)
        }
    }
}