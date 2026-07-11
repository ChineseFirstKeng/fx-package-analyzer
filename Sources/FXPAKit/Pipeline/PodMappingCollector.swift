import Foundation

/// Pod 映射采集 —— 1:1 复刻 helpers/collect_pod_mapping.py（并行 -showBuildSettings）。
public struct PodMappingCollector {
    public enum ProjType: String { case workspace, project }

    /// 采集并写出 pod_mapping.json，返回映射（PRODUCT_NAME → info）。
    @discardableResult
    public static func collect(projType: ProjType, projPath: String, outputPath: String) throws -> JSONValue {
        // 1. 获取 scheme
        let listResult = try Shell.xcodebuild(["-" + projType.rawValue, projPath, "-list"])
        var schemes: [String] = []
        var inSchemes = false
        for line in listResult.stdout.components(separatedBy: "\n") {
            if line.contains("Schemes:") { inSchemes = true; continue }
            if inSchemes {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.isEmpty { break }
                if s.contains("Privacy") { continue }
                schemes.append(s)
            }
        }

        let maxWorkers = min(8, max(schemes.count, 1))
        Logger.info("[Pod映射] 共 \(schemes.count) 个 scheme，并行 \(maxWorkers) 路...")

        // 2. 并行查询 build settings
        struct Row { let prod: String?; let machO: String?; let podSrc: String? }
        var rows = [Row?](repeating: nil, count: schemes.count)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxWorkers
        let lock = NSLock()
        for (i, s) in schemes.enumerated() {
            queue.addOperation {
                let q = queryScheme(projType: projType, projPath: projPath, scheme: s)
                let row = Row(prod: q.prod, machO: q.machO, podSrc: q.podSrc)
                lock.lock(); rows[i] = row; lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        // 3. 汇总（顺序按 scheme 列表，稳定）
        var mapping: [(String, JSONValue)] = []
        var srcRoots: [(String, JSONValue)] = []
        var srcRootSeen = Set<String>()
        for row in rows {
            guard let row, let prod = row.prod, !prod.isEmpty, let machO = row.machO, !machO.isEmpty else { continue }
            var manager = ""
            var srcRoot = ""
            if let podSrc = row.podSrc, !podSrc.isEmpty {
                srcRoot = podSrc.hasSuffix("/") ? String(podSrc.reversed().drop(while: { $0 == "/" }).reversed()) : podSrc
                manager = "cocoapods"
                if !srcRootSeen.contains(srcRoot) {
                    srcRootSeen.insert(srcRoot)
                    srcRoots.append((srcRoot, .string(prod)))
                }
            }
            mapping.append((prod, .object([
                ("manager", .string(manager)),
                ("src_root", .string(srcRoot)),
                ("mach_o_type", .string(machO)),
            ])))
        }

        // 输出：{src_roots:{...}, ...mapping}
        var out: [(String, JSONValue)] = [("src_roots", .object(srcRoots))]
        out.append(contentsOf: mapping)
        let output = JSONValue.object(out)
        try Generators.writeJSON(output, to: outputPath)
        Logger.info("[Pod映射] \(mapping.count) 条 → \(outputPath)")
        return output
    }

    private static func queryScheme(projType: ProjType, projPath: String, scheme: String) -> (prod: String?, machO: String?, podSrc: String?) {
        guard let r = try? Shell.xcodebuild(
            ["-" + projType.rawValue, projPath, "-scheme", scheme, "-showBuildSettings"],
            timeout: 30) else {
            return (nil, nil, nil)
        }
        var prod: String? = nil, machO: String? = nil, podSrc: String? = nil
        for line in r.stdout.components(separatedBy: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("PRODUCT_NAME = ") && !s.contains("FULL_PRODUCT_NAME") {
                prod = valueAfterEqual(s)
            } else if s.hasPrefix("MACH_O_TYPE = ") {
                machO = valueAfterEqual(s)
            } else if s.hasPrefix("PODS_TARGET_SRCROOT = ") {
                podSrc = valueAfterEqual(s)
            }
        }
        return (prod, machO, podSrc)
    }

    /// 取 "= " 之后的值（对齐 split('= ', 1)[1]）。
    private static func valueAfterEqual(_ s: String) -> String {
        guard let range = s.range(of: "= ") else { return "" }
        return String(s[range.upperBound...])
    }
}
