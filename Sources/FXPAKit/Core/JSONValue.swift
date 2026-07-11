import Foundation

/// 动态 JSON 值 —— 用于表达形状不固定的 JSON（如 pod_mapping.json、REPORT_DATA 中的混合结构）。
/// 支持 Codable，编码时保持插入顺序（对象用有序数组存储）。
public indirect enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    /// 有序对象：保留键的插入顺序，保证渲染输出稳定
    case object([(String, JSONValue)])

    // MARK: Decoding

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            // 无序对象解码（顺序不保证，仅用于读取外部 JSON）
            let dict = try c.decode([String: JSONValue].self)
            self = .object(dict.map { ($0.key, $0.value) })
        }
    }

    // MARK: Encoding

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer(); try c.encode(b)
        case .int(let i):
            var c = encoder.singleValueContainer(); try c.encode(i)
        case .double(let d):
            var c = encoder.singleValueContainer(); try c.encode(d)
        case .string(let s):
            var c = encoder.singleValueContainer(); try c.encode(s)
        case .array(let a):
            var uc = encoder.unkeyedContainer()
            for item in a { try uc.encode(item) }
        case .object(let pairs):
            var kc = encoder.container(keyedBy: DynamicKey.self)
            for (k, v) in pairs {
                try kc.encode(v, forKey: DynamicKey(stringValue: k)!)
            }
        }
    }

    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    // MARK: 快速构建（JSONSerialization → JSONValue，避免 Codable 级联，大文件快很多）

    /// 从 JSON 数据快速解析为 JSONValue（对象键顺序不保证，仅用于读取外部 JSON）。
    public static func parse(_ data: Data) -> JSONValue? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSONValue(foundation: obj)
    }

    public init(foundation obj: Any) {
        switch obj {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                let d = n.doubleValue
                if d.rounded() == d && abs(d) < 9e15 { self = .int(n.intValue) }
                else { self = .double(d) }
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { JSONValue(foundation: $0) })
        case let dict as [String: Any]:
            self = .object(dict.map { ($0.key, JSONValue(foundation: $0.value)) })
        default:
            self = .null
        }
    }

    // MARK: Accessors

    public subscript(key: String) -> JSONValue? {
        if case .object(let pairs) = self {
            return pairs.first(where: { $0.0 == key })?.1
        }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d):
            guard d.isFinite && d >= -9.007199254740992e15 && d <= 9.007199254740992e15 else { return nil }
            return Int(d)
        default: return nil
        }
    }
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    public var objectPairs: [(String, JSONValue)]? {
        if case .object(let p) = self { return p }
        return nil
    }
}
