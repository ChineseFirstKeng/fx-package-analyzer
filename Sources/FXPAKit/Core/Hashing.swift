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

    /// 计算目录的确定性 SHA256（十六进制小写）。
    /// 按相对路径排序后，依次哈希每个文件的「相对路径 + 内容」，确保相同内容的目录产生相同哈希。
    /// 跳过符号链接，失败返回空串。
    public static func sha256(ofDirectory dir: String) -> String {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return "" }
        var hasher = SHA256()
        let sorted = entries.sorted()
        for entry in sorted {
            let full = (dir as NSString).appendingPathComponent(entry)
            // 跳过符号链接
            if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
               (attrs[.type] as? FileAttributeType) == .typeSymbolicLink { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let sub = sha256(ofDirectory: full)
                hasher.update(data: Data("\(entry)/\(sub)".utf8))
            } else {
                let fileHash = sha256(ofFile: full)
                hasher.update(data: Data("\(entry):\(fileHash)".utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
