import Foundation

/// 源码工程资源扫描 —— 1:1 复刻 lib/resource_scanner.py。
/// analyze_assets 与后续 analyze_unused_resources 共用。
public struct ResourceScanner {
    public let config: PackageCheckConfig
    private let extToCategory: [String: String]
    private let allowed: Set<String>
    private let skipDirs: Set<String>

    /// 资源扫描默认跳过目录（向后兼容：config 中无此配置时使用的硬编码列表）。
    static let defaultSkipDirs: Set<String> = [
        ".git", "DerivedData", "build", "Carthage", "node_modules",
        ".swiftpm", "__pycache__", ".claude", ".app", ".xcarchive",
        ".xcodeproj", ".xcworkspace",
    ]

    public init(config: PackageCheckConfig) {
        self.config = config
        self.extToCategory = config.extToCategory
        self.allowed = config.allowedExtensions
        self.skipDirs = config.resourceSkipDirs.isEmpty ? Self.defaultSkipDirs : config.resourceSkipDirs
    }

    // MARK: 扫描结果

    public struct ScanResult {
        public var totalSize: Int
        public var byCategory: [(String, Int)]   // 降序
        public var byType: [(String, Int)]        // 降序
        public var allFiles: [AssetFile]          // 降序
        public var allImages: [AssetFile]         // 降序
    }

    // MARK: 工具

    private func guessCategory(_ ext: String) -> String {
        extToCategory[ext] ?? "other"
    }

    /// 从文件路径推断所属 Pod/模块（对齐 guess_source_module）。
    func guessSourceModule(_ filepath: String, _ projectDir: String) -> String {
        let rel = Self.relativePath(filepath, from: projectDir)
        let parts = rel.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2 && parts[0] == "Pods" {
            return parts[1]
        }
        if parts.count >= 1 {
            let top = parts[0]
            if ![".", "..", "Pods", "Carthage", "DerivedData", "build"].contains(top) {
                return top
            }
        }
        return "主工程"
    }

    /// 去掉 @2x/@3x/~ipad/~语言 后缀和扩展名（对齐 normalize_base_name）。
    static func normalizeBaseName(_ filename: String) -> String {
        var name = (filename as NSString).deletingPathExtension
        name = resub(name, "@[234]x$", caseInsensitive: false)
        name = resub(name, "~(ipad|iphone|mac)$", caseInsensitive: true)
        name = resub(name, "~[a-z]{2}(-[A-Za-z]+)?$", caseInsensitive: false)
        return name
    }

