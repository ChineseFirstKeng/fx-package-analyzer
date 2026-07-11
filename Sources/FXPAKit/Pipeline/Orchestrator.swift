import Foundation

/// 统一编排器 —— 复刻 package_analyzer.sh 主流程。
public struct Orchestrator {
    let options: RunOptions

    public init(options: RunOptions) { self.options = options }

    public func run() throws {
        Logger.plain("")
        Logger.plain("   ╔══════════════════════════════════════╗")
        Logger.plain("   ║     iOS 包体积统一分析工具           ║")
        Logger.plain("   ╚══════════════════════════════════════╝")
        Logger.plain("")

        // 输出目录
        let outputDir = try resolveOutputDir()
        // tee 到 build.log（对齐原脚本的 exec > >(tee -a "$LOG_FILE")）
        let logPath = (outputDir as NSString).appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: logPath, contents: nil)
        Logger.logFileHandle = FileHandle(forWritingAtPath: logPath)
        Logger.info("日志文件: \(logPath)")
        Logger.info("输出目录: \(outputDir)")

        // 解析输入
        var resolved = try InputResolver.resolve(absolutePath(options.inputPath))

        // 主指令：若缺少 .package-check.json 则直接生成默认配置（早于编译）
        ensurePackageCheckConfig(projectDir: resolved.projectDir)

        // 编译（如需要）
        var buildResult: Builder.BuildResult? = nil
        if resolved.appPath == nil {
            guard let projectDir = resolved.projectDir else {
                throw AnalyzerError.missingInput("无法确定 .app 路径")
            }
            let builder = Builder(projectDir: projectDir, configuration: options.configuration,
                                  teamID: options.teamID, outputDir: outputDir, toggles: options.toggles)
            let r = try builder.build()
            buildResult = r
            resolved.appPath = r.appPath
            resolved.appName = r.appName
            resolved.xcarchivePath = r.xcarchivePath
        }

        let config = PackageCheckConfig.load(projectDir: resolved.projectDir)

        // 环境信息采集
        let env = collectEnv(build: buildResult, projectDir: resolved.projectDir)
        try writeBuildEnv(env, to: outputDir)
        Logger.info("AssetCatalog: AppIcon=\(env.appIcon), LaunchImage=\(env.launchImage)")

        // Pod 映射
        var podMappingPath: String? = nil
        if let build = buildResult {
            Logger.header("采集 Pod 映射")
            let pmPath = (outputDir as NSString).appendingPathComponent("pod_mapping.json")
            if (try? PodMappingCollector.collect(projType: build.projType, projPath: build.projPath, outputPath: pmPath)) != nil {
                podMappingPath = pmPath
                Logger.info("Pod 映射已生成: \(pmPath)")
            }
        } else {
            Logger.info("跳过 Pod 映射（无工程信息）")
        }

        // 构建分析上下文
        let ctx = AnalysisContext(
            appPath: resolved.appPath,
            projectDir: resolved.projectDir,
            linkmapPath: buildResult?.linkmapPath,
            podLinkmapsDir: buildResult?.podLinkmapsDir,
            xcarchivePath: resolved.xcarchivePath,
            buildDir: buildResult?.buildDir,
            builtProductsDir: buildResult?.builtProductsDir,
            scheme: buildResult?.scheme,
            configuration: options.configuration,
            outputDir: outputDir,
            podMappingPath: podMappingPath,
            appIcon: env.appIcon,
            launchImage: env.launchImage,
            config: config,
            thinningExportPath: buildResult?.thinningExportPath,
            astDir: buildResult?.astDir
        )

        try runAnalyzers(context: ctx)
        try generateReport(context: ctx, appName: resolved.appName ?? "")

        // 保留 .app 到输出目录
        if let appPath = resolved.appPath, ResourceScanner.isDir(appPath) {
            let saved = (outputDir as NSString).appendingPathComponent((appPath as NSString).lastPathComponent)
            if !FileManager.default.fileExists(atPath: saved) {
                try? FileManager.default.copyItem(atPath: appPath, toPath: saved)
                Logger.info("已保留 .app: \(saved)")
            }
        }

        // 清理编译产物
        if !options.keepBuild, let buildDir = buildResult?.buildDir, FileManager.default.fileExists(atPath: buildDir) {
            try? FileManager.default.removeItem(atPath: buildDir)
            Logger.info("已清理编译产物")
        }

        // 关闭日志文件
        Logger.logFileHandle?.closeFile()
        Logger.logFileHandle = nil


