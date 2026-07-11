import Foundation

/// LinkMap 文件树节点 —— 对齐 analyze_linkmap.py get_file_tree()。
/// 目录有 children、无 path；叶子有 path、无 children（编码时 nil 键省略）。
public final class LinkMapTreeNode: Codable {
    public var name: String
    public var type: String
    public var size: Int
    public var path: String?
    public var children: [LinkMapTreeNode]?

    public init(name: String, type: String, size: Int, path: String? = nil, children: [LinkMapTreeNode]? = nil) {
        self.name = name
        self.type = type
        self.size = size
        self.path = path
        self.children = children
    }
}

/// 符号条目。
public struct LinkMapSymbol: Codable {
    public var name: String
    public var size: Int
}

/// 模块内的 .o 文件。
public struct LinkMapModuleFile: Codable {
    public var path: String
    public var size: Int
    public var symbols: [LinkMapSymbol]
}

/// 模块聚合。
public struct LinkMapModule: Codable {
    public var name: String
    public var size: Int
    public var file_count: Int
    public var files: [LinkMapModuleFile]
    public var lib_type: String
    // pod_mapping 注解（提供 pod_mapping 时对所有模块设置，未匹配为空串）
    public var pod: String?
    public var manager: String?
    public var mach_o_type: String?
    // Pod 动态库 LinkMap 合并出的模块标记
    public var _pod_linkmap: Bool?
}

/// 模块 Section 明细。
public struct LinkMapModuleSection: Codable {
    public var module: String
    public var total: Int
    public var sections: [String: Int]
}

/// .o 文件汇总。
public struct LinkMapOFile: Codable {
    public var path: String
    public var size: Int
}

/// analyze_linkmap.py 输出。
public struct LinkMapResult: Codable {
    public var meta: Meta
    public var total_size: Int
    public var total_size_display: String
    public var modules: [LinkMapModule]
    public var sections: [String: Int]
    public var file_tree: LinkMapTreeNode
    public var top_o_files: [LinkMapOFile]
    public var module_sections: [LinkMapModuleSection]

    public struct Meta: Codable {
        public var linkmap_path: String
        public var object_file_count: Int
        public var symbol_count: Int
    }
}
