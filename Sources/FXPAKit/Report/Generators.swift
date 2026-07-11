import Foundation

/// 统一报告 / 模块汇总 JSON 生成 —— 复刻 adapters.py 的 build_unified_entries / generate_unified_json /
/// 模块拆解 JSON / 统一概览 app_tree。
public enum Generators {

    // MARK: 合并条目

    final class Entry {
        var code = 0
        var resource = 0
        var type = "other"
        var total = 0
        var name = ""
        init() {}
    }

    /// 保留插入顺序的字典。
    final class OrderedMap {
        private(set) var keys: [String] = []
        private var map: [String: Entry] = [:]
        func get(_ name: String) -> Entry {
            if let e = map[name] { return e }
            let e = Entry(); map[name] = e; keys.append(name); return e
        }
        func contains(_ name: String) -> Bool { map[name] != nil }
        subscript(_ name: String) -> Entry? { map[name] }
        func remove(_ name: String) { map[name] = nil; keys.removeAll { $0 == name } }
        func set(_ name: String, _ e: Entry) {
            if map[name] == nil { keys.append(name) }
            map[name] = e
        }
        var values: [Entry] { keys.compactMap { map[$0] } }
    }

    /// 合并 LinkMap + Asset + Pod → entries（复刻 build_unified_entries）。
    static func buildUnifiedEntries(lm: JSONValue, asset: JSONValue, pod: JSONValue, appName: String) -> [JSONValue] {
        let MAIN = ReportConstants.mainAppLabel
        let lmModules = lm["modules"]?.arrayValue ?? []
        let assetSources = asset["by_source"]?.arrayValue ?? []
        let podPods = pod["pods"]?.arrayValue ?? []

        var lmLibType: [String: String] = [:]
        for m in lmModules {
            var name = m["name"]?.stringValue ?? ""
            if name == "MainApp" { name = "主工程" }
            lmLibType[name] = m["lib_type"]?.stringValue ?? "static"
        }

        let merged = OrderedMap()

        for m in lmModules {
            var name = m["name"]?.stringValue ?? ""
            var t = "other"
            if name == "MainApp" { name = MAIN; t = "main_app" }
            let d = merged.get(name)
            d.code += m["size"]?.intValue ?? 0
            d.type = t
        }
        let hasLinkmap = !lmModules.isEmpty

        for s in assetSources {
            var name = s["name"]?.stringValue ?? ""
            if name == "主工程" { name = MAIN }
            let d = merged.get(name)
            let sCode = s["code"]?.intValue ?? 0
            if sCode > 0 {
                if name == MAIN {
                    if !hasLinkmap { d.code = sCode; d.type = "main_app" }
                } else if d.code == 0 {
                    d.code = sCode; d.type = "dynamic_framework"
                }
            }
            d.resource += s["resource"]?.intValue ?? 0
        }

        var bundleToPod: [String: String] = [:]
        for p in podPods {
            let pname = p["name"]?.stringValue ?? ""
            for f in p["files"]?.arrayValue ?? [] {
                let path = f["path"]?.stringValue ?? ""
                let bname = path.split(separator: "/").last.map(String.init) ?? path
                if bname != "." && bname != ".." {
                    bundleToPod[bname] = pname
                    if bname.hasSuffix(".bundle") {
                        bundleToPod[String(bname.dropLast(7))] = pname
                    }
                }
            }
        }
        for p in podPods {
            merged.get(p["name"]?.stringValue ?? "").type = "static_lib"
        }

        for otherName in merged.keys {
            guard let od = merged[otherName] else { continue }
            if od.code == 0 && od.resource > 0 {
                if let owner = bundleToPod[otherName], owner != otherName, let ownerE = merged[owner] {
                    ownerE.resource += od.resource
                    ownerE.total = ownerE.code + ownerE.resource
                    merged.remove(otherName)
                }
            }
        }

        if !appName.isEmpty && merged.contains(appName) && merged.contains(MAIN) {
            let mainE = merged[MAIN]!, appE = merged[appName]!
            mainE.code += appE.code
            mainE.resource += appE.resource
            mainE.total = mainE.code + mainE.resource
            mainE.type = "main_app"
            merged.remove(appName)
        } else if merged.contains(appName) && !appName.isEmpty {
            let appE = merged[appName]!
            merged.remove(appName)
            appE.name = MAIN
            appE.type = "main_app"
            merged.set(MAIN, appE)
        }

        var dynamicFwNames = Set<String>()
        for s in assetSources where (s["code"]?.intValue ?? 0) > 0 {
            dynamicFwNames.insert(s["name"]?.stringValue ?? "")
        }

        for name in merged.keys {
            guard let d = merged[name] else { continue }
            d.name = name
            d.total = d.code + d.resource
            if d.type == "other" && d.code > 0 {
                if name == MAIN || name == "linker synthesized" { continue }
                let lt = lmLibType[name] ?? ""
                if lt == "system" { d.type = "system" }
                else if lt == "dynamic" { d.type = "dynamic_framework" }
                else if lt == "static" && dynamicFwNames.contains(name) { d.type = "dynamic_framework" }
                else if lt == "static" { d.type = "static_lib" }
                else if dynamicFwNames.contains(name) { d.type = "dynamic_framework" }
                else { d.type = "static_lib" }
            }
        }

        var systemCode = 0
        for name in merged.keys {
            guard let d = merged[name] else { continue }
            if d.type == "system" || lmLibType[name] == "system" {
                systemCode += d.code
                merged.remove(name)
            }
        }
        if systemCode > 0 {
            let e = Entry(); e.name = "系统库(不占包体积)"; e.code = systemCode; e.resource = 0; e.total = systemCode; e.type = "other"
            merged.set("系统库(不占包体积)", e)
        }

        let noiseNames: Set<String> = ["Frameworks", "PrivateFrameworks", "lib", "usr",
                                       "Release-iphoneos", "arm64", "Objects-normal", "Library"]
        var noiseCode = 0
        for name in merged.keys {
            guard let d = merged[name] else { continue }
            if d.resource == 0 && d.total < 200 * 1024 &&
                (noiseNames.contains(name) || (d.type == "other" && d.total < 20 * 1024)) {
                noiseCode += d.code
                merged.remove(name)
            }
        }
        if noiseCode > 0 {
            let e = Entry(); e.name = "其他代码"; e.code = noiseCode; e.resource = 0; e.total = noiseCode; e.type = "other"
            merged.set("其他代码", e)
        }

        // 稳定的 total 降序
        var result = LinkMapParser.stableSortBySizeDesc(merged.values) { $0.total }

        if hasLinkmap && merged.contains(MAIN) {
            let lmTotalCode = lm["total_size"]?.intValue ?? 0
            var mainBinaryCode = 0
            for s in assetSources {
                let n = s["name"]?.stringValue ?? ""
                if (n == MAIN || n == "主工程") && (s["code"]?.intValue ?? 0) > 0 {
                    mainBinaryCode = s["code"]!.intValue!
                    break
                }
            }
            let metadata = mainBinaryCode - lmTotalCode
            if metadata > 1024 * 1024 {
                let e = Entry(); e.name = "二进制元数据"; e.code = metadata; e.resource = 0; e.total = metadata; e.type = "other"
                result.append(e)
            }
        }

        return result.map { e in
            JSONValue.object([
                ("name", .string(e.name)),
                ("code", .int(e.code)),
                ("resource", .int(e.resource)),
                ("total", .int(e.total)),
                ("type", .string(e.type)),
            ])
        }
    }

