import Foundation

/// 每轮对话消耗。
///
/// 数据来源：**鲸鱼插件（dsh-whale-widget）的账本**
///   ~/.dsh/.dshw-usage.json
/// 它监听 DSH 的 usage 事件，把每轮写成一条：
///   {"ts": ..., "day": "2026-10-15", "model": "deepseek-flash",
///    "cost": 0.26533508, "tokens": 10442304}
///
/// 为什么读这个文件而不是自己解析会话：
///   DSH 本来就知道消耗，会话文件是 zstd 多帧压缩、系统没有独立 libzstd，
///   自己解纯属绕远。这里让 DSH 侧的插件当代言人，程序只读明文 JSON ——
///   简单、稳定，且与网页版鲸鱼同源（数字不会有第二份口径）。
enum TurnLedger {
    /// 一轮记录。
    struct Event: Decodable {
        let ts: Double          // 毫秒时间戳
        let day: String
        let model: String
        let cost: Double        // 人民币元
        let tokens: Int

        var date: Date { Date(timeIntervalSince1970: ts / 1000) }
    }

    /// 账本整体（只取需要的字段）。
    struct Ledger: Decodable {
        let events: [Event]?
        let lastBalance: Double?
        let todayUsage: Double?
        let dayStart: Double?
    }

    /// 账本文件候选（按优先级）。
    ///
    /// · .whalefloat-usage.json —— 本程序自己的采集插件（dsh-turn-usage）写的，
    ///   网页版鲸鱼停用后这是主数据源；
    /// · .dshw-usage.json —— 网页版鲸鱼的历史账本，作为回退（保留旧数据）。
    static var fileCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dsh = home.appendingPathComponent(".dsh")
        return [
            dsh.appendingPathComponent(".whalefloat-usage.json"),
            dsh.appendingPathComponent(".dshw-usage.json"),
        ]
    }

    /// 缓存：文件没变就复用上一次的结果。
    ///
    /// tick() 每秒调一次 load()，而账本有几十上百条事件 ——
    /// 每次都读盘再解析属于白烧 IO。用修改时间做判据即可。
    /// 由 lock 保护 —— 读写都可能来自不同线程（tick、窗口刷新）。
    nonisolated(unsafe) private static var cache: (stamp: Date, ledger: Ledger?)?
    private static let cacheLock = NSLock()

    /// 候选文件里最新的修改时间（作为缓存的判据）。没有文件时返回 distantPast。
    private static func newestStamp() -> Date {
        var newest = Date.distantPast
        for url in fileCandidates {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let m = attrs[.modificationDate] as? Date, m > newest {
                newest = m
            }
        }
        return newest
    }

    /// 读账本：在候选文件里取**事件最多的那份**，
    /// 避免新旧数据源切换的瞬间丢掉历史。
    static func load() -> Ledger? {
        let stamp = newestStamp()
        cacheLock.lock()
        if let c = cache, c.stamp == stamp {
            let hit = c.ledger
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        var best: Ledger?
        for url in fileCandidates {
            guard let data = try? Data(contentsOf: url),
                  let led = try? JSONDecoder().decode(Ledger.self, from: data)
            else { continue }
            let n = led.events?.count ?? 0
            if best == nil || n > (best?.events?.count ?? 0) {
                best = led
            }
        }
        cacheLock.lock()
        cache = (stamp, best)
        cacheLock.unlock()
        return best
    }

    /// 最近一轮（最新的事件）。没有则 nil。
    static func latest() -> Event? {
        guard let l = load(), let ev = l.events, !ev.isEmpty else { return nil }
        return ev.max { $0.ts < $1.ts }
    }
}

/// 用量数据的汇总视图，供 UI 一轮渲染。
struct UsageSnapshot {
    /// 最近一轮
    var lastTurn: TurnLedger.Event?
    /// 今日累计消耗（元）
    var todayTotal: Double?
    /// 今日轮数
    var turnCount: Int
}