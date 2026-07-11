import Foundation

/// iOS 资源分析器 —— 复刻 analyze_assets.py（扫描源码工程中所有资源的体积分布）。
public struct AssetsAnalyzer: Analyzer {
    public var outputFileName: String { "asset.json" }
    public var displayName: String { "asset_analyzer" }
    public var fallbackJSON: String { #"{"by_category":{},"by_type":{},"all_files":[],"all_images":[],"total_size":0,"by_source":[]}"# }

    public init() {}

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let projectDir = context.projectDir, ResourceScanner.isDir(projectDir) else {
            throw AnalyzerError.missingInput("asset 需要工程目录")
        }
        let scanner = ResourceScanner(config: context.config)
        let scan = scanner.scanProjectResources(projectDir)
        Logger.info("扫描源码工程: \(projectDir)")
        Logger.info("资源文件 \(scan.allFiles.count) 个，共 \(ByteFormatter.fmt(scan.totalSize))")

        // 按 source 聚合（主工程 vs 各 Pod），供统一概览使用
        var bySourceOrder: [String] = []
        var bySourceAgg: [String: (code: Int, resource: Int)] = [:]
        for f in scan.allFiles {
            let src = f.source
            if bySourceAgg[src] == nil { bySourceOrder.append(src); bySourceAgg[src] = (0, 0) }
            // 资源类文件全部计入 resource
            bySourceAgg[src]!.resource += f.size
        }
        let bySource: [AssetBySource] = bySourceOrder.map { name in
            let agg = bySourceAgg[name]!
            return AssetBySource(name: name, code: agg.code, resource: agg.resource, total: agg.code + agg.resource)
        }

        return AssetResult(
            total_size: scan.totalSize,
            by_category: Dictionary(uniqueKeysWithValues: scan.byCategory),
            by_type: Dictionary(uniqueKeysWithValues: scan.byType),
            all_files: scan.allFiles,
            all_images: scan.allImages,
            meta: .init(scan_path: URL(fileURLWithPath: projectDir).standardized.path,
                        file_count: scan.allFiles.count),
            total_size_display: ByteFormatter.fmt(scan.totalSize),
            by_source: bySource
        )
    }
}
