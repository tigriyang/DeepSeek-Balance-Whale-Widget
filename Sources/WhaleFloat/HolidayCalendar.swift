import Foundation

/// 法定节假日数据 —— 用官方发布的数据，不自己推算。
///
/// 数据源：[NateScarlet/holiday-cn](https://github.com/NateScarlet/holiday-cn)
/// 直接给出对应的政策原文链接。
///
/// 为什么不自算：峰谷判断依赖「今天是不是法定假日 / 是不是调休补班」，
/// 而调休是行政决定 —— 每年 11 月才公布次年安排，任何算法都推不出来。
/// 农历节日虽然能用历法算，但少了调休照样不准，还不如直接用权威数据。
///
/// 三层来源，依次降级：
///   1. 用户缓存   ~/.dsh/whalefloat-holidays/<年>.json（联网更新下来的）
///   2. 内置快照   app 包内 Resources/holidays/<年>.json
///   3. 兜底       周末算放假（数据缺失时节假日会误判成工作日，
///                 但至少不会反过来把工作日当假日）
enum HolidayCalendar {
    struct Day: Codable {
        let name: String
        let date: String
        let isOffDay: Bool
    }

    struct Year: Codable {
        let year: Int
        let papers: [String]?
        let days: [Day]
    }

    /// "YYYY-MM-DD" → 是否放假。
    /// 下面两个都由 lock 保护，只是 Swift 6 看不出这层关系。
    nonisolated(unsafe) private static var table: [String: (off: Bool, name: String)] = [:]
    nonisolated(unsafe) private static var loadedYears: Set<Int> = []
    private static let lock = NSLock()

    private static var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/whalefloat-holidays", isDirectory: true)
    }

    // MARK: - 查询

    /// 某天是否按「谷价」处理（法定假日）。
    ///
    /// 注意：补班日（调休上班的周末）在这张表里是 `isOffDay = false`，
    /// 所以工作日判断天然正确 —— 这正是用官方数据的好处。
    static func isOffDay(_ date: Date) -> Bool {
        let key = dayKey(date)
        loadIfNeeded(year: year(of: date))
        lock.lock()
        let hit = table[key]
        lock.unlock()
        if let hit { return hit.off }
        // 兜底：没有数据时按周末算
        return isWeekend(date)
    }

    /// 该日的名称（如「春节」），没有则返回 nil。
    static func name(of date: Date) -> String? {
        let key = dayKey(date)
        loadIfNeeded(year: year(of: date))
        lock.lock()
        let hit = table[key]
        lock.unlock()
        return hit?.name
    }

    /// 某个年份的数据是否已就绪。
    static func hasData(for year: Int) -> Bool {
        loadIfNeeded(year: year)
        lock.lock()
        let ok = loadedYears.contains(year)
        lock.unlock()
        return ok
    }

    // MARK: - 装载

    private static func loadIfNeeded(year: Int) {
        lock.lock()
        let done = loadedYears.contains(year)
        lock.unlock()
        if done { return }

        // 用户缓存优先，其次内置快照
        let candidates = [
            cacheDir.appendingPathComponent("\(year).json"),
            Bundle.main.resourceURL?
                .appendingPathComponent("holidays/\(year).json"),
        ].compactMap { $0 }

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let y = try? JSONDecoder().decode(Year.self, from: data),
                  // 空文件也算「没数据」—— 次年安排要等 11 月才公布，
                  // 在此之前它会是个只有 year 字段的空壳。当成有数据的话，
                  // 降级逻辑就永远不会生效了。
                  !y.days.isEmpty else { continue }
            lock.lock()
            for d in y.days { table[d.date] = (d.isOffDay, d.name) }
            loadedYears.insert(year)
            lock.unlock()
            NSLog("WhaleFloat: 载入 \(year) 年节假日数据（\(y.days.count) 条）")
            return
        }
        // 都没有就记一笔，避免每次查询都重试读盘
        lock.lock()
        loadedYears.insert(year)
        lock.unlock()
    }

    // MARK: - 联网更新

    private static let sourceBase =
        "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master"

    /// 检查并下载数据。
    ///
    /// 拉「今年」和「明年」：明年的安排通常 11 月前后公布，
    /// 公布之前拉到的会是空文件，跳过即可，下周再试。
    /// 用 jsDelivr 而不是 raw.githubusercontent —— 后者在国内时常连不上。
    static func refresh(completion: (() -> Void)? = nil) {
        let thisYear = year(of: Date())
        let targets = [thisYear, thisYear + 1]
        let group = DispatchGroup()

        try? FileManager.default.createDirectory(at: cacheDir,
                                                 withIntermediateDirectories: true)

        for y in targets {
            // 已经有数据就不重复拉（当年数据不会变，除非有临时调整）
            let dst = cacheDir.appendingPathComponent("\(y).json")
            let fresh = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate]) as? Date
            if let fresh, Date().timeIntervalSince(fresh) < 7 * 86400 { continue }

            guard let url = URL(string: "\(sourceBase)/\(y).json") else { continue }
            group.enter()
            URLSession.shared.dataTask(with: url) { data, _, _ in
                defer { group.leave() }
                guard let data, let parsed = try? JSONDecoder().decode(Year.self, from: data),
                      !parsed.days.isEmpty else { return }
                try? data.write(to: dst)
                // 重新装载该年
                lock.lock()
                loadedYears.remove(y)
                for d in parsed.days { table[d.date] = (d.isOffDay, d.name) }
                loadedYears.insert(y)
                lock.unlock()
                NSLog("WhaleFloat: 更新 \(y) 年节假日数据（\(parsed.days.count) 条）")
            }.resume()
        }
        group.notify(queue: .main) { completion?() }
    }

    // MARK: - 工具

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return c
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: date)
    }

    private static func year(of date: Date) -> Int {
        cal.component(.year, from: date)
    }

    private static func isWeekend(_ date: Date) -> Bool {
        let w = cal.component(.weekday, from: date)
        return w == 1 || w == 7
    }
}