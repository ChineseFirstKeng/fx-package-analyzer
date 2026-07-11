import Foundation

/// .app 文件结构分析器 —— 1:1 复刻 analyze_app_structure.py。
public struct AppStructureAnalyzer: Analyzer {
    public var outputFileName: String { "app_structure.json" }
    public var displayName: String { "app_structure_analyzer" }
    public var fallbackJSON: String {
        #"{"total_size":0,"root":{"name":"","type":"dir","size":0,"path":"","children":[]}}"#
    }

    public init() {}

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let appPath = context.appPath else {
            throw AnalyzerError.missingInput("app_structure 需要 .app 路径")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appPath, isDirectory: &isDir), isDir.boolValue else {
            throw AnalyzerError.missingInput("不是有效目录: \(appPath)")
        }
        let appName = (appPath as NSString).lastPathComponent
        let root = Self.buildTree(dirPath: appPath, rootName: appName)
        root.path = "."
        Logger.info("扫描完成: \(appName)")
        Logger.info("  总大小: \(ByteFormatter.fmt(root.size))")
        Logger.info("  顶层条目: \(root.children.count)")
        return AppStructureResult(total_size: root.size, root: root)
    }

    /// 递归构建目录树（对齐 build_tree）。
    static func buildTree(dirPath: String, rootName: String) -> AppFileNode {
        let node = AppFileNode(name: rootName, type: "dir", size: 0, path: ".", children: [])
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else {
            return node
        }
        // 排序：目录优先，同类按小写名字典序（对齐 (not isdir, name.lower())）
        let sorted = entries.sorted { a, b in
            let ad = Self.isDirectory(dirPath + "/" + a)
            let bd = Self.isDirectory(dirPath + "/" + b)
            if ad != bd { return ad && !bd }
            return a.lowercased() < b.lowercased()
        }
        for entry in sorted {
            let fullPath = dirPath + "/" + entry
            // 跳过符号链接（对齐 Python os.walk followlinks=False）
            if Self.isSymlink(fullPath) { continue }
            if Self.isDirectory(fullPath) {
                let child = buildTree(dirPath: fullPath, rootName: entry)
                child.path = entry
                node.children.append(child)
                node.size += child.size
            } else {
                let fsize = Self.fileSize(fullPath)
                var ext = ("." + (entry as NSString).pathExtension).lowercased()
                if (entry as NSString).pathExtension.isEmpty {
                    ext = ""
                }
                if ext.isEmpty && MachOMagic.isMachO(fullPath) {
                    ext = "macho"
                }
                let child = AppFileNode(name: entry, type: ext, size: fsize, path: entry, children: [])
                node.children.append(child)
                node.size += fsize
            }
        }
        return node
    }

    private static func isSymlink(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func fileSize(_ path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }
}

public enum AnalyzerError: Error, CustomStringConvertible {
    case missingInput(String)
    public var description: String {
        switch self {
        case .missingInput(let m): return m
        }
    }
}
