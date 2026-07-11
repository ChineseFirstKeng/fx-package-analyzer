import Foundation

/// 各报告 adapter —— 将分析器 JSON 转为 REPORT_DATA context（复刻 adapters.py 的 build_*_context）。
public enum Adapters {

    // MARK: 主工程名识别

    /// 复刻 _get_main_app_names。
    static func mainAppNames(store: ReportStore?, appName: String = "") -> Set<String> {
        var names: Set<String> = ["MainApp", "主工程"]
        if !appName.isEmpty { names.insert(appName) }
        guard let store else { return names }
        if let env = store.load("build_env.json"), let scheme = env["scheme"]?.stringValue, !scheme.isEmpty {
            names.insert(scheme)
        }
        if let lm = store.load("linkmap.json"),
           let lmFile = lm["meta"]?["linkmap_path"]?.stringValue, !lmFile.isEmpty,
           !lmFile.contains("Pods.build") {
            let base = (lmFile as NSString).lastPathComponent
            let nameFromLm = base.components(separatedBy: "-LinkMap")[0].components(separatedBy: "_LinkMap")[0]
            if !nameFromLm.isEmpty { names.insert(nameFromLm) }
        }
        return names
    }

    static func renameMainApp(_ name: String, _ mainNames: Set<String>) -> String {
        mainNames.contains(name) ? ReportConstants.mainAppLabel : name
    }

    static func treeCol(_ key: String, _ label: String, _ colWidth: String, _ cls: String) -> JSONValue {
        .object([("key", .string(key)), ("label", .string(label)), ("colWidth", .string(colWidth)), ("cls", .string(cls))])
    }

    private static let fmt = ByteFormatter.fmt

    // MARK: asset

