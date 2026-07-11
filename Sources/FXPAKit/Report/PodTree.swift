import Foundation

/// 包管理 .o + 符号树构建 —— 1:1 复刻 lib/pod_tree.py。
public enum PodTree {
    /// 递归收集 app_structure 中所有 .bundle 目录子树。
    static func collectBundles(_ node: JSONValue, into result: inout [String: [JSONValue]]) {
        guard node["type"]?.stringValue == "dir" else { return }
        let name = node["name"]?.stringValue ?? ""
        if name.hasSuffix(".bundle") {
            result[name] = node["children"]?.arrayValue ?? []
            return
        }
        for child in node["children"]?.arrayValue ?? [] {
            collectBundles(child, into: &result)
        }
    }

    /// 解析 .o 路径 → (显示名, 类型扩展)。保留 inner[:-2] 怪癖。
    static func parseOPath(_ path: String) -> (String, String) {
        if let re = try? NSRegularExpression(pattern: #"\(([^)]+\.o)\)$"#),
           let m = re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
           m.numberOfRanges > 1 {
            let inner = (path as NSString).substring(with: m.range(at: 1))
            if inner.hasSuffix(".o") {
                return (String(inner.dropLast(2)), ".o")
            }
            let ext = ("." + (inner as NSString).pathExtension)
            return (inner, (inner as NSString).pathExtension.isEmpty ? ".o" : ext)
        }
        let basename = (path as NSString).lastPathComponent
        if basename.hasSuffix(".o") {
            return (String(basename.dropLast(2)), ".o")
        }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        return (name, ext.isEmpty ? ".o" : "." + ext)
    }

    /// 从 linkmap.json 构建模块 .o + 符号树（静态/动态通用）。返回 JSONValue 或 nil。
    static func buildODetailTree(_ moduleName: String, store: ReportStore) -> JSONValue? {
        var treeChildren: [JSONValue] = []

        if let lm = store.load("linkmap.json") {
            var candidates: Set<String> = [moduleName]
            if let pm = store.load("pod_mapping.json") {
                if let entry = pm[moduleName], let p = entry["pod"]?.stringValue, !p.isEmpty {
                    candidates.insert(p)
                }
                for (prod, info) in pm.objectPairs ?? [] {
                    if info["pod"]?.stringValue == moduleName { candidates.insert(prod) }
                }
            }
            // 遍历 modules，优先 _pod_linkmap
            var match: JSONValue? = nil
            for m in lm["modules"]?.arrayValue ?? [] {
                guard let name = m["name"]?.stringValue, candidates.contains(name) else { continue }
                if m["_pod_linkmap"]?.boolValue == true { match = m; break }
                if match == nil { match = m }
            }
            if let match, let files = match["files"]?.arrayValue, !files.isEmpty {
                var oKids: [JSONValue] = []
                for f in files {
                    let (name, typ) = parseOPath(f["path"]?.stringValue ?? "")
                    var symKids: [JSONValue] = []
                    for s in f["symbols"]?.arrayValue ?? [] {
                        let nm = s["name"]?.stringValue ?? ""
                        let st: String
                        if nm.hasPrefix("-[") { st = "sym_objc" }
                        else if nm.hasPrefix("+[") { st = "sym_objc" }
                        else if String(nm.prefix(8)).contains("$s") { st = "sym_swift" }
                        else { st = "sym_c" }
                        symKids.append(.object([
                            ("name", .string(nm)), ("type", .string(st)), ("size", .int(s["size"]?.intValue ?? 0)),
                        ]))
                    }
                    oKids.append(.object([
                        ("name", .string(name)), ("type", .string(typ)),
                        ("size", .int(f["size"]?.intValue ?? 0)),
                        ("children", .array(symKids)),
                    ]))
                }
                treeChildren.append(.object([
                    ("name", .string(".o 文件 (\(files.count))")), ("type", .string("dir")),
                    ("size", .int(match["size"]?.intValue ?? 0)), ("children", .array(oKids)),
                ]))
            }
        }

        if let pr = store.load("pod_resource.json") {
            for p in pr["pods"]?.arrayValue ?? [] {
                guard p["name"]?.stringValue == moduleName else { continue }
                let resFiles = p["files"]?.arrayValue ?? []
                if !resFiles.isEmpty {
                    var bundleSubtrees: [String: [JSONValue]] = [:]
                    if let app = store.load("app_structure.json") {
                        for c in app["root"]?["children"]?.arrayValue ?? [] {
                            collectBundles(c, into: &bundleSubtrees)
                        }
                    }
                    var rKids: [JSONValue] = []
                    for f in resFiles {
                        let fpath = f["path"]?.stringValue ?? ""
                        let name = fpath.split(separator: "/").last.map(String.init) ?? fpath
                        let ext = "." + (fpath as NSString).pathExtension
                        let hasExt = !(fpath as NSString).pathExtension.isEmpty
                        var children: [JSONValue] = []
                        if hasExt && ext == ".bundle" {
                            let bundleKey = fpath.split(separator: "/").last.map(String.init) ?? ""
                            if let sub = bundleSubtrees[bundleKey] { children = sub }
                        }
                        rKids.append(.object([
                            ("name", .string(name)),
                            ("type", .string(hasExt ? ext : "")),
                            ("size", .int(f["size"]?.intValue ?? 0)),
                            ("children", children.isEmpty ? .null : .array(children)),
                        ]))
                    }
                    let resTotal = resFiles.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) }
                    treeChildren.append(.object([
                        ("name", .string("资源文件 (\(resFiles.count))")), ("type", .string("dir")),
                        ("size", .int(resTotal)), ("children", .array(rKids)),
                    ]))
                }
                break
            }
        }

        if treeChildren.isEmpty { return nil }
        let total = treeChildren.reduce(0) { $0 + ($1["size"]?.intValue ?? 0) }
        return .object([
            ("name", .string(moduleName)), ("type", .string("dir")),
            ("size", .int(total)), ("children", .array(treeChildren)),
        ])
    }

    /// 从 app_structure.json 构建动态库基础树（回退用）。
    static func buildDynamicDetailTree(_ fwName: String, store: ReportStore) -> JSONValue? {
        guard let app = store.load("app_structure.json") else { return nil }
        for c in app["root"]?["children"]?.arrayValue ?? [] {
            if c["name"]?.stringValue == "Frameworks" && c["type"]?.stringValue == "dir" {
                for fw in c["children"]?.arrayValue ?? [] {
                    if fw["name"]?.stringValue == fwName + ".framework" {
                        return .object([
                            ("name", .string(fwName)), ("type", .string("dir")),
                            ("size", .int(fw["size"]?.intValue ?? 0)),
                            ("children", fw["children"] ?? .array([])),
                        ])
                    }
                }
            }
        }
        return nil
    }
}
