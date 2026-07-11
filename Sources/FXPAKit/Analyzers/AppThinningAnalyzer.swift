import Foundation

/// App Thinning 分析 —— 1:1 复刻 analyze_thinning.py（解析 App Thinning Size Report.txt）。
public struct AppThinningAnalyzer: Analyzer {
    public var outputFileName: String { "app_thinning.json" }
    public var displayName: String { "app_thinning_analyzer" }
    public var fallbackJSON: String { #"{"variants":[]}"# }

    public init() {}

    public func run(context: AnalysisContext) throws -> Encodable {
        // 优先 .xcarchive，否则 .app
        let path = context.xcarchivePath ?? context.appPath ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw AnalyzerError.missingInput("app_thinning 需要 .xcarchive/.app 路径")
        }
        let absPath = URL(fileURLWithPath: path).standardized.path
        let isArchive = absPath.hasSuffix(".xcarchive")

        Logger.info("分析: \(absPath)")

        var variants: [JSONValue] = []
        var universalSize = 0
        var assetThinning: [JSONValue] = []

        if isArchive {
            if let report = findThinningReport(absPath) {
                Logger.info("找到 thinning 报告: \(report)")
                let (vs, uni) = parseThinningReport(report)
                variants = vs
                universalSize = uni ?? 0
                // 设备标签
                for i in variants.indices {
                    let ids = (variants[i]["device_ids"]?.arrayValue ?? []).compactMap { $0.stringValue }
                    if !ids.isEmpty {
                        variants[i] = variants[i].adding("device_label", .string(DeviceNames.variantLabel(ids)))
                    }
                }
            } else {
                Logger.warn("未找到 App Thinning Size Report.txt")
            }
            if let app = findAppInArchive(absPath) {
                Logger.info("分析 asset thinning: \(app)")
                assetThinning = analyzeAssetThinning(app)
            } else {
                Logger.warn("未在 archive 中找到 .app")
            }
        } else {
            assetThinning = analyzeAssetThinning(absPath)
        }

        // 兜底 universal = .app 实际大小
        var actualSize = 0
        if isArchive, let app = findAppInArchive(absPath), let en = FileManager.default.enumerator(atPath: app) {
            for case let rel as String in en {
                let fp = (app as NSString).appendingPathComponent(rel)
                if !ResourceScanner.isDir(fp) { actualSize += ResourceScanner.fileSize(fp) }
            }
        }
        if universalSize == 0 && actualSize > 0 { universalSize = actualSize }

        // summary（复刻 get_summary，`or` 语义：0 也回退到 app+odr）
        let sizes = variants.compactMap { v -> Int? in
            let t = v["total_size"]?.intValue ?? 0
            let s = t > 0 ? t : ((v["app_size"]?.intValue ?? 0) + (v["odr_size"]?.intValue ?? 0))
            return s > 0 ? s : nil
        }
        let avgVariant = sizes.isEmpty ? 0 : sizes.reduce(0, +) / sizes.count
        let minVariant = sizes.min() ?? 0
        let maxVariant = sizes.max() ?? 0
        func installOf(_ v: JSONValue) -> Int {
            let t = v["total_size_uncompressed"]?.intValue ?? 0
            return t > 0 ? t : ((v["app_size_uncompressed"]?.intValue ?? 0) + (v["odr_size_uncompressed"]?.intValue ?? 0))
        }
        let installSizes = variants.compactMap { v -> Int? in let s = installOf(v); return s > 0 ? s : nil }
        let avgInstall = installSizes.isEmpty ? 0 : installSizes.reduce(0, +) / installSizes.count
        let maxInstall = installSizes.max() ?? 0
        var savings = 0, savingsPct = 0.0, installSavings = 0
        if universalSize > 0 && maxVariant > 0 {
            savings = universalSize - maxVariant
            savingsPct = Double(savings) / Double(universalSize) * 100
            let universalInstall = variants.reduce(0) { $0 + installOf($1) }
            if universalInstall > 0 && maxInstall > 0 { installSavings = universalInstall - maxInstall }
        }

        Logger.info("\(variants.count) 个变体，universal ~\(ByteFormatter.fmt(universalSize))，Asset 条目 \(assetThinning.count)")
        return JSONValue.object([
            ("meta", .object([
                ("path", .string(absPath)),
                ("type", .string(isArchive ? "xcarchive" : "app")),
                ("generated_at", .string(DateUtil.now())),
            ])),
            ("summary", .object([
                ("variant_count", .int(variants.count)),
                ("universal_size", .int(universalSize)),
                ("avg_variant_size", .int(avgVariant)),
                ("max_variant_size", .int(maxVariant)),
                ("min_variant_size", .int(minVariant)),
                ("thinning_savings", .int(savings)),
                ("thinning_savings_pct", .double(savingsPct)),
                ("avg_install_size", .int(avgInstall)),
                ("max_install_size", .int(maxInstall)),
                ("install_savings", .int(installSavings)),
                ("asset_thinning_entries", .int(assetThinning.count)),
            ])),
            ("variants", .array(variants)),
            ("asset_thinning", .array(assetThinning)),
        ])
    }

