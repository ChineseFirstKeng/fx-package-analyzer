import Foundation
import CryptoKit

/// 文件哈希 —— 复刻 resource_scanner.py 的 sha256()（分块读取）。
/// 使用系统内置 CryptoKit，无需外部依赖。
public enum Hashing {
    /// 计算文件 SHA256（十六进制小写）。失败返回空串。
    public static func sha256(ofFile path: String) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? fh.read(upToCount: 8192)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
