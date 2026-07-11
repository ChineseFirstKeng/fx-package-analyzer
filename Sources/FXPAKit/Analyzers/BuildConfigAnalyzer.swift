import Foundation

/// 编译配置审计 —— 1:1 复刻 analyze_build_config.sh 内嵌的 Python 规则。
public struct BuildConfigAnalyzer: Analyzer {
    public var outputFileName: String { "build_config_audit.json" }
    public var displayName: String { "build_config_auditor" }
    public var printSummary: ((Encodable) -> Void)? {
        { (r_: Encodable) in
            guard let r = r_ as? BuildConfigResult else { return }
            let s = r.summary
            Logger.plain("")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  编译配置审计")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  审计项: \(s.total_rules)  |  合规: \(s.pass)  |  不合规: \(s.fail)  |  未设置: \(s.unknown)")
            if s.fail > 0 {
                for rule in r.results where rule.status == "fail" {
                    Logger.plain("  ✗ \(rule.key): 当前=\(rule.current.isEmpty ? "(未设置)" : rule.current)  推荐=\(rule.expected)")
                }
            }
            Logger.plain("")
            Logger.plain(String(repeating: "=", count: 60))
        }
    }
    public var fallbackJSON: String { #"{"results":[]}"# }

    public init() {}

    // 21 条规则（对齐 shell 中 rules 列表）
    static let rules: [(key: String, expected: String, desc: String, criticality: String)] = [
        ("SWIFT_OPTIMIZATION_LEVEL", "-Osize", "Swift 优化等级，-Osize 比 -O 小 5-10%", "high"),
        ("STRIP_STYLE", "all", "剥离调试符号样式", "high"),
        ("DEPLOYMENT_POSTPROCESSING", "YES", "启用部署后处理（strip）", "high"),
        ("GCC_OPTIMIZATION_LEVEL", "s", "C/C++/ObjC 编译优化，s=侧重体积", "medium"),
        ("DEAD_CODE_STRIPPING", "YES", "链接时移除未使用代码", "high"),
        ("LLVM_LTO", "YES_THIN", "链接时优化(LTO)，可减小 5-10% 体积", "high"),
        ("SWIFT_COMPILATION_MODE", "wholemodule", "Swift 全模块编译，配合 LTO 效果最佳", "medium"),
        ("ASSETCATALOG_COMPILER_OPTIMIZATION", "space", "资源目录编译优化，space=侧重体积", "medium"),
        ("STRIP_SWIFT_SYMBOLS", "YES", "剥离 Swift 符号", "high"),
        ("COPY_PHASE_STRIP", "YES", "Copy Bundle Resources 阶段剥离符号", "medium"),
        ("STRIP_INSTALLED_PRODUCT", "YES", "剥离安装产物", "medium"),
        ("ENABLE_BITCODE", "NO", "Bitcode 已废弃，关闭可减小体积", "low"),
        ("COMPRESS_PNG_FILES", "YES", "压缩 PNG 资源", "medium"),
        ("ENABLE_CPP_EXCEPTIONS", "NO", "关闭 C++ 异常可减小二进制体积", "medium"),
        ("ENABLE_CPP_RTTI", "NO", "关闭 C++ RTTI 可减小二进制体积", "medium"),
        ("GCC_ENABLE_OBJC_EXCEPTIONS", "NO", "关闭 ObjC 异常可减小体积（如不需要）", "low"),
        ("ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES", "NO", "避免嵌入 Swift 标准库（iOS 12.2+ 系统内置）", "high"),
        ("ONLY_ACTIVE_ARCH", "YES", "Debug 仅编译当前架构", "low"),
        ("ALWAYS_SEARCH_USER_PATHS", "NO", "关闭隐式头文件搜索", "low"),
        ("VALID_ARCHS", "", "限制支持架构可减小体积，推荐 arm64", "medium"),
        ("ARCHS", "arm64", "目标架构，arm64 即可", "medium"),
    ]

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let projectDir = context.projectDir, ResourceScanner.isDir(projectDir) else {
            throw AnalyzerError.missingInput("build_config 需要工程目录")
        }
        // 找工程文件（对齐 shell：maxdepth 2，排除 Pods）
        let fm = FileManager.default
        var projPath = ""
        var projType = ""
        // 优先顶层 workspace
        for e in (try? fm.contentsOfDirectory(atPath: projectDir)) ?? [] {
            let full = (projectDir as NSString).appendingPathComponent(e)
            if e.hasSuffix(".xcworkspace") && !e.contains("Pods") && ResourceScanner.isDir(full) {
                projPath = full; projType = "workspace"; break
            }
        }
        if projPath.isEmpty {
            for e in (try? fm.contentsOfDirectory(atPath: projectDir)) ?? [] {
                let full = (projectDir as NSString).appendingPathComponent(e)
                if e.hasSuffix(".xcodeproj") && !e.contains("Pods") && ResourceScanner.isDir(full) {
                    projPath = full; projType = "project"; break
                }
            }
        }
        guard !projPath.isEmpty else { throw AnalyzerError.missingInput("build_config: 未找到 .xcodeproj/.xcworkspace") }

        Logger.info("找到: ./\((projPath as NSString).lastPathComponent) (\(projType))")

        // scheme
        let scheme = try detectScheme(projPath: projPath, projType: projType, projectDir: projectDir)
        Logger.info("自动推断 scheme: \(scheme)")
        Logger.info("运行 xcodebuild -showBuildSettings ...")
        let buildOutput: String
        do {
            buildOutput = try Shell.xcodebuild(["-" + projType, projPath, "-scheme", scheme, "-showBuildSettings"]).stdout
        } catch {
            Logger.warn("xcodebuild 可能未成功运行")
            Logger.warn("尝试在 Xcode 中先打开一次项目以确保 schemes 可用")
            throw error
        }

        // 提取值（对齐 shell 内嵌 Python 的提取逻辑）
        func setting(_ key: String) -> String {
            for line in buildOutput.components(separatedBy: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix(key + " ") || s.hasPrefix(key + "=") {
                    // split('=', 1)：只按第一个 = 切，保留值中的 =
                    if let r = s.range(of: "=") { return String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
                }
            }
            return ""
        }

        var results: [BuildConfigRule] = []
        var passCnt = 0, failCnt = 0, unknownCnt = 0
        for (key, expected, desc, criticality) in Self.rules {
            let current = setting(key)
            let (status, statusLabel): (String, String)
            if current.isEmpty { status = "unknown"; statusLabel = "未设置" }
            else if current == expected { status = "pass"; statusLabel = "合规" }
            else if expected == "YES" && (current == "YES" || current == "1") { status = "pass"; statusLabel = "合规" }
            else if expected == "NO" && (current == "NO" || current == "0") { status = "pass"; statusLabel = "合规" }
            else if expected.isEmpty && !current.isEmpty { status = "pass"; statusLabel = "已设置" }
            else { status = "fail"; statusLabel = "不合规" }
            switch status {
            case "pass": passCnt += 1
            case "fail": failCnt += 1
            default: unknownCnt += 1
            }
            results.append(BuildConfigRule(key: key, expected: expected.isEmpty ? "(任意非空)" : expected,
                                           current: current, status: status, status_label: statusLabel,
                                           description: desc, criticality: criticality))
        }

        let absProject = URL(fileURLWithPath: projectDir).standardized.path
        return BuildConfigResult(
            meta: .init(project_dir: absProject, project_path: projPath, project_type: projType, scheme: scheme, generated_at: DateUtil.now()),
            summary: .init(total_rules: results.count, pass: passCnt, fail: failCnt, unknown: unknownCnt),
            results: results)
    }

    private func detectScheme(projPath: String, projType: String, projectDir: String) throws -> String {
        let raw = try Shell.xcodebuild(["-" + projType, projPath, "-list"]).stdout
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
        // 回退：取最长的 scheme 名（主 App 通常比 Pod 名长，对齐 shell awk）
        if let longest = schemes.max(by: { $0.count < $1.count }) { return longest }
        throw AnalyzerError.missingInput("build_config: 无法推断 scheme")
    }
}