    // MARK: 统一 JSON

    @discardableResult
    public static func generateUnifiedJson(store: ReportStore, appName: String) throws -> JSONValue {
        let lm = store.loadOrEmpty("linkmap.json")
        let asset = store.loadOrEmpty("asset.json")
        let pod = store.loadOrEmpty("pod_resource.json")
        let buildEnv = store.loadOrEmpty("build_env.json")

        let entries = buildUnifiedEntries(lm: lm, asset: asset, pod: pod, appName: appName)
        let totalAll = entries.reduce(0) { $0 + ($1["total"]?.intValue ?? 0) }
        let totalResource = entries.reduce(0) { $0 + ($1["resource"]?.intValue ?? 0) }

        // total_code：主二进制(type=='' 且无点) + Frameworks 子项（复刻原逻辑）
        var totalCode = 0
        let appStruct = store.loadOrEmpty("app_structure.json")
        let root = appStruct["root"] ?? .object([])
        for child in root["children"]?.arrayValue ?? [] {
            let name = child["name"]?.stringValue ?? ""
            let ftype = child["type"]?.stringValue ?? ""
            if ftype == "" && !name.contains(".") {
                totalCode += child["size"]?.intValue ?? 0
            } else if name == "Frameworks" && ftype == "dir" {
                for fw in child["children"]?.arrayValue ?? [] {
                    totalCode += fw["size"]?.intValue ?? 0
                }
            }
        }
        totalCode = min(totalCode, totalAll)

        let unified = JSONValue.object([
            ("meta", .object([
                ("app_name", .string(appName)),
                ("timestamp", .string(DateUtil.now())),
                ("xcode_version", .string(buildEnv["xcode_version"]?.stringValue ?? "")),
                ("sdk_version", .string(buildEnv["sdk_version"]?.stringValue ?? "")),
                ("deployment_target", .string(buildEnv["deployment_target"]?.stringValue ?? "")),
                ("total_code", .int(totalCode)),
                ("total_resource", .int(totalResource)),
                ("total_size", .int(totalAll)),
                ("entry_count", .int(entries.count)),
            ])),
            ("entries", .array(entries)),
        ])
        try writeJSON(unified, to: (store.outputDir as NSString).appendingPathComponent("unified_report.json"))
        return unified
    }

