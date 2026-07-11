import Foundation

/// 类型擦除的 Encodable 包装，便于写出任意分析器结果。
public struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    public init(_ wrapped: Encodable) {
        self.encodeFunc = wrapped.encode
    }
    public func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}
