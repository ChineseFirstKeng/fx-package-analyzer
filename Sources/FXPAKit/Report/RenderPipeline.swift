import Foundation

/// 报告渲染管线 —— 复刻 reports/render.py 的 render_all / render_sub_reports / render_unified。
public struct RenderPipeline {
    let store: ReportStore
    let renderer: Renderer

    public init(outputDir: String) throws {
        self.store = ReportStore(outputDir)
        self.renderer = try Renderer()
    }

    /// JSON → 模板（render.py JSON_TO_TEMPLATE，注意不含 linkmap）。
    static let jsonToTemplate: [String] = [
        "asset.json", "assets_car.json", "dead_code.json", "app_thinning.json",
        "localization.json", "swift_stdlib.json", "objc_unused.json",
        "build_config_audit.json", "module_breakdown.json",
    ]

    /// 侧边栏 Tab（render.py SIDEBAR_TABS）。
    static let sidebarTabs: [(json: String, html: String, label: String, icon: String)] = [
        ("module_breakdown.json", "module_breakdown_report.html", "模块拆解", "&#128230"),
        ("asset.json", "asset_report.html", "资源明细", "&#128196;"),
        ("build_config_audit.json", "build_config_audit_report.html", "编译配置", "&#9879;"),
        ("swift_stdlib.json", "swift_stdlib_report.html", "Swift标准库", "&#128153;"),
        ("dead_code.json", "dead_code_report.html", "无用代码", "&#128128;"),
        ("objc_unused.json", "objc_unused_report.html", "ObjC未使用", "&#128128;"),
        ("app_thinning.json", "app_thinning_report.html", "App Thinning", "&#128241;"),
        ("localization.json", "localization_report.html", "本地化", "&#127760;"),
        ("assets_car.json", "assets_car_report.html", "Car拆解", "&#128230;"),
    ]

    static let treeColumns: [JSONValue] = [
        .object([("key", "name"), ("label", "名称"), ("colWidth", "auto"), ("cls", "lbl")]),
        .object([("key", "type"), ("label", "文件类型"), ("colWidth", "100px"), ("cls", "num")]),
        .object([("key", "size"), ("label", "大小"), ("colWidth", "100px"), ("cls", "sz")]),
        .object([("key", "pct"), ("label", "占比"), ("colWidth", "85px"), ("cls", "num")]),
    ]

    /// 生成统一 JSON + 渲染全部报告。
    public func renderAll(appName: String) throws {
        try Generators.generateUnifiedJson(store: store, appName: appName)
        try Generators.generateModuleBreakdownJson(store: store)
        let count = try renderSubReports()
        Logger.info("已渲染 \(count) 个子报告")
        try renderUnified(appName: appName)
    }

    /// 渲染每个存在的 JSON → 对应 HTML。
    func renderSubReports() throws -> Int {
        var count = 0
        for jsonFile in Self.jsonToTemplate {
            guard store.exists(jsonFile), let data = store.load(jsonFile) else { continue }
            let baseName = jsonFile.replacingOccurrences(of: ".json", with: "")
            let explains = Explains.load(baseName)
            let context: JSONValue
            switch baseName {
            case "asset":
                context = Adapters.buildAssetContext(data, explains: explains, store: store)
            case "module_breakdown":
                context = Adapters.buildModuleBreakdownContext(data, explains: explains, store: store)
            case "dead_code":
                context = Adapters.buildDeadCodeContext(data, explains: explains)
            case "swift_stdlib":
                context = Adapters.buildSwiftStdlibContext(data, explains: explains)
            case "localization":
                context = Adapters.buildLocalizationContext(data, explains: explains)
            case "build_config_audit":
                context = Adapters.buildBuildConfigContext(data, explains: explains)
            case "assets_car":
                context = Adapters.buildAssetsCarContext(data, explains: explains)
            case "app_thinning":
                context = Adapters.buildAppThinningContext(data, explains: explains)
            case "objc_unused":
                context = Adapters.buildObjCUnusedContext(data, explains: explains)
            default:
                continue
            }
            try renderer.render(template: "report.html", data: context,
                                outputPath: (store.outputDir as NSString).appendingPathComponent("\(baseName)_report.html"))
            count += 1
        }
        return count
    }

