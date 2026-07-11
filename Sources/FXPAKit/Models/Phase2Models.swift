import Foundation

// MARK: Swift 标准库（analyze_swift_stdlib.py）
public struct SwiftStdlibEmbeddedLib: Codable { public var name: String; public var path: String; public var size: Int }
public struct SwiftStdlibIssue: Codable { public var severity: String; public var title: String; public var detail: String }
public struct SwiftStdlibRecommendation: Codable { public var type: String; public var title: String; public var detail: String }
public struct SwiftStdlibResult: Codable {
    public var meta: Meta; public var summary: Summary; public var embedded_libs: [SwiftStdlibEmbeddedLib]
    public struct Meta: Codable { public var app_path: String; public var generated_at: String }
    public struct Summary: Codable {
        public var app_path: String; public var embedded_swift_count: Int; public var total_swift_size: Int
        public var binary_links_swift: Bool; public var main_binary: String; public var has_frameworks_dir: Bool
        public var issues: [SwiftStdlibIssue]; public var recommendations: [SwiftStdlibRecommendation]
    }
}

// MARK: 编译配置审计（analyze_build_config.sh）
public struct BuildConfigRule: Codable {
    public var key: String; public var expected: String; public var current: String
    public var status: String; public var status_label: String; public var description: String; public var criticality: String
}
public struct BuildConfigResult: Codable {
    public var meta: Meta; public var summary: Summary; public var results: [BuildConfigRule]
    public struct Meta: Codable { public var project_dir: String; public var project_path: String; public var project_type: String; public var scheme: String; public var generated_at: String }
    public struct Summary: Codable { public var total_rules: Int; public var pass: Int; public var fail: Int; public var unknown: Int }
}

// MARK: 本地化审计（analyze_localization.py）
public struct LocLanguageInfo: Codable {
    public var lang_code: String; public var display_name: String; public var lproj_count: Int
    public var total_size: Int; public var file_count: Int; public var strings_count: Int; public var strings_size: Int
    public var stringsdict_count: Int; public var stringsdict_size: Int; public var nib_count: Int; public var nib_size: Int
    public var image_count: Int; public var image_size: Int; public var other_count: Int; public var other_size: Int
    public var files: [LocFile]
}
public struct LocFile: Codable { public var name: String; public var path: String; public var size: Int; public var ext: String }
public struct LocUnusedKeyEntry: Codable { public var key: String; public var file: String }
public struct LocRecommendation: Codable { public var type: String; public var title: String; public var detail: String }
public struct LocSummary: Codable {
    public var app_path: String; public var language_count: Int; public var total_localization_size: Int
    public var lproj_dir_count: Int; public var source_keys_count: Int; public var recommendations: [LocRecommendation]
    public var unused_keys: [String: Int]
}
public struct LocalizationResult: Codable {
    public var meta: LocMeta; public var summary: LocSummary; public var languages: [String: LocLanguageInfo]; public var unused_keys: [String: [LocUnusedKeyEntry]]
    public struct LocMeta: Codable { public var app_path: String; public var source_dir: String?; public var generated_at: String }
}

// MARK: 无用代码（analyze_dead_code.py）
public struct DeadCodeItem: Codable {
    public var name: String; public var kind: String; public var kind_label: String
    public var file: String; public var line: Int; public var hints: [String]; public var estimated_size: Int; public var module: String
    public var matched_symbols: Int?
}
public struct DeadCodeResult: Codable {
    public var meta: Meta; public var summary: Summary; public var unused_items: [DeadCodeItem]
    public struct Meta: Codable { public var project_dir: String; public var scheme: String?; public var periphery_installed: Bool; public var linkmap_path: String?; public var generated_at: String }
    public struct Summary: Codable {
        public var total_unused_items: Int; public var total_estimated_savings: Int
        public var periphery_installed: Bool; public var linkmap_available: Bool
        public var by_kind: [String: Int]?
        public var by_module: [String: CodableModuleStat]?
        public init(total_unused_items: Int, total_estimated_savings: Int, periphery_installed: Bool, linkmap_available: Bool, by_kind: [String:Int]? = nil, by_module: [String:CodableModuleStat]? = nil) {
            self.total_unused_items = total_unused_items; self.total_estimated_savings = total_estimated_savings
            self.periphery_installed = periphery_installed; self.linkmap_available = linkmap_available
            self.by_kind = by_kind; self.by_module = by_module
        }
    }
}
public struct CodableModuleStat: Codable { public var count: Int; public var size: Int }

// MARK: Pod 资源归因（analyze_pod_resources.py）
public struct PodResourcePod: Codable {
    public var name: String; public var size: Int; public var file_count: Int; public var files: [PodResourceFile]; public var by_category: [String: Int]
}
public struct PodResourceFile: Codable { public var path: String; public var size: Int; public var category: String }
public struct PodResourceTarget: Codable { public var size: Int; public var pod_count: Int; public var pods: [String] }
public struct PodResourceResult: Codable {
    public var meta: Meta; public var total_size: Int; public var total_size_display: String; public var by_category: [String: Int]; public var by_target: [String: PodResourceTarget]; public var pods: [PodResourcePod]
    public struct Meta: Codable { public var project_dir: String; public var pods_root: String; public var built_products_dir: String; public var resources_sh_count: Int; public var pod_count: Int; public var resource_count: Int }
}
