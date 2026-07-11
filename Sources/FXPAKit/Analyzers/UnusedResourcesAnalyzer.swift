import Foundation

/// 无用资源检测 —— 1:1 复刻 analyze_unused_resources.py（正则+字符串双匹配）。
public struct UnusedResourcesAnalyzer: Analyzer {
    public var outputFileName: String { "unused_resource.json" }
    public var displayName: String { "unused_resource_detector" }
    public var printSummary: ((Encodable) -> Void)? {
        { (r_: Encodable) in
            guard let r = r_ as? UnusedResult else { return }
            let s = r.summary
            Logger.plain("")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  无用资源检测")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  资源总数:   \(s.total_resources) (\(ByteFormatter.fmt(s.total_size)))")
            Logger.plain("  未引用:     \(s.unused_count) (\(ByteFormatter.fmt(s.unused_size)))")
            Logger.plain("  高置信度:   \(s.high_confidence)")
            Logger.plain("  中置信度:   \(s.medium_confidence)")
            Logger.plain("  低置信度:   \(s.low_confidence)")
            Logger.plain("")
            let byOwner = s.by_owner.sorted { $0.value.unused_size > $1.value.unused_size }
            if !byOwner.isEmpty {
                Logger.plain("  归属库                               资源数     未用         浪费")
                Logger.plain("  ------------------------------ ------ ------ ----------")
                for (o, st) in byOwner where st.unused > 0 {
                    Logger.plain("  " + String(o.prefix(28)).padding(toLength: 30, withPad: " ", startingAt: 0) + " " + String(format: "%6d", st.total) + " " + String(format: "%6d", st.unused) + " " + ByteFormatter.fmt(st.unused_size).padding(toLength: 10, withPad: " ", startingAt: 0))
                }
                Logger.plain("")
            }
            if !r.unused.isEmpty {
                Logger.plain("  资源名                                             大小    置信度")
                Logger.plain("  ---------------------------------------- ---------- ------")
                for u in r.unused.prefix(20) {
                    Logger.plain("  " + String(u.name.prefix(38)).padding(toLength: 40, withPad: " ", startingAt: 0) + " " + ByteFormatter.fmt(u.size).padding(toLength: 10, withPad: " ", startingAt: 0) + " " + (u.confidence == "high" ? "    高" : (u.confidence == "medium" ? "    中" : "    低")).suffix(6))
                }
                if r.unused.count > 20 { Logger.plain("  ... 还有 \(r.unused.count - 20) 个") }
            }
            Logger.plain(String(repeating: "=", count: 60))
        }
    }
    public var fallbackJSON: String { #"{"unused_resources":[]}"# }

    public init() {}

    /// 正则模式（对齐 REFERENCE_PATTERNS，均大小写不敏感，捕获组 1 为资源名）。
    static let patternStrings: [String] = [
        #"Image\s*\(\s*"([^"]+)""#,
        #"Image\s*\(\s*"([^"]+)"\s*,\s*bundle\s*:"#,
        #"Image\s*\(\s*decorative\s*:\s*"([^"]+)""#,
        #"Color\s*\(\s*"([^"]+)""#,
        #"Color\s*\(.*name\s*:\s*"([^"]+)""#,
        #"UIColor\s*\(\s*named\s*:\s*"([^"]+)""#,
        #"UIImage\s*\(\s*named\s*:\s*"([^"]+)""#,
        #"UIImage\s*\(\s*named\s*:\s*'([^']+)'"#,
        #"\[UIImage\s+imageNamed\s*:\s*@"([^"]+)""#,
        #"imageNamed\s*:\s*@"([^"]+)""#,
        #"#imageLiteral\s*\(\s*resourceName\s*:\s*"([^"]+)""#,
        #"NSImage\s*\(\s*named\s*:\s*"([^"]+)""#,
        #"UIFont\s*\(\s*name\s*:\s*"([^"]+)""#,
        #"Font\.custom\s*\(\s*"([^"]+)""#,
        #"NSLocalizedString\s*\(\s*"([^"]+)""#,
        #"NSLocalizedString\s*\(\s*@"([^"]+)""#,
        #"Text\s*\(\s*"([A-Z][a-zA-Z_]*(?:\.[a-zA-Z_]+)*)"\s*(?:,\s*tableName\s*:.+?)?\s*\)"#,
        #"bundle.*URL\s*\(\s*forResource\s*:\s*"([^"]+)""#,
        #"bundle.*path\s*\(\s*forResource\s*:\s*"([^"]+)""#,
        #"NSBundle.*pathForResource\s*:\s*@"([^"]+)""#,
        #"NSDataAsset\s*\(\s*name\s*:\s*"([^"]+)""#,
        #"image\s*=\s*"([^"]+)""#,
        #"@"([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)""#,
        #""([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)""#,
    ]
    static let patterns: [NSRegularExpression] = patternStrings.compactMap {
        try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
    }

    static let sourceExts = Set([".m", ".mm", ".swift", ".h", ".c", ".cpp", ".storyboard", ".xib", ".json", ".plist", ".pch", ".metal"])

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let projectDir = context.projectDir, ResourceScanner.isDir(projectDir) else {
            throw AnalyzerError.missingInput("unused_resources 需要工程目录")
        }
        let sourceDir = projectDir
        let scanner = ResourceScanner(config: context.config)
        let scan = scanner.scanProjectResources(projectDir)
        Logger.info("扫描资源: \(projectDir)")
        Logger.info("找到 \(scan.allFiles.count) 个资源文件, 共计 \(ByteFormatter.fmt(scan.totalSize))")

        // resource_scanner 条目 → 检测格式
        struct ResEntry { var fullName, baseName, bareName, path, ext, owner: String; var size: Int }
        let resources: [ResEntry] = scan.allFiles.map { f in
            ResEntry(fullName: (f.path as NSString).lastPathComponent, baseName: f.base_name,
                     bareName: f.base_name, path: f.path, ext: f.ext, owner: f.source, size: f.size)
        }

        var resourceNames = Set<String>()
        for r in resources { resourceNames.insert(r.baseName); resourceNames.insert(r.bareName) }
        resourceNames = resourceNames.filter { $0.count >= 2 }

        Logger.info("[方式1] 正则匹配扫描源码引用: \(sourceDir)")
        let regexRefs = scanSourceRefs(sourceDir, scanner: scanner)
        Logger.info("[方式2] 字符串匹配扫描源码引用: \(sourceDir)")
        let strRefs = scanSourceRefsByString(sourceDir, resourceNames)

        var referenced = regexRefs.refs
        referenced.formUnion(strRefs)
        let regexOnly = regexRefs.refs.subtracting(strRefs).count
        let strOnly = strRefs.subtracting(regexRefs.refs).count
        let both = regexRefs.refs.intersection(strRefs).count
        Logger.info("匹配结果汇总：正则独有=\(regexOnly)，字符串独有=\(strOnly)，两者共有=\(both)")
        var refModules: [String: Set<String>] = [:]
        for name in referenced {
            refModules[name] = regexRefs.modules[name] ?? []
        }
        if let icon = context.appIcon, !icon.isEmpty { referenced.insert(icon) }
        if let lm = context.launchImage, !lm.isEmpty { referenced.insert(lm) }

        // 构建未使用列表（对齐 build_unused_list）
        var unused: [UnusedItem] = []
        for r in resources {
            let hasRef = referenced.contains(r.fullName) || referenced.contains(r.baseName) || referenced.contains(r.bareName)
            if hasRef { continue }
            var confidence = "high"; var reason = ""
            if r.baseName.contains("_") && r.baseName.rangeOfCharacter(from: .decimalDigits) != nil {
                confidence = "medium"; reason = "名称含数字编号，可能为运行时动态拼接"
            }
            if r.path.contains(".bundle/") || r.path.contains("Frameworks/") {
                confidence = "medium"; reason = "位于 framework/bundle 内，可能通过 dynamic lookup 加载"
            }
            if r.ext == ".strings" { confidence = "medium"; reason = "strings 文件可能通过 NSLocalizedString 间接引用" }
            if [".ttf", ".otf", ".woff", ".woff2"].contains(r.ext) {
                confidence = "low"; reason = "字体文件通过 PostScript 名称引用，非文件名"
            }
            let mods = refModules[r.fullName] ?? refModules[r.baseName] ?? refModules[r.bareName] ?? []
            unused.append(UnusedItem(name: r.fullName, base_name: r.baseName, path: r.path, size: r.size,
                                     ext: r.ext, owner: r.owner, confidence: confidence, reason: reason,
                                     referenced_from: Array(mods).sorted()))
        }
        unused.sort { $0.size > $1.size }

        let hi = unused.filter { $0.confidence == "high" }.count
        let mid = unused.filter { $0.confidence == "medium" }.count
        let lo = unused.filter { $0.confidence == "low" }.count
        Logger.info("资源 \(resources.count) 个；源码引用名 \(referenced.count) 个")
        Logger.info("未引用资源 \(unused.count) 个（高 \(hi) / 中 \(mid) / 低 \(lo)）")
        Logger.info("置信度 → 高:\(hi)  中:\(mid)  低:\(lo)")

        let totalSize = resources.reduce(0) { $0 + $1.size }
        var byOwner: [String: OwnerStat] = [:]
        for r in resources { byOwner[r.owner, default: OwnerStat(total: 0, unused: 0, unused_size: 0)].total += 1 }
        for u in unused {
            var s = byOwner[u.owner] ?? OwnerStat(total: 0, unused: 0, unused_size: 0)
            s.unused += 1; s.unused_size += u.size
            byOwner[u.owner] = s
        }

        return UnusedResult(
            meta: .init(project_dir: URL(fileURLWithPath: projectDir).standardized.path,
                        source_dir: URL(fileURLWithPath: sourceDir).standardized.path, generated_at: DateUtil.now()),
            summary: .init(total_resources: resources.count, total_size: totalSize,
                           unused_count: unused.count, unused_size: unused.reduce(0) { $0 + $1.size },
                           high_confidence: unused.filter { $0.confidence == "high" }.count,
                           medium_confidence: unused.filter { $0.confidence == "medium" }.count,
                           low_confidence: unused.filter { $0.confidence == "low" }.count,
                           by_owner: byOwner),
            resources: resources.map { UnusedResourceEntry(name: $0.fullName, base_name: $0.baseName,
                                                           path: $0.path, size: $0.size, ext: $0.ext, owner: $0.owner) },
            unused: unused
        )
    }

    // MARK: 引用扫描

    struct RefResult { var refs = Set<String>(); var modules: [String: Set<String>] = [:] }

    private func scanSourceRefs(_ sourceDir: String, scanner: ResourceScanner) -> RefResult {
        var result = RefResult()
        let files = allSourceFiles(sourceDir)
        Logger.info("主工程/Pods 源码: \(files.count) 个文件")
        Logger.info("共扫描 \(files.count) 个源码文件...")
        for sf in files {
            guard let content = try? String(contentsOfFile: sf, encoding: .utf8) else { continue }
            let module = scanner.guessSourceModule(sf, sourceDir)
            let ns = content as NSString
            let full = NSRange(location: 0, length: ns.length)
            for re in Self.patterns {
                for m in re.matches(in: content, range: full) where m.numberOfRanges > 1 {
                    let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    if name.count >= 2 {
                        result.refs.insert(name)
                        result.modules[name, default: []].insert(module)
                    }
                }
            }
        }
        Logger.info("在源码中发现 \(result.refs.count) 个引用名")
        return result
    }

    private func scanSourceRefsByString(_ sourceDir: String, _ resourceNames: Set<String>) -> Set<String> {
        let files = allSourceFiles(sourceDir)
        Logger.info("字符串匹配：扫描 \(files.count) 个源码文件，搜索 \(resourceNames.count) 个资源名...")
        var blob = Data()
        for sf in files {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: sf)) {
                blob.append(d)
                blob.append(0x0A)  // 分隔，避免跨文件误拼
            }
        }
        var referenced = Set<String>()
        for name in resourceNames where name.count >= 2 {
            if blob.range(of: Data(name.utf8)) != nil { referenced.insert(name) }
        }
        Logger.info("字符串匹配：发现 \(referenced.count) 个资源被引用")
        return referenced
    }

    /// 源码文件 = 工程目录 + Podfile :path 本地开发 Pod 目录（对齐 scan_source_references 的合并）。
    private func allSourceFiles(_ sourceDir: String) -> [String] {
        var files = collectSourceFiles(sourceDir)
        let podDirs = findDevPodDirs(sourceDir)
        for podDir in podDirs {
            let podFiles = collectSourceFiles(podDir)
            let podName = (podDir as NSString).lastPathComponent
            Logger.info("本地 Pod \(podName): \(podFiles.count) 个文件")
            files.append(contentsOf: podFiles)
        }
        return files
    }

    /// 复刻 analyze_unused_resources.find_dev_pod_dirs：返回 :path Pod 的 podspec 父目录。
    private func findDevPodDirs(_ sourceDir: String) -> [String] {
        let podfile = (sourceDir as NSString).appendingPathComponent("Podfile")
        guard let content = try? String(contentsOfFile: podfile, encoding: .utf8) else { return [] }
        let pattern = #"pod\s+['"]([^'"]+)['"]\s*,\s*(?::path|:podspec|path|podspec)\s*=>\s*['"]([^'"]+)['"]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var dirs: [String] = []
        let ns = content as NSString
        re.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let rel = ns.substring(with: m.range(at: 2))
            let podspecAbs = URL(fileURLWithPath: (sourceDir as NSString).appendingPathComponent(rel)).standardized.path
            let podDir = (podspecAbs as NSString).deletingLastPathComponent
            let podName = ns.substring(with: m.range(at: 1))
            if ResourceScanner.isDir(podDir) { Logger.info("发现本地 Pod: \(podName) → \(podDir)"); dirs.append(podDir) }
        }
        return dirs
    }

    private func collectSourceFiles(_ dir: String) -> [String] {
        var result: [String] = []
        let skip = Set(["DerivedData", "build", "Carthage", ".git"])
        guard let enumerator = FileManager.default.enumerator(atPath: dir) else { return result }
        for case let rel as String in enumerator {
            let ext = "." + (rel as NSString).pathExtension.lowercased()
            if !Self.sourceExts.contains(ext) { continue }
            let comps = rel.components(separatedBy: "/")
            if comps.contains(where: { skip.contains($0) || $0.hasPrefix(".") }) { continue }
            result.append((dir as NSString).appendingPathComponent(rel))
        }
        return result
    }
}