    // MARK: 模块汇总 JSON

    @discardableResult
    public static func generateModuleBreakdownJson(store: ReportStore) throws -> JSONValue {
        let lm = store.loadOrEmpty("linkmap.json")
        let app = store.loadOrEmpty("app_structure.json")

        var dynFwMap: [(String, Int)] = []   // 保留顺序
        var dynFwIndex: [String: Int] = [:]
        let appRoot = app["root"] ?? .object([])
        for c in appRoot["children"]?.arrayValue ?? [] {
            if c["name"]?.stringValue == "Frameworks" && c["type"]?.stringValue == "dir" {
                for fw in c["children"]?.arrayValue ?? [] {
                    let n = fw["name"]?.stringValue ?? ""
                    if n.hasSuffix(".framework") {
                        dynFwMap.append((String(n.dropLast(10)), fw["size"]?.intValue ?? 0))
                        dynFwIndex[String(n.dropLast(10))] = dynFwMap.count - 1
                    }
                }
            }
        }

        struct Agg { var staticSize = 0; var dynamicSize = 0; var fileCount = 0; var manager = ""; var resourceSize = 0 }
        var aggOrder: [String] = []
        var agg: [String: Agg] = [:]
        func ensure(_ pod: String, manager: String = "") {
            if agg[pod] == nil { agg[pod] = Agg(); agg[pod]!.manager = manager; aggOrder.append(pod) }
        }

        for m in lm["modules"]?.arrayValue ?? [] {
            let libType = m["lib_type"]?.stringValue ?? ""
            if ["system", "synthesized", "toolchain"].contains(libType) { continue }
            let pod = m["name"]?.stringValue ?? ""
            let manager = m["manager"]?.stringValue ?? ""
            let sz = m["size"]?.intValue ?? 0
            let fc = m["file_count"]?.intValue ?? 0
            ensure(pod, manager: manager)
            if libType == "dynamic" { agg[pod]!.dynamicSize += sz } else { agg[pod]!.staticSize += sz }
            agg[pod]!.fileCount += fc
        }

        var podLmPods = Set<String>()
        for m in lm["modules"]?.arrayValue ?? [] where m["_pod_linkmap"]?.boolValue == true {
            podLmPods.insert(m["name"]?.stringValue ?? "")
        }
        for (fwName, fwSize) in dynFwMap {
            if podLmPods.contains(fwName) { continue }
            ensure(fwName)
            agg[fwName]!.dynamicSize += fwSize
        }

        let podRes = store.loadOrEmpty("pod_resource.json")
        for podInfo in podRes["pods"]?.arrayValue ?? [] {
            let podName = podInfo["name"]?.stringValue ?? ""
            let resSize = (podInfo["files"]?.arrayValue ?? []).reduce(0) { $0 + ($1["size"]?.intValue ?? 0) }
            if resSize > 0 {
                ensure(podName)
                agg[podName]!.resourceSize += resSize
            }
        }

        var lmModulesByName: [String: JSONValue] = [:]
        for m in lm["modules"]?.arrayValue ?? [] {
            lmModulesByName[m["name"]?.stringValue ?? ""] = m
        }

        // 稳定的 total 降序
        let sortedNames = aggOrder.enumerated().sorted { a, b in
            let ta = agg[a.element]!.staticSize + agg[a.element]!.dynamicSize + agg[a.element]!.resourceSize
            let tb = agg[b.element]!.staticSize + agg[b.element]!.dynamicSize + agg[b.element]!.resourceSize
            if ta != tb { return ta > tb }
            return a.offset < b.offset
        }.map { $0.element }

        var modules: [JSONValue] = []
        var mainModule: JSONValue? = nil
        func moduleJSON(_ name: String, _ a: Agg, _ total: Int) -> JSONValue {
            .object([
                ("name", .string(name)), ("static_size", .int(a.staticSize)),
                ("dynamic_size", .int(a.dynamicSize)), ("resource_size", .int(a.resourceSize)),
                ("total", .int(total)), ("file_count", .int(a.fileCount)), ("manager", .string(a.manager)),
            ])
        }
        for name in sortedNames {
            let a = agg[name]!
            let total = a.staticSize + a.dynamicSize + a.resourceSize
            if total <= 0 { continue }
            // 主模块判定（复刻原逻辑，含 `name not in agg` —— 原始条件恒为假，故实际总走 else）
            if a.manager.isEmpty && a.dynamicSize == 0 && (agg[name] == nil) {
                if let lmMod = lmModulesByName[name] {
                    let files = lmMod["files"]?.arrayValue ?? []
                    let hasBuild = files.contains { ($0["path"]?.stringValue ?? "").contains(".build/") }
                    let hasPods = files.contains { ($0["path"]?.stringValue ?? "").contains("/Pods/") }
                    if !files.isEmpty && hasBuild && !hasPods {
                        mainModule = moduleJSON(name, a, total)
                        continue
                    }
                }
            }
            modules.append(moduleJSON(name, a, total))
        }

        var totalStatic = modules.reduce(0) { $0 + ($1["static_size"]?.intValue ?? 0) + ($1["resource_size"]?.intValue ?? 0) }
        var totalDynamic = modules.reduce(0) { $0 + ($1["dynamic_size"]?.intValue ?? 0) }
        if let mm = mainModule {
            totalStatic += (mm["static_size"]?.intValue ?? 0) + (mm["resource_size"]?.intValue ?? 0)
            totalDynamic += mm["dynamic_size"]?.intValue ?? 0
        }

        let result = JSONValue.object([
            ("meta", .object([
                ("total_code", .int(modules.reduce(0) { $0 + ($1["static_size"]?.intValue ?? 0) + ($1["dynamic_size"]?.intValue ?? 0) })),
                ("total_resource", .int(modules.reduce(0) { $0 + ($1["resource_size"]?.intValue ?? 0) })),
                ("total_static", .int(totalStatic)),
                ("total_dynamic", .int(totalDynamic)),
                ("total_size", .int(totalStatic + totalDynamic)),
            ])),
            ("modules", .array(modules)),
            ("main_module", mainModule ?? .null),
        ])
        try writeJSON(result, to: (store.outputDir as NSString).appendingPathComponent("module_breakdown.json"))
        return result
    }

