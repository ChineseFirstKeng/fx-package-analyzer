import Foundation

/// 字节大小格式化 —— 复刻 lib/formatters.py 的 fmt()。
/// ≥1 MiB → "X.XX MB"；≥1 KiB → "X.XX KB"；否则 "X B"。
public enum ByteFormatter {
    public static func fmt(_ b: Int) -> String {
        if b >= 1_048_576 {
            return String(format: "%.2f MB", Double(b) / 1_048_576.0)
        }
        if b >= 1024 {
            return String(format: "%.2f KB", Double(b) / 1024.0)
        }
        return "\(b) B"
    }
}

/// HTML 转义 —— 复刻 lib/formatters.py 的 esc()。
public enum HTMLEscape {
    public static func esc(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        r = r.replacingOccurrences(of: "\"", with: "&quot;")
        r = r.replacingOccurrences(of: "'", with: "&#39;")
        return r
    }
}