    /// 复刻 build_asset_context（Phase 1：未使用/重复资源 section 待 Phase 2 产出对应 JSON 后填充）。
    public static func buildAssetContext(_ data: JSONValue, explains: [String: JSONValue], store: ReportStore?) -> JSONValue {
        let meta = data["meta"] ?? .object([])
        let byCat = data["by_category"]?.objectPairs ?? []
        let allFiles = data["all_files"]?.arrayValue ?? []
        let allImages = data["all_images"]?.arrayValue ?? []
        let bySource = data["by_source"]?.arrayValue ?? []
        let totalSize = data["total_size"]?.intValue ?? 0
        let fileCount = meta["file_count"]?.intValue ?? 0

        let catItems = byCat.sorted { $0.1.intValue ?? 0 > $1.1.intValue ?? 0 }.map {
            Ctx.donut($0.0, $0.1.intValue ?? 0, ReportConstants.catColors[$0.0] ?? "#94a3b8")
        }

        // build_env 中的 AppIcon / LaunchImage
        var activeAppicon = ""
        var activeLaunchimage = ""
        if let env = store?.load("build_env.json") {
            activeAppicon = env["app_icon"]?.stringValue ?? ""
            activeLaunchimage = env["launch_image"]?.stringValue ?? ""
        }

        let treeCols: [JSONValue] = [
            treeCol("name", "名称", "auto", "lbl"),
            treeCol("size", "大小", "100px", "sz"),
            treeCol("type", "类型", "100px", "num"),
        ]

        // 类别 → 扩展名 → 文件（保留插入顺序聚合后排序）
        struct ExtBucket { var order: [String] = []; var files: [String: [JSONValue]] = [:] }
        var catOrder: [String] = []
        var catMap: [String: ExtBucket] = [:]
        for f in allFiles {
            let cat = f["category"]?.stringValue ?? "other"
            var ext = f["ext"]?.stringValue ?? ""
            if ext.isEmpty { ext = "." + ((f["path"]?.stringValue ?? "") as NSString).pathExtension }
            if catMap[cat] == nil { catMap[cat] = ExtBucket(); catOrder.append(cat) }
            if catMap[cat]!.files[ext] == nil { catMap[cat]!.order.append(ext); catMap[cat]!.files[ext] = [] }
            catMap[cat]!.files[ext]!.append(f)
        }
        func sizeOf(_ f: JSONValue) -> Int { f["size"]?.intValue ?? 0 }
        func extTotal(_ files: [JSONValue]) -> Int { files.reduce(0) { $0 + sizeOf($1) } }

        var resourceTrees: [JSONValue] = []
        let catsSorted = catOrder.sorted { a, b in
            let ta = catMap[a]!.files.values.reduce(0) { $0 + extTotal($1) }
            let tb = catMap[b]!.files.values.reduce(0) { $0 + extTotal($1) }
            return ta > tb
        }
        for cat in catsSorted {
            let bucket = catMap[cat]!
            var extChildren: [JSONValue] = []
            var catTotal = 0
            let extsSorted = bucket.order.sorted { extTotal(bucket.files[$0]!) > extTotal(bucket.files[$1]!) }
            for ext in extsSorted {
                let files = bucket.files[ext]!
                let extTot = extTotal(files)
                catTotal += extTot
                var fileChildren: [JSONValue] = []
                for f in files.sorted(by: { sizeOf($0) > sizeOf($1) }) {
                    var name = f["path"]?.stringValue ?? ""
                    let base = f["base_name"]?.stringValue ?? ""
                    if !base.isEmpty && !activeAppicon.isEmpty && name.contains(".appiconset") {
                        name += (base == activeAppicon) ? "（当前App图标）" : "（未使用）"
                    } else if !base.isEmpty && !activeLaunchimage.isEmpty && name.contains(".launchimage") {
                        name += (base == activeLaunchimage) ? "（当前启动图）" : "（未使用）"
                    }
                    fileChildren.append(.object([
                        ("name", .string(name)), ("type", .string(ext)), ("size", .int(sizeOf(f))),
                    ]))
                }
                extChildren.append(.object([
                    ("name", .string("\(ext) (\(files.count) 个)")), ("type", .string("dir")),
                    ("size", .int(extTot)), ("children", .array(fileChildren)),
                ]))
            }
            let fileTotalCount = bucket.files.values.reduce(0) { $0 + $1.count }
            resourceTrees.append(.object([
                ("name", .string("\(cat) (\(fileTotalCount) 个)")), ("type", .string("dir")),
                ("size", .int(catTotal)), ("children", .array(extChildren)),
            ]))
        }

        // 代码 & 资源拆分表
        var srcRows: [JSONValue] = []
        for s in bySource.prefix(100) {
            let total = s["total"]?.intValue ?? 0
            let pct = Double(total) / Double(max(totalSize, 1)) * 100
            var name = s["name"]?.stringValue ?? ""
            if name == "主工程" { name = ReportConstants.mainAppLabel }
            srcRows.append(Ctx.row([
                Ctx.cell(name, "lbl"),
                Ctx.cell(fmt(s["code"]?.intValue ?? 0), "sz"),
                Ctx.cell(fmt(s["resource"]?.intValue ?? 0), "sz"),
                Ctx.cell("<b>\(fmt(total))</b>", "sz"),
                Ctx.cell(String(format: "%.1f%%", pct), "num"),
            ], sortKey: total))
        }
        let srcCols: [JSONValue] = [
            Ctx.col("来源", true, "str"), Ctx.col("代码 (Mach-O)", true, "num", "right"),
            Ctx.col("资源", true, "num", "right"), Ctx.col("合计", true, "num", "right"),
            Ctx.col("占比", true, "num", "right"),
        ]

        // ─ 未使用资源 section ─
        var unusedSection: JSONValue? = nil
        if let store {
            let unusedExplains = Explains.load("unused_resource")
            let unusedExplainHTML = Explains.renderBlock(unusedExplains["explain"])
            if let ud = store.load("unused_resource.json"),
               let ul = ud["unused"]?.arrayValue ?? (ud["unused_resources"]?.arrayValue), !ul.isEmpty {
                let us = ul.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) }
                let uCols = [treeCol("name", "名称", "auto", "lbl"), treeCol("size", "大小", "100px", "sz"), treeCol("type", "类型", "100px", "num")]
                // 按 owner 分组，owner 按组内总大小降序（对齐 Python）
                var ownerMap: [String: [JSONValue]] = [:]
                for u in ul {
                    let o = u["owner"]?.stringValue ?? "未知"
                    ownerMap[o, default: []].append(u)
                }
                func fileNode(_ u: JSONValue) -> JSONValue {
                    let p = u["path"]?.stringValue ?? u["name"]?.stringValue ?? ""
                    let fname = (p as NSString).lastPathComponent
                    let ext = (fname as NSString).pathExtension
                    return .object([("name", .string(fname)),
                                    ("type", .string(ext.isEmpty ? "file" : "." + ext)),
                                    ("size", .int(u["size"]?.intValue ?? 0))])
                }
                let sortedOwners = ownerMap.keys.sorted { a, b in
                    ownerMap[a]!.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) } > ownerMap[b]!.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) }
                }
                var uTrees: [JSONValue] = []
                for owner in sortedOwners {
                    let items = ownerMap[owner]!
                    let xcassetsFiles = items.filter { ($0["path"]?.stringValue ?? "").contains(".xcassets/") }
                    let looseFiles = items.filter { !($0["path"]?.stringValue ?? "").contains(".xcassets/") }
                    var children: [JSONValue] = []
                    // xcassets → imageset → 文件 三层
                    if !xcassetsFiles.isEmpty {
                        let xcRe = try? NSRegularExpression(pattern: #"/([^/]+\.xcassets)/([^/]+)\.(imageset|appiconset|launchimage)/"#)
                        var xcOrder: [String] = []
                        var xcMap: [String: (order: [String], sets: [String: [JSONValue]])] = [:]
                        var unmatched: [JSONValue] = []
                        for u in xcassetsFiles {
                            let path = u["path"]?.stringValue ?? ""
                            let ns = path as NSString
                            if let re = xcRe, let m = re.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 3 {
                                let xcName = ns.substring(with: m.range(at: 1))
                                let isetName = ns.substring(with: m.range(at: 2)) + "." + ns.substring(with: m.range(at: 3))
                                if xcMap[xcName] == nil { xcOrder.append(xcName); xcMap[xcName] = ([], [:]) }
                                if xcMap[xcName]!.sets[isetName] == nil { xcMap[xcName]!.order.append(isetName); xcMap[xcName]!.sets[isetName] = [] }
                                xcMap[xcName]!.sets[isetName]!.append(u)
                            } else { unmatched.append(u) }
                        }
                        func groupSize(_ sets: [String: [JSONValue]]) -> Int { sets.values.reduce(0) { $0 + $1.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) } } }
                        for xcName in xcOrder.sorted(by: { groupSize(xcMap[$0]!.sets) > groupSize(xcMap[$1]!.sets) }) {
                            let g = xcMap[xcName]!
                            var isetChildren: [JSONValue] = []
                            for isetName in g.order.sorted(by: { g.sets[$0]!.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) } > g.sets[$1]!.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) } }) {
                                let fnodes = g.sets[isetName]!.sorted { ($0["size"]?.intValue ?? 0) > ($1["size"]?.intValue ?? 0) }.map(fileNode)
                                let isetTotal = fnodes.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) }
                                isetChildren.append(.object([("name", .string("\(isetName) (\(fnodes.count) 个)")), ("type", "dir"),
                                                             ("size", .int(isetTotal)), ("children", .array(fnodes))]))
                            }
                            let xcTotal = isetChildren.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) }
                            children.append(.object([("name", .string("\(xcName) (\(isetChildren.count) 个 imageset)")), ("type", "dir"),
                                                     ("size", .int(xcTotal)), ("children", .array(isetChildren))]))
                        }
                        for u in unmatched { children.append(fileNode(u)) }
                    }
                    for u in looseFiles.sorted(by: { ($0["size"]?.intValue ?? 0) > ($1["size"]?.intValue ?? 0) }) { children.append(fileNode(u)) }
                    let ownerTotal = children.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) }
                    uTrees.append(.object([("name", .string("\(owner) (\(items.count) 个)")), ("type", "dir"),
                                           ("size", .int(ownerTotal)), ("children", .array(children))]))
                }
                unusedSection = Ctx.section("未使用资源", hint: "\(ul.count) 个, \(fmt(us))",
                    explain: unusedExplainHTML,
                    banner: .object([("type", .string("warning")), ("text", .string("发现 \(ul.count) 个未引用资源，建议审查是否可删除"))]),
                    treeList: .object([("columns", .array(uCols)), ("trees", .array(uTrees)), ("start_collapsed", .bool(true)),
                                       ("filter", .object([("search", .object([("id", .string("unusedSearch")), ("placeholder", .string("搜索文件名..."))]))]))]))
            }
        }

        // ─ 重复资源 section ─
        var dupSection: JSONValue? = nil
        if let store {
            let dupExplains = Explains.load("duplicate_resource")
            let dupExplainHTML = Explains.renderBlock(dupExplains["explain"])
            if let dd = store.load("duplicate_resource.json"),
               let dg = dd["duplicates"]?.arrayValue ?? (dd["duplicate_groups"]?.arrayValue), !dg.isEmpty {
                let ws = dg.reduce(0) { $0 + ($1["total_waste"]?.intValue ?? $1["wasted_size"]?.intValue ?? 0) }
                let dCols = [treeCol("name", "名称", "auto", "lbl"), treeCol("size", "大小", "100px", "sz"), treeCol("type", "类型", "100px", "num")]
                var dTrees: [JSONValue] = []
                for grp in dg.sorted(by: { ($0["total_waste"]?.intValue ?? $0["wasted_size"]?.intValue ?? 0) > ($1["total_waste"]?.intValue ?? $1["wasted_size"]?.intValue ?? 0) }) {
                    let h = grp["sha256"]?.stringValue ?? grp["hash"]?.stringValue ?? ""
                    let files = grp["files"]?.arrayValue ?? []
                    let waste = grp["total_waste"]?.intValue ?? grp["wasted_size"]?.intValue ?? 0
                    var fChildren: [JSONValue] = []
                    for fItem in files {
                        let p = fItem["path"]?.stringValue ?? ""
                        let ext = "." + (p as NSString).pathExtension
                        fChildren.append(.object([
                            ("name", .string(p)), ("type", .string(ext)), ("size", .int(fItem["size"]?.intValue ?? 0)),
                        ]))
                    }
                    dTrees.append(.object([
                        ("name", .string("重复组 SHA256:\(h)")),
                        ("type", .string("dir")),
                        ("size", .int(waste > 0 ? waste : fChildren.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) })),
                        ("children", .array(fChildren)),
                    ]))
                }
                dupSection = Ctx.section("重复资源", hint: "\(dg.count) 组, 浪费 \(fmt(ws))",
                    explain: dupExplainHTML,
                    banner: .object([("type", .string("warning")), ("text", .string("发现 \(dg.count) 组重复资源，共浪费 \(fmt(ws))"))]),
                    treeList: .object([("columns", .array(dCols)), ("trees", .array(dTrees)), ("start_collapsed", .bool(true))]))
            }
        }

        let scanPath = meta["scan_path"]?.stringValue ?? ""
        let sizeDisplay = data["total_size_display"]?.stringValue ?? fmt(totalSize)

        var sections: [JSONValue] = [
            Ctx.section("资源类别分布",
                        explain: Explains.renderBlock(explains["explain_category"]),
                        donut: .object([("center_label", .string("资源总大小")), ("items", .array(catItems))]),
                        treeList: .object([
                            ("columns", .array(treeCols)), ("trees", .array(resourceTrees)),
                            ("start_collapsed", .bool(true)),
                            ("filter", .object([("search", .object([("id", .string("catTreeSearch")), ("placeholder", .string("搜索文件名..."))]))])),
                        ])),
        ]
        if !bySource.isEmpty {
            sections.append(Ctx.section("代码 & 资源拆分", hint: "共 \(bySource.count) 项",
                explain: Explains.renderBlock(explains["explain_code_resource"]),
                table: .object([("id", .string("srcTable")), ("columns", .array(srcCols)), ("rows", .array(srcRows))])))
        }
        if let unusedSection { sections.append(unusedSection) }
        if let dupSection { sections.append(dupSection) }

        return .object([
            ("title", .string("资源分析报告")),
            ("meta", .string("扫描路径: \(scanPath) | 文件总数: \(fileCount) | 资源总大小: \(sizeDisplay)")),
            ("generated_at", .string(DateUtil.now())),
            ("kpis", .array([
                .object([("label", .string("资源总大小")), ("value", .int(totalSize)), ("value_display", .bool(true))]),
                .object([("label", .string("文件总数")), ("value", .int(fileCount))]),
                .object([("label", .string("图片文件")), ("value", .int(allImages.count))]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
    }

    // MARK: linkmap

    /// 复刻 build_linkmap_context。
    public static func buildLinkmapContext(_ data: JSONValue, explains: [String: JSONValue], store: ReportStore?) -> JSONValue {
        let meta = data["meta"] ?? .object([])
        let modules = data["modules"]?.arrayValue ?? []
        let sectionsDict = data["sections"]?.objectPairs ?? []
        let totalSize = data["total_size"]?.intValue ?? 0
        let mainNames = mainAppNames(store: store)
        let MAIN = ReportConstants.mainAppLabel

        // 模块表
        var modRows: [JSONValue] = []
        for m in modules {
            let size = m["size"]?.intValue ?? 0
            let pct = totalSize != 0 ? Double(size) / Double(totalSize) * 100 : 0
            let name = renameMainApp(m["name"]?.stringValue ?? "", mainNames)
            let libType = m["lib_type"]?.stringValue ?? ""
            let badge = (name == MAIN)
                ? "<span class=\"type-badge type-main_app\">\(MAIN)</span>"
                : Ctx.typeBadge(libType)
            modRows.append(Ctx.row([
                Ctx.cell(name, "lbl", title: name),
                Ctx.cell(fmt(size), "sz"),
                Ctx.cell(String(format: "%.1f%%", pct), "num"),
                Ctx.cell(String(m["file_count"]?.intValue ?? 0), "num"),
                Ctx.cell(badge, "num"),
            ], sortKey: size))
        }
        let modCols: [JSONValue] = [
            Ctx.col("模块", true, "str"), Ctx.col("大小", true, "num", "right"),
            Ctx.col("占比", true, "num", "right"), Ctx.col("文件数", true, "num", "right"),
            Ctx.col("类型", true, "str"),
        ]

        // 段分布（按 segment 分组）
        var segOrder: [String] = []
        var segGroups: [String: Int] = [:]
        for (k, v) in sectionsDict {
            let seg = k.contains(",") ? String(k.split(separator: ",")[0]) : k
            if segGroups[seg] == nil { segOrder.append(seg) }
            segGroups[seg, default: 0] += v.intValue ?? 0
        }
        var secItems: [JSONValue] = []
        for (k, v) in segGroups.sorted(by: { $0.value > $1.value }) {
            secItems.append(.object([("label", .string(k)), ("value", .int(v)),
                                     ("color", .string(ReportConstants.palette[secItems.count % ReportConstants.palette.count]))]))
        }

        // 优化建议
        var tips: [(String, String)] = []
        if !modules.isEmpty {
            let top5 = modules.prefix(5).reduce(0) { $0 + ($1["size"]?.intValue ?? 0) }
            if top5 > 2 * 1024 * 1024 { tips.append(("high", "Top 5 模块合计 \(fmt(top5))，建议拆分大模块")) }
            let first = modules[0]["size"]?.intValue ?? 0
            if first > Int(Double(totalSize) * 0.6) && modules.count > 1 {
                tips.append(("medium", "最大模块占比 \(Int(Double(first) / Double(max(totalSize, 1)) * 100))%，依赖过于集中"))
            }
        }
        if totalSize == 0 { tips.append(("high", "LinkMap 无效或未解析到代码段")) }
        if sectionsDict.contains(where: { $0.0.lowercased().contains("swift") }) && totalSize < 30 * 1024 * 1024 {
            tips.append(("low", "含 Swift 元数据段，Swift 标准库可能增加 5-15MB 开销"))
        }
        var tipsSection: JSONValue? = nil
        if !tips.isEmpty {
            var html = ""
            for (severity, text) in tips {
                let color = ["high": "#dc3545", "medium": "#fd7e14", "low": "#0d6efd"][severity] ?? "#6c757d"
                let badge = ["high": "高", "medium": "中", "low": "低"][severity] ?? ""
                html += "<div style=\"margin-bottom:10px\"><span style=\"display:inline-block;background:\(color);color:#fff;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600;margin-right:8px\">\(badge)</span>\(HTMLEscape.esc(text))</div>"
            }
            tipsSection = Ctx.section("优化建议", contentHtml: html)
        }

        // 文件树
        var treeSection: JSONValue? = nil
        if let fileTree = data["file_tree"], !(fileTree["children"]?.arrayValue ?? []).isEmpty {
            var html = "<div class=\"tree-container\">"
            html += "<div class=\"tree-header\">"
            html += "<span class=\"tree-col-name\">路径</span>"
            html += "<span class=\"tree-col-type\">类型</span>"
            html += "<span class=\"tree-col-size\">大小</span>"
            html += "<span class=\"tree-col-pct\">占比</span>"
            html += "<span class=\"tree-col-path\">完整路径</span>"
            html += "</div>"
            html += Ctx.renderTreeHTML(fileTree, totalSize: totalSize)
            html += "</div>"
            treeSection = Ctx.section("文件目录树", hint: "\(meta["object_file_count"]?.intValue ?? 0) 个 .o 文件", contentHtml: html)
        }

        let hasSwift = sectionsDict.contains { $0.0.lowercased().contains("swift") }
        let swiftNote = hasSwift ? " · 含 Swift" : ""
        let sizeDisplay = data["total_size_display"]?.stringValue ?? fmt(totalSize)

        var sections: [JSONValue] = [
            Ctx.section("模块概览", hint: "共 \(modules.count) 个模块",
                explain: Explains.renderBlock(explains["explain_module_overview"]),
                table: .object([("id", .string("modTable")), ("columns", .array(modCols)), ("rows", .array(modRows))])),
            Ctx.section("Mach-O 段分布", hint: "共 \(sectionsDict.count) 个段",
                explain: Explains.renderBlock(explains["explain_macho_sections"]),
                donut: .object([("center_label", .string("段总大小")), ("items", .array(secItems))])),
        ]
        if let tipsSection { sections.append(tipsSection) }
        if let treeSection { sections.append(treeSection) }

        return .object([
            ("title", .string("代码模块分析")),
            ("meta", .string("对象文件: \(meta["object_file_count"]?.intValue ?? 0) | 符号: \(meta["symbol_count"]?.intValue ?? 0) | 总大小: \(sizeDisplay)\(swiftNote)")),
            ("generated_at", .string(DateUtil.now())),
            ("kpis", .array([
                .object([("label", .string("代码总大小")), ("value", .int(totalSize)), ("value_display", .bool(true)), ("sub", .string("LinkMap 解析汇总"))]),
                .object([("label", .string("模块数")), ("value", .int(modules.count)), ("sub", .string("Pods / SPM / 主工程"))]),
                .object([("label", .string("文件数")), ("value", .int(meta["object_file_count"]?.intValue ?? 0)), ("sub", .string(".o 编译单元"))]),
                .object([("label", .string("符号数")), ("value", .int(meta["symbol_count"]?.intValue ?? 0)), ("sub", .string("函数 / 方法 / 变量"))]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
    }

    // MARK: module_breakdown

    /// 模块拆解报告。
    public static func buildModuleBreakdownContext(_ data: JSONValue, explains: [String: JSONValue], store: ReportStore) -> JSONValue {
        let meta = data["meta"] ?? .object([])
        let modules = data["modules"]?.arrayValue ?? []
        let mainModule = data["main_module"]
        let hasMain = mainModule.map { if case .null = $0 { return false } else { return true } } ?? false

        let totalCode = meta["total_code"]?.intValue ?? 0
        let totalResource = meta["total_resource"]?.intValue ?? 0
        let totalSize = meta["total_size"]?.intValue ?? 0
        let moduleCount = modules.count + (hasMain ? 1 : 0)
        let fileCount = modules.reduce(0) { $0 + ($1["file_count"]?.intValue ?? 0) }

        let treeColumns: [JSONValue] = [
            treeCol("name", "名称", "auto", "lbl"),
            treeCol("size", "大小", "100px", "sz"),
            treeCol("pct", "占比", "85px", "num"),
            treeCol("type", "类型", "100px", "num"),
        ]

        // all_modules：main 在前
        var allModules: [(JSONValue, Bool)] = []
        if hasMain, let mm = mainModule { allModules.append((mm, true)) }
        for m in modules { allModules.append((m, false)) }

        var staticTrees: [JSONValue] = []
        var dynamicTrees: [JSONValue] = []
        var mainTrees: [JSONValue] = []
        var totalStatic = 0
        var totalDynamic = 0
        for (m, isMain) in allModules {
            let name = m["name"]?.stringValue ?? ""
            let code = (m["static_size"]?.intValue ?? 0) + (m["dynamic_size"]?.intValue ?? 0)
            let resource = m["resource_size"]?.intValue ?? 0
            let totalM = code + resource
            let isDynamic = (m["dynamic_size"]?.intValue ?? 0) > 0

            var tree = PodTree.buildODetailTree(name, store: store)
            if tree == nil { tree = PodTree.buildDynamicDetailTree(name, store: store) }
            guard var t = tree else { continue }
            t = t.adding("_lib_type", .string(isDynamic ? "dynamic_framework" : "static_lib"))
            t = t.adding("_total", .int(totalM))

            if isMain { mainTrees.append(t) }
            else if isDynamic { dynamicTrees.append(t); totalDynamic += totalM }
            else { staticTrees.append(t); totalStatic += totalM }
        }
        // 主模块加到静态库前
        for t in mainTrees {
            staticTrees.insert(t, at: 0)
            totalStatic += t["_total"]?.intValue ?? 0
        }

        var sections: [JSONValue] = [
            Ctx.section("检测原理", explain: Explains.renderBlock(explains["explain"])),
        ]
        if !staticTrees.isEmpty {
            sections.append(Ctx.section("静态库", hint: "\(staticTrees.count) 个 · \(fmt(totalStatic))",
                treeList: .object([
                    ("columns", .array(treeColumns)), ("trees", .array(staticTrees)),
                    ("type_labels", ReportConstants.moduleBreakdownTypeLabels), ("start_collapsed", .bool(true)),
                    ("filter", .object([("search", .object([("id", .string("staticSearch")), ("placeholder", .string("搜索模块名..."))]))])),
                ])))
        }
        if !dynamicTrees.isEmpty {
            sections.append(Ctx.section("动态库", hint: "\(dynamicTrees.count) 个 · \(fmt(totalDynamic))",
                treeList: .object([
                    ("columns", .array(treeColumns)), ("trees", .array(dynamicTrees)),
                    ("type_labels", ReportConstants.moduleBreakdownTypeLabels), ("start_collapsed", .bool(true)),
                    ("filter", .object([("search", .object([("id", .string("dynSearch")), ("placeholder", .string("搜索模块名..."))]))])),
                ])))
        }

        return .object([
            ("title", .string("模块拆解（代码+资源）")),
            ("meta", .string("\(moduleCount) 个模块 | \(fileCount) 个 .o 文件 | 代码 \(fmt(totalCode)) + 资源 \(fmt(totalResource))")),
            ("generated_at", .string(DateUtil.now())),
            ("kpis", .array([
                .object([("label", .string("模块合计")), ("value", .int(totalSize)), ("value_display", .bool(true)), ("sub", .string("\(moduleCount) 个模块"))]),
                .object([("label", .string("静态库")), ("value", .int(totalStatic)), ("value_display", .bool(true)), ("sub", .string("链入主二进制"))]),
                .object([("label", .string("动态库")), ("value", .int(totalDynamic)), ("value_display", .bool(true)), ("sub", .string(".app Frameworks"))]),
                .object([("label", .string("文件数")), ("value", .int(fileCount)), ("sub", .string(".o + 资源文件"))]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
    }

    // MARK: swift_stdlib（复刻 build_swift_stdlib_context）

    public static func buildSwiftStdlibContext(_ data: JSONValue, explains: [String: JSONValue]) -> JSONValue {
        let meta = data["meta"] ?? .object([])
        let summary = data["summary"] ?? .object([])
        let libs = data["embedded_libs"]?.arrayValue ?? []
        let issues = summary["issues"]?.arrayValue ?? []
        let rec = summary["recommendations"]?.arrayValue ?? []
        let totalSwift = summary["total_swift_size"]?.intValue ?? 0

        var banner: JSONValue? = nil
        if libs.isEmpty { banner = .object([("type", "ok"), ("text", "✅ 未嵌入 Swift 标准库动态库，无需优化")]) }
        else if totalSwift > 5 * 1024 * 1024 { banner = .object([("type", "warning"), ("text", .string("⚠️ 嵌入 \(libs.count) 个 Swift 动态库，总计 \(fmt(totalSwift))，建议优化"))]) }

        let libCols = [Ctx.col("库名", true, "str"), Ctx.col("大小", true, "num", "right")]
        let libRows = libs.sorted { ($0["size"]?.intValue ?? 0) > ($1["size"]?.intValue ?? 0) }.map {
            Ctx.row([Ctx.cell($0["name"]?.stringValue ?? "", "lbl"), Ctx.cell(fmt($0["size"]?.intValue ?? 0), "sz")], sortKey: $0["size"]?.intValue ?? 0)
        }

        var sections: [JSONValue] = [Ctx.section("检测原理", explain: Explains.renderBlock(explains["swift_stdlib_explain"]))]
        if !libRows.isEmpty {
            sections.append(Ctx.section("嵌入的 Swift 动态库", banner: banner,
                table: .object([("id", "libTable"), ("columns", .array(libCols)), ("rows", .array(libRows))])))
        }
        if !issues.isEmpty {
            let cols = [Ctx.col("级别", false, "str"), Ctx.col("问题", true, "str"), Ctx.col("说明", true, "str")]
            let rows = issues.map { iss -> JSONValue in
                let sev = iss["severity"]?.stringValue ?? "low"
                let sevLabel = ["high": "HIGH", "medium": "MEDIUM", "low": "LOW"][sev] ?? sev
                let sevCls = ["high": "severity bad", "medium": "severity warn", "low": "severity ok"][sev] ?? ""
                return Ctx.row([Ctx.cell(sevLabel, sevCls), Ctx.cell(iss["title"]?.stringValue ?? "", "lbl"), Ctx.cell(iss["detail"]?.stringValue ?? "", "lbl")])
            }
            sections.append(Ctx.section("发现的问题", table: .object([("id", "issueTable"), ("columns", .array(cols)), ("rows", .array(rows))])))
        }
        if let recSec = recommendationSection(rec) { sections.append(recSec) }

        return .object([
            ("title", "Swift 标准库嵌入检测报告"),
            ("meta", .string("App: " + ((meta["app_path"]?.stringValue ?? "") as NSString).lastPathComponent)),
            ("generated_at", .string(DateUtil.now())),
            ("kpis", .array([
                .object([("label", "嵌入 Swift 库数"), ("value", .int(libs.count)), ("sub", "libswift*.dylib")]),
                .object([("label", "Swift 标准库总大小"), ("value", .int(totalSwift)), ("value_display", .bool(true)),
                         ("color", .string(totalSwift > 5*1024*1024 ? "#dc2626" : (totalSwift == 0 ? "#16a34a" : "#d97706")))]),
                .object([("label", "主二进制链接 Swift"), ("value", .string((summary["binary_links_swift"]?.boolValue ?? false) ? "✅ 是" : "❌ 否"))]),
                .object([("label", "Frameworks 目录"), ("value", .string((summary["has_frameworks_dir"]?.boolValue ?? false) ? "✅ 存在" : "❌ 无"))]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
    }

    // MARK: build_config（复刻 build_build_config_context）

    public static func buildBuildConfigContext(_ data: JSONValue, explains: [String: JSONValue]) -> JSONValue {
        let meta = data["meta"] ?? .object([])
        let summary = data["summary"] ?? .object([])
        let results = data["results"]?.arrayValue ?? []
        let total = summary["total_rules"]?.intValue ?? 0
        let passCnt = summary["pass"]?.intValue ?? 0
        let failCnt = summary["fail"]?.intValue ?? 0
        let passPct = Double(passCnt) / Double(max(total, 1)) * 100

        let cols = [Ctx.col("配置 Key", true, "str"), Ctx.col("说明", true, "str"), Ctx.col("推荐值", true, "str"),
                    Ctx.col("当前值", true, "str"), Ctx.col("状态", true, "str"), Ctx.col("严重度", true, "str")]
        let statusColors = ["pass": "#10b981", "fail": "#ef4444", "unknown": "#f59e0b"]
        let statusClsMap = ["pass": "ok", "fail": "bad", "unknown": "warn"]
        var rows: [JSONValue] = []
        for r in results {
            let status = r["status"]?.stringValue ?? ""
            let statusCls = statusClsMap[status] ?? ""
            let cur = r["current"]?.stringValue ?? ""
            let curDisplay = cur.isEmpty ? "—" : cur
            rows.append(Ctx.rowStr([
                Ctx.cell(r["key"]?.stringValue ?? "", "lbl"),
                Ctx.cell(r["description"]?.stringValue ?? "", "lbl"),
                Ctx.cell(r["expected"]?.stringValue ?? "", "sz"),
                Ctx.cell("<span style=\"color:\(statusColors[status] ?? "#94a3b8")\">\(curDisplay)</span>", "sz"),
                Ctx.cell("<span class=\"severity \(statusCls)\">\(r["status_label"]?.stringValue ?? status)</span>", "num"),
                Ctx.cell(r["criticality"]?.stringValue ?? "", "num"),
            ], sortKeyStr: r["key"]?.stringValue ?? ""))
        }

        let barHTML = "<div style=\"margin:16px 0\"><div style=\"font-size:13px;margin-bottom:6px\">合规率: \(Int(passPct))% (\(passCnt)/\(total))</div><div style=\"height:8px;background:#e2e8f0;border-radius:4px;overflow:hidden\"><div style=\"height:100%;width:\(Int(passPct))%;background:linear-gradient(90deg,#ef4444,#f59e0b,#10b981);border-radius:4px\"></div></div></div>"

        var banner: JSONValue? = nil
        if failCnt > 0 { banner = .object([("type", "warning"), ("text", .string("\(failCnt) 项配置不合规，建议修复以减小包体积"))]) }

        var sections: [JSONValue] = [Ctx.section("检测原理", explain: Explains.renderBlock(explains["explain"]))]
        if !rows.isEmpty {
            sections.append(Ctx.section("配置项明细", hint: "共 \(total) 项", banner: banner,
                table: .object([("id", "configTable"), ("columns", .array(cols)), ("rows", .array(rows))]),
                contentHtml: barHTML))
        }
        return .object([
            ("title", "编译配置审计报告"),
            ("meta", .string("Scheme: \(meta["scheme"]?.stringValue ?? "") | \(meta["project_path"]?.stringValue ?? "")")),
            ("generated_at", .string(DateUtil.now())),
            ("kpis", .array([
                .object([("label", "审计项"), ("value", .int(total))]),
                .object([("label", "合规率"), ("value", .string("\(Int(passPct))%")), ("sub", .string("\(passCnt)/\(total) 项合规")),
                         ("color", .string(failCnt > 0 ? "#ef4444" : "#10b981"))]),
                .object([("label", "不合规"), ("value", .int(failCnt)), ("color", "#ef4444")]),
                .object([("label", "未设置"), ("value", .int(summary["unknown"]?.intValue ?? 0)), ("color", "#f59e0b")]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
    }

    // MARK: localization（复刻 build_localization_context）

    public static func buildLocalizationContext(_ data: JSONValue, explains: [String: JSONValue]) -> JSONValue {
        let meta = data["meta"] ?? .object([])
        let summary = data["summary"] ?? .object([])
        let languages = data["languages"]?.objectPairs ?? []
        let unusedKeys = data["unused_keys"]?.objectPairs ?? []
        let totalL10n = summary["total_localization_size"]?.intValue ?? 0
        let sourceKeysCount = summary["source_keys_count"]?.intValue ?? 0
        let totalUnusedKeys = unusedKeys.reduce(0) { $0 + ($1.1.arrayValue?.count ?? 0) }
        let langCount = summary["language_count"]?.intValue ?? 0

        let sortedLangs = languages.sorted { ($0.1["total_size"]?.intValue ?? 0) > ($1.1["total_size"]?.intValue ?? 0) }

        var langDonut: [JSONValue] = []
        for (i, (code, lang)) in sortedLangs.enumerated() {
            let sz = lang["total_size"]?.intValue ?? 0
            if sz > 0 {
                langDonut.append(Ctx.donut("\(lang["display_name"]?.stringValue ?? code)(\(code))", sz, ReportConstants.palette[i % ReportConstants.palette.count]))
            }
        }

        let langCols = [Ctx.col("语言", true, "str"), Ctx.col("代码", true, "str"), Ctx.col("lproj 数", true, "num", "right"),
                        Ctx.col("文件数", true, "num", "right"), Ctx.col(".strings", true, "num", "right"),
                        Ctx.col("Strings 大小", true, "num", "right"), Ctx.col("总大小", true, "num", "right"),
                        Ctx.col("占比", true, "num", "right"), Ctx.col("未使用key", true, "num", "right")]
        var langRows: [JSONValue] = []
        for (code, lang) in sortedLangs {
            let sz = lang["total_size"]?.intValue ?? 0
            let pct = Double(sz) / Double(max(totalL10n, 1)) * 100
            let unusedCount = data["unused_keys"]?[code]?.arrayValue?.count ?? 0
            langRows.append(Ctx.row([
                Ctx.cell(lang["display_name"]?.stringValue ?? code, "lbl"),
                Ctx.cell(code, "lbl", style: "font-family:monospace;font-size:12px"),
                Ctx.cell(String(lang["lproj_count"]?.intValue ?? 0), "num"),
                Ctx.cell(String(lang["file_count"]?.intValue ?? 0), "num"),
                Ctx.cell(String(lang["strings_count"]?.intValue ?? 0), "num"),
                Ctx.cell(fmt(lang["strings_size"]?.intValue ?? 0), "sz"),
                Ctx.cell(fmt(sz), "sz"),
                Ctx.cell(String(format: "%.1f%%", pct), "num"),
                Ctx.cell(String(unusedCount), "num", style: unusedCount > 0 ? "color:#dc2626" : nil),
            ], sortKey: sz))
        }

        var unusedSection: JSONValue? = nil
        if totalUnusedKeys > 0 {
            let cols = [Ctx.col("语言", true, "str"), Ctx.col("Key", true, "str"), Ctx.col("文件", true, "str")]
            var rows: [JSONValue] = []
            for (lang, keys) in unusedKeys.sorted(by: { ($0.1.arrayValue?.count ?? 0) > ($1.1.arrayValue?.count ?? 0) }) {
                for k in (keys.arrayValue ?? []).prefix(50) {
                    rows.append(Ctx.row([
                        Ctx.cell(lang, "lbl"),
                        Ctx.cell(k["key"]?.stringValue ?? "", "lbl", style: "font-family:monospace;font-size:12px"),
                        Ctx.cell(((k["file"]?.stringValue ?? "") as NSString).lastPathComponent),
                    ]))
                }
            }
            unusedSection = Ctx.section("可能未使用的本地化 key", hint: "共 \(totalUnusedKeys) 个",
                table: .object([("id", "unusedTable"), ("columns", .array(cols)), ("rows", .array(rows))]))
        }

        var banner: JSONValue? = nil
        if langCount == 0 { banner = .object([("type", "ok"), ("text", "未发现本地化资源")]) }
        else if langCount > 10 { banner = .object([("type", "warning"), ("text", .string("支持 \(langCount) 种语言，本地化总计 \(fmt(totalL10n))，建议审查"))]) }

        var sections: [JSONValue] = [Ctx.section("审计说明", explain: Explains.renderBlock(explains["explain"]))]
        if !langRows.isEmpty {
            sections.append(Ctx.section("语言分布", explain: Explains.renderBlock(explains["explain"]), banner: banner,
                donut: .object([("center_label", "本地化总大小"), ("items", .array(langDonut))]),
                table: .object([("id", "langTable"), ("columns", .array(langCols)), ("rows", .array(langRows))])))
        }
        if let unusedSection { sections.append(unusedSection) }
        if let recSec = recommendationSection(summary["recommendations"]?.arrayValue ?? []) { sections.append(recSec) }

        return .object([
            ("title", "本地化语言审计报告"),
            ("meta", .string("App: \(((meta["app_path"]?.stringValue ?? "") as NSString).lastPathComponent) | \(langCount) 种语言")),
            ("generated_at", .string(DateUtil.now())),
            ("kpis", .array([
                .object([("label", "语言数"), ("value", .int(langCount)), ("sub", ".lproj 目录")]),
                .object([("label", "本地化总大小"), ("value", .int(totalL10n)), ("value_display", .bool(true))]),
                .object([("label", "本地化 key 引用"), ("value", .int(sourceKeysCount)), ("sub", "源码中找到")]),
                .object([("label", "可能未使用 key"), ("value", .int(totalUnusedKeys)), ("sub", "未在源码中引用"),
                         ("color", .string(totalUnusedKeys > 0 ? "#ef4444" : "#10b981"))]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
    }

    // MARK: dead_code（复刻 build_dead_code_context）

    public static func buildDeadCodeContext(_ data: JSONValue, explains: [String: JSONValue]) -> JSONValue {
        let meta = data["meta"] ?? .object([])
        let summary = data["summary"] ?? .object([])
        let unused = data["unused_items"]?.arrayValue ?? []
        let totalUnused = summary["total_unused_items"]?.intValue ?? 0
        let totalSavings = summary["total_estimated_savings"]?.intValue ?? 0
        let linkmapOk = summary["linkmap_available"]?.boolValue ?? false
        let peripheryOk = meta["periphery_installed"]?.boolValue ?? false

        var banner: JSONValue? = nil
        if totalUnused > 0 { banner = .object([("type", "warning"), ("text", .string("发现 \(totalUnused) 个未使用代码项，预估可节省 \(fmt(totalSavings))"))]) }

        let byKind = summary["by_kind"]?.objectPairs ?? []
        let byModule = summary["by_module"]?.objectPairs ?? []
        var sections: [JSONValue] = []

        // 安装指引
        if !peripheryOk {
            let html = "<div style=\"margin-bottom:14px\"><strong>安装方式（任选其一）：</strong><br><br><code>brew install peripheryapp/periphery/periphery</code><br><br><strong>安装后重新运行此工具</strong>，即可获得完整的无用代码检测能力。<br><br><strong>当前为 LinkMap 启发式模式</strong>：仅能检测部分符号，准确率有限。建议安装 Periphery 以获得最佳效果。</div>"
            sections.append(Ctx.section("Periphery 未安装", contentHtml: "<div class=\"explain\">\(html)</div>"))
        }

        // 按声明类型分布
        if !byKind.isEmpty {
            let sortedKinds = byKind.sorted { ($0.1.intValue ?? 0) > ($1.1.intValue ?? 0) }
            let items = sortedKinds.prefix(10).enumerated().map { (i, kv) in Ctx.donut(kv.0, kv.1.intValue ?? 0, ReportConstants.palette[i % ReportConstants.palette.count]) }
            let totalKind = sortedKinds.reduce(0) { $0 + ($1.1.intValue ?? 0) }
            let cols = [Ctx.col("类型", true, "str"), Ctx.col("数量", true, "num", "right"), Ctx.col("占比", true, "num", "right")]
            let rows = sortedKinds.map { kv in Ctx.row([Ctx.cell(kv.0, "lbl"), Ctx.cell(String(kv.1.intValue ?? 0), "num"),
                Ctx.cell(String(format: "%.1f%%", Double(kv.1.intValue ?? 0) / Double(max(totalKind, 1)) * 100), "num")], sortKey: kv.1.intValue ?? 0) }
            sections.append(Ctx.section("按声明类型分布",
                donut: .object([("center_label", "声明总数"), ("items", .array(Array(items)))]),
                table: .object([("id", "kindTable"), ("columns", .array(cols)), ("rows", .array(rows))])))
        }

        // 按模块分布
        if !byModule.isEmpty {
            let sortedMods = byModule.sorted { ($0.1["size"]?.intValue ?? 0) > ($1.1["size"]?.intValue ?? 0) }
            let cols = [Ctx.col("模块", true, "str"), Ctx.col("未使用项", true, "num", "right"), Ctx.col("预估大小", true, "num", "right")]
            let rows = sortedMods.prefix(20).map { kv in Ctx.row([Ctx.cell(kv.0, "lbl"), Ctx.cell(String(kv.1["count"]?.intValue ?? 0), "num"),
                Ctx.cell(fmt(kv.1["size"]?.intValue ?? 0), "sz")], sortKey: kv.1["size"]?.intValue ?? 0) }
            sections.append(Ctx.section("按模块分布", hint: "Top 20", table: .object([("id", "modTable"), ("columns", .array(cols)), ("rows", .array(Array(rows)))])))
        }

        // 明细
        if !unused.isEmpty {
            let sortedUnused = unused.sorted { ($0["estimated_size"]?.intValue ?? 0) > ($1["estimated_size"]?.intValue ?? 0) }
            let cols = [Ctx.col("名称", true, "str"), Ctx.col("类型", true, "str"), Ctx.col("位置", true, "str"),
                        Ctx.col("预估大小", true, "num", "right"), Ctx.col("模块", true, "str"), Ctx.col("原因", false, "str")]
            var rows: [JSONValue] = []
            for item in sortedUnused.prefix(500) {
                let file = item["file"]?.stringValue ?? ""
                let loc = file.isEmpty ? "—" : "\((file as NSString).lastPathComponent):\(item["line"]?.intValue ?? 0)"
                let est = item["estimated_size"]?.intValue ?? 0
                rows.append(Ctx.row([
                    Ctx.cell(item["name"]?.stringValue ?? "", "lbl", title: item["name"]?.stringValue),
                    Ctx.cell(item["kind_label"]?.stringValue ?? ""),
                    Ctx.cell(loc),
                    Ctx.cell(est > 0 ? fmt(est) : "—", "sz"),
                    Ctx.cell(item["module"]?.stringValue ?? ""),
                    Ctx.cell((item["hints"]?.arrayValue ?? []).compactMap { $0.stringValue }.joined(separator: ", "), "lbl"),
                ], sortKey: est, attrs: [("kind", item["kind_label"]?.stringValue ?? ""), ("module", item["module"]?.stringValue ?? "")]))
            }
            var kindOpts: [JSONValue] = [.object([("value", "all"), ("label", "全部")])]
            for k in byKind.map({ $0.0 }).sorted() { kindOpts.append(.object([("value", .string(k)), ("label", .string(k))])) }
            var modOpts: [JSONValue] = [.object([("value", "all"), ("label", "全部")])]
            for m in byModule.map({ $0.0 }).sorted() { modOpts.append(.object([("value", .string(m)), ("label", .string(m))])) }
            let filter = JSONValue.object([
                ("selects", .array([
                    .object([("id", "kindFilter"), ("label", "类型"), ("dataKey", "kind"), ("options", .array(kindOpts))]),
                    .object([("id", "modFilter"), ("label", "模块"), ("dataKey", "module"), ("options", .array(modOpts))]),
                ])),
                ("search", .object([("id", "codeSearch"), ("placeholder", "搜索名称...")])),
            ])
            sections.append(Ctx.section("未使用代码明细", hint: "共 \(unused.count) 项，按预估大小降序",
                explain: Explains.renderBlock(explains["dead_code_explain"]), banner: banner, filter: filter,
                table: .object([("id", "codeTable"), ("columns", .array(cols)), ("rows", .array(rows))])))
        }

        return .object([
            ("title", "无用代码检测报告"),
            ("meta", .string("项目: \(meta["project_dir"]?.stringValue ?? "") | Periphery: \(peripheryOk ? "可用" : "未安装") | LinkMap: \(linkmapOk ? "已加载" : "未提供")")),
            ("generated_at", .string(DateUtil.now())),
            ("kpis", .array([
                .object([("label", "未使用代码项"), ("value", .int(totalUnused)), ("sub", "个声明")]),
                .object([("label", "预估可节省"), ("value", .int(totalSavings)), ("value_display", .bool(true)), ("sub", "关联 LinkMap")]),
                .object([("label", "Periphery"), ("value", .string(peripheryOk ? "✅ 可用" : "❌ 未安装")), ("sub", .string(peripheryOk ? "已集成扫描" : "需安装后使用"))]),
                .object([("label", "LinkMap"), ("value", .string(linkmapOk ? "✅ 已加载" : "⚠️ 未提供")), ("sub", .string(linkmapOk ? "可估算大小" : "无法估算大小"))]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
    }

    /// 复刻 recommendations → content_html section（loc/swift 共用）。
    private static func recommendationSection(_ rec: [JSONValue]) -> JSONValue? {
        guard !rec.isEmpty else { return nil }
        var html = ""
        for r in rec {
            let icon = ["ok": "✅", "warning": "⚠️", "info": "ℹ️"][r["type"]?.stringValue ?? "info"] ?? "ℹ️"
            html += "<div style=\"margin-bottom:14px\"><strong>\(icon) \(HTMLEscape.esc(r["title"]?.stringValue ?? ""))</strong><br><span style=\"font-size:13px;color:var(--text2);white-space:pre-line\">\(HTMLEscape.esc(r["detail"]?.stringValue ?? ""))</span></div>"
        }
        return Ctx.section("优化建议", contentHtml: html)
    }

    // MARK: assets_car（复刻 build_assets_car_context）

    public static func buildAssetsCarContext(_ data: JSONValue, explains: [String: JSONValue]) -> JSONValue {
        let meta = data["meta"] ?? .object([])
        let ts = data["type_summary"]?.objectPairs ?? []
        let dups = data["duplicates"]?.arrayValue ?? []
        let largests = data["largest_assets"]?.arrayValue ?? []
        let scaleAnalysis = data["scale_analysis"]?.arrayValue ?? []
        let totalSize = data["total_size"]?.intValue ?? meta["total_size"]?.intValue ?? 0

        let sortedTs = ts.sorted { ($0.1["size"]?.intValue ?? 0) > ($1.1["size"]?.intValue ?? 0) }
        let donutItems = sortedTs.enumerated().map { (i, kv) in
            Ctx.donut(kv.0, kv.1["size"]?.intValue ?? 0, ReportConstants.palette[i % ReportConstants.palette.count])
        }
        let tsCols = [Ctx.col("类型", true, "str"), Ctx.col("数量", true, "num", "right"), Ctx.col("大小", true, "num", "right"), Ctx.col("占比", true, "num", "right")]
        let tsRows = sortedTs.map { kv in
            Ctx.row([Ctx.cell(kv.0, "lbl"), Ctx.cell(String(kv.1["count"]?.intValue ?? 0), "num"),
                     Ctx.cell(fmt(kv.1["size"]?.intValue ?? 0), "sz"),
                     Ctx.cell(String(format: "%.1f%%", Double(kv.1["size"]?.intValue ?? 0) / Double(max(totalSize, 1)) * 100), "num")],
                    sortKey: kv.1["size"]?.intValue ?? 0)
        }

        // 最大资源表（键名对齐原 adapter：name/type/size/scale/idiom + Width/Height/appearance/car_name）
        let largestCols = [Ctx.col("名称", true, "str"), Ctx.col("类型", true, "str"), Ctx.col("大小", true, "num", "right"),
                           Ctx.col("Scale", true, "num", "right"), Ctx.col("Idiom", true, "str"), Ctx.col("尺寸", false, "str"),
                           Ctx.col("外观", false, "str"), Ctx.col("来源", true, "str")]
        var largestRows: [JSONValue] = []
        for a in largests.prefix(100) {
            let w = a["Width"]?.intValue.map(String.init) ?? (a["Width"]?.stringValue ?? "")
            let h = a["Height"]?.intValue.map(String.init) ?? (a["Height"]?.stringValue ?? "")
            let dims = (!w.isEmpty && !h.isEmpty) ? "\(w)x\(h)" : "-"
            largestRows.append(Ctx.row([
                Ctx.cell(a["name"]?.stringValue ?? "", "lbl", title: a["name"]?.stringValue),
                Ctx.cell(a["type"]?.stringValue ?? ""),
                Ctx.cell(fmt(a["size"]?.intValue ?? 0), "sz"),
                Ctx.cell(a["scale"]?.intValue.map(String.init) ?? "-", "num"),
                Ctx.cell(a["idiom"]?.stringValue ?? "-", "num"),
                Ctx.cell(dims),
                Ctx.cell(a["appearance"]?.stringValue ?? ""),
                Ctx.cell(a["car_name"]?.stringValue ?? "", "lbl"),
            ], sortKey: a["size"]?.intValue ?? 0))
        }

        // 重复
        var dupBanner: JSONValue? = nil
        if !dups.isEmpty {
            let waste = dups.reduce(0) { $0 + ($1["waste"]?.intValue ?? 0) }
            dupBanner = .object([("type", "warning"), ("text", .string("发现 \(dups.count) 组重复资源，浪费 \(fmt(waste))"))])
        }
        let dupCols = [Ctx.col("SHA1", true, "str"), Ctx.col("名称", true, "str"), Ctx.col("实例数", true, "num", "right"),
                       Ctx.col("单个大小", true, "num", "right"), Ctx.col("浪费", true, "num", "right")]
        var dupRows: [JSONValue] = []
        for d in dups {
            let namesArr = (d["names"]?.arrayValue ?? []).compactMap { $0.stringValue }
            var names = namesArr.prefix(5).joined(separator: ", ")
            if namesArr.count > 5 { names += " ... 还有 \(namesArr.count - 5) 个" }
            let sha = d["sha1"]?.stringValue ?? ""
            dupRows.append(Ctx.row([
                Ctx.cell(String(sha.prefix(16)) + "...", "lbl", title: sha),
                Ctx.cell(names, "lbl", title: names),
                Ctx.cell(String(d["count"]?.intValue ?? 0), "num"),
                Ctx.cell(fmt(d["size"]?.intValue ?? 0), "sz"),
                Ctx.cell(fmt(d["waste"]?.intValue ?? 0), "sz"),
            ], sortKey: d["waste"]?.intValue ?? 0))
        }

        // Scale 缺失
        var scaleSection: JSONValue? = nil
        if !scaleAnalysis.isEmpty {
            let cols = [Ctx.col("名称", true, "str"), Ctx.col("Idiom", true, "str"), Ctx.col("已有 Scale", false, "str"),
                        Ctx.col("缺失 Scale", false, "str"), Ctx.col("总大小", true, "num", "right")]
            let rows = scaleAnalysis.prefix(50).map { s in
                Ctx.row([
                    Ctx.cell(s["name"]?.stringValue ?? "", "lbl"),
                    Ctx.cell(s["idiom"]?.stringValue ?? ""),
                    Ctx.cell((s["present_scales"]?.arrayValue ?? []).map { "@\($0.intValue ?? 0)x" }.joined(separator: ", ")),
                    Ctx.cell((s["missing_scales"]?.arrayValue ?? []).map { "@\($0.intValue ?? 0)x" }.joined(separator: ", ")),
                    Ctx.cell(fmt(s["total_size"]?.intValue ?? 0), "sz"),
                ], sortKey: s["total_size"]?.intValue ?? 0)
            }
            scaleSection = Ctx.section("Scale 缺失分析", hint: "同一资源在不同 scale 下不完整",
                table: .object([("id", "scaleTable"), ("columns", .array(cols)), ("rows", .array(Array(rows)))]))
        }

        let maxAsset = largests.first
        let maxKpiSub = maxAsset.flatMap { String(($0["name"]?.stringValue ?? "").prefix(30)) } ?? ""

        var sections: [JSONValue] = []
        if !donutItems.isEmpty {
            sections.append(Ctx.section("资源类型分布", hint: "共 \(ts.count) 种类型",
                explain: Explains.renderBlock(explains["assets_car_type_detail"]),
                donut: .object([("center_label", "类型分布"), ("items", .array(donutItems))])))
        }
        if !tsRows.isEmpty {
            sections.append(Ctx.section("类型明细", explain: Explains.renderBlock(explains["assets_car_type_detail"]),
                table: .object([("id", "typeTable"), ("columns", .array(tsCols)), ("rows", .array(tsRows))])))
        }
        if !largestRows.isEmpty {
            sections.append(Ctx.section("最大的资源", hint: "Top \(largests.count)",
                explain: Explains.renderBlock(explains["assets_car_largest"]),
                table: .object([("id", "largeTable"), ("columns", .array(largestCols)), ("rows", .array(largestRows))])))
        }
        if !dupRows.isEmpty {
            sections.append(Ctx.section("重复资源", hint: "SHA1 哈希相同",
                explain: Explains.renderBlock(explains["assets_car_duplicate"]), banner: dupBanner,
                table: .object([("id", "dupTable"), ("columns", .array(dupCols)), ("rows", .array(dupRows))])))
        }
        if let scaleSection { sections.append(scaleSection) }

        return .object([
            ("title", "Assets.car 深度分析报告"),
            ("meta", .string("Car 文件数: \(meta["car_files_found"]?.intValue ?? 0) | 资源总数: \(meta["total_asset_count"]?.intValue ?? 0) | 总大小: \(data["total_size_display"]?.stringValue ?? meta["total_size_display"]?.stringValue ?? fmt(totalSize))")),
            ("generated_at", .string(DateUtil.now())),
            ("kpis", .array([
                .object([("label", "Assets.car 总大小"), ("value", .int(totalSize)), ("value_display", .bool(true))]),
                .object([("label", "资源数"), ("value", .int(meta["total_asset_count"]?.intValue ?? 0)), ("sub", "个独立资源条目")]),
                .object([("label", "资源类型"), ("value", .int(ts.count))]),
                .object([("label", "最大资源"), ("value", .string(maxAsset != nil ? fmt(maxAsset!["size"]?.intValue ?? 0) : "N/A")), ("sub", .string(maxKpiSub))]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
    }

    // MARK: app_thinning（复刻 build_app_thinning_context）

    public static func buildAppThinningContext(_ data: JSONValue, explains: [String: JSONValue]) -> JSONValue {
        let meta = data["meta"] ?? .object([])
        let summary = data["summary"] ?? .object([])
        let variants = data["variants"]?.arrayValue ?? []
        let savings = summary["thinning_savings"]?.intValue ?? 0
        let universal = summary["universal_size"]?.intValue ?? 0

        let vCols = [Ctx.col("设备/变体", true, "str"), Ctx.col("App", true, "num", "right"),
                     Ctx.col("下载大小", true, "num", "right"), Ctx.col("安装大小", true, "num", "right"), Ctx.col("节省", true, "num", "right")]
        var vRows: [JSONValue] = []
        for v in variants {
            let totalSz = v["total_size"]?.intValue ?? 0
            let saveSz = universal > 0 ? max(0, universal - totalSz) : 0
            vRows.append(Ctx.row([
                Ctx.cell(v["device_label"]?.stringValue ?? v["name"]?.stringValue ?? "", "lbl", title: v["name"]?.stringValue),
                Ctx.cell(fmt(v["app_size"]?.intValue ?? 0), "sz"),
                Ctx.cell(fmt(totalSz), "sz"),
                Ctx.cell(fmt(v["install_size"]?.intValue ?? 0), "sz"),
                Ctx.cell(fmt(saveSz), "sz"),
            ], sortKey: totalSz))
        }
        let savingsPct = Double(savings) / Double(max(universal, 1)) * 100
        let barHTML = "<div style=\"margin:16px 0\"><div style=\"font-size:13px;margin-bottom:6px\">Thinning 节省: \(fmt(savings)) (\(String(format: "%.1f", savingsPct))%)</div><div style=\"height:8px;background:#e2e8f0;border-radius:4px;overflow:hidden\"><div style=\"height:100%;width:\(String(format: "%.0f", min(100, savingsPct)))%;background:linear-gradient(90deg,#10b981,#3b82f6);border-radius:4px\"></div></div></div>"

        var sections: [JSONValue] = []
        if !vRows.isEmpty {
            sections.append(Ctx.section("设备变体大小", hint: "共 \(variants.count) 个变体",
                explain: Explains.renderBlock(explains["explain"]),
                table: .object([("id", "varTable"), ("columns", .array(vCols)), ("rows", .array(vRows))]),
                contentHtml: barHTML))
        }
        let maxVariant = variants.map { $0["total_size"]?.intValue ?? 0 }.max() ?? 0
        return .object([
            ("title", "App Thinning 验证报告"),
            ("meta", .string("归档: \(meta["path"]?.stringValue ?? "") | \(variants.count) 个变体 | Universal: \(fmt(universal))")),
            ("generated_at", .string(DateUtil.now())),
            ("kpis", .array([
                .object([("label", "设备变体"), ("value", .int(summary["variant_count"]?.intValue ?? 0))]),
                .object([("label", "Universal"), ("value", .int(universal)), ("value_display", .bool(true)), ("sub", .string("实际下载 \(fmt(maxVariant))"))]),
                .object([("label", "Thinning 节省"), ("value", .int(savings)), ("value_display", .bool(true)),
                         ("sub", .string("\(String(format: "%.1f", savingsPct))%")), ("color", .string(savings > 0 ? "#10b981" : "#94a3b8"))]),
                .object([("label", "Asset 条目"), ("value", .int(summary["asset_thinning_entries"]?.intValue ?? 0)), ("sub", "含 scale/idiom 信息")]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
    }

    // MARK: objc_unused（复刻 build_objc_unused_context）

    public static func buildObjCUnusedContext(_ data: JSONValue, explains: [String: JSONValue]) -> JSONValue {
        let summary = data["summary"] ?? .object([])
        let unusedClasses = data["unused_classes"]?.arrayValue ?? []
        let unusedMethods = data["unused_methods"]?.arrayValue ?? []
        let dynamicCalls = data["dynamic_calls"]?.arrayValue ?? []

        // ── 未使用类 → table ──
        let clsCols: [JSONValue] = [Ctx.col("类名", true, "str")]
        let clsRows: [JSONValue] = unusedClasses.map { c in
            Ctx.row([Ctx.cell(c["name"]?.stringValue ?? "", "lbl")])
        }

        // ── 未使用方法 → treeList（按文件分组）──
        let mCols: [JSONValue] = [
            .object([("key", "name"), ("label", "方法"), ("colWidth", "auto"), ("cls", "lbl")]),
            .object([("key", "type"), ("label", "类型"), ("colWidth", "80px"), ("cls", "num")]),
        ]
        var mOrder: [String] = []
        var mByFile: [String: [JSONValue]] = [:]
        for m in unusedMethods {
            let fname = ((m["file"]?.stringValue ?? "") as NSString).lastPathComponent
            let key = fname.isEmpty ? "(未知文件)" : fname
            if mByFile[key] == nil { mOrder.append(key); mByFile[key] = [] }
            mByFile[key]!.append(m)
        }
        var mTrees: [JSONValue] = []
        for fname in mOrder.sorted() {
            let children = mByFile[fname]!.map { m -> JSONValue in
                return .object([("name", .string(m["name"]?.stringValue ?? "")),
                                ("type", .string(m["type"]?.stringValue ?? "")),
                                ("size", .int(0))])
            }
            mTrees.append(.object([("name", .string(fname)), ("type", .string("dir")),
                                   ("size", .int(0)), ("children", .array(children))]))
        }

        // ── 动态调用 → table ──
        let dynCols: [JSONValue] = [
            Ctx.col("源码", true, "str"),
            Ctx.col("文件:行号", true, "str"),
        ]
        let dynRows: [JSONValue] = dynamicCalls.map { d in
            let src = d["source"]?.stringValue ?? ""
            let fname = ((d["file"]?.stringValue ?? "") as NSString).lastPathComponent
            return Ctx.row([
                Ctx.cell(src.isEmpty ? "第 \(d["line"]?.intValue ?? 0) 行" : src, "lbl"),
                Ctx.cell("\(fname):\(d["line"]?.intValue ?? 0)", "lbl"),
            ])
        }

        var sections: [JSONValue] = [
            Ctx.section("检测原理", explain: Explains.renderBlock(explains["explain"])),
        ]
        if !mTrees.isEmpty {
            sections.append(Ctx.section("未使用方法", hint: "共 \(unusedMethods.count) 个 · \(mTrees.count) 个文件",
                treeList: .object([("columns", .array(mCols)), ("trees", .array(mTrees)),
                                   ("type_labels", .object(ReportConstants.treeTypeLabels.map { ($0.key, .string($0.value)) })),
                                   ("start_collapsed", .bool(true)),
                                   ("filter", .object([("search", .object([("id", "methodSearch"), ("placeholder", "搜索方法名...")]))]))])))
        }
        if !clsRows.isEmpty {
            sections.append(Ctx.section("未使用类", hint: "\(unusedClasses.count) 个",
                table: .object([("id", "clsTable"), ("columns", .array(clsCols)), ("rows", .array(clsRows))])))
        }
        if !dynRows.isEmpty {
            sections.append(Ctx.section("动态调用", hint: "\(dynamicCalls.count) 个",
                table: .object([("id", "dynTable"), ("columns", .array(dynCols)), ("rows", .array(dynRows))])))
        }

        let filesAnalyzed = summary["files_analyzed"]?.intValue ?? 0
        let filesFailed = summary["files_failed"]?.intValue ?? 0
        let declaredClasses = summary["declared_classes"]?.intValue ?? 0
        let declaredMethods = summary["declared_methods"]?.intValue ?? 0
        return .object([
            ("title", "ObjC 未使用代码检测报告（增强版）"),
            ("meta", .string("\(filesAnalyzed) 个 AST 文件 | \(declaredClasses) 个类 | \(declaredMethods) 个方法")),
            ("generated_at", .string(DateUtil.now())),
            ("kpis", .array([
                .object([("label", "分析文件"), ("value", .int(filesAnalyzed)), ("sub", .string("失败 \(filesFailed) 个"))]),
                .object([("label", "未使用类"), ("value", .int(summary["unused_classes"]?.intValue ?? unusedClasses.count)),
                         ("sub", .string("共 \(declaredClasses) 个声明")), ("color", "#ef4444")]),
                .object([("label", "未使用方法"), ("value", .int(summary["unused_methods"]?.intValue ?? unusedMethods.count)),
                         ("sub", .string("共 \(declaredMethods) 个声明")), ("color", "#ef4444")]),
                .object([("label", "动态调用"), ("value", .int(dynamicCalls.count)), ("sub", "需人工确认"), ("color", "#f59e0b")]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
    }
}

