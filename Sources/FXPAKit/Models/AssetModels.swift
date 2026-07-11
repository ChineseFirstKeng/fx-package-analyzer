import Foundation

/// 单个资源文件条目 —— 对齐 resource_scanner.py 产出。
public struct AssetFile: Codable {
    public var path: String
    public var relative_path: String
    public var size: Int
    public var ext: String
    public var category: String
    public var source: String
    public var base_name: String
    public var sha256: String
    public var children: [AssetFile]?
}

/// 按来源拆分的资源统计。
public struct AssetBySource: Codable {
    public var name: String
    public var code: Int
    public var resource: Int
    public var total: Int
}

/// analyze_assets.py / resource_scanner.py 输出。
public struct AssetResult: Codable {
    public var total_size: Int
    public var by_category: [String: Int]
    public var by_type: [String: Int]
    public var all_files: [AssetFile]
    public var all_images: [AssetFile]
    public var meta: AssetMeta
    public var total_size_display: String
    public var by_source: [AssetBySource]

    public struct AssetMeta: Codable {
        public var scan_path: String
        public var file_count: Int
    }
}
