import EventKit
import Foundation

/// 用系统日历判断「此刻是否法定节假日」。
///
/// 系统日历（用户订阅的「中国大陆节假日」）里同时有**节日**和**节气**：
/// 霜降、立冬、小雪这些是节气，不放假；重阳节、妇女节也不放假。
/// 所以不能「有事件就算假日」，得按法定假日名单过滤。
///
/// 只回答一件事：**今天是不是法定假日**。
/// 放假几天、哪天调休补班 —— 日历里没有这些，交给 HolidayCalendar 的 JSON 数据。
enum SystemHoliday {
    /// 法定假日名单的关键词。
    /// 匹配事件名里是否包含其中之一；春节那几天在日历里写作
    /// 「除夕 / 春节 / 正月初二 / 正月初三」，所以「正月初」也算。
    private static let legalNames = [
        "元旦", "春节", "除夕", "正月初", "正月十五",
        "清明", "劳动节", "端午", "中秋", "国庆",
    ]

    /// 明显不是假日的（节气、不放假纪念日）—— 反向排除，双保险。
    private static let notHoliday = [
        "立春", "雨水", "惊蛰", "春分", "谷雨",
        "立夏", "小满", "芒种", "夏至", "小暑", "大暑",
        "立秋", "处暑", "白露", "秋分", "寒露", "霜降",
        "立冬", "小雪", "大雪", "冬至", "小寒", "大寒",
        "妇女", "青年", "儿童", "建党", "建军", "教师", "记者", "护士",
        "情人节", "愚人", "万圣", "感恩", "圣诞",
        "重阳", "腊八", "小年",
    ]

    /// EKEventStore 不是 Sendable，但只在主线程用。
    nonisolated(unsafe) private static let store = EKEventStore()
    nonisolated(unsafe) private static var authorized = false
    nonisolated(unsafe) private static var asked = false

    /// 请求访问权限（只在首次调用时弹框）。
    static func requestAccessIfNeeded(completion: (@Sendable (Bool) -> Void)? = nil) {
        if asked { completion?(authorized); return }
        asked = true
        let done: (Bool) -> Void = { ok in
            authorized = ok
            NSLog("WhaleFloat: 日历访问 \(ok ? "已允许" : "被拒绝")")
            DispatchQueue.main.async { completion?(ok) }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in done(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in done(granted) }
        }
    }

    /// 今天是不是法定假日。
    ///
    /// 返回 nil 表示「查不到」（没授权 / 没订阅节假日日历）——
    /// 调用方应当退回自己那份数据，而不是当成「不是假日」。
    static func isTodayHoliday() -> Bool? {
        guard authorized else { return nil }
        guard let cal = holidayCalendar() else { return nil }

        let now = Date()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let dayStart = c.startOfDay(for: now)
        guard let dayEnd = c.date(byAdding: .day, value: 1, to: dayStart) else { return nil }

        let pred = store.predicateForEvents(withStart: dayStart, end: dayEnd,
                                            calendars: [cal])
        let events = store.events(matching: pred)
        guard !events.isEmpty else { return false }   // 今天没事件 → 不是假日

        for e in events {
            let title = (e.title ?? "").trimmingCharacters(in: .whitespaces)
            if title.isEmpty { continue }
            if notHoliday.contains(where: { title.contains($0) }) { continue }
            if legalNames.contains(where: { title.contains($0) }) { return true }
        }
        return false
    }

    /// 找那个节假日日历。标题里带「节假日」或 Holiday 的都算。
    private static func holidayCalendar() -> EKCalendar? {
        let all = store.calendars(for: .event)
        return all.first {
            let t = $0.title
            return t.contains("节假日") || t.lowercased().contains("holiday")
        }
    }
}