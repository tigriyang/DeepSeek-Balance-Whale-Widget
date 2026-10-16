import Foundation

// MARK: - 峰谷定价

/// DeepSeek 官方峰谷计价规则（2026-09-19 版，实测自鲸鱼插件源码）。
///
/// 高峰时段：工作日 09:00–12:00、14:00–18:00（北京时间）；
/// 其余时段谷价；2026-08-23 起周末全天谷价；法定节假日全天谷价。
enum PeakValley {
    /// 高峰时段（北京时间，[起, 止)，小时制）。
    static let peakHours: [(start: Int, end: Int)] = [(9, 12), (14, 18)]

    /// 2026 年法定节假日（全天谷价）。来自鲸鱼插件的 HOLIDAY_VALLEY。
    static let holidays: Set<String> = [
        "2026-01-01", "2026-01-02", "2026-01-03",
        "2026-02-15", "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19",
        "2026-02-20", "2026-02-21", "2026-02-22", "2026-02-23",
        "2026-04-04", "2026-04-05", "2026-04-06",
        "2026-05-01", "2026-05-02", "2026-05-03", "2026-05-04", "2026-05-05",
        "2026-06-19", "2026-06-20", "2026-06-21",
        "2026-09-25", "2026-09-26", "2026-09-27",
        "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04",
        "2026-10-05", "2026-10-06", "2026-10-07",
    ]

    /// 调休上班的周末（这些日子按工作日算峰谷）。
    static let makeupWorkdays: Set<String> = [
        "2026-01-04", "2026-05-09", "2026-09-20", "2026-10-10",
    ]

    /// 中文星期，用于显示。
    static func weekdayZh(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let w = cal.component(.weekday, from: date)
        return names[max(0, min(6, w - 1))]
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: date)
    }

    /// 是否处于高峰计价。全部按北京时间判定。
    static func isPeak(at date: Date = Date()) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let key = dayKey(date)
        // 法定节假日 → 全天谷价（优先级最高）
        if holidays.contains(key) { return false }
        let weekday = cal.component(.weekday, from: date)  // 1=周日 7=周六
        let isWeekend = (weekday == 1 || weekday == 7)
        // 周末默认谷价，但调休上班的周末按工作日
        if isWeekend && !makeupWorkdays.contains(key) { return false }
        let hour = cal.component(.hour, from: date)
        for slot in peakHours where hour >= slot.start && hour < slot.end {
            return true
        }
        return false
    }

    /// 下一个切换时刻（用于倒计时）。返回 (时间点, 切换后是否高峰)。
    static func nextChange(from date: Date = Date()) -> (Date, Bool) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let current = isPeak(at: date)
        // 逐分钟向前找切换点，最多找 3 天（够覆盖任意边界）
        var probe = date
        for _ in 0..<(3 * 24 * 60) {
            probe = probe.addingTimeInterval(60)
            if isPeak(at: probe) != current { return (probe, !current) }
        }
        return (date.addingTimeInterval(3600), !current)
    }

    /// 倒计时文案，如 "高峰还有 01:23:45"。
    static func countdownText(from date: Date = Date()) -> String {
        let (next, nextIsPeak) = nextChange(from: date)
        let secs = max(0, Int(next.timeIntervalSince(date)))
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        let label = nextIsPeak ? "距高峰" : "距谷价"
        return String(format: "%@ %02d:%02d:%02d", label, h, m, s)
    }
}

// MARK: - 凭据

/// 从 DSH 的凭据文件里读 DeepSeek API key。
///
/// 为什么读文件而不是走 DSH：本程序独立于 DSH，不依赖它的运行时。
/// 凭据文件是稳定的契约（YAML，refs 段里有 DEEPSEEK_API_KEY）。
enum Credentials {
    /// 凭据文件候选路径（按顺序找，取第一个存在的）。
    static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.dsh/.credentials.yaml",
            "\(home)/.dsh/credentials.yaml",
        ]
    }

    /// 读 API key。找不到返回 nil（调用方决定如何提示）。
    static func deepSeekAPIKey() -> String? {
        // 环境变量优先（便于用户覆盖或测试）
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"],
           !env.isEmpty {
            return env
        }
        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let key = parseAPIKey(from: text) { return key }
        }
        return nil
    }

    /// 从 YAML 文本里抽 DEEPSEEK_API_KEY 的值。
    /// 只做行级扫描，不引 YAML 依赖 —— 这个文件结构简单且稳定。
    static func parseAPIKey(from text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("DEEPSEEK_API_KEY") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            // 去掉可能的引号与行尾逗号（YAML flow 风格里常见）
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if value.hasSuffix(",") { value.removeLast() }
            if value.isEmpty { continue }
            return value
        }
        return nil
    }
}

// MARK: - 余额

/// 官方余额接口返回。
struct BalanceInfo: Decodable {
    let isAvailable: Bool
    let balanceInfos: [Wallet]

    struct Wallet: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

/// 一次查询的结果，供 UI 直接消费。
struct BalanceSnapshot {
    var total: Double
    var granted: Double
    var toppedUp: Double
    var currency: String
    var fetchedAt: Date

    var symbol: String { currency == "USD" ? "$" : "¥" }
    var totalText: String { String(format: "%@%.2f", symbol, total) }
}

/// 查余额。直连官方接口，不走 DSH。
actor BalanceClient {
    private let session: URLSession
    private let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        session = URLSession(configuration: cfg)
    }

    enum Failure: LocalizedError {
        case noKey
        case http(Int)
        case badPayload
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "未找到 DEEPSEEK_API_KEY"
            case .http(let code): return "接口返回 HTTP \(code)"
            case .badPayload: return "响应结构异常"
            case .transport(let msg): return "网络错误：\(msg)"
            }
        }
    }

    /// 查询余额。抛出 Failure，调用方展示错误文案。
    func fetch() async throws -> BalanceSnapshot {
        guard let key = Credentials.deepSeekAPIKey() else { throw Failure.noKey }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.http(http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(BalanceInfo.self, from: data),
              let first = decoded.balanceInfos.first else {
            throw Failure.badPayload
        }
        return BalanceSnapshot(
            total: Double(first.totalBalance) ?? 0,
            granted: Double(first.grantedBalance) ?? 0,
            toppedUp: Double(first.toppedUpBalance) ?? 0,
            currency: first.currency,
            fetchedAt: Date()
        )
    }
}
