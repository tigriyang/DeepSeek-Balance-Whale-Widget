import Foundation

// MARK: - 峰谷定价

/// DeepSeek 官方峰谷计价规则（2026-09-19 版，实测自鲸鱼插件源码）。
///
/// 高峰时段：工作日 09:00–12:00、14:00–18:00（北京时间）；
/// 其余时段谷价；2026-08-23 起周末全天谷价；法定节假日全天谷价。
enum PeakValley {
    /// 高峰时段（北京时间，[起, 止)，小时制）。
    static let peakHours: [(start: Int, end: Int)] = [(9, 12), (14, 18)]

    /// 节假日数据改由 HolidayCalendar 提供（官方发布，不硬编码年份）。

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
    ///
    /// 节假日数据来自官方发布（见 HolidayCalendar），不再硬编码年份 ——
    /// 往年那种写法一到次年就静默失效。
    static func isPeak(at date: Date = Date()) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        // 今天这一刻优先问系统日历 —— 用户订阅的节假日日历是权威源，
        // 且不需要我们去维护年份。查不到（未授权/未订阅）则返回 nil，往下走。
        if cal.isDateInToday(date), let fromSystem = SystemHoliday.isTodayHoliday() {
            if fromSystem { return false }   // 法定假日 → 全天谷价
            // 不是假日时不能就此断定「按工作日」——今天可能是调休的周末，
            // 那要上班。交给下面的周末判断，它读得到 JSON 里的补班数据。
        }

        // 其余日期（含未来，倒计时要用）：走本地数据。
        // 法定假日全谷价；补班的周末在这里返回 false，于是按工作日继续判时段。
        // 数据缺失时退化为「周末算假日」。
        if HolidayCalendar.isOffDay(date) { return false }
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
    var totalText: String { AppInfo.money(total, symbol: symbol) }
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
            case .noKey:
                return "没找到 API 密钥（~/.dsh/.credentials.yaml）"
            case .http(let code):
                // 只说「HTTP 401」用户没法判断该做什么，
                // 这里直接给出可能原因和下一步。
                switch code {
                case 401: return "密钥无效或已过期"
                case 403: return "密钥没有访问权限"
                case 404: return "接口地址不对"
                case 429: return "请求太频繁，稍后再试"
                case 500...599: return "服务端异常（HTTP \(code)）"
                default: return "接口返回 HTTP \(code)"
                }
            case .badPayload:
                return "响应结构异常"
            case .transport(let msg):
                return "网络不通：\(msg)"
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