    // MARK: 概览树

    /// 返回 (root, total, typeDist) 或 nil（复刻 build_overview_app_tree）。
    public static func buildOverviewAppTree(store: ReportStore) -> (root: JSONValue, total: Int, typeDist: [(String, Int)])? {
        guard let data = store.load("app_structure.json"),
              let root = data["root"], !(root["children"]?.arrayValue ?? []).isEmpty else {
            return nil
        }
        let total = data["total_size"]?.intValue ?? 0
        var distOrder: [String] = []
        var dist: [String: Int] = [:]
        func collect(_ node: JSONValue) {
            for child in node["children"]?.arrayValue ?? [] {
                if child["type"]?.stringValue == "dir" {
                    collect(child)
                } else {
                    let name = child["name"]?.stringValue ?? ""
                    let ext = name.contains(".") ? ("." + (name as NSString).pathExtension).lowercased() : ""
                    let label = ext.isEmpty ? "binary" : ext
                    if dist[label] == nil { distOrder.append(label) }
                    dist[label, default: 0] += child["size"]?.intValue ?? 0
                }
            }
        }
        collect(root)
        return (root, total, distOrder.map { ($0, dist[$0]!) })
    }

    // MARK: 工具

    static func writeJSON(_ v: JSONValue, to path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try enc.encode(v)
        try data.write(to: URL(fileURLWithPath: path))
    }
}

/// 时间戳工具。
public enum DateUtil {
    public static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
    public static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
