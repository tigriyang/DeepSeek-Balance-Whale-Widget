import CryptoKit
import Foundation
import Security

/// 当前可执行文件的签名身份指纹。
///
/// 用途只有一个：判断「这次运行的身份变了没有」。
/// TCC 的授权是记在代码签名身份上的；身份一变，系统设置里那个开关
/// 就变成旧条目的残影 —— 显示已开，实际不给新进程。
/// 有证书时用证书叶子的 SHA256（同一张证书重签不变）；
/// ad-hoc 没有证书，只能用 CDHash（每次构建都变）。
enum AppIdentity {
    static func token() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return "unknown" }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "unknown" }

        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certs.first {
            let data = SecCertificateCopyData(leaf) as Data
            return "cert-" + SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
        }
        if let unique = dict[kSecCodeInfoUnique as String] as? Data {
            return "adhoc-" + unique.map { String(format: "%02x", $0) }.joined()
        }
        return "unknown"
    }
}
