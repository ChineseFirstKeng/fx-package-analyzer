import Foundation

/// 访问嵌入的资源包（templates / config）。
/// Package.swift 用 `.copy("Resources/templates")` 拷贝，故目录名保持为 "templates"。
public enum Resources {
    /// 资源根目录 URL。
    public static var root: URL {
        Bundle.module.resourceURL ?? Bundle.module.bundleURL
    }

    public static var templatesDir: URL { root.appendingPathComponent("templates") }
    public static var configDir: URL { root.appendingPathComponent("config") }

    /// 读取 templates/ 下的文本文件（如 report.html、css/layout.css）。
    public static func templateString(_ relativePath: String) throws -> String {
        let url = templatesDir.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 读取 templates/explains/<stem>.json 原始数据（不存在返回 nil）。
    public static func explainData(_ stem: String) -> Data? {
        let url = templatesDir.appendingPathComponent("explains/\(stem).json")
        return try? Data(contentsOf: url)
    }

    /// 默认 .package-check.json 的 URL。
    public static var defaultPackageCheck: URL {
        configDir.appendingPathComponent("default_package_check.json")
    }
}
