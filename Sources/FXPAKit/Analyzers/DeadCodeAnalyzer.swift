import Foundation

/// 无用代码检测 —— 1:1 复刻 analyze_dead_code.py（Periphery + LinkMap 关联）。
public struct DeadCodeAnalyzer: Analyzer {
    public var outputFileName: String { "dead_code.json" }
    public var displayName: String { "dead_code_detector" }
    public var printSummary: ((Encodable) -> Void)? {
        { (r_: Encodable) in
            guard let r = r_ as? DeadCodeResult else { return }
            let s = r.summary
            Logger.plain("")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  无用代码检测")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  Periphery: \(s.periphery_installed ? "✅ 可用" : "❌ 未安装")")
            Logger.plain("  LinkMap:   \(s.linkmap_available ? "✅ 已加载" : "⚠️  未提供")")
            Logger.plain("  未使用项:  \(s.total_unused_items)")
            Logger.plain("  预估节省:  \(ByteFormatter.fmt(s.total_estimated_savings))")
            Logger.plain("")
            if let byKind = s.by_kind, !byKind.isEmpty {
                Logger.plain("  类型           数量")
                Logger.plain("  ------------ ------")
                for (k, c) in byKind.sorted(by: { $0.1 > $1.1 }).prefix(10) {
                    Logger.plain("  " + String(k.prefix(10)).padding(toLength: 12, withPad: " ", startingAt: 0) + " " + String(format: "%6d", c))
                }
                Logger.plain("")
            }
            Logger.plain(String(repeating: "=", count: 60))
        }
    }
    public var fallbackJSON: String { #"{"unused_items":[]}"# }

    public let config: PackageCheckConfig

    public init(config: PackageCheckConfig) {
        self.config = config
    }

    static let kindLabels: [String: String] = [
        "class": "类", "struct": "结构体", "enum": "枚举", "protocol": "协议",
        "typealias": "类型别名", "extension": "扩展",
        "function.instance": "实例方法", "function.static": "静态方法",
        "function.class": "类方法", "function.free": "自由函数",
        "variable.instance": "实例变量", "variable.static": "静态变量",
        "variable.class": "类变量", "variable.free": "自由变量",
        "property.instance": "实例属性", "property.static": "静态属性", "property.class": "类属性",
        "initializer": "初始化器", "deinitializer": "反初始化器",
        "subscript": "下标", "case": "枚举值",
        "associatedtype": "关联类型", "genericTypeParam": "泛型参数", "enumelement": "枚举元素",
    ]

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let projectDir = context.projectDir, ResourceScanner.isDir(projectDir) else {
            throw AnalyzerError.missingInput("dead_code 需要工程目录")
        }
        let fm = FileManager.default

        // 检测工程
        var projType = "", projPath = ""
        for name in (try? fm.contentsOfDirectory(atPath: projectDir)) ?? [] {
            let full = (projectDir as NSString).appendingPathComponent(name)
            if name.hasSuffix(".xcworkspace") && ResourceScanner.isDir(full) { projType = "workspace"; projPath = full; break }
            if name.hasSuffix(".xcodeproj") && ResourceScanner.isDir(full) { projType = "project"; projPath = full }
        }

        Logger.info("开始无用代码检测 ...")

        // Periphery 是否安装
        var peripheryVersion = ""
        if let r = try? Shell.run("/usr/bin/env", ["periphery", "version"], timeout: 10), r.ok {
            peripheryVersion = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let peripheryInstalled = !peripheryVersion.isEmpty
        if peripheryInstalled {
            Logger.info("Periphery 版本: \(peripheryVersion)")
        } else {
            Logger.warn("Periphery 未安装，将使用 LinkMap 启发式分析")
            Logger.info("安装方式: brew install peripheryapp/periphery/periphery")
        }

        var unusedItems: [DeadCodeItem] = []
        if peripheryInstalled {
            if projPath.isEmpty {
                Logger.error("未找到 .xcodeproj 或 .xcworkspace")
            } else {
                let scheme = context.scheme ?? autoDetectScheme(projPath: projPath, projType: projType, projectDir: projectDir)
                if let scheme, !scheme.isEmpty { Logger.info("自动推断 scheme: \(scheme)") }
                var cmd = ["periphery", "scan", "--format", "json", "--quiet"]
                cmd += (projType == "workspace") ? ["--workspace", projPath] : ["--project", projPath]
                if let scheme, !scheme.isEmpty { cmd += ["--schemes", scheme] }
                Logger.info("检测到 Periphery，执行扫描 ...")
                Logger.info("运行: \(cmd.joined(separator: " "))")
                do {
                    let r = try Shell.run("/usr/bin/env", cmd, currentDirectory: projectDir, timeout: 600)
                    if r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Logger.warn("Periphery 无输出，stderr: \(String(r.stderr.prefix(500)))")
                    } else {
                        unusedItems = parsePeriphery(r.stdout, projectDir: projectDir)
                    }
                } catch Shell.ShellError.timedOut {
                    Logger.error("Periphery 扫描超时（10 分钟）")
                } catch Shell.ShellError.launchFailed {
                    Logger.error("Periphery 未找到")
                } catch {
                    Logger.error("Periphery 执行失败: \(error)")
                }
            }
        }

        // LinkMap 符号大小关联
        var linkmapSymbols: [String: Int] = [:]
        let lmPath = context.linkmapPath
        if let lmPath, fm.fileExists(atPath: lmPath) {
            Logger.info("加载 LinkMap: \(lmPath)")
            let parser = LinkMapParser(path: lmPath)
            if (try? parser.parse()) != nil {
                for sym in parser.symbols where !sym.name.isEmpty && sym.size > 0 {
                    linkmapSymbols[sym.name, default: 0] += sym.size
                }
                Logger.info("LinkMap 解析完成: \(linkmapSymbols.count) 个符号")
            }
        }
        if !linkmapSymbols.isEmpty {
            for i in unusedItems.indices {
                let name = unusedItems[i].name, kind = unusedItems[i].kind
                var total = 0, matched = 0
                for (symName, size) in linkmapSymbols where symbolMatches(symName, name, kind) {
                    total += size; matched += 1
                }
                if matched > 0 { unusedItems[i].estimated_size = total; unusedItems[i].matched_symbols = matched }
            }
            let totalMatched = unusedItems.filter { ($0.matched_symbols ?? 0) > 0 }.count
            if totalMatched > 0 {
                Logger.info("关联 LinkMap: \(totalMatched)/\(unusedItems.count) 项匹配到符号大小")
            }
        }

        Logger.info("Periphery: \(peripheryInstalled ? "可用" : "未安装")；LinkMap: \(linkmapSymbols.isEmpty ? "未提供" : "已加载(\(linkmapSymbols.count) 符号)")；未使用项 \(unusedItems.count)")
        // summary
        var byKind: [String: Int] = [:]
        var byModule: [String: CodableModuleStat] = [:]
        for it in unusedItems {
            byKind[it.kind_label, default: 0] += 1
            var s = byModule[it.module] ?? CodableModuleStat(count: 0, size: 0)
            s.count += 1; s.size += it.estimated_size
            byModule[it.module] = s
        }
        let totalEstimated = unusedItems.reduce(0) { $0 + $1.estimated_size }
        Logger.success("检测完成，发现 \(unusedItems.count) 个未使用代码项")

        return DeadCodeResult(
            meta: .init(project_dir: URL(fileURLWithPath: projectDir).standardized.path, scheme: context.scheme,
                        periphery_installed: peripheryInstalled, linkmap_path: lmPath, generated_at: DateUtil.now()),
            summary: .init(total_unused_items: unusedItems.count, total_estimated_savings: totalEstimated,
                           periphery_installed: peripheryInstalled, linkmap_available: !linkmapSymbols.isEmpty,
                           by_kind: byKind, by_module: byModule),
            unused_items: unusedItems)
    }

    private func parsePeriphery(_ raw: String, projectDir: String) -> [DeadCodeItem] {
        var items: [JSONValue] = []
        if let data = raw.data(using: .utf8), let v = JSONValue.parse(data) {
            if let arr = v.arrayValue { items = arr }
            else if let results = v["results"]?.arrayValue ?? v["unused"]?.arrayValue { items = results }
        } else {
            // line-delimited JSON
            for line in raw.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if let d = t.data(using: .utf8), let v = JSONValue.parse(d) { items.append(v) }
            }
        }
        var result: [DeadCodeItem] = []
        for item in items {
            let name = item["name"]?.stringValue ?? item["identifier"]?.stringValue ?? ""
            if name.isEmpty { continue }
            let kind = item["kind"]?.stringValue ?? item["type"]?.stringValue ?? "unknown"
            let loc = item["location"]
            let filepath = loc?["file"]?.stringValue ?? loc?["filename"]?.stringValue ?? ""
            let line = loc?["line"]?.intValue ?? 0
            var hints: [String] = []
            if let h = item["hints"]?.arrayValue ?? item["reasons"]?.arrayValue { hints = h.compactMap { $0.stringValue } }
            result.append(DeadCodeItem(name: name, kind: kind, kind_label: Self.kindLabels[kind] ?? kind,
                                       file: filepath, line: line, hints: hints, estimated_size: 0,
                                       module: guessModule(filepath, projectDir: projectDir), matched_symbols: nil))
        }
        return result
    }

    private func guessModule(_ filepath: String, projectDir: String) -> String {
        if filepath.isEmpty { return "Unknown" }
        if let r = filepath.range(of: "/Pods/") {
            let after = filepath[r.upperBound...]
            if let end = after.firstIndex(of: "/") { return String(after[..<end]) }
        }
        if let r = filepath.range(of: ".framework/") {
            if let slash = filepath[..<r.lowerBound].lastIndex(of: "/") {
                return String(filepath[filepath.index(after: slash)..<r.lowerBound])
            }
        }
        return (projectDir as NSString).lastPathComponent
    }

    private func symbolMatches(_ symName: String, _ itemName: String, _ itemKind: String) -> Bool {
        if ["function.instance", "function.class", "function.static"].contains(itemKind) {
            if symName.contains("[\(itemName) ") || symName.contains("[\(itemName)]") { return true }
            let parts = itemName.split(separator: ".")
            if parts.count >= 2 { if symName.contains("[\(parts[0]) \(parts.last!)]") { return true } }
        }
        if ["class", "struct", "enum", "protocol"].contains(itemKind) {
            if symName.contains(itemName) { return true }
            if symName.contains(" \(itemName)") || symName.contains(".\(itemName)") { return true }
        }
        if ["variable.instance", "variable.static", "property.instance", "property.static"].contains(itemKind) {
            if let last = itemName.split(separator: ".").last, symName.contains(String(last)) { return true }
        }
        return false
    }

    private func autoDetectScheme(projPath: String, projType: String, projectDir: String) -> String? {
        guard let raw = try? Shell.xcodebuild(["-" + projType, projPath, "-list"]).stdout else { return nil }
        var schemes: [String] = []; var inSchemes = false
        for line in raw.components(separatedBy: "\n") {
            if line.contains("Schemes:") { inSchemes = true; continue }
            if inSchemes {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.isEmpty || s.contains(":") { inSchemes = false; continue }
                if !s.hasPrefix("Pods-") { schemes.append(s) }
            }
        }
        let projName = (projectDir as NSString).lastPathComponent
        if let m = schemes.first(where: { $0.lowercased().contains(projName.lowercased()) }) { return m }
        return schemes.max(by: { $0.count < $1.count })
    }
}
