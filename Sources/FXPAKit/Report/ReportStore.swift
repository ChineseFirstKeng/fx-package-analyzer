import Foundation

/// 从输出目录加载分析器 JSON（对齐 Python 各处 `json.load(open(path))`）。
/// 带缓存：同一文件只解析一次（linkmap.json 等大文件会被多个消费者反复读取）。
public struct ReportStore {
    public let outputDir: String
    private let cache = Cache()

    final class Cache {
        var map: [String: JSONValue] = [:]
        var missing: Set<String> = []
    }

    public init(_ outputDir: String) { self.outputDir = outputDir }

    /// 加载 JSON 文件为 JSONValue；不存在返回 nil。用 JSONSerialization 快速解析并缓存。
    public func load(_ name: String) -> JSONValue? {
        if let cached = cache.map[name] { return cached }
        if cache.missing.contains(name) { return nil }
        let path = (outputDir as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let v = JSONValue.parse(data) else {
            cache.missing.insert(name)
            return nil
        }
        cache.map[name] = v
        return v
    }

    /// 加载存在的 JSON，否则空对象。
    public func loadOrEmpty(_ name: String) -> JSONValue {
        load(name) ?? .object([])
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: (outputDir as NSString).appendingPathComponent(name))
    }
}
