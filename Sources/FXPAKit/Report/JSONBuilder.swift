import Foundation

/// JSON 构建便捷方法。
extension JSONValue {
    /// 用键值对构建对象（过滤 nil value）。
    public static func obj(_ pairs: [(String, JSONValue?)]) -> JSONValue {
        .object(pairs.compactMap { pair in pair.1.map { (pair.0, $0) } })
    }

    /// 在对象末尾追加/覆盖一个键，返回新对象（非对象则原样返回）。
    public func adding(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var pairs) = self else { return self }
        pairs.removeAll { $0.0 == key }
        pairs.append((key, value))
        return .object(pairs)
    }
}

/// JSONValue 字面量扩展。
extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public typealias Key = String
    public typealias Value = JSONValue
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(elements.map { ($0.0, $0.1) })
    }
}
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}