    /// 递归拆分 .app 树的代码/资源（复刻 _classify_app_files）。
    static func classifyAppFiles(_ node: JSONValue, inFramework: Bool = false) -> (exec: Int, resource: Int) {
        var execSize = 0, resSize = 0
        for child in node["children"]?.arrayValue ?? [] {
            if child["type"]?.stringValue == "dir" {
                let childInFw = inFramework || (child["name"]?.stringValue ?? "").hasSuffix(".framework")
                let (ce, cr) = classifyAppFiles(child, inFramework: childInFw)
                execSize += ce; resSize += cr
            } else {
                let size = child["size"]?.intValue ?? 0
                if child["type"]?.stringValue == "macho" { execSize += size } else { resSize += size }
            }
        }
        return (execSize, resSize)
    }

    /// 渲染统一报告 + 概览页。
    func renderUnified(appName: String) throws {
        guard let data = store.load("unified_report.json") else {
            Logger.info("[统一报告] 跳过: unified_report.json 不存在")
            return
        }
        let meta = data["meta"] ?? .object([])
        let entries = data["entries"]?.arrayValue ?? []
        let totalAll = meta["total_size"]?.intValue ?? 0

        let dynamicCount = entries.filter { $0["type"]?.stringValue == "dynamic_framework" }.count
        let staticCount = entries.filter { $0["type"]?.stringValue == "static_lib" }.count

        // 按类型聚合
        var typeOrder: [String] = []
        var typeData: [String: Int] = [:]
        for r in entries {
            let rtype = r["type"]?.stringValue ?? ""
            let tlabel = ReportConstants.typeLabels[rtype] ?? (rtype.isEmpty ? "其他" : rtype)
            if typeData[tlabel] == nil { typeOrder.append(tlabel) }
            typeData[tlabel, default: 0] += r["total"]?.intValue ?? 0
        }
        let typeLabelsSorted = typeData.keys.sorted()

        // 侧边栏
        var sidebarItems: [JSONValue] = []
        var iframeTabs: [JSONValue] = []
        var tabIndex = 1
        for tab in Self.sidebarTabs {
            let htmlPath = (store.outputDir as NSString).appendingPathComponent(tab.html)
            if FileManager.default.fileExists(atPath: htmlPath),
               (ResourceScanner.fileSize(htmlPath)) > 100 {
                sidebarItems.append(.object([
                    ("index", .int(tabIndex)), ("label", .string(tab.label)),
                    ("icon", .string(tab.icon)), ("html_file", .string(tab.html)),
                ]))
                iframeTabs.append(.object([("index", .int(tabIndex)), ("html_file", .string(tab.html))]))
                tabIndex += 1
            }
        }

        let appNameMeta = meta["app_name"]?.stringValue ?? ""
        let generatedAt = meta["timestamp"]?.stringValue ?? DateUtil.now()

        // 概览树 + 代码/资源拆分
        let appTree = Generators.buildOverviewAppTree(store: store)
        var appActualSize = 0
        var totalCode = 0
        var totalResource = 0
        if let appStruct = store.load("app_structure.json") {
            appActualSize = appStruct["total_size"]?.intValue ?? 0
            let (c, r) = Self.classifyAppFiles(appStruct["root"] ?? .object([]))
            totalCode = c; totalResource = r
        }
        let realTotal = appActualSize > 0 ? appActualSize : totalAll
        let otherSize = max(0, realTotal - totalCode - totalResource)

        let overviewExplains = Explains.load("overview")
        let appStructExplain = overviewExplains["app_structure_explain"]
        let kpiExplain = overviewExplains["overview_kpi_explain"]

        var sections: [JSONValue] = []
        if let kpiExplain, !Explains.renderBlock(kpiExplain).isEmpty {
            sections.append(.object([("title", "指标说明"), ("explain", .string(Explains.renderBlock(kpiExplain)))]))
        }
        if let appTree {
            let donutSorted = appTree.typeDist.sorted { $0.1 > $1.1 }
            var donutItems: [JSONValue] = []
            for (i, item) in donutSorted.enumerated() {
                donutItems.append(.object([
                    ("label", .string(item.0)), ("value", .int(item.1)),
                    ("color", .string(ReportConstants.palette[i % ReportConstants.palette.count])),
                ]))
            }
            sections.append(.object([
                ("title", ".app 文件结构"),
                ("hint", .string(ByteFormatter.fmt(appTree.total))),
                ("explain", .string(Explains.renderBlock(appStructExplain))),
                ("donut", .object([("center_label", ".app 总大小"), ("items", .array(donutItems))])),
                ("tree", .object([("root", appTree.root), ("total_size", .int(appTree.total)), ("columns", .array(Self.treeColumns))])),
            ]))
        }

        let overviewContext = JSONValue.object([
            ("title", .string(appNameMeta.isEmpty ? "包体积分析报告" : "\(appNameMeta) 包体积分析报告")),
            ("meta", .string("总大小: \(ByteFormatter.fmt(realTotal)) | 可执行文件: \(ByteFormatter.fmt(totalCode)) | 资源: \(ByteFormatter.fmt(totalResource)) | 其他: \(ByteFormatter.fmt(otherSize)) | 条目: \(entries.count)")),
            ("generated_at", .string(generatedAt)),
            ("kpis", .array([
                .object([("label", "总大小"), ("value", .int(realTotal)), ("value_display", .bool(true))]),
                .object([("label", "所有可执行文件"), ("value", .int(totalCode)), ("value_display", .bool(true))]),
                .object([("label", "资源"), ("value", .int(totalResource)), ("value_display", .bool(true))]),
                .object([("label", "其他"), ("value", .int(otherSize)), ("value_display", .bool(true))]),
            ])),
            ("sections", .array(sections)),
            ("extra_js", .string("")),
        ])
        try renderer.render(template: "report.html", data: overviewContext,
                            outputPath: (store.outputDir as NSString).appendingPathComponent("overview_report.html"))

        // 统一页面
        let typeLabelsJSON = JSONValue.object(ReportConstants.typeLabels.map { ($0.key, .string($0.value)) })
        var typeDataJSON: [(String, JSONValue)] = []
        for k in typeOrder { typeDataJSON.append((k, .int(typeData[k]!))) }
        var iframeAll: [JSONValue] = [.object([("index", .int(0)), ("html_file", .string("overview_report.html"))])]
        iframeAll.append(contentsOf: iframeTabs)

        let unifiedContext = JSONValue.object([
            ("title", "统一报告"),
            ("app_name", .string(appNameMeta)),
            ("generated_at", .string(generatedAt)),
            ("meta", meta),
            ("entries", .array(entries)),
            ("total_all", .int(totalAll)),
            ("total_code", .int(totalCode)),
            ("total_resource", .int(totalResource)),
            ("dynamic_count", .int(dynamicCount)),
            ("static_count", .int(staticCount)),
            ("type_data", .object(typeDataJSON)),
            ("type_labels", typeLabelsJSON),
            ("type_labels_sorted", .array(typeLabelsSorted.map { .string($0) })),
            ("palette", .array(ReportConstants.palette.map { .string($0) })),
            ("sidebar_items", .array(sidebarItems)),
            ("iframe_tabs", .array(iframeAll)),
        ])
        try renderer.render(template: "unified_report.html", data: unifiedContext,
                            outputPath: (store.outputDir as NSString).appendingPathComponent("unified_report.html"))

        Logger.info("统一报告: \((store.outputDir as NSString).appendingPathComponent("unified_report.html"))")
    }
}
