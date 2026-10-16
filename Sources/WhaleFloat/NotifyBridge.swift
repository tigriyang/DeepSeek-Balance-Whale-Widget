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
    static func trace(_ msg: String) {
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

    private func push(id: String, title: String, body: String, sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = "DSH · " + title
        content.body = body
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
        guard let textResponse = response as? UNTextInputNotificationResponse else { return }
        let text = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let sessionId = (response.notification.request.content.userInfo["sessionId"] as? String) ?? ""
        Task { @MainActor in Self.shared.writeReply(text: text, sessionId: sessionId) }
    }

    /// 把回复写回文件，DSH 侧插件轮询到后会注入对话。
    private func writeReply(text: String, sessionId: String) {
        replySeq += 1
        let payload: [String: Any] = [
            "seq": replySeq,
            "text": text,
            "sessionId": sessionId,
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