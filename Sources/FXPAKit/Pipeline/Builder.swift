import Foundation

/// 编译 & 归档 —— 复刻 package_analyzer.sh 的 do_build + 环境采集 + LinkMap 定位。
public struct Builder {
    public struct BuildResult {
        public var appPath: String
        public var appName: String
        public var scheme: String
        public var projType: PodMappingCollector.ProjType
        public var projPath: String
        public var buildDir: String
        public var linkmapPath: String?
        public var podLinkmapsDir: String?
        public var xcarchivePath: String
        public var builtProductsDir: String
        public var thinningExportPath: String?
        public var astDir: String?
    }

    let projectDir: String
    let configuration: String
    let teamID: String?
    let outputDir: String
    let toggles: ModuleToggles

    public init(projectDir: String, configuration: String, teamID: String?, outputDir: String, toggles: ModuleToggles) {
        self.projectDir = projectDir
        self.configuration = configuration
        self.teamID = teamID
        self.outputDir = outputDir
        self.toggles = toggles
    }

    public enum BuildError: Error, CustomStringConvertible {
        case noProject, noScheme, archiveFailed, noApp
        public var description: String {
            switch self {
            case .noProject: return "未找到 .xcworkspace 或 .xcodeproj"
            case .noScheme: return "未找到 scheme"
            case .archiveFailed: return "归档失败"
            case .noApp: return "Archive 中未找到 .app"
            }
        }
    }

    public func build() throws -> BuildResult {
        Logger.header("编译 & 归档")
        let fm = FileManager.default

        // 1. 找工程
        let entries = (try? fm.contentsOfDirectory(atPath: projectDir)) ?? []
        var proj = ""
        var projType: PodMappingCollector.ProjType = .project
        if let ws = entries.first(where: { $0.hasSuffix(".xcworkspace") }) {
            proj = (projectDir as NSString).appendingPathComponent(ws); projType = .workspace
        } else if let xc = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
            proj = (projectDir as NSString).appendingPathComponent(xc); projType = .project
        }
        guard !proj.isEmpty else { throw BuildError.noProject }

        // 2. Scheme 检测
        let scheme = try detectScheme(proj: proj, projType: projType)
        Logger.info("Scheme: \(scheme)")

        // 3. BUILD_DIR
        let buildDir = try makeTempDir()
        let lmOutDir = (buildDir as NSString).appendingPathComponent("linkmaps")
        try? fm.createDirectory(atPath: lmOutDir, withIntermediateDirectories: true)

        // 4. dev_team
        var devTeam = teamID ?? ""
        if devTeam.isEmpty {
            let bs = try? Shell.xcodebuild(["-" + projType.rawValue, proj, "-scheme", scheme, "-showBuildSettings"])
            if let out = bs?.stdout {
                for line in out.components(separatedBy: "\n") where line.contains("DEVELOPMENT_TEAM") {
                    let v = line.replacingOccurrences(of: " ", with: "").components(separatedBy: "=").last ?? ""
                    if v.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil { devTeam = v; break }
                }
            }
        }
        if !devTeam.isEmpty { Logger.info("签名 Team: \(devTeam)") }
        else { Logger.info("未检测到 Team ID，跳过签名（App Thinning 数据将不完整）") }

        // 5. xcconfig（objc_unused 启用时注入 CC wrapper 生成 .ast）
        var objcAstDir: String? = nil
        var ccWrapper: String? = nil
        if toggles.objcUnused {
            let dir = (buildDir as NSString).appendingPathComponent("objc_ast")
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            objcAstDir = dir
            ccWrapper = try writeClangASTWrapper(buildDir: buildDir)
        }
        let xcconfig = (buildDir as NSString).appendingPathComponent("force_linkmap.xcconfig")
        try writeXcconfig(to: xcconfig, buildDir: buildDir, devTeam: devTeam, ccWrapper: ccWrapper)

        // 6. archive
        let archivePath = (buildDir as NSString).appendingPathComponent("\(scheme).xcarchive")
        Logger.info("归档中 (xcodebuild archive)...")
        var args = ["-" + projType.rawValue, proj, "-scheme", scheme,
                    "-configuration", configuration, "-sdk", "iphoneos",
                    "-destination", "generic/platform=iOS",
                    "-archivePath", archivePath, "-derivedDataPath", buildDir,
                    "-xcconfig", xcconfig, "-UseModernBuildSystem=NO"]
        if !devTeam.isEmpty { args.append("-allowProvisioningUpdates") }
        args.append("archive")
        let env: [String: String]? = objcAstDir.map { ["AST_OUTPUT_DIR": $0, "AST_LOG_FILE": "\(outputDir)/ast_wrapper.log"] }
        let code = try Shell.runInheriting("/usr/bin/xcodebuild", args, environment: env)
        guard code == 0 else { throw BuildError.archiveFailed }
        Logger.success("归档完成")

        // 7. 提取 .app
        guard let appPath = findApp(in: archivePath) else { throw BuildError.noApp }
        let appName = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        Logger.info(".app: \(appPath)")

        // 8. LinkMap
        let linkmapPath = findLinkmap(in: buildDir, scheme: scheme)
        if let linkmapPath {
            Logger.info("LinkMap: \(linkmapPath)")
            // 复制原始 LinkMap 到报告目录
            try? fm.copyItem(atPath: linkmapPath, toPath: (outputDir as NSString).appendingPathComponent("linkmap.txt")); Logger.info("原始 LinkMap 已复制到报告目录")
        } else {
            Logger.warn("未找到 LinkMap（代码归因将不完整）")
        }

        // 9. 收集 Pod 独立 LinkMap
        let podLmDir = (outputDir as NSString).appendingPathComponent("pod_linkmaps")
        try? fm.createDirectory(atPath: podLmDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: lmOutDir) {
            for lm in (try? fm.contentsOfDirectory(atPath: lmOutDir)) ?? [] where lm.hasSuffix("-LinkMap.txt") {
                let src = (lmOutDir as NSString).appendingPathComponent(lm)
                if src == linkmapPath { continue }
                try? fm.copyItem(atPath: src, toPath: (podLmDir as NSString).appendingPathComponent(lm))
                Logger.info("Pod LinkMap: \(lm)")
            }
        }

        let builtProducts = (buildDir as NSString)
            .appendingPathComponent("Build/Products/\(configuration)-iphoneos")

        // App Thinning 导出（仅当启用；复刻 generate_thinning_report.sh）
        var thinningExportPath: String? = nil
        if toggles.thinning {
            thinningExportPath = exportThinningReport(archivePath: archivePath, devTeam: devTeam, buildDir: buildDir)
        }

