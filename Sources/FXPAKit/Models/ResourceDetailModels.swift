import Foundation

// MARK: 重复资源（analyze_duplicates.py）

public struct DuplicateGroup: Codable {
    public var sha256: String
    public var size_per_instance: Int
    public var count: Int
    public var total_waste: Int
    public var files: [AssetFile]
}

public struct DuplicateResult: Codable {
    public var meta: Meta
    public var summary: Summary
    public var duplicates: [DuplicateGroup]
    public var all_files: [AssetFile]

    public struct Meta: Codable { public var scan_path: String; public var generated_at: String }
    public struct Summary: Codable {
        public var total_files_scanned: Int
        public var total_scanned_size: Int
        public var duplicate_groups: Int
        public var duplicate_file_count: Int
        public var total_waste: Int
    }
}

// MARK: 无用资源（analyze_unused_resources.py）

public struct UnusedItem: Codable {
    public var name: String
    public var base_name: String
    public var path: String
    public var size: Int
    public var ext: String
    public var owner: String
    public var confidence: String
    public var reason: String
    public var referenced_from: [String]
}

public struct UnusedResourceEntry: Codable {
    public var name: String
    public var base_name: String
    public var path: String
    public var size: Int
    public var ext: String
    public var owner: String
}

public struct OwnerStat: Codable {
    public var total: Int
    public var unused: Int
    public var unused_size: Int
}

public struct UnusedResult: Codable {
    public var meta: Meta
    public var summary: Summary
    public var resources: [UnusedResourceEntry]
    public var unused: [UnusedItem]

    public struct Meta: Codable { public var project_dir: String; public var source_dir: String; public var generated_at: String }
    public struct Summary: Codable {
        public var total_resources: Int
        public var total_size: Int
        public var unused_count: Int
        public var unused_size: Int
        public var high_confidence: Int
        public var medium_confidence: Int
        public var low_confidence: Int
        public var by_owner: [String: OwnerStat]
    }
}
