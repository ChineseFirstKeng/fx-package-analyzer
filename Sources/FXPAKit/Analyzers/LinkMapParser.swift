import Foundation

/// LinkMap 解析器 —— 1:1 复刻 analyze_linkmap.py。
/// 性能关键：直接在 UTF-8 字节上单遍解析（Swift String 的字素索引对 64MB 文件极慢）。
final class LinkMapParser {
    let path: String
    private(set) var objectFiles: [Int: String] = [:]
    private(set) var objectFileCount = 0
    private var sectionOrder: [String] = []
    private var sectionSize: [String: Int] = [:]
    private var sectionRanges: [(Int, Int, String)] = []
    struct Sym { let address: Int; let size: Int; let fileID: Int?; let name: String }
    private(set) var symbols: [Sym] = []
    private(set) var totalSize = 0

    /// file_id → 模块名 记忆表（guessModule 只按文件算一次）。
    private var fileModuleCache: [Int: String] = [:]

    init(path: String) { self.path = path }

    // 字节常量
    private static let NL: UInt8 = 0x0A, CR: UInt8 = 0x0D, TAB: UInt8 = 0x09
    private static let HASH: UInt8 = 0x23, LB: UInt8 = 0x5B, RB: UInt8 = 0x5D, SP: UInt8 = 0x20

    private enum State { case none, objects, sections, symbols }

    // MARK: 解析入口（单遍字节扫描）

