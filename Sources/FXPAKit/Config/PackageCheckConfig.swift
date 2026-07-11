import Foundation

/// 资源类型定义：type → 扩展名列表。对齐 default_package_check.json 的 resource.resource_types。
public struct ResourceTypeDef {
    public let type: String
    public let suffixes: [String]
}

/// .package-check.json 配置读取。
///
/// 说明：原 package_analyzer.sh 用 CLI 开关控制模块启停（本工具由 CLI 复刻），
/// 而 .package-check.json 主要被 resource_scanner 用于 `resource.resource_types`。
/// 这里加载 resource_types（项目级覆盖 → 默认），供 AssetsAnalyzer 使用。
public struct PackageCheckConfig {
    public let resourceTypes: [ResourceTypeDef]

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

    // MARK: 加载

    /// 从原始 JSON 数据解析 resource.resource_types。
    private static func parseResourceTypes(_ data: Data) -> [ResourceTypeDef]? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let types = root["resource"]?["resource_types"]?.arrayValue else {
            return nil
        }
        var defs: [ResourceTypeDef] = []
        for item in types {
            guard let type = item["type"]?.stringValue,
                  let suffixes = item["resource_suffix"]?.arrayValue else { continue }
            defs.append(ResourceTypeDef(type: type, suffixes: suffixes.compactMap { $0.stringValue }))
        }
        return defs
    }

    /// 默认配置（来自嵌入的 default_package_check.json）。
    public static func loadDefault() -> PackageCheckConfig {
        if let data = try? Data(contentsOf: Resources.defaultPackageCheck),
           let defs = parseResourceTypes(data) {
            return PackageCheckConfig(resourceTypes: defs)
        }
        // 极端兜底：空
        return PackageCheckConfig(resourceTypes: [])
    }

    /// 加载：优先 `{projectDir}/.package-check.json` 的 resource_types，否则用默认。
    public static func load(projectDir: String?) -> PackageCheckConfig {
        let base = loadDefault()
        guard let projectDir else { return base }
        let path = (projectDir as NSString).appendingPathComponent(".package-check.json")
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let defs = parseResourceTypes(data), !defs.isEmpty else {
            return base
        }
        return PackageCheckConfig(resourceTypes: defs)
    }
}
