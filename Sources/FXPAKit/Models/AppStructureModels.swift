import Foundation

/// .app 文件结构节点 —— 对齐 analyze_app_structure.py 的节点（所有字段恒存在，文件 children 为空数组）。
public final class AppFileNode: Codable {
    public var name: String
    public var type: String
    public var size: Int
    public var path: String
    public var children: [AppFileNode]

    public init(name: String, type: String, size: Int, path: String, children: [AppFileNode] = []) {
        self.name = name
        self.type = type
        self.size = size
        self.path = path
        self.children = children
    }
}

/// analyze_app_structure.py 输出。
public struct AppStructureResult: Codable {
    public var total_size: Int
    public var root: AppFileNode
}