    private static func resub(_ str: String, _ pattern: String, caseInsensitive: Bool) -> String {
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return str }
        let range = NSRange(str.startIndex..., in: str)
        return re.stringByReplacingMatches(in: str, range: range, withTemplate: "")
    }

    /// 相对路径（对齐 os.path.relpath）。
    static func relativePath(_ path: String, from base: String) -> String {
        let p = URL(fileURLWithPath: path).standardized.path
        let b = URL(fileURLWithPath: base).standardized.path
        if p == b { return "." }
        if p.hasPrefix(b + "/") {
            return String(p.dropFirst(b.count + 1))
        }
        // 退化：按分量计算（跨目录场景少见）
        let pc = p.split(separator: "/").map(String.init)
        let bc = b.split(separator: "/").map(String.init)
        var i = 0
        while i < pc.count && i < bc.count && pc[i] == bc[i] { i += 1 }
        let up = Array(repeating: "..", count: bc.count - i)
        return (up + pc[i...]).joined(separator: "/")
    }

    // MARK: Podfile 本地私有库

    /// 解析 Podfile :path/:podspec 私有库（对齐 find_local_pod_dirs）。
    func findLocalPodDirs(_ projectDir: String) -> [(String, String)] {
        let podfile = (projectDir as NSString).appendingPathComponent("Podfile")
        guard let content = try? String(contentsOfFile: podfile, encoding: .utf8) else { return [] }
        let pattern = #"pod\s+['"]([^'"]+)['"]\s*,\s*(?::path|:podspec|path|podspec)\s*=>\s*['"]([^'"]+)['"]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var pods: [(String, String)] = []
        let ns = content as NSString
        re.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let name = ns.substring(with: m.range(at: 1))
            let rel = ns.substring(with: m.range(at: 2))
            let podspecAbs = URL(fileURLWithPath: (projectDir as NSString).appendingPathComponent(rel)).standardized.path
            let podDir = rel.hasSuffix(".podspec") ? (podspecAbs as NSString).deletingLastPathComponent : podspecAbs
            let srcDir = (podDir as NSString).appendingPathComponent(name)
            if Self.isDir(srcDir) {
                pods.append((name, srcDir))
            } else if Self.isDir(podDir) {
                pods.append((name, podDir))
            }
        }
        return pods
    }

    // MARK: 扫描

    /// 解析目录型 bundle（由 package_assets 类型配置，如 .imageset / .mlpackage / .scnassets 等）。
    /// 每个匹配到的目录作为一个资源条目，内部文件存入 children 供前端展开。
    func scanPackageAssets(_ baseDir: String, srcOverride: String? = nil) -> [AssetFile] {
        let suffixes = config.packageSuffixes
        guard !suffixes.isEmpty else { return [] }
        var files: [AssetFile] = []

        walk(baseDir, skipSuffixes: suffixes) { root in
            let matchedSuffix = suffixes.first(where: { root.hasSuffix($0) })
            guard let matchedSuffix = matchedSuffix else { return }

            let dirName = (root as NSString).lastPathComponent
            let baseName = (dirName as NSString).deletingPathExtension
            let source = srcOverride ?? guessSourceModule(root, baseDir)
            let rel = Self.relativePath(root, from: baseDir)
            let children = collectFiles(in: root, baseDir: baseDir, source: source)
            let totalSize = children.reduce(0) { $0 + $1.size }
            files.append(AssetFile(
                path: rel,
                relative_path: rel,
                size: totalSize,
                ext: matchedSuffix,
                category: guessCategory(matchedSuffix),
                source: source,
                base_name: baseName,
                sha256: Hashing.sha256(ofDirectory: root),
                children: children.isEmpty ? nil : children
            ))
        }
        return files
    }

    /// 递归收集目录内所有文件为 AssetFile 条目
    private func collectFiles(in dir: String, baseDir: String, source: String) -> [AssetFile] {
        guard Self.isDir(dir) else { return [] }
        var files: [AssetFile] = []
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for entry in entries {
            let full = dir + "/" + entry
            if Self.isSymlink(full) { continue }
            if Self.isDir(full) {
                files.append(contentsOf: collectFiles(in: full, baseDir: baseDir, source: source))
            } else {
                let e = ("." + (entry as NSString).pathExtension).lowercased()
                let ext = (entry as NSString).pathExtension.isEmpty ? "" : e
                let fsize = Self.fileSize(full)
                let rel = Self.relativePath(full, from: baseDir)
                files.append(AssetFile(
                    path: rel,
                    relative_path: rel,
                    size: fsize,
                    ext: ext,
                    category: guessCategory(ext),
                    source: source,
                    base_name: Self.normalizeBaseName(entry),
                    sha256: Hashing.sha256(ofFile: full)
                ))
            }
        }
        return files
    }

    /// 扫描普通松散资源（排除目录型 bundle 和 .xcassets 内文件，后者由 scanPackageAssets 处理）。
    func scanLooseResources(_ baseDir: String, srcOverride: String? = nil) -> [AssetFile] {
        let suffixes = config.packageSuffixes
        var files: [AssetFile] = []
        walk(baseDir, skipSuffixes: suffixes) { root in
            // 跳过目录型 bundle 自身（其内部文件由 scanPackageAssets 处理）
            if !suffixes.isEmpty && suffixes.contains(where: { root.hasSuffix($0) }) { return }
            let fnames = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for fname in fnames {
                // 跳过 .package-check.json（工具自身配置，不上报为资源）
                if fname == ".package-check.json" { continue }
                let fpath = root + "/" + fname
                guard !Self.isDir(fpath) else { continue }
                let e = ("." + (fname as NSString).pathExtension).lowercased()
                let ext = (fname as NSString).pathExtension.isEmpty ? "" : e
                if !allowed.contains(ext) { continue }
                let size = Self.fileSize(fpath)
                let rel = Self.relativePath(fpath, from: baseDir)
                let source = srcOverride ?? guessSourceModule(fpath, baseDir)
                files.append(AssetFile(
                    path: rel,
                    relative_path: rel,
                    size: size,
                    ext: ext,
                    category: guessCategory(ext),
                    source: source,
                    base_name: Self.normalizeBaseName(fname),
                    sha256: Hashing.sha256(ofFile: fpath)
                ))
            }
        }
        return files
    }

    /// 扫描整个工程（对齐 scan_project_resources）。
    public func scanProjectResources(_ projectDir: String) -> ScanResult {
        var allFiles: [AssetFile] = []
        var seen = Set<String>()
        func add(_ batch: [AssetFile]) {
            for f in batch where !seen.contains(f.path) {
                seen.insert(f.path)
                allFiles.append(f)
            }
        }
        add(scanPackageAssets(projectDir))
        add(scanLooseResources(projectDir))
        for (podName, srcDir) in findLocalPodDirs(projectDir) {
            add(scanPackageAssets(srcDir, srcOverride: podName))
            add(scanLooseResources(srcDir, srcOverride: podName))
        }

        let total = allFiles.reduce(0) { $0 + $1.size }
        var byCat: [String: Int] = [:]
        var byType: [String: Int] = [:]
        for f in allFiles {
            byCat[f.category, default: 0] += f.size
            let ext = f.ext.isEmpty ? "(no ext)" : f.ext
            byType[ext, default: 0] += f.size
        }
        let images = allFiles.filter { $0.category == "images" }
        return ScanResult(
            totalSize: total,
            byCategory: byCat.sorted { $0.value > $1.value },
            byType: byType.sorted { $0.value > $1.value },
            allFiles: allFiles.sorted { $0.size > $1.size },
            allImages: images.sorted { $0.size > $1.size }
        )
    }

    // MARK: 目录遍历（对齐 os.walk + dirs 剪枝）

    /// 自顶向下遍历目录，对每个目录调用 visit(root)。剪枝规则对齐 os.walk 中的 dirs[:] 过滤。
    /// 不跟随符号链接（对齐 Python os.walk followlinks=False）。
    /// - skipSuffixes: 目录名以这些后缀结尾则跳过不进入（如 .xcassets/.mlpackage 等目录型 bundle）。
    private func walk(_ base: String, skipHidden: Bool = false, skipSuffixes: Set<String> = [], visit: (String) -> Void) {
        guard Self.isDir(base) else { return }
        visit(base)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: base))?.sorted() ?? []
        for entry in entries {
            let full = base + "/" + entry
            // 跳过符号链接（对齐 Python os.walk followlinks=False）
            if Self.isSymlink(full) { continue }
            guard Self.isDir(full) else { continue }
            // 跳过目录型 bundle（如 .xcassets / .mlpackage / .bundle / .scnassets）
            if !skipSuffixes.isEmpty && skipSuffixes.contains(where: { entry.hasSuffix($0) }) {
                visit(full)
                continue
            }
            // 剪枝：SKIP_DIRS + 隐藏目录
            if skipHidden {
                if entry.hasPrefix(".") { continue }
            } else {
                if self.skipDirs.contains(entry) || entry.hasPrefix(".") { continue }
            }
            walk(full, skipHidden: skipHidden, skipSuffixes: skipSuffixes, visit: visit)
        }
    }

    static func isSymlink(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func isDir(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func fileSize(_ path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }
}