    // MARK: 报告定位/解析

    private func findThinningReport(_ archive: String) -> String? {
        let direct = (archive as NSString).appendingPathComponent("App Thinning Size Report.txt")
        if FileManager.default.fileExists(atPath: direct) { return direct }
        if let en = FileManager.default.enumerator(atPath: archive) {
            for case let rel as String in en where (rel as NSString).lastPathComponent == "App Thinning Size Report.txt" {
                return (archive as NSString).appendingPathComponent(rel)
            }
        }
        return nil
    }

    private func findAppInArchive(_ archive: String) -> String? {
        let appsDir = (archive as NSString).appendingPathComponent("Products/Applications")
        if let app = (try? FileManager.default.contentsOfDirectory(atPath: appsDir))?.first(where: { $0.hasSuffix(".app") }) {
            return (appsDir as NSString).appendingPathComponent(app)
        }
        if let en = FileManager.default.enumerator(atPath: archive) {
            for case let rel as String in en where rel.hasSuffix(".app") {
                return (archive as NSString).appendingPathComponent(rel)
            }
        }
        return nil
    }

    /// 解析大小字符串 "123 MB" → 字节（复刻 parse_size_str）。
    static func parseSizeStr(_ s: String) -> Int {
        let up = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard let re = try? NSRegularExpression(pattern: #"([\d.]+)\s*(MB|KB|B|GB)?"#),
              let m = re.firstMatch(in: up, range: NSRange(up.startIndex..., in: up)), m.numberOfRanges > 1 else { return 0 }
        let ns = up as NSString
        let val = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let unit = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : "B"
        let mult: [String: Double] = ["B": 1, "KB": 1024, "MB": 1048576, "GB": 1073741824]
        return Int(val * (mult[unit] ?? 1))
    }

    /// 解析 "X MB compressed, Y MB uncompressed" → (comp, uncomp)（复刻 parse_compressed_uncompressed）。
    static func parseCompUncomp(_ s: String) -> (Int, Int) {
        let t = s.trimmingCharacters(in: .whitespaces)
        let pattern = #"(Zero\s*KB|[\d.]+\s*\w+)\s*compressed\s*,\s*(Zero\s*KB|[\d.]+\s*\w+)\s*uncompressed"#
        if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), m.numberOfRanges > 2 {
            let ns = t as NSString
            let g1 = ns.substring(with: m.range(at: 1)), g2 = ns.substring(with: m.range(at: 2))
            let comp = g1.lowercased().contains("zero") ? 0 : parseSizeStr(g1)
            let uncomp = g2.lowercased().contains("zero") ? 0 : parseSizeStr(g2)
            return (comp, uncomp)
        }
        return (parseSizeStr(t), 0)
    }