        Logger.success("构建完成")
        return BuildResult(
            appPath: appPath, appName: appName, scheme: scheme, projType: projType,
            projPath: proj, buildDir: buildDir, linkmapPath: linkmapPath,
            podLinkmapsDir: fm.fileExists(atPath: podLmDir) ? podLmDir : nil,
            xcarchivePath: archivePath, builtProductsDir: builtProducts,
            thinningExportPath: thinningExportPath, astDir: objcAstDir)
    }

    /// 写出 clang AST wrapper（复刻 helpers/clang_ast_wrapper.sh），返回其路径。
    private func writeClangASTWrapper(buildDir: String) throws -> String {
        let path = (buildDir as NSString).appendingPathComponent("clang_ast_wrapper.sh")
        let script = #"""
        #!/bin/bash
        AST_OUTPUT_DIR="${AST_OUTPUT_DIR:-/tmp/objc_ast_output}"
        AST_LOG_FILE="${AST_LOG_FILE:-/tmp/objc_ast_wrapper.log}"
        CLANG=$(xcrun --find clang 2>/dev/null || command -v clang 2>/dev/null || echo "/usr/bin/clang")
        log() { echo "$@" >&2; echo "$@" >> "$AST_LOG_FILE"; }
        IGNORE_PATTERNS=("Prefix.pch" "Pods-")
        should_ignore() { local f; f="$1"; for p in "${IGNORE_PATTERNS[@]}"; do [[ "$f" == *"$p"* ]] && return 0; done; return 1; }
        IS_COMPILE=false; INPUT_FILE=""
        for arg in "$@"; do
            [ "$arg" = "-c" ] && IS_COMPILE=true
            [[ "$arg" == *.m || "$arg" == *.mm ]] && INPUT_FILE="$arg"
        done
        if [ "$IS_COMPILE" = true ] && [ -n "$INPUT_FILE" ]; then
            if should_ignore "$INPUT_FILE"; then
                log "[AST] SKIP $(basename "$INPUT_FILE")"
            else
                mkdir -p "$AST_OUTPUT_DIR"
                BASENAME=$(basename "$INPUT_FILE" | sed 's/\.[^.]*$//')
                FILE_HASH=$(echo -n "$INPUT_FILE" | shasum -a 256 2>/dev/null | cut -c1-16)
                AST_FILE="${AST_OUTPUT_DIR}/${BASENAME}_${FILE_HASH}.ast"
                if [ ! -f "$AST_FILE" ] || [ "$INPUT_FILE" -nt "$AST_FILE" ]; then
                    AST_ARGS=(); SKIP_NEXT=false; SKIP_NEXT2=false
                    for arg in "$@"; do
                        [ "$SKIP_NEXT" = true ] && { SKIP_NEXT=false; continue; }
                        [ "$SKIP_NEXT2" = true ] && { SKIP_NEXT2=false; continue; }
                        [ "$arg" = "-c" ] && continue
                        [ "$arg" = "-o" ] && { SKIP_NEXT=true; continue; }
                        [[ "$arg" == -fbuild-session-file* ]] && continue
                        [ "$arg" = "-fmodules-validate-once-per-build-session" ] && continue
                        [[ "$arg" == -Werror* ]] && continue
                        [[ "$arg" == -index-store-path* ]] && { SKIP_NEXT2=true; [[ "$arg" == *=* ]] && SKIP_NEXT2=false; continue; }
                        AST_ARGS+=("$arg")
                    done
                    if "$CLANG" -emit-ast "${AST_ARGS[@]}" -o "$AST_FILE" >/dev/null 2>&1; then
                        log "[AST] #${CNT:-?}: $(basename "$INPUT_FILE")  OK"
                    else
                        log "[AST] #${CNT:-?}: $(basename "$INPUT_FILE")  FAIL"
                    fi
                else
                    log "[AST] SKIP $(basename "$INPUT_FILE")"
                fi
            fi
        fi
        exec "$CLANG" "$@"
        """#
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// 导出 App Thinning Size Report（复刻 generate_thinning_report.sh）。
    private func exportThinningReport(archivePath: String, devTeam: String, buildDir: String) -> String? {
        let report = (archivePath as NSString).appendingPathComponent("App Thinning Size Report.txt")
        if FileManager.default.fileExists(atPath: report) { return nil }
        let exportPath = (buildDir as NSString).appendingPathComponent("thinning_export")
        try? FileManager.default.removeItem(atPath: exportPath)

        // exportOptions plist
        let opts = (buildDir as NSString).appendingPathComponent("export_thinning_opts.plist")
        let teamLine = devTeam.isEmpty ? "" : "    <key>teamID</key>\n    <string>\(devTeam)</string>\n"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>method</key>
            <string>debugging</string>
            <key>thinning</key>
            <string>&lt;thin-for-all-variants&gt;</string>
        \(teamLine)</dict>
        </plist>
        """
        try? plist.write(toFile: opts, atomically: true, encoding: .utf8)

        Logger.info("导出 App Thinning 报告 (thin-for-all-variants)...")
        // 无条件加 -allowProvisioningUpdates（对齐 generate_thinning_report.sh）
        let args = ["-exportArchive", "-archivePath", archivePath, "-exportPath", exportPath,
                    "-exportOptionsPlist", opts, "-allowProvisioningUpdates"]
        // 净化 Ruby 环境（xcodebuild 的 ipatool 依赖系统 Ruby，rbenv/RVM 会破坏）
        var cleanEnv = ProcessInfo.processInfo.environment
        for k in ["GEM_PATH", "GEM_HOME", "IRBRC", "RUBYOPT", "RUBYLIB"] { cleanEnv[k] = nil }
        cleanEnv["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let code = (try? Shell.runInheriting("/usr/bin/xcodebuild", args, environment: cleanEnv, replaceEnvironment: true)) ?? -1
        if code != 0 { Logger.warn("Thinning 导出失败（App Thinning 数据将不完整）"); return nil }

        // 报告可能落在 export 目录，拷回 archive
        if !FileManager.default.fileExists(atPath: report),
           let en = FileManager.default.enumerator(atPath: exportPath) {
            for case let rel as String in en where (rel as NSString).lastPathComponent == "App Thinning Size Report.txt" {
                try? FileManager.default.copyItem(atPath: (exportPath as NSString).appendingPathComponent(rel), toPath: report)
                break
            }
        }
        return FileManager.default.fileExists(atPath: exportPath) ? exportPath : nil
    }

    // MARK: Scheme 检测

    private func detectScheme(proj: String, projType: PodMappingCollector.ProjType) throws -> String {
        var schemeHint = ((proj as NSString).lastPathComponent as NSString).deletingPathExtension
        _ = schemeHint
        schemeHint = ((proj as NSString).lastPathComponent as NSString).deletingPathExtension

        let listRaw = (try? Shell.xcodebuild(["-" + projType.rawValue, proj, "-list"]))?.stdout ?? ""
        var schemes: [String] = []
        var inSchemes = false
        for line in listRaw.components(separatedBy: "\n") {
            if line.contains("Schemes:") { inSchemes = true; continue }
            if inSchemes {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.isEmpty { continue }
                if s.hasPrefix("Pods-") { continue }
                schemes.append(s)
            }
        }
        if let m = schemes.first(where: { $0 == schemeHint }) { return m }
        let dirName = (projectDir as NSString).lastPathComponent
        if let m = schemes.first(where: { $0 == dirName }) { return m }
        if let first = schemes.first { return first }
        throw BuildError.noScheme
    }

    // MARK: xcconfig

    private func writeXcconfig(to path: String, buildDir: String, devTeam: String, ccWrapper: String? = nil) throws {
        let lmPath = "\(buildDir)/linkmaps/$(PRODUCT_NAME)-LinkMap.txt"
        let ccLine = ccWrapper.map { "\nCC = \($0)" } ?? ""
        let common = """
        CLANG_ENABLE_EXPLICIT_MODULES = NO
        ARCHS = arm64
        WRITE_LINK_MAP_FILE = YES
        LINK_MAP_FILE_WRITES_TEXT = YES
        LD_GENERATE_MAP_FILE = YES
        LD_MAP_FILE_PATH = \(lmPath)
        ONLY_ACTIVE_ARCH = NO
        DEBUG_INFORMATION_FORMAT = dwarf
        GCC_GENERATE_DEBUGGING_SYMBOLS = NO\(ccLine)
        """
        let content: String
        if !devTeam.isEmpty {
            content = "DEVELOPMENT_TEAM = \(devTeam)\n" + common + "\n"
        } else {
            content = """
            CODE_SIGNING_ALLOWED = NO
            CODE_SIGNING_REQUIRED = NO
            CODE_SIGN_IDENTITY =
            """ + "\n" + common + "\n"
        }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: 提取 .app

    private func findApp(in archivePath: String) -> String? {
        let appsDir = (archivePath as NSString).appendingPathComponent("Products/Applications")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: appsDir) else { return nil }
        if let app = items.first(where: { $0.hasSuffix(".app") }) {
            return (appsDir as NSString).appendingPathComponent(app)
        }
        return nil
    }

    // MARK: LinkMap 定位（复刻 find_linkmap_in_dir 打分）

    func findLinkmap(in dir: String, scheme: String) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        let knownDir = (dir as NSString).appendingPathComponent("linkmaps")
        if fm.fileExists(atPath: knownDir) {
            candidates = ((try? fm.contentsOfDirectory(atPath: knownDir)) ?? [])
                .filter { $0.hasSuffix("-LinkMap.txt") }
                .map { (knownDir as NSString).appendingPathComponent($0) }
        }
        if candidates.isEmpty {
            candidates = recursiveFind(dir) { name in
                let l = name.lowercased()
                return l.contains("linkmap") && !l.hasSuffix(".json") && !l.hasSuffix(".xcconfig")
            }
        }
        if candidates.isEmpty { return nil }

        var best = ""
        var bestScore = -1
        for f in candidates {
            guard let firstLine = firstLine(of: f) else { continue }
            if firstLine.range(of: #"^# (Path|Object files|Symbols|Sections):"#, options: .regularExpression) == nil {
                continue
            }
            var binaryPath = firstLine
            if firstLine.hasPrefix("# Path: ") {
                binaryPath = String(firstLine.dropFirst("# Path: ".count)).trimmingCharacters(in: .whitespaces)
            }
            let binaryName = (binaryPath as NSString).lastPathComponent
            var score = 0
            if binaryPath.contains(".framework/") { score = -100 }
            else if binaryPath.contains(".app/") { score = 10 }
            else if binaryPath.hasSuffix(".app") { score = 0 }
            else { score = 5 }
            if !scheme.isEmpty && binaryName == scheme { score += 50 }
            let fsize = ResourceScanner.fileSize(f)
            score += fsize / 1024
            if score > bestScore { bestScore = score; best = f }
        }
        return best.isEmpty ? nil : best
    }

    private func firstLine(of path: String) -> String? {
        // 只读前 8KB 并宽松解码（LinkMap 可能很大且含非 UTF-8 符号名，全量严格读会失败）
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 8192), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "\n").first
    }

    private func recursiveFind(_ dir: String, matching: (String) -> Bool) -> [String] {
        var result: [String] = []
        guard let en = FileManager.default.enumerator(atPath: dir) else { return result }
        for case let rel as String in en {
            let name = (rel as NSString).lastPathComponent
            if matching(name) {
                let full = (dir as NSString).appendingPathComponent(rel)
                if !ResourceScanner.isDir(full) { result.append(full) }
            }
        }
        return result
    }

    private func makeTempDir() throws -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("package_analyzer_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
