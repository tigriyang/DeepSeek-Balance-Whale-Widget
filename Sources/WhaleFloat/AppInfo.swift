import AppKit

enum AppInfo {
    /// 次要文字的字号（菜单、面板里的说明与数值统一用它）。
    static let subFontSize: CGFloat = 12

    /// 金额格式化。
    ///
    /// 小额保留两位小数；上万后用「万」「亿」——
    /// 否则余额一大，气泡和分析窗口里就会挤出一长串数字。
    /// （上游 issue #245 报过同类问题。）
    static func money(_ v: Double, symbol: String = "¥") -> String {
        let a = abs(v)
        if a >= 100_000_000 {
            return String(format: "%@%.2f亿", symbol, v / 100_000_000)
        }
        if a >= 10_000 {
            return String(format: "%@%.2f万", symbol, v / 10_000)
        }
        return String(format: "%@%.2f", symbol, v)
    }

    /// 应用版本。
    ///
    /// **只被 build-app.sh 读取**，用来写进 Info.plist —— 运行时不读它。
    /// 改这里之后必须重新跑构建，Finder 与菜单里显示的版本才会跟着变。
    static let version = "0.1.11"
}

/// 外部链接。