    @discardableResult
    func parse() throws -> LinkMapParser {
        guard FileManager.default.fileExists(atPath: path) else {
            throw AnalyzerError.missingInput("LinkMap 文件不存在: \(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let bytes = [UInt8](data)
        let n = bytes.count
        var state: State = .none
        var totalFromSymbols = 0

        var lineStart = 0
        var i = 0
        while i <= n {
            if i == n || bytes[i] == Self.NL {
                var lineEnd = i
                if lineEnd > lineStart && bytes[lineEnd - 1] == Self.CR { lineEnd -= 1 }
                if lineEnd > lineStart || i < n {
                    processLine(bytes, lineStart, lineEnd, state: &state, totalFromSymbols: &totalFromSymbols)
                }
                lineStart = i + 1
            }
            i += 1
        }

        if objectFileCount == 0 {
            Logger.warn("未找到 Object files 段")
        }
        if totalSize == 0 {
            Logger.info("从 Sections 表未获取到数据，将从符号表汇总")
            totalSize = totalFromSymbols
        }
        Logger.info("解析到 \(objectFileCount) 个目标文件(.o)")
        Logger.info("二进制总大小: \(fmtSize(totalSize))")
        Logger.info("解析到 \(symbols.count) 个符号")
        Logger.info("符号总大小: \(fmtSize(totalFromSymbols))")
        // 统计无法关联到源文件的符号数（symbols with nil fileID）
        let unlinkedCount = symbols.filter { $0.fileID == nil }.count
        if unlinkedCount > 0 {
            Logger.info("\(unlinkedCount) 个符号无法关联到源文件（可能为链接器合成）")
        }
        // 不在此处 buildFileModuleCache()：对齐 Python —— _guess_module 仅在 get_modules()
        // 等真正需要模块信息时才调用，避免仅 parse 不需要模块时打出不必要的 WARN
        return self
    }

    private func fmtSize(_ b: Int) -> String {
        if b >= 1_048_576 { return String(format: "%.2f MB", Double(b) / 1_048_576.0) }
        if b >= 1024 { return String(format: "%.2f KB", Double(b) / 1024.0) }
        return "\(b) B"
    }

    /// 处理单行（[lo, hi) 字节区间，不含换行）。
    private func processLine(_ b: [UInt8], _ lo: Int, _ hi: Int, state: inout State, totalFromSymbols: inout Int) {
        if lo >= hi { return }
        // 注释/标题行
        if b[lo] == Self.HASH {
            if matchHeader(b, lo, hi, "# Object files:") || matchHeader(b, lo, hi, "# Objects:") {
                state = .objects
            } else if matchHeader(b, lo, hi, "# Sections:") {
                state = .sections
            } else if matchHeader(b, lo, hi, "# Symbols:") {
                state = .symbols
            } else if matchHeader(b, lo, hi, "# Dead Stripped Symbols") || matchHeader(b, lo, hi, "# Source Files") {
                // 结束符号块（objects/sections 不会遇到）
                state = .none
            }
            // 其他 # 行（如列标题 "# Address Size Segment Section"）：忽略，保持当前块
            return
        }

        switch state {
        case .objects:
            if let (id, rlo, rhi) = parseBracket(b, lo, hi) {
                let pathStr = string(b, rlo, trimEnd(b, rlo, rhi))
                if pathStr.isEmpty { return }
                if objectFiles[id] == nil { objectFileCount += 1 }
                objectFiles[id] = pathStr
            }
        case .sections:
            // trim + split by tab
            var s = lo; var e = hi
            while s < e && b[s] == Self.SP { s += 1 }
            while e > s && b[e - 1] == Self.SP { e -= 1 }
            let fields = splitTabs(b, s, e, max: 4)
            if fields.count >= 4 {
                guard let addr = hexInt(b, fields[0].0, fields[0].1),
                      let size = hexInt(b, fields[1].0, fields[1].1) else { return }
                let section = string(b, fields[2].0, fields[2].1) + "," + string(b, fields[3].0, fields[3].1)
                if sectionSize[section] == nil { sectionOrder.append(section) }
                sectionSize[section, default: 0] += size
                sectionRanges.append((addr, addr + size, section))
                totalSize += size
            }
        case .symbols:
            // 跳过前导空白
            var s = lo
            while s < hi && (b[s] == Self.SP || b[s] == Self.TAB) { s += 1 }
            if s >= hi || b[s] == Self.HASH { return }
            // addr \t size \t rest
            let fields = splitTabs(b, s, hi, max: 3)
            if fields.count < 3 { return }
            guard let address = hexInt(b, fields[0].0, fields[0].1),
                  let size = hexInt(b, fields[1].0, fields[1].1) else { return }
            let rlo = fields[2].0, rhi = fields[2].1
            if let (id, nlo, nhi) = parseBracket(b, rlo, rhi) {
                symbols.append(Sym(address: address, size: size, fileID: id, name: string(b, nlo, nhi)))
            } else {
                // 无 file_id 的符号：名字未被后续使用，存空串省内存
                symbols.append(Sym(address: address, size: size, fileID: nil, name: ""))
            }
            totalFromSymbols += size
        case .none:
            break
        }
    }

    // MARK: 字节工具

    private func matchHeader(_ b: [UInt8], _ lo: Int, _ hi: Int, _ ascii: String) -> Bool {
        let pat = Array(ascii.utf8)
        if hi - lo < pat.count { return false }
        for k in 0..<pat.count where b[lo + k] != pat[k] { return false }
        return true
    }

    /// 从 [lo,hi) 解析 `[  N] ...` → (id, restLo, restHi)。
    private func parseBracket(_ b: [UInt8], _ lo: Int, _ hi: Int) -> (Int, Int, Int)? {
        var i = lo
        while i < hi && b[i] == Self.SP { i += 1 }
        guard i < hi && b[i] == Self.LB else { return nil }
        i += 1
        var num = 0; var hasDigit = false
        while i < hi && b[i] != Self.RB {
            let c = b[i]
            if c == Self.SP { i += 1; continue }
            if c < 0x30 || c > 0x39 { return nil }
            num = num * 10 + Int(c - 0x30); hasDigit = true
            i += 1
        }
        guard i < hi, b[i] == Self.RB, hasDigit else { return nil }
        i += 1  // 跳过 ]
        while i < hi && b[i] == Self.SP { i += 1 }
        return (num, i, hi)
    }

    /// 十六进制解析（支持 0x 前缀）。
    private func hexInt(_ b: [UInt8], _ lo: Int, _ hi: Int) -> Int? {
        var s = lo, e = hi
        while s < e && b[s] == Self.SP { s += 1 }
        while e > s && b[e - 1] == Self.SP { e -= 1 }
        if e - s >= 2 && b[s] == 0x30 && (b[s+1] == 0x78 || b[s+1] == 0x58) { s += 2 }
        if s >= e { return nil }
        var v = 0
        for k in s..<e {
            let c = b[k]
            let d: Int
            switch c {
            case 0x30...0x39: d = Int(c - 0x30)
            case 0x61...0x66: d = Int(c - 0x61 + 10)
            case 0x41...0x46: d = Int(c - 0x41 + 10)
            default: return nil
            }
            v = v << 4 | d
        }
        return v
    }

    /// 按 tab 切分，最多 max 段（最后一段含剩余 tab）。返回各段 [lo,hi)。
    private func splitTabs(_ b: [UInt8], _ lo: Int, _ hi: Int, max: Int) -> [(Int, Int)] {
        var res: [(Int, Int)] = []
        var segStart = lo
        var i = lo
        while i < hi {
            if b[i] == Self.TAB && res.count < max - 1 {
                res.append((segStart, i))
                segStart = i + 1
            }
            i += 1
        }
        res.append((segStart, hi))
        return res
    }

    private func trimEnd(_ b: [UInt8], _ lo: Int, _ hi: Int) -> Int {
        var e = hi
        while e > lo && (b[e - 1] == Self.SP || b[e - 1] == Self.TAB) { e -= 1 }
        return e
    }

    private func string(_ b: [UInt8], _ lo: Int, _ hi: Int) -> String {
        if lo >= hi { return "" }
        return String(decoding: b[lo..<hi], as: UTF8.self)
    }

    // MARK: 按文件归类记忆

    private func buildFileModuleCache() {
        guard fileModuleCache.isEmpty else { return }
        for (id, p) in objectFiles { fileModuleCache[id] = Self.guessModule(p) }
    }

    /// 确保 fileModuleCache 已构建（懒加载，对齐 Python —— 仅在需要时调 guessModule）。
    private func ensureModuleCache() {
        if fileModuleCache.isEmpty { buildFileModuleCache() }
    }

    // MARK: 输出

    func sectionsDict() -> [String: Int] { sectionSize }

    func getModules() -> [LinkMapModule] {
        ensureModuleCache()
        final class FileAgg { var size = 0; var symbols: [LinkMapSymbol] = [] }
        final class ModAgg { var size = 0; var fileOrder: [String] = []; var files: [String: FileAgg] = [:] }
        var order: [String] = []
        var mods: [String: ModAgg] = [:]

        for sym in symbols {
            guard let fid = sym.fileID, let filePath = objectFiles[fid],
                  let moduleName = fileModuleCache[fid] else { continue }
            let m: ModAgg
            if let existing = mods[moduleName] { m = existing }
            else { m = ModAgg(); mods[moduleName] = m; order.append(moduleName) }
            m.size += sym.size
            let f: FileAgg
            if let existing = m.files[filePath] { f = existing }
            else { f = FileAgg(); m.files[filePath] = f; m.fileOrder.append(filePath) }
            f.size += sym.size
            f.symbols.append(LinkMapSymbol(name: sym.name, size: sym.size))
        }

        let indexed = order.enumerated().map { ($0.offset, $0.element) }
        let sortedMods = indexed.sorted { a, b in
            let sa = mods[a.1]!.size, sb = mods[b.1]!.size
            if sa != sb { return sa > sb }
            return a.0 < b.0
        }
        var result: [LinkMapModule] = []
        for (_, name) in sortedMods {
            let agg = mods[name]!
            let fIndexed = agg.fileOrder.enumerated().map { ($0.offset, $0.element) }
            let fSorted = fIndexed.sorted { a, b in
                let sa = agg.files[a.1]!.size, sb = agg.files[b.1]!.size
                if sa != sb { return sa > sb }
                return a.0 < b.0
            }
            var files: [LinkMapModuleFile] = []
            for (_, p) in fSorted {
                let fa = agg.files[p]!
                let syms = Self.stableSortBySizeDesc(fa.symbols) { $0.size }
                files.append(LinkMapModuleFile(path: p, size: fa.size, symbols: syms))
            }
            let libType = Self.detectLibType(Array(agg.fileOrder))
            result.append(LinkMapModule(name: name, size: agg.size, file_count: files.count,
                                        files: files, lib_type: libType))
        }
        return result
    }

    func getFileTree() -> LinkMapTreeNode {
        var fileSizeOrder: [String] = []
        var fileSize: [String: Int] = [:]
        for sym in symbols {
            guard let fid = sym.fileID, let p = objectFiles[fid] else { continue }
            if fileSize[p] == nil { fileSizeOrder.append(p) }
            fileSize[p, default: 0] += sym.size
        }
        if fileSize.isEmpty {
            return LinkMapTreeNode(name: "LinkMap", type: "dir", size: 0, children: [])
        }
        let allParts = fileSizeOrder.map { p in p.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." } }
        var prefixLen = 0
        let minLen = allParts.map { $0.count }.min() ?? 0
        for i in 0..<minLen {
            let set = Set(allParts.map { $0[i] })
            if set.count == 1 { prefixLen = i + 1 } else { break }
        }

        final class DirBuilder {
            var name: String; var size = 0
            var childOrder: [String] = []
            var children: [String: DirBuilder] = [:]
            var leaf: LinkMapTreeNode? = nil
            init(_ n: String) { name = n }
        }
        let root = DirBuilder("LinkMap")
        for p in fileSizeOrder {
            let size = fileSize[p]!
            var parts = p.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." }
            if parts.count > prefixLen { parts = Array(parts[prefixLen...]) } else { parts = [] }
            if parts.isEmpty { continue }
            root.size += size
            var node = root
            for (i, part) in parts.enumerated() {
                let isLast = (i == parts.count - 1)
                if isLast {
                    let ext = { () -> String in
                        let e = (part as NSString).pathExtension
                        return e.isEmpty ? ".o" : "." + e
                    }()
                    let leafNode = DirBuilder(part)
                    leafNode.size = size
                    leafNode.leaf = LinkMapTreeNode(name: part, type: ext, size: size, path: p)
                    if node.children[part] == nil { node.childOrder.append(part) }
                    node.children[part] = leafNode
                } else {
                    if node.children[part] == nil {
                        node.children[part] = DirBuilder(part)
                        node.childOrder.append(part)
                    }
                    node.children[part]!.size += size
                    node = node.children[part]!
                }
            }
        }
        func convert(_ b: DirBuilder) -> LinkMapTreeNode {
            if let leaf = b.leaf { return leaf }
            let kids = b.childOrder.map { b.children[$0]! }
            let sortedKids = Self.stableSortBySizeDesc(kids) { $0.size }.map { convert($0) }
            return LinkMapTreeNode(name: b.name, type: "dir", size: b.size, children: sortedKids)
        }
        return convert(root)
    }

    func getFiles() -> [LinkMapOFile] {
        var order: [String] = []
        var sizes: [String: Int] = [:]
        for sym in symbols {
            guard let fid = sym.fileID, let p = objectFiles[fid] else { continue }
            if sizes[p] == nil { order.append(p) }
            sizes[p, default: 0] += sym.size
        }
        let indexed = order.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            let sa = sizes[a.1]!, sb = sizes[b.1]!
            if sa != sb { return sa > sb }
            return a.0 < b.0
        }
        return sorted.map { LinkMapOFile(path: $0.1, size: sizes[$0.1]!) }
    }

    func getModuleSections(topN: Int = 50) -> [LinkMapModuleSection] {
        ensureModuleCache()
        let sortedRanges = sectionRanges.sorted { $0.0 < $1.0 }
        func sectionFor(_ addr: Int) -> String? {
            var lo = 0, hi = sortedRanges.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let (s, e, name) = sortedRanges[mid]
                if addr < s { hi = mid - 1 }
                else if addr >= e { lo = mid + 1 }
                else { return name }
            }
            return nil
        }
        final class SecAgg { var order: [String] = []; var secs: [String: Int] = [:] }
        var order: [String] = []
        var modSecs: [String: SecAgg] = [:]
        for sym in symbols {
            guard let fid = sym.fileID, let module = fileModuleCache[fid] else { continue }
            guard let secName = sectionFor(sym.address) else { continue }
            let a: SecAgg
            if let existing = modSecs[module] { a = existing }
            else { a = SecAgg(); modSecs[module] = a; order.append(module) }
            if a.secs[secName] == nil { a.order.append(secName) }
            a.secs[secName, default: 0] += sym.size
        }
        let indexed = order.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            let ta = modSecs[a.1]!.secs.values.reduce(0, +)
            let tb = modSecs[b.1]!.secs.values.reduce(0, +)
            if ta != tb { return ta > tb }
            return a.0 < b.0
        }
        var result: [LinkMapModuleSection] = []
        for (_, module) in sorted.prefix(topN) {
            let m = modSecs[module]!
            let total = m.secs.values.reduce(0, +)
            let secsSorted = m.secs.sorted { $0.value > $1.value }
            result.append(LinkMapModuleSection(module: module, total: total,
                                               sections: Dictionary(uniqueKeysWithValues: secsSorted)))
        }
        return result
    }

