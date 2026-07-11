import Foundation

/// LinkMap 代码归因分析器 —— 复刻 analyze_linkmap.py 的 main 组装逻辑。
public struct LinkMapAnalyzer: Analyzer {
    public var outputFileName: String { "linkmap.json" }
    public var displayName: String { "linkmap_parser" }
    public var fallbackJSON: String { #"{"modules":[]}"# }

    public init() {}

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let linkmapPath = context.linkmapPath, FileManager.default.fileExists(atPath: linkmapPath) else {
            throw AnalyzerError.missingInput("无 LinkMap")
        }
        let parser = LinkMapParser(path: linkmapPath)
        try parser.parse()

        var result = LinkMapResult(
            meta: .init(linkmap_path: parser.path,
                        object_file_count: parser.objectFileCount,
                        symbol_count: parser.symbols.count),
            total_size: parser.totalSize,
            total_size_display: fmtSize(parser.totalSize),
            modules: parser.getModules(),
            sections: parser.sectionsDict(),
            file_tree: parser.getFileTree(),
            top_o_files: parser.getFiles(),
            module_sections: parser.getModuleSections()
        )

        // ── Pod 动态库 LinkMap 合并 ──
        if let dir = context.podLinkmapsDir, ResourceScanner.isDir(dir) {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            for fname in files where fname.hasSuffix(".txt") {
                let fpath = dir + "/" + fname
                // 回退名 = 原始文件名（对齐 Python：fw_name = fname）
                var fwName = fname
                // 优先从首行 `# Path:` 提取（只读前 8KB 宽松解码，对齐 Python 的 readline()+errors='replace'）
                if let fh = FileHandle(forReadingAtPath: fpath) {
                    let head = (try? fh.read(upToCount: 8192)) ?? nil
                    try? fh.close()
                    if let head, let firstLine = String(decoding: head, as: UTF8.self)
                        .components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces),
                       firstLine.hasPrefix("# Path:") {
                        let binaryPath = String(firstLine.dropFirst("# Path:".count)).trimmingCharacters(in: .whitespaces)
                        fwName = ((binaryPath as NSString).lastPathComponent as NSString).deletingPathExtension
                    }
                }
                Logger.info("解析 Pod linkmap: \(fname) → \(fwName)")
                do {
                    let podParser = LinkMapParser(path: fpath)
                    try podParser.parse()
                    let podModules = podParser.getModules()
                    var allFiles: [LinkMapModuleFile] = []
                    var total = 0
                    for m in podModules where m.name != "linker synthesized" {
                        allFiles.append(contentsOf: m.files)
                        total += m.size
                    }
                    if !allFiles.isEmpty {
                        result.modules.append(LinkMapModule(
                            name: fwName, size: total, file_count: allFiles.count,
                            files: allFiles, lib_type: "dynamic", _pod_linkmap: true))
                    }
                } catch {
                    Logger.warn("Pod linkmap 解析失败: \(fname): \(error)")
                }
            }
        }

        // ── pod_mapping 注解 ──
        if let pmPath = context.podMappingPath, FileManager.default.fileExists(atPath: pmPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: pmPath)),
           let pm = JSONValue.parse(data) {
            for i in result.modules.indices {
                let name = result.modules[i].name
                if let entry = pm[name] {
                    result.modules[i].pod = entry["pod"]?.stringValue ?? ""
                    result.modules[i].manager = entry["manager"]?.stringValue ?? ""
                    result.modules[i].mach_o_type = entry["mach_o_type"]?.stringValue ?? ""
                } else {
                    result.modules[i].pod = ""
                    result.modules[i].manager = ""
                    result.modules[i].mach_o_type = ""
                }
            }
        }

        return result
    }

    private func fmtSize(_ b: Int) -> String {
        if b >= 1_048_576 { return String(format: "%.2f MB", Double(b) / 1_048_576.0) }
        if b >= 1024 { return String(format: "%.2f KB", Double(b) / 1024.0) }
        return "\(b) B"
    }
}
