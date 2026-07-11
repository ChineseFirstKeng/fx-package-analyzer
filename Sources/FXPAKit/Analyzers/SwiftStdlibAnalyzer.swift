import Foundation

/// Swift 标准库嵌入检测 —— 1:1 复刻 analyze_swift_stdlib.py。
public struct SwiftStdlibAnalyzer: Analyzer {
    public var outputFileName: String { "swift_stdlib.json" }
    public var displayName: String { "swift_stdlib_checker" }
    public var printSummary: ((Encodable) -> Void)? {
        { (r_: Encodable) in
            guard let r = r_ as? SwiftStdlibResult else { return }
            let s = r.summary
            Logger.plain("")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  Swift 标准库嵌入检测")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  嵌入 Swift 库: \(s.embedded_swift_count)")
            Logger.plain("  Swift 总大小:  \(ByteFormatter.fmt(s.total_swift_size))")
            Logger.plain("  主二进制链接:  \(s.binary_links_swift ? "是" : "否")")
            Logger.plain("")
            if !s.issues.isEmpty { for issue in s.issues { Logger.plain("  ⚠️  \(issue.title)") } }
            if !s.recommendations.isEmpty { for rec in s.recommendations { let icon = rec.type == "ok" ? "✅" : (rec.type == "warning" ? "⚠️" : "ℹ️"); Logger.plain("  \(icon) \(rec.title)") } }
            Logger.plain("")
        }
    }
    public var fallbackJSON: String { #"{"embedded_libs":[]}"# }

    public init() {}

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let appPath = context.appPath, ResourceScanner.isDir(appPath) else {
            throw AnalyzerError.missingInput("swift_stdlib 需要 .app 路径")
        }
        Logger.info("开始 Swift 标准库检测 ...")
        let fm = FileManager.default

        // 主二进制
        var mainBinary = ""
        let appName = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let candidate = (appPath as NSString).appendingPathComponent(appName)
        if fm.fileExists(atPath: candidate) {
            mainBinary = candidate
        } else {
            for f in (try? fm.contentsOfDirectory(atPath: appPath)) ?? [] where !f.hasPrefix(".") {
                let fp = (appPath as NSString).appendingPathComponent(f)
                if !ResourceScanner.isDir(fp) && MachOMagic.isMachO(fp) { mainBinary = fp; break }
            }
        }

        // Frameworks 目录
        let fwDir = (appPath as NSString).appendingPathComponent("Frameworks")
        let hasFwDir = ResourceScanner.isDir(fwDir)

        // 扫描 libswift*.dylib
        var embedded: [SwiftStdlibEmbeddedLib] = []
        var totalSize = 0
        var seen = Set<String>()
        if hasFwDir {
            for name in (try? fm.contentsOfDirectory(atPath: fwDir)) ?? [] {
                if name.hasPrefix("libswift") && name.hasSuffix(".dylib") {
                    let fp = (fwDir as NSString).appendingPathComponent(name)
                    if !ResourceScanner.isDir(fp) {
                        let size = ResourceScanner.fileSize(fp)
                        embedded.append(SwiftStdlibEmbeddedLib(name: name, path: fp, size: size))
                        seen.insert(fp); totalSize += size
                    }
                }
            }
            // 子目录中的 Swift runtime（罕见）
            if let en = fm.enumerator(atPath: fwDir) {
                for case let rel as String in en {
                    let base = (rel as NSString).lastPathComponent
                    if base.hasPrefix("libswift") && base.hasSuffix(".dylib") {
                        let fp = (fwDir as NSString).appendingPathComponent(rel)
                        if !seen.contains(fp) && !ResourceScanner.isDir(fp) {
                            let size = ResourceScanner.fileSize(fp)
                            embedded.append(SwiftStdlibEmbeddedLib(name: rel, path: fp, size: size))
                            seen.insert(fp); totalSize += size
                        }
                    }
                }
            }
        }

        // 主二进制是否链接 Swift
        var binaryLinksSwift = false
        if !mainBinary.isEmpty, let out = try? Shell.run("/usr/bin/otool", ["-L", mainBinary], timeout: 30).stdout {
            binaryLinksSwift = out.contains("libswift") || out.lowercased().contains("swift")
        }

        // 问题 + 建议（对齐 _analyze_issues）
        var issues: [SwiftStdlibIssue] = []
        var recs: [SwiftStdlibRecommendation] = []
        if embedded.isEmpty {
            recs.append(.init(type: "ok", title: "未嵌入 Swift 标准库",
                              detail: ".app 中未发现嵌入的 libswift*.dylib，无需优化。"))
        } else {
            if !binaryLinksSwift {
                issues.append(.init(severity: "high", title: "主二进制未链接 Swift，但嵌入了 Swift 标准库",
                                    detail: "主二进制未发现 Swift 链接依赖，但 .app/Frameworks/ 中有 Swift 动态库。可能是 Extension 需要，也可能是误嵌入。"))
            }
            recs.append(.init(type: "info", title: "Swift 标准库嵌入分析",
                detail: "当前嵌入 \(embedded.count) 个 Swift 动态库，总计 \(ByteFormatter.fmt(totalSize))。\n\niOS 12.2+ 系统已内置 Swift 标准库，如果 Deployment Target >= 12.2，可通过以下方式避免嵌入：\n1. Build Settings → ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES → NO\n2. 确保所有 Swift 代码使用静态链接（Xcode 默认行为）\n3. 检查是否有 Extension 需要单独嵌入 Swift 标准库"))
            if totalSize > 5 * 1024 * 1024 {
                recs.append(.init(type: "warning", title: "Swift 标准库占用 \(ByteFormatter.fmt(totalSize))，建议优化",
                                  detail: "超过 5MB 的 Swift 标准库嵌入值得优化。检查 ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES 设置。"))
            }
        }

        Logger.success("检测完成: 嵌入 \(embedded.count) 个 Swift 库, 总计 \(ByteFormatter.fmt(totalSize))")
        let absApp = URL(fileURLWithPath: appPath).standardized.path
        return SwiftStdlibResult(
            meta: .init(app_path: absApp, generated_at: DateUtil.now()),
            summary: .init(app_path: absApp, embedded_swift_count: embedded.count, total_swift_size: totalSize,
                           binary_links_swift: binaryLinksSwift, main_binary: mainBinary, has_frameworks_dir: hasFwDir,
                           issues: issues, recommendations: recs),
            embedded_libs: embedded)
    }
}
