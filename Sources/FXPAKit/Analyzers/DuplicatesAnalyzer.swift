import Foundation

/// 重复资源检测 —— 1:1 复刻 analyze_duplicates.py（SHA256 分组）。
public struct DuplicatesAnalyzer: Analyzer {
    public var outputFileName: String { "duplicate_resource.json" }
    public var displayName: String { "duplicate_resource_detector" }
    public var fallbackJSON: String { #"{"duplicates":[]}"# }

    public var printSummary: ((Encodable) -> Void)? {
        { (r_: Encodable) in
            guard let r = r_ as? DuplicateResult else { return }
            let s = r.summary
            Logger.plain("")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  重复资源检测")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  扫描文件: \(s.total_files_scanned) (\(ByteFormatter.fmt(s.total_scanned_size)))")
            Logger.plain("  重复组:   \(s.duplicate_groups)")
            Logger.plain("  重复文件: \(s.duplicate_file_count)")
            Logger.plain("  浪费:     \(ByteFormatter.fmt(s.total_waste))")
            if !r.duplicates.isEmpty {
                Logger.plain("")
                Logger.plain("  SHA256               实例       单个大小         浪费")
                Logger.plain("  ------------------ ---- ---------- ----------")
                for dup in r.duplicates.prefix(15) {
                    let sha = String(dup.sha256.prefix(16))
                    Logger.plain("  " + String(sha.prefix(18)).padding(toLength: 18, withPad: " ", startingAt: 0) + " " + String(format: "%4d", dup.count) + " " + ByteFormatter.fmt(dup.size_per_instance).padding(toLength: 10, withPad: " ", startingAt: 0) + " " + ByteFormatter.fmt(dup.total_waste).padding(toLength: 10, withPad: " ", startingAt: 0))
                }
            }
            Logger.plain(String(repeating: "=", count: 60))
        }
    }

    public init() {}

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let projectDir = context.projectDir, ResourceScanner.isDir(projectDir) else {
            throw AnalyzerError.missingInput("duplicates 需要工程目录")
        }
        let scanner = ResourceScanner(config: context.config)
        Logger.info("扫描源码工程: \(projectDir)")
        let scan = scanner.scanProjectResources(projectDir)
        let allFiles = scan.allFiles

        // 按 sha256 分组（保留首次出现顺序）
        var order: [String] = []
        var groups: [String: [AssetFile]] = [:]
        for f in allFiles {
            let sha = f.sha256
            if sha.isEmpty { continue }
            if groups[sha] == nil { order.append(sha) }
            groups[sha, default: []].append(f)
        }

        var duplicates: [DuplicateGroup] = []
        for sha in order {
            let entries = groups[sha]!
            if entries.count > 1 {
                let size = entries[0].size
                duplicates.append(DuplicateGroup(
                    sha256: sha,
                    size_per_instance: size,
                    count: entries.count,
                    total_waste: size * (entries.count - 1),
                    files: entries.sorted { $0.path < $1.path }
                ))
            }
        }
        duplicates.sort { $0.total_waste > $1.total_waste }

        let waste = duplicates.reduce(0) { $0 + $1.total_waste }
        let scannedSize = allFiles.reduce(0) { $0 + $1.size }
        Logger.info("扫描 \(allFiles.count) 个文件，共 \(ByteFormatter.fmt(scannedSize))")
        Logger.info("发现 \(duplicates.count) 组重复资源，浪费 \(ByteFormatter.fmt(waste))")

        return DuplicateResult(
            meta: .init(scan_path: URL(fileURLWithPath: projectDir).standardized.path, generated_at: DateUtil.now()),
            summary: .init(
                total_files_scanned: allFiles.count,
                total_scanned_size: scannedSize,
                duplicate_groups: duplicates.count,
                duplicate_file_count: duplicates.reduce(0) { $0 + ($1.count - 1) },
                total_waste: waste
            ),
            duplicates: duplicates,
            all_files: allFiles
        )
    }
}
