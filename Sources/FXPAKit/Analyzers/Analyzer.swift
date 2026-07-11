import Foundation

/// 分析上下文 —— Orchestrator 传给各分析器的共享输入。
/// 各分析器按需取用（有的只要 .app，有的要工程目录/LinkMap）。
public struct AnalysisContext {
    public let appPath: String?          // .app 绝对路径
    public let projectDir: String?       // 工程根目录
    public let linkmapPath: String?      // 主 LinkMap
    public let podLinkmapsDir: String?   // Pod 独立 LinkMap 目录
    public let xcarchivePath: String?    // .xcarchive
    public let buildDir: String?         // 临时编译目录
    public let builtProductsDir: String? // 编译产物目录
    public let scheme: String?
    public let configuration: String
    public let outputDir: String         // 报告输出目录
    public let podMappingPath: String?   // pod_mapping.json
    public let appIcon: String?
    public let launchImage: String?
    public let config: PackageCheckConfig
    public let thinningExportPath: String?
    public let astDir: String?

    public init(appPath: String?, projectDir: String?, linkmapPath: String?, podLinkmapsDir: String?,
                xcarchivePath: String?, buildDir: String?, builtProductsDir: String?, scheme: String?,
                configuration: String, outputDir: String, podMappingPath: String?, appIcon: String?,
                launchImage: String?, config: PackageCheckConfig, thinningExportPath: String?,
                astDir: String? = nil) {
        self.appPath = appPath; self.projectDir = projectDir; self.linkmapPath = linkmapPath
        self.podLinkmapsDir = podLinkmapsDir; self.xcarchivePath = xcarchivePath; self.buildDir = buildDir
        self.builtProductsDir = builtProductsDir; self.scheme = scheme; self.configuration = configuration
        self.outputDir = outputDir; self.podMappingPath = podMappingPath; self.appIcon = appIcon
        self.launchImage = launchImage; self.config = config; self.thinningExportPath = thinningExportPath
        self.astDir = astDir
    }
}

/// 分析器协议 —— 高内聚低耦合的核心。每个分析器产出一个 Encodable 结果，写为同名 JSON。
public protocol Analyzer {
    /// 输出 JSON 文件名（如 "linkmap.json"）。
    var outputFileName: String { get }
    /// 展示名（日志用）。
    var displayName: String { get }
    /// 执行分析，返回可编码结果；返回 nil 表示应写入空结构降级 JSON。
    func run(context: AnalysisContext) throws -> Encodable
    /// 失败/跳过时写入的降级空 JSON（原始 JSON 字符串）。
    var fallbackJSON: String { get }
    /// 终端摘要（对齐原脚本 _print_summary）。空则不打印。
    var printSummary: ((Encodable) -> Void)? { get }
}

public extension Analyzer {
    var printSummary: ((Encodable) -> Void)? { return nil }
}
