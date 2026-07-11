import Foundation

/// 输入路径解析 —— 复刻 package_analyzer.sh 的 resolve_input / find_nearby_project。
public struct InputResolver {
    public struct Resolved {
        public var appPath: String?
        public var appName: String?
        public var projectDir: String?
        public var xcarchivePath: String?
    }

    public enum ResolveError: Error, CustomStringConvertible {
        case notFound(String)
        case unrecognized(String)
        case noAppInArchive
        public var description: String {
            switch self {
            case .notFound(let p): return "路径不存在: \(p)"
            case .unrecognized(let p): return "无法识别输入类型: \(p)"
            case .noAppInArchive: return ".xcarchive 中未找到 .app"
            }
        }
    }

    public static func resolve(_ input: String) throws -> Resolved {
        let fm = FileManager.default
        guard fm.fileExists(atPath: input) else { throw ResolveError.notFound(input) }
        var r = Resolved()

        // .app
        if input.hasSuffix(".app") && isDir(input) {
            r.appPath = input
            r.appName = ((input as NSString).lastPathComponent as NSString).deletingPathExtension
            Logger.info("输入: .app → \(input)")
            r.projectDir = findNearbyProject(input)
            return r
        }
        // .xcarchive
        if input.hasSuffix(".xcarchive") && isDir(input) {
            let appsDir = (input as NSString).appendingPathComponent("Products/Applications")
            if isDir(appsDir), let found = (try? fm.contentsOfDirectory(atPath: appsDir))?
                .first(where: { $0.hasSuffix(".app") }) {
                let appPath = (appsDir as NSString).appendingPathComponent(found)
                r.appPath = appPath
                r.appName = (found as NSString).deletingPathExtension
                r.xcarchivePath = input
                Logger.info("从 .xcarchive 提取: \(appPath)")
                r.projectDir = findNearbyProject(input)
                return r
            }
            throw ResolveError.noAppInArchive
        }
        // 工程目录 / .xcodeproj / .xcworkspace
        if isDir(input) {
            var projectDir = input
            if input.hasSuffix(".xcodeproj") || input.hasSuffix(".xcworkspace") {
                projectDir = (input as NSString).deletingLastPathComponent
            }
            r.projectDir = projectDir
            Logger.info("工程目录: \(projectDir)")
            return r
        }
        throw ResolveError.unrecognized(input)
    }

    /// 向上找 5 层含 .xcworkspace 的目录（复刻 find_nearby_project）。
    static func findNearbyProject(_ start: String) -> String? {
        var d = start
        for _ in 1...5 {
            d = (d as NSString).deletingLastPathComponent
            if let ws = (try? FileManager.default.contentsOfDirectory(atPath: d))?
                .first(where: { $0.hasSuffix(".xcworkspace") }), !ws.isEmpty {
                _ = ws
                return d
            }
        }
        return nil
    }

    static func isDir(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
