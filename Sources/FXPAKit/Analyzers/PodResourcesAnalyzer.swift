import Foundation

/// Pod 资源归因 —— 1:1 复刻 analyze_pod_resources.py（解析 *-resources.sh）。
public struct PodResourcesAnalyzer: Analyzer {
    public var outputFileName: String { "pod_resource.json" }
    public var displayName: String { "pod_resource_analyzer" }
    public var printSummary: ((Encodable) -> Void)? {
        { (r_: Encodable) in
            guard let r = r_ as? PodResourceResult else { return }
            Logger.plain("")
            Logger.plain(String(repeating: "=", count: 70))
            Logger.plain("  Pod 资源归因分析报告")
            Logger.plain(String(repeating: "=", count: 70))
            Logger.plain("  项目目录: \(r.meta.project_dir)")
            Logger.plain("  resources.sh 数: \(r.meta.resources_sh_count)")
            Logger.plain("  Pod 数: \(r.meta.pod_count)")
            Logger.plain("  资源文件数: \(r.meta.resource_count)")
            Logger.plain("  资源总大小: \(r.total_size_display)")
            Logger.plain("")
            if !r.pods.isEmpty {
                Logger.plain(String(repeating: "-", count: 70))
                Logger.plain("  Pod 资源排名 (Top 20)")
                Logger.plain(String(repeating: "-", count: 70))
                Logger.plain("  Pod 名                          大小         占比   文件数")
                Logger.plain("  ------------------------------ ---------- ------ ------")
                for p in r.pods.prefix(20) {
                    let pct = Double(p.size) / Double(max(r.total_size, 1)) * 100
                    Logger.plain("  " + String(p.name.prefix(28)).padding(toLength: 30, withPad: " ", startingAt: 0) + " " + ByteFormatter.fmt(p.size).padding(toLength: 10, withPad: " ", startingAt: 0) + " " + String(format: "%6.1f%%", pct) + " " + String(format: "%6d", p.file_count))
                }
                if r.pods.count > 20 { Logger.plain("  ... 还有 \(r.pods.count - 20) 个 Pod 未显示") }
                Logger.plain("")
            }
            if !r.by_category.isEmpty {
                Logger.plain(String(repeating: "-", count: 70))
                Logger.plain("  按类别分布")
                Logger.plain(String(repeating: "-", count: 70))
                for (cat, sz) in r.by_category.sorted(by: { $0.1 > $1.1 }) {
                    let pct = Double(sz) / Double(max(r.total_size, 1)) * 100
                    Logger.plain("  " + String(cat.prefix(20)).padding(toLength: 20, withPad: " ", startingAt: 0) + " " + ByteFormatter.fmt(sz).padding(toLength: 10, withPad: " ", startingAt: 0) + " " + String(format: "%6.1f%%", pct))
                }
                Logger.plain("")
            }
            Logger.plain(String(repeating: "=", count: 70))
        }
    }
    public var fallbackJSON: String { #"{"pods":[]}"# }

    private let config: PackageCheckConfig

    public init(config: PackageCheckConfig = .loadDefault()) {
        self.config = config
    }

    private func guessCategory(_ path: String) -> String {
        let ext = "." + (path as NSString).pathExtension.lowercased()
        if let c = config.extToCategory[ext] { return c }
        let base = (path as NSString).lastPathComponent
        if ext == ".bundle" || base.hasSuffix(".bundle") { return "bundle" }
        if (path as NSString).pathExtension.isEmpty { return "binary" }
        return "other"
    }

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let projectDir = context.projectDir, ResourceScanner.isDir(projectDir) else {
            throw AnalyzerError.missingInput("pod_resources 需要工程目录")
        }
        let fm = FileManager.default
        let absProject = URL(fileURLWithPath: projectDir).standardized.path

        // pods_root
        var podsRoot: String? = nil
        for c in [(absProject as NSString).appendingPathComponent("Pods"),
                  ((absProject as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Pods")] {
            if ResourceScanner.isDir(c) { podsRoot = c; break }
        }
        guard let podsRoot else {
            Logger.error("未找到 Pods 目录")
            return PodResourceResult(
                meta: .init(project_dir: absProject, pods_root: "", built_products_dir: context.builtProductsDir ?? "",
                            resources_sh_count: 0, pod_count: 0, resource_count: 0),
                total_size: 0, total_size_display: ByteFormatter.fmt(0),
                by_category: [:], by_target: [:], pods: [])
        }

        let builtProducts = context.builtProductsDir

        // pod_mapping → src_roots（解析变量）
        var srcRoots: [(String, String)] = []
        if let pmPath = context.podMappingPath, let data = try? Data(contentsOf: URL(fileURLWithPath: pmPath)),
           let pm = JSONValue.parse(data), let roots = pm["src_roots"]?.objectPairs {
            for (root, prodVal) in roots {
                var resolved = root
                resolved = resolved.replacingOccurrences(of: "${PODS_ROOT}", with: podsRoot).replacingOccurrences(of: "$PODS_ROOT", with: podsRoot)
                if let bp = builtProducts { resolved = resolved.replacingOccurrences(of: "${BUILT_PRODUCTS_DIR}", with: bp) }
                resolved = (resolved as NSString).standardizingPath
                srcRoots.append((resolved, prodVal.stringValue ?? ""))
            }
            Logger.info("加载 pod_mapping: \(srcRoots.count) 个 src_root")
        }

        // 找 *-resources.sh
        let tsfDir = (podsRoot as NSString).appendingPathComponent("Target Support Files")
        var shFiles: [String] = []
        var seenBase = Set<String>()
        if let en = fm.enumerator(atPath: tsfDir) {
            for case let rel as String in en {
                let base = (rel as NSString).lastPathComponent
                if base.hasSuffix("-resources.sh") && !seenBase.contains(base) {
                    seenBase.insert(base)
                    shFiles.append((tsfDir as NSString).appendingPathComponent(rel))
                }
            }
        }
        shFiles.sort()

        if shFiles.isEmpty {
            Logger.warn("未找到 *-resources.sh 文件")
            return PodResourceResult(
                meta: .init(project_dir: absProject, pods_root: podsRoot, built_products_dir: builtProducts ?? "",
                            resources_sh_count: 0, pod_count: 0, resource_count: 0),
                total_size: 0, total_size_display: ByteFormatter.fmt(0),
                by_category: [:], by_target: [:], pods: [])
        }

        Logger.info("找到 \(shFiles.count) 个 resources.sh:")
        for sh in shFiles { Logger.info("        \(sh)") }
        Logger.info("PODS_ROOT: \(podsRoot)")
        if let bp = builtProducts { Logger.info("BUILT_PRODUCTS_DIR: \(bp)") }

        // 解析每个 sh
        struct RawItem { var pod: String; var target: String; var rawPath: String }
        var raw: [RawItem] = []
        for sh in shFiles {
            let target = (((sh as NSString).lastPathComponent) as NSString).lastPathComponent.replacingOccurrences(of: "-resources.sh", with: "")
            guard let content = try? String(contentsOfFile: sh, encoding: .utf8) else { continue }
            var seen = Set<String>()
            let quoteRe = try! NSRegularExpression(pattern: #""([^"]+)""#)
            for line in content.components(separatedBy: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard l.hasPrefix("install_resource") else { continue }
                let ns = l as NSString
                guard let m = quoteRe.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { continue }
                let rawPath = ns.substring(with: m.range(at: 1))
                if seen.contains(rawPath) { continue }
                seen.insert(rawPath)
                let pod = extractPod(rawPath: rawPath, target: target, srcRoots: srcRoots, podsRoot: podsRoot, builtProducts: builtProducts) ?? "unknown"
                raw.append(RawItem(pod: pod, target: target, rawPath: rawPath))
            }
        }

        Logger.info("解析到 \(raw.count) 个资源条目")

        // 测量
        struct MItem { var pod: String; var target: String; var path: String; var size: Int; var category: String }
        var measured: [MItem] = []
        var notFound = 0
        for item in raw {
            let size = measureFile(item.rawPath, podsRoot: podsRoot, builtProducts: builtProducts)
            if size == 0 { notFound += 1; continue }
            measured.append(MItem(pod: item.pod, target: item.target, path: item.rawPath, size: size, category: guessCategory(item.rawPath)))
        }

        // 按 pod 聚合
        struct PodAgg { var size = 0; var order: [String] = []; var files: [String: Int] = [:]; var fileList: [MItem] = [] }
        var podOrder: [String] = []
        var podData: [String: PodAgg] = [:]
        for r in measured {
            if podData[r.pod] == nil { podData[r.pod] = PodAgg(); podOrder.append(r.pod) }
            podData[r.pod]!.size += r.size
            if podData[r.pod]!.files[r.path] == nil { podData[r.pod]!.order.append(r.path) }
            podData[r.pod]!.files[r.path, default: 0] += r.size
            podData[r.pod]!.fileList.append(r)
        }
        var pods: [PodResourcePod] = []
        for name in podOrder.sorted(by: { (podData[$0]!.size) > (podData[$1]!.size) }) {
            let agg = podData[name]!
            let files = agg.order.sorted { agg.files[$0]! > agg.files[$1]! }.map {
                PodResourceFile(path: $0, size: agg.files[$0]!, category: guessCategory($0))
            }
            var byCat: [String: Int] = [:]
            for f in files { byCat[f.category, default: 0] += f.size }
            pods.append(PodResourcePod(name: name, size: agg.size, file_count: files.count, files: files,
                                       by_category: byCat))
        }
        pods.sort { $0.size > $1.size }

        // by_category / by_target
        var byCat: [String: Int] = [:]
        for r in measured { byCat[r.category, default: 0] += r.size }
        var byTarget: [String: PodResourceTarget] = [:]
        var tgtPods: [String: Set<String>] = [:]
        var tgtSize: [String: Int] = [:]
        for r in measured { tgtSize[r.target, default: 0] += r.size; tgtPods[r.target, default: []].insert(r.pod) }
        for (t, size) in tgtSize {
            byTarget[t] = PodResourceTarget(size: size, pod_count: tgtPods[t]!.count, pods: Array(tgtPods[t]!).sorted())
        }

        if notFound > 0 { Logger.warn("\(notFound)/\(raw.count) 个资源文件未找到") }
        let total = measured.reduce(0) { $0 + $1.size }
        let podCount = Set(measured.map { $0.pod }).count
        Logger.info("归因成功 \(measured.count) 个资源，\(podCount) 个 Pod，总 \(ByteFormatter.fmt(total))")
        Logger.info("解析 \(shFiles.count) 个 resources.sh；归因 \(measured.count) 个资源 / \(podCount) 个 Pod，共 \(ByteFormatter.fmt(total))")
        return PodResourceResult(
            meta: .init(project_dir: absProject, pods_root: podsRoot, built_products_dir: builtProducts ?? "",
                        resources_sh_count: shFiles.count, pod_count: podCount, resource_count: measured.count),
            total_size: total, total_size_display: ByteFormatter.fmt(total),
            by_category: byCat, by_target: byTarget, pods: pods)
    }

    // MARK: 提取 Pod 名

    private func extractPod(rawPath: String, target: String, srcRoots: [(String, String)], podsRoot: String, builtProducts: String?) -> String? {
        if !target.hasPrefix("Pods-") { return target }
        if let resolved = resolvePath(rawPath, podsRoot: podsRoot, builtProducts: builtProducts) {
            for (root, prod) in srcRoots.sorted(by: { $0.0.count > $1.0.count }) {
                if resolved.hasPrefix(root + "/") || resolved == root { return prod }
            }
        }
        // 回退：从路径提取
        var s = rawPath
        for v in ["${PODS_ROOT}/", "${BUILT_PRODUCTS_DIR}/", "${PODS_CONFIGURATION_BUILD_DIR}/",
                  "$PODS_ROOT/", "$BUILT_PRODUCTS_DIR/", "$PODS_CONFIGURATION_BUILD_DIR/"] {
            if let r = s.range(of: v) { s = s.replacingCharacters(in: r, with: ""); break }
        }
        let parts = s.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." }
        if parts.isEmpty { return nil }
        let skip: Set<String> = ["Release-iphoneos", "Debug-iphoneos", "Release", "Debug", "Products"]
        if skip.contains(parts[0]) && parts.count > 1 { return parts[1] }
        return parts[0]
    }

    private func resolvePath(_ rawPath: String, podsRoot: String, builtProducts: String?) -> String? {
        var resolved = rawPath.replacingOccurrences(of: "${PODS_ROOT}", with: podsRoot).replacingOccurrences(of: "$PODS_ROOT", with: podsRoot)
        if let bp = builtProducts {
            resolved = resolved.replacingOccurrences(of: "${BUILT_PRODUCTS_DIR}", with: bp).replacingOccurrences(of: "$BUILT_PRODUCTS_DIR", with: bp)
            resolved = resolved.replacingOccurrences(of: "${PODS_CONFIGURATION_BUILD_DIR}", with: bp).replacingOccurrences(of: "$PODS_CONFIGURATION_BUILD_DIR", with: bp)
        }
        resolved = (resolved as NSString).standardizingPath
        return FileManager.default.fileExists(atPath: resolved) ? resolved : nil
    }

    private func measureFile(_ rawPath: String, podsRoot: String, builtProducts: String?) -> Int {
        var resolved = rawPath.replacingOccurrences(of: "${PODS_ROOT}", with: podsRoot).replacingOccurrences(of: "$PODS_ROOT", with: podsRoot)
        if let bp = builtProducts {
            resolved = resolved.replacingOccurrences(of: "${BUILT_PRODUCTS_DIR}", with: bp).replacingOccurrences(of: "$BUILT_PRODUCTS_DIR", with: bp)
            resolved = resolved.replacingOccurrences(of: "${PODS_CONFIGURATION_BUILD_DIR}", with: bp).replacingOccurrences(of: "$PODS_CONFIGURATION_BUILD_DIR", with: bp)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue {
            var total = 0
            if let en = FileManager.default.enumerator(atPath: resolved) {
                for case let rel as String in en {
                    let fp = (resolved as NSString).appendingPathComponent(rel)
                    var d: ObjCBool = false
                    if FileManager.default.fileExists(atPath: fp, isDirectory: &d), !d.boolValue {
                        total += ResourceScanner.fileSize(fp)
                    }
                }
            }
            return total
        }
        return ResourceScanner.fileSize(resolved)
    }
}