        Logger.header("完成")
        Logger.plain("")
        Logger.plain("   输出目录: \(outputDir)")
        // 文件列表（直接跑 ls -lh，对齐 package_analyzer.sh）
        let fm = FileManager.default
        var lsFiles: [String] = []
        for f in ((try? fm.contentsOfDirectory(atPath: ctx.outputDir)) ?? []).sorted() {
            if ["html", "json", "txt"].contains(where: { f.hasSuffix("." + $0) }) {
                lsFiles.append((ctx.outputDir as NSString).appendingPathComponent(f))
            }
        }
        if !lsFiles.isEmpty, let lsOut = try? Shell.run("/bin/ls", ["-lh"] + lsFiles).stdout.trimmingCharacters(in: .whitespacesAndNewlines), !lsOut.isEmpty {
            Logger.plain(lsOut)
        }
        Logger.plain("")
        // .app 路径（对齐 shell：检查保存到输出目录的副本）
        if let appPath = resolved.appPath {
            let savedApp = (ctx.outputDir as NSString).appendingPathComponent((appPath as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: savedApp) {
                Logger.plain("   .app 路径: \(savedApp)")
                Logger.plain("")
            }
        }
        // 打开报告（粗体，对齐 shell printf "${BOLD}打开报告:${NC}"）
        let bold = Logger.colored ? "\u{001B}[1m" : ""
        let nc = Logger.colored ? "\u{001B}[0m" : ""
        Logger.plain("   \(bold)打开报告:\(nc)")
        Logger.plain("   open \((ctx.outputDir as NSString).appendingPathComponent("unified_report.html"))")
        Logger.plain("")
    }

    // MARK: 分析调度

    private func runAnalyzers(context ctx: AnalysisContext) throws {
        Logger.header("分析")
        let t = options.toggles

        // 1. LinkMap
        run(LinkMapAnalyzer(), enabled: t.linkmap, ready: ctx.linkmapPath != nil, ctx: ctx,
            disabledMsg: "LinkMap 解析")
        // 2. 资源
        run(AssetsAnalyzer(), enabled: t.assets, ready: ctx.projectDir != nil, ctx: ctx,
            disabledMsg: "资源分析 (.app)")
        // 5. 重复资源检测
        run(DuplicatesAnalyzer(), enabled: t.duplicates, ready: ctx.projectDir != nil, ctx: ctx,
            disabledMsg: "重复资源检测")
        // 7. 无用资源检测
        run(UnusedResourcesAnalyzer(), enabled: t.unusedResources, ready: ctx.projectDir != nil, ctx: ctx,
            disabledMsg: "无用资源检测")
        // 14. app_structure（原脚本恒开启）
        run(AppStructureAnalyzer(), enabled: true, ready: ctx.appPath != nil, ctx: ctx,
            disabledMsg: "文件结构分析")

        // 3. Pod 资源归因
        run(PodResourcesAnalyzer(), enabled: t.podResources, ready: ctx.projectDir != nil, ctx: ctx,
            disabledMsg: "Pod 资源归因")
        // 6. 动态库依赖链（已删除，不跑）
        // 8. 编译配置审计
        run(BuildConfigAnalyzer(), enabled: t.buildConfig, ready: ctx.projectDir != nil, ctx: ctx,
            disabledMsg: "编译配置审计")
        // 12. Swift 标准库嵌入检测
        run(SwiftStdlibAnalyzer(), enabled: t.swiftStdlib, ready: ctx.appPath != nil, ctx: ctx,
            disabledMsg: "Swift 标准库嵌入检测")
        // 13. 本地化语言审计
        run(LocalizationAnalyzer(), enabled: t.localization, ready: ctx.appPath != nil, ctx: ctx,
            disabledMsg: "本地化语言审计")
        // 10. 无用代码检测
        run(DeadCodeAnalyzer(), enabled: t.deadCode, ready: ctx.projectDir != nil, ctx: ctx,
            disabledMsg: "无用代码检测")

        // 4. Assets.car 拆解
        run(AssetsCarAnalyzer(), enabled: t.assetsCar, ready: ctx.appPath != nil, ctx: ctx,
            disabledMsg: "Assets.car 拆解")
        // 9. App Thinning
        run(AppThinningAnalyzer(), enabled: t.thinning, ready: (ctx.xcarchivePath != nil || ctx.appPath != nil), ctx: ctx,
            disabledMsg: "App Thinning")
        // 11. ObjC 未使用代码检测
        run(ObjCUnusedAnalyzer(), enabled: t.objcUnused, ready: ctx.astDir != nil, ctx: ctx,
            disabledMsg: "ObjC 未使用代码检测")

        Logger.success("分析完成")
    }

    /// 运行单个分析器：成功写 JSON，失败写降级 JSON，未就绪/禁用则跳过。
    private func run(_ analyzer: Analyzer, enabled: Bool, ready: Bool, ctx: AnalysisContext, disabledMsg: String) {
        let outPath = (ctx.outputDir as NSString).appendingPathComponent(analyzer.outputFileName)
        guard enabled else { Logger.info("\(disabledMsg): (已禁用)"); return }
        guard ready else { Logger.info("\(analyzer.displayName): (输入不足，跳过)"); return }
        Logger.info("\(analyzer.displayName)...")
        do {
            let result = try analyzer.run(context: ctx)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try enc.encode(AnyEncodable(result))
            try data.write(to: URL(fileURLWithPath: outPath))
            // 打印终端摘要（对齐原脚本各分析器的 _print_summary）
            analyzer.printSummary?(result)
            Logger.success("JSON 已写入: \(outPath)")
        } catch {
            Logger.warn("\(analyzer.displayName) 失败: \(error)")
            try? analyzer.fallbackJSON.write(toFile: outPath, atomically: true, encoding: .utf8)
        }
    }