    // MARK: 模块归属（对齐 _guess_module，手动实现避免正则开销）

    static func guessModule(_ filePath: String) -> String {
        let path = filePath
        if let r = path.range(of: ".a(") {
            if let slash = path[..<r.lowerBound].lastIndex(of: "/") {
                let name = String(path[path.index(after: slash)..<r.lowerBound])
                return name.hasPrefix("lib") ? String(name.dropFirst(3)) : name
            }
        }
        if let r = path.range(of: "/Pods/") {
            let after = path[r.upperBound...]
            if let end = after.firstIndex(of: "/") { return String(after[..<end]) }
        }
        var searchStart = path.startIndex
        var lastBuild: String? = nil
        while let r = path.range(of: ".build/", range: searchStart..<path.endIndex) {
            if let slash = path[..<r.lowerBound].lastIndex(of: "/") {
                lastBuild = String(path[path.index(after: slash)..<r.lowerBound])
            }
            searchStart = r.upperBound
        }
        if let lastBuild { return lastBuild }
        for marker in [".framework/", ".framework("] {
            if let r = path.range(of: marker) {
                if let slash = path[..<r.lowerBound].lastIndex(of: "/") {
                    return String(path[path.index(after: slash)..<r.lowerBound])
                }
            }
        }
        if path.contains("linker synthesized") { return "linker synthesized" }
        Logger.warn("无法归类路径: \(path)")
        return "(未归类)"
    }

