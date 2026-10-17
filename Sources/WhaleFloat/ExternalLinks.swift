import AppKit

enum ExternalLinks {
    /// DeepSeek 平台用量与充值页。
    static let billing = "https://platform.deepseek.com/usage"

    static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 进程清理助手：按命令行特征找进程并结束。
///
/// 用 `ps` + 匹配而不是 `pkill`：pkill 依赖进程名（截断到 16 字符），
/// 而 `dsh-launcher.sh`、`dsh web` 这类要匹配的是**完整命令行**。