    private func generateReport(context ctx: AnalysisContext, appName: String) throws {
        Logger.header("生成统一报告")
        let pipeline = try RenderPipeline(outputDir: ctx.outputDir)
        try pipeline.renderAll(appName: appName)
        // 报告摘要（对齐 render.py render_unified 的输出）
        if let unified = ReportStore(ctx.outputDir).load("unified_report.json") {
            let m = unified["meta"] ?? .object([])
            let t = m["total_size"]?.intValue ?? 0
            let c = m["total_code"]?.intValue ?? 0
            let r = m["total_resource"]?.intValue ?? 0
            let e = m["entry_count"]?.intValue ?? 0
            Logger.plain(String(format: "总大小: %@", ByteFormatter.fmt(t)))
            Logger.plain("  代码: " + ByteFormatter.fmt(c))
            Logger.plain("  资源: " + ByteFormatter.fmt(r))
            Logger.plain("  条目: " + String(e))
        }
        Logger.success("报告已生成")
    }

    // MARK: 环境采集

    struct EnvInfo {
        var xcodeVersion = "未知"
        var sdkVersion = "未知"
        var deploymentTarget = ""
        var projectDir = ""
        var scheme = ""
        var appIcon = ""
        var launchImage = ""
    }

    private func collectEnv(build: Builder.BuildResult?, projectDir: String?) -> EnvInfo {
        var env = EnvInfo()
        env.projectDir = projectDir ?? ""
        if let v = try? Shell.xcodebuild(["-version"]).stdout.components(separatedBy: "\n").first, !v.isEmpty {
            env.xcodeVersion = v
        }
        guard let build else { return env }
        env.scheme = build.scheme
        if let out = try? Shell.xcodebuild(["-" + build.projType.rawValue, build.projPath,
                                            "-scheme", build.scheme, "-showBuildSettings"]).stdout {
            func setting(_ key: String) -> String {
                for line in out.components(separatedBy: "\n") {
                    let s = line.trimmingCharacters(in: .whitespaces)
                    // 精确匹配 "KEY = value" 行（避免匹配到引用该键的其它行）
                    if s.hasPrefix(key + " = ") {
                        if let r = s.range(of: " = ") {
                            return String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                        }
                    } else if s == key + " =" {
                        return ""
                    }
                }
                return ""
            }
            env.sdkVersion = setting("SDKROOT").isEmpty ? "未知" : setting("SDKROOT")
            env.deploymentTarget = setting("IPHONEOS_DEPLOYMENT_TARGET")
            env.appIcon = setting("ASSETCATALOG_COMPILER_APPICON_NAME")
            env.launchImage = setting("ASSETCATALOG_COMPILER_LAUNCHIMAGE_NAME")
        }
        Logger.info("Xcode: \(env.xcodeVersion) | SDK: \(env.sdkVersion) | Deployment Target: \(env.deploymentTarget.isEmpty ? "未知" : env.deploymentTarget)")
        return env
    }

    private func writeBuildEnv(_ env: EnvInfo, to outputDir: String) throws {
        let json = JSONValue.object([
            ("xcode_version", .string(env.xcodeVersion)),
            ("sdk_version", .string(env.sdkVersion)),
            ("deployment_target", .string(env.deploymentTarget)),
            ("project_dir", .string(env.projectDir)),
            ("scheme", .string(env.scheme)),
            ("app_icon", .string(env.appIcon)),
            ("launch_image", .string(env.launchImage)),
            ("recorded_at", .string(DateUtil.now())),
        ])
        try Generators.writeJSON(json, to: (outputDir as NSString).appendingPathComponent("build_env.json"))
    }

    // MARK: 工具

    /// 若缺少 .package-check.json 则用内置默认模板生成（复刻 init 的拷贝行为）。
    /// 有工程目录则放到工程目录，否则退回当前目录（对齐 init 默认 ./.package-check.json）。
    private func ensurePackageCheckConfig(projectDir: String?) {
        let targetDir = (projectDir != nil && ResourceScanner.isDir(projectDir!))
            ? projectDir!
            : FileManager.default.currentDirectoryPath
        let dest = (targetDir as NSString).appendingPathComponent(".package-check.json")
        if FileManager.default.fileExists(atPath: dest) { return }
        let defaultURL = Resources.defaultPackageCheck
        guard FileManager.default.fileExists(atPath: defaultURL.path) else {
            Logger.warn("默认配置模板缺失，跳过 .package-check.json 生成")
            return
        }
        do {
            try FileManager.default.copyItem(at: defaultURL, to: URL(fileURLWithPath: dest))
            Logger.info("未找到 .package-check.json，已自动生成默认配置: \(dest)")
        } catch {
            Logger.warn("自动生成 .package-check.json 失败: \(error)")
        }
    }

    private func resolveOutputDir() throws -> String {
        let dir: String
        if let out = options.outputDir {
            dir = out
        } else {
            dir = "./package_analysis_\(DateUtil.timestamp())"
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return absolutePath(dir)
    }

    private func absolutePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: path).standardized.path
    }
}