    // MARK: 库类型（对齐 _detect_lib_type）

    static func detectLibType(_ filePaths: [String]) -> String {
        var hasRealO = false, hasSynthesized = false, allToolchain = true, hasFrameworkRef = false
        for p in filePaths {
            let basename = p.split(separator: "/").last.map(String.init) ?? p
            if basename.hasSuffix(".o") || p.contains(".o)") {
                hasRealO = true
                if !(p.hasPrefix("/Applications/Xcode.app/") || p.hasPrefix("/usr/lib/")) { allToolchain = false }
            }
            if p == "linker synthesized" { hasSynthesized = true; allToolchain = false }
            if p.contains(".framework/") || p.contains(".framework(") { hasFrameworkRef = true }
        }
        if hasRealO { return allToolchain ? "toolchain" : "static" }
        if hasSynthesized { return "synthesized" }
        for p in filePaths {
            if p.hasPrefix("/System/Library/") || p.hasPrefix("/usr/lib/")
                || p.hasPrefix("/usr/bin/") || p.hasPrefix("/Applications/Xcode.app/") { return "system" }
        }
        if hasFrameworkRef { return "stub" }
        return "static"
    }

    static func stableSortBySizeDesc<T>(_ arr: [T], _ size: (T) -> Int) -> [T] {
        arr.enumerated().sorted { a, b in
            let sa = size(a.element), sb = size(b.element)
            if sa != sb { return sa > sb }
            return a.offset < b.offset
        }.map { $0.element }
    }
}