    /// 复刻 parse_thinning_report。
    private func parseThinningReport(_ reportPath: String) -> ([JSONValue], Int?) {
        guard let content = try? String(contentsOfFile: reportPath, encoding: .utf8) else { return ([], nil) }
        var variants: [JSONValue] = []
        var current: [(String, JSONValue)]? = nil
        var universalSize: Int? = nil

        func reMatch(_ line: String, _ pattern: String, _ opts: NSRegularExpression.Options = []) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts),
                  let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            let ns = line as NSString
            return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
        func setField(_ key: String, _ value: JSONValue) {
            guard var c = current else { return }
            c.removeAll { $0.0 == key }; c.append((key, value)); current = c
        }
        func getField(_ key: String) -> JSONValue? { current?.first(where: { $0.0 == key })?.1 }

        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let g = reMatch(line, #"^Variant:\s*(.+)"#) {
                if let c = current { variants.append(.object(c)) }
                current = [("name", .string(g[1].trimmingCharacters(in: .whitespaces))), ("app_size", .int(0)),
                           ("odr_size", .int(0)), ("total_size", .int(0)), ("assets_size", .int(0)),
                           ("code_size", .int(0)), ("device_ids", .array([]))]
                continue
            }
            if current == nil {
                if let g = reMatch(line, #"^(?:Uncompressed|Universal|App)\s+(?:size|Size)[:\s]+(.+)"#) {
                    universalSize = Self.parseSizeStr(g[1])
                }
                continue
            }
            if let g = reMatch(line, #"Supported variant descriptors:\s*(.+)"#) {
                let desc = g[1]
                if desc.contains("Universal") { setField("device_ids", .array([.string("Universal")])) }
                else if let re = try? NSRegularExpression(pattern: #"device:\s*([a-zA-Z]+\d+,\d+(?:-[A-Z])?)"#) {
                    let ns = desc as NSString
                    var ids: [String] = []
                    for m in re.matches(in: desc, range: NSRange(location: 0, length: ns.length)) {
                        let id = ns.substring(with: m.range(at: 1))
                        if !ids.contains(id) { ids.append(id) }
                    }
                    setField("device_ids", .array(ids.map { .string($0) }))
                }
                continue
            }
            if let g = reMatch(line, #"^(?:App \+ On Demand Resources|Total)\s+size[:\s]+(.+)"#) {
                let (comp, uncomp) = Self.parseCompUncomp(g[1])
                setField("total_size", .int(comp)); setField("total_size_uncompressed", .int(uncomp)); continue
            }
            if let g = reMatch(line, #"^App\s+size[:\s]+(.+)"#) {
                let (comp, uncomp) = Self.parseCompUncomp(g[1])
                setField("app_size", .int(comp)); setField("app_size_uncompressed", .int(uncomp)); continue
            }
            if let g = reMatch(line, #"^On\s+Demand\s+Resources\s+size[:\s]+(.+)"#) {
                let (comp, uncomp) = Self.parseCompUncomp(g[1])
                setField("odr_size", .int(comp)); setField("odr_size_uncompressed", .int(uncomp)); continue
            }
            if let g = reMatch(line, #"^Assets[:\s]+(.+)"#) {
                setField("assets_size", .int(Self.parseSizeStr(g[1]))); continue
            }
            _ = getField
        }
        if let c = current { variants.append(.object(c)) }

        if universalSize == nil && !variants.isEmpty {
            var uni = variants.map { ($0["app_size"]?.intValue ?? 0) + ($0["odr_size"]?.intValue ?? 0) }.max() ?? 0
            if variants.count > 1 { uni *= variants.count }
            universalSize = uni
        }
        return (variants, universalSize)
    }

    /// 用 assetutil 提取 .car 的 thinning 信息（复刻 analyze_asset_thinning）。
    private func analyzeAssetThinning(_ appPath: String) -> [JSONValue] {
        var results: [JSONValue] = []
        guard let en = FileManager.default.enumerator(atPath: appPath) else { return results }
        for case let rel as String in en where rel.hasSuffix(".car") {
            let carPath = (appPath as NSString).appendingPathComponent(rel)
            guard let r = try? Shell.run("/usr/bin/xcrun", ["assetutil", "--info", carPath], timeout: 30), r.ok,
                  let data = r.stdout.data(using: .utf8), let parsed = JSONValue.parse(data),
                  let arr = parsed.arrayValue else { continue }
            for asset in arr {
                var scales: [String] = []
                var idioms: [String] = []
                if let sc = asset["Scale"] { scales.append(sc.intValue.map(String.init) ?? (sc.stringValue ?? "")) }
                if let id = asset["Idiom"]?.stringValue { idioms.append(id) }
                if !scales.isEmpty || !idioms.isEmpty {
                    results.append(.object([
                        ("car", .string((carPath as NSString).lastPathComponent)),
                        ("name", .string(asset["Name"]?.stringValue ?? "?")),
                        ("type", .string(asset["AssetType"]?.stringValue ?? "?")),
                        ("scales", .array(scales.map { .string($0) })),
                        ("idioms", .array(idioms.map { .string($0) })),
                    ]))
                }
            }
        }
        return results
    }
}
