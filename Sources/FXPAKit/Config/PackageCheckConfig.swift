import Foundation

/// 资源类型定义：type → 后缀列表。对齐 default_package_check.json 根级 resource_types。
public struct ResourceTypeDef {
    public let type: String
    public let suffixes: [String]
}

/// .package-check.json 配置读取。
///
/// 说明：.package-check.json 中唯一被代码读取的字段是根级 `resource_types`。
/// 其余字段（如旧版 code/linkmap/enabled 等）均为历史遗留，本工具通过 CLI 开关控制模块启停，
/// 不再从该文件中读取。
/// 这里加载 resource_types（项目级覆盖 → 默认），供 AssetsAnalyzer / PodResourcesAnalyzer 使用。
public struct PackageCheckConfig {
    public let version: Int?
    public let resourceTypes: [ResourceTypeDef]
    public let resourceSkipDirs: Set<String>
    public let unusedCodeSkipDirs: Set<String>

    /// 扩展名（小写）→ 类别 映射
    public var extToCategory: [String: String] {
        var m: [String: String] = [:]
        for def in resourceTypes {
            for suffix in def.suffixes {
                m[suffix.lowercased()] = def.type
            }
        }
        return m
    }

    /// 允许的扩展名集合
    public var allowedExtensions: Set<String> {
        Set(extToCategory.keys)
    }

    /// 目录型 bundle 后缀集合（如 .xcassets / .mlpackage / .scnassets）。
    /// 这些目录作为不透明资源整体处理，不穿透扫描内部文件。
    public var packageSuffixes: Set<String> {
        Set(resourceTypes
            .filter { $0.type == "package_assets" }
            .flatMap { $0.suffixes }
            .map { $0.lowercased() })
    }

    // MARK: 加载

    /// 从原始 JSON 数据解析根级 resource_types。
    private static func parseResourceTypes(_ data: Data) -> [ResourceTypeDef]? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        // 支持新旧两种格式：新格式 root["resource_types"]，旧格式 root["resource"]["resource_types"]
        var types = root["resource_types"]?.arrayValue
        if types == nil {
            types = root["resource"]?["resource_types"]?.arrayValue
        }
        guard let types else { return nil }
        var defs: [ResourceTypeDef] = []
        for item in types {
            guard let type = item["type"]?.stringValue else { continue }
            // 新格式 key 为 suffixes，旧格式 key 为 resource_suffix
            let suffixes = item["suffixes"]?.arrayValue ?? item["resource_suffix"]?.arrayValue
            guard let suffixes else { continue }
            defs.append(ResourceTypeDef(type: type, suffixes: suffixes.compactMap { $0.stringValue }))
        }
        return defs
    }

    /// 从原始 JSON 数据解析 skip_directories。
    /// 支持：root["resource_scanner"]["skip_directories"] 和 root["unused_code"]["skip_directories"]。
    private static func parseSkipDirs(_ root: JSONValue, _ section: String) -> Set<String>? {
        guard let arr = root[section]?["skip_directories"]?.arrayValue else { return nil }
        let dirs = arr.compactMap { $0.stringValue }
        return dirs.isEmpty ? nil : Set(dirs)
    }

    /// 默认配置（来自嵌入的 default_package_check.json）。
    public static func loadDefault() -> PackageCheckConfig {
        if let data = try? Data(contentsOf: Resources.defaultPackageCheck),
           let defs = parseResourceTypes(data) {
            let root = (try? JSONDecoder().decode(JSONValue.self, from: data))
            let version = root?["version"]?.intValue
            let rDirs = root.flatMap { parseSkipDirs($0, "resource_scanner") } ?? []
            let uDirs = root.flatMap { parseSkipDirs($0, "unused_code") } ?? []
            return PackageCheckConfig(version: version, resourceTypes: defs,
                                      resourceSkipDirs: rDirs, unusedCodeSkipDirs: uDirs)
        }
        // 极端兜底：空
        return PackageCheckConfig(version: nil, resourceTypes: [],
                                  resourceSkipDirs: [], unusedCodeSkipDirs: [])
    }

    /// 加载：优先 `{projectDir}/.package-check.json` 的各字段，否则用默认。
    public static func load(projectDir: String?) -> PackageCheckConfig {
        let base = loadDefault()
        guard let projectDir else { return base }
        let path = (projectDir as NSString).appendingPathComponent(".package-check.json")
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return base
        }
        let root = (try? JSONDecoder().decode(JSONValue.self, from: data))
        let version = root?["version"]?.intValue

        // resource_types：项目覆盖优先
        let defs: [ResourceTypeDef]
        if let parsed = parseResourceTypes(data), !parsed.isEmpty {
            defs = parsed
        } else {
            defs = base.resourceTypes
        }

        // resource_scanner.skip_directories：项目覆盖优先，否则用默认
        let rDirs: Set<String>
        if let dirs = root.flatMap({ parseSkipDirs($0, "resource_scanner") }) {
            rDirs = dirs
        } else {
            rDirs = base.resourceSkipDirs
        }

        // unused_code.skip_directories：项目覆盖优先，否则用默认
        let uDirs: Set<String>
        if let dirs = root.flatMap({ parseSkipDirs($0, "unused_code") }) {
            uDirs = dirs
        } else {
            uDirs = base.unusedCodeSkipDirs
        }

        return PackageCheckConfig(version: version, resourceTypes: defs,
                                  resourceSkipDirs: rDirs, unusedCodeSkipDirs: uDirs)
    }
}
