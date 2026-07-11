import Foundation

/// Assets.car 深度拆解 —— 1:1 复刻 analyze_assets_car.py（xcrun assetutil --info）。
public struct AssetsCarAnalyzer: Analyzer {
    public var outputFileName: String { "assets_car.json" }
    public var displayName: String { "assets_car_analyzer" }
    public var fallbackJSON: String { #"{"type_summary":{}}"# }
    public var topAssets: Int

    public var printSummary: ((Encodable) -> Void)? {
        { (r_: Encodable) in
            guard let r = r_ as? JSONValue else { return }
            Logger.plain("")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  Assets.car 深度分析")
            Logger.plain(String(repeating: "=", count: 60))
            let meta = r["meta"] ?? .object([])
            Logger.plain("  .car 文件数: \(meta["car_files_found"]?.intValue ?? 0)")
            Logger.plain("  资源总数:   \(meta["total_asset_count"]?.intValue ?? 0)")
            Logger.plain("  总大小:     \(meta["total_size_display"]?.stringValue ?? "0 B")")
            Logger.plain("")
            if let ts = r["type_summary"]?.objectPairs, !ts.isEmpty {
                let hdrType = "类型".padding(toLength: 20, withPad: " ", startingAt: 0)
                Logger.plain("  \(hdrType)      数量          大小")
                Logger.plain("  " + String(repeating: "-", count: 20) + " " + String(repeating: "-", count: 6) + " " + String(repeating: "-", count: 12))
                for (t, d) in ts.prefix(10) {
                    let cnt = d["count"]?.intValue ?? 0
                    let sz = d["size"]?.intValue ?? 0
                    let col1 = String(t.prefix(20)).padding(toLength: 20, withPad: " ", startingAt: 0)
                    let col2 = String(format: "%6d", cnt)
                    let col3 = ByteFormatter.fmt(sz).padding(toLength: 12, withPad: " ", startingAt: 0)
                    Logger.plain("  \(col1) \(col2) \(col3)")
                }
                Logger.plain("")
            }
            if let dups = r["duplicates"]?.arrayValue, !dups.isEmpty {
                let waste = dups.reduce(0) { $0 + ($1["total_waste"]?.intValue ?? 0) }
                Logger.plain("  重复资源: \(dups.count) 组, 浪费 \(ByteFormatter.fmt(waste))")
            }
            Logger.plain(String(repeating: "=", count: 60))
        }
    }

    public init(topAssets: Int = 100) { self.topAssets = topAssets }

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let appPath = context.appPath else {
            throw AnalyzerError.missingInput("assets_car 需要 .app 路径")
        }
        let absInput = URL(fileURLWithPath: appPath).standardized.path

        // 找 .car 文件
        var carFiles: [String] = []
        if !ResourceScanner.isDir(absInput) && absInput.hasSuffix(".car") {
            carFiles = [absInput]
        } else if ResourceScanner.isDir(absInput) {
            if let en = FileManager.default.enumerator(atPath: absInput) {
                for case let rel as String in en where rel.hasSuffix(".car") {
                    carFiles.append((absInput as NSString).appendingPathComponent(rel))
                }
            }
            carFiles.sort()
        }

        var errors: [String] = []
        var allAssets: [JSONValue] = []
        var metadata: JSONValue = .object([])

        // assetutil 路径
        let assetutil = (try? Shell.run("/usr/bin/xcrun", ["--find", "assetutil"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if carFiles.isEmpty {
            Logger.warn("未找到 Assets.car 文件")
        } else if assetutil.isEmpty {
            Logger.error("assetutil 未找到")
        } else {
            for carPath in carFiles {
                var relPath = carPath
                if carPath.hasPrefix(absInput) { relPath = String(carPath.dropFirst(absInput.count)).drop(while: { $0 == "/" }).description }
                Logger.info("解析: \(relPath)")
                guard let r = try? Shell.run(assetutil, ["--info", carPath], timeout: 60), r.ok else {
                    Logger.warn("assetutil 失败: \(relPath)")
                    errors.append("\(relPath): assetutil 失败"); continue
                }
                guard let data = r.stdout.data(using: .utf8), let parsed = JSONValue.parse(data),
                      let arr = parsed.arrayValue, !arr.isEmpty else {
                    Logger.warn("JSON 解析失败 (\(relPath))")
                    errors.append("\(relPath): JSON 解析失败或为空"); continue
                }
                // 首元素为 metadata（含 AssetStorageVersion）
                let firstIsMeta = arr[0]["AssetStorageVersion"] != nil
                if case .object = metadata, metadata.objectPairs?.isEmpty ?? true, firstIsMeta {
                    // 去掉 Key Format
                    let pairs = (arr[0].objectPairs ?? []).filter { $0.0 != "Key Format" }
                    metadata = .object(pairs)
                }
                let items = firstIsMeta ? Array(arr.dropFirst()) : arr
                let carName = (carPath as NSString).lastPathComponent
                for item in items {
                    guard case .object(var pairs) = item else { continue }
                    pairs.append(("_car_path", .string(relPath)))
                    pairs.append(("_car_name", .string(carName)))
                    allAssets.append(.object(pairs))
                }
            }
        }

        Logger.info("找到 \(carFiles.count) 个 .car 文件")
        Logger.info("解析到 \(allAssets.count) 个资源")
        func sizeOf(_ a: JSONValue) -> Int { a["SizeOnDisk"]?.intValue ?? 0 }
        let totalSize = allAssets.reduce(0) { $0 + sizeOf($1) }

        // 类型汇总
        var typeOrder: [String] = []
        var typeAgg: [String: (count: Int, size: Int)] = [:]
        for a in allAssets {
            let t = a["AssetType"]?.stringValue ?? "Unknown"
            if typeAgg[t] == nil { typeOrder.append(t); typeAgg[t] = (0, 0) }
            typeAgg[t]!.count += 1; typeAgg[t]!.size += sizeOf(a)
        }
        let typeSummary = JSONValue.object(typeOrder.sorted { typeAgg[$0]!.size > typeAgg[$1]!.size }.map {
            ($0, .object([("count", .int(typeAgg[$0]!.count)), ("size", .int(typeAgg[$0]!.size))]))
        })

        // 重复（跨 .car）
        var shaOrder: [String] = []
        var shaGroups: [String: [JSONValue]] = [:]
        for a in allAssets {
            guard let sha = a["SHA1Digest"]?.stringValue else { continue }
            if shaGroups[sha] == nil { shaOrder.append(sha) }
            shaGroups[sha, default: []].append(a)
        }
        var duplicates: [JSONValue] = []
        for sha in shaOrder {
            let assets = shaGroups[sha]!
            if assets.count < 2 { continue }
            var carOrder: [String] = []
            var byCar: [String: [JSONValue]] = [:]
            for a in assets {
                let c = a["_car_path"]?.stringValue ?? ""
                if byCar[c] == nil { carOrder.append(c) }
                byCar[c, default: []].append(a)
            }
            if byCar.count < 2 { continue }
            let reps = carOrder.map { byCar[$0]!.max { sizeOf($0) < sizeOf($1) }! }
            let size = sizeOf(reps[0])
            duplicates.append(.object([
                ("sha1", .string(sha)),
                ("names", .array(reps.map { .string("\($0["Name"]?.stringValue ?? "?") [\($0["_car_path"]?.stringValue ?? "")]") })),
                ("count", .int(reps.count)),
                ("size_per_instance", .int(size)),
                ("total_waste", .int(size * (reps.count - 1))),
            ]))
        }
        duplicates.sort { ($0["total_waste"]?.intValue ?? 0) > ($1["total_waste"]?.intValue ?? 0) }

        // 最大资源 Top N
        let largest = Array(allAssets.sorted { sizeOf($0) > sizeOf($1) }.prefix(topAssets))

        // Scale 缺失分析
        var scaleGroupOrder: [String] = []
        var scaleGroups: [String: [JSONValue]] = [:]
        for a in allAssets where ["Image", "PDF"].contains(a["AssetType"]?.stringValue ?? "") {
            let name = a["Name"]?.stringValue ?? ""
            let idiom = a["Idiom"]?.stringValue ?? "universal"
            let base = ResourceScanner_resub_atNx(name)
            let key = base + "\u{0}" + idiom
            if scaleGroups[key] == nil { scaleGroupOrder.append(key) }
            scaleGroups[key, default: []].append(a)
        }
        var scaleAnalysis: [JSONValue] = []
        for key in scaleGroupOrder {
            let assets = scaleGroups[key]!
            let parts = key.components(separatedBy: "\u{0}")
            let base = parts[0], idiom = parts.count > 1 ? parts[1] : "universal"
            // sizes_by_scale：同 scale 去重（dict，后者覆盖），再求和（对齐 Python）
            var sizeByScale: [Int: Int] = [:]
            var scaleOrder: [Int] = []
            for a in assets {
                let sc = a["Scale"]?.intValue ?? 1
                if sizeByScale[sc] == nil { scaleOrder.append(sc) }
                sizeByScale[sc] = sizeOf(a)
            }
            let scales = Set(sizeByScale.keys)
            let missing = Set([1, 2, 3]).subtracting(scales)
            if !missing.isEmpty {
                scaleAnalysis.append(.object([
                    ("name", .string(base)), ("idiom", .string(idiom)),
                    ("present_scales", .array(scales.sorted().map { .int($0) })),
                    ("missing_scales", .array(missing.sorted().map { .int($0) })),
                    ("sizes_by_scale", .object(scaleOrder.map { (String($0), .int(sizeByScale[$0]!)) })),
                    ("total_size", .int(sizeByScale.values.reduce(0, +))),
                ]))
            }
        }
        scaleAnalysis.sort { ($0["total_size"]?.intValue ?? 0) > ($1["total_size"]?.intValue ?? 0) }

        return JSONValue.object([
            ("meta", .object([
                ("input_path", .string(absInput)),
                ("car_files_found", .int(carFiles.count)),
                ("car_files", .array(carFiles.map { .string($0) })),
                ("total_asset_count", .int(allAssets.count)),
                ("total_size", .int(totalSize)),
                ("total_size_display", .string(ByteFormatter.fmt(totalSize))),
                ("assetutil_metadata", metadata),
                ("errors", .array(errors.map { .string($0) })),
                ("generated_at", .string(DateUtil.now())),
            ])),
            ("type_summary", typeSummary),
            ("duplicates", .array(duplicates)),
            ("largest_assets", .array(largest)),
            ("scale_analysis", .array(scaleAnalysis)),
            ("all_assets", .array(allAssets)),
        ])
    }
}

/// 去掉名字末尾的 @Nx（复刻 re.sub(r'@\d+x$', '', name)）。
func ResourceScanner_resub_atNx(_ name: String) -> String {
    guard let re = try? NSRegularExpression(pattern: #"@\d+x$"#) else { return name }
    let range = NSRange(name.startIndex..., in: name)
    return re.stringByReplacingMatches(in: name, range: range, withTemplate: "")
}
