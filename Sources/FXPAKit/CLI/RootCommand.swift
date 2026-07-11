import ArgumentParser
import Foundation

/// fxpa 根命令 —— 纯容器：无参数时显示帮助（子命令列表）。
public struct RootCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "fxpa",
        abstract: "iOS 包体积统一分析工具",
        discussion: """
        一次编译，一份报告：合并 LinkMap 代码 + .app 资源 + Pod 资源。

        用法:
          fxpa check <路径> [选项]   分析包体积（路径可为 工程目录/.xcworkspace/.xcodeproj/.app/.xcarchive）
          fxpa init                  在当前目录生成默认 .package-check.json

        运行 'fxpa check -h' 查看全部分析选项与模块开关。
        """,
        version: "0.1.0",
        subcommands: [CheckCommand.self, InitCommand.self]
    )

    public init() {}

    /// 无子命令时打印帮助（fxpa == fxpa -h）。
    public func run() throws {
        print(RootCommand.helpMessage())
    }
}

/// 分析命令 `fxpa check <路径>` —— 复刻 package_analyzer.sh 的参数。
public struct CheckCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "分析包体积",
        discussion: "路径可为 工程目录 / .xcworkspace / .xcodeproj / .app / .xcarchive"
    )

    public init() {}

    @Argument(help: "工程目录 / .xcworkspace / .xcodeproj / .app / .xcarchive")
    var path: String

    @Option(name: [.short, .long], help: "编译配置 (默认 Release)")
    var configuration: String = "Release"

    @Option(name: [.customShort("t"), .long], help: "签名 Team ID（10 位大写字母数字）")
    var team: String?

    @Flag(name: .long, help: "保留编译产物")
    var keepBuild: Bool = false

    @Option(name: [.short, .long], help: "输出目录 (默认 ./package_analysis_时间戳)")
    var output: String?

    // ── 模块开关（--enable-x / --disable-x）──
    @Flag(inversion: .prefixedEnableDisable, help: "LinkMap 代码归因")
    var linkmap = true
    @Flag(inversion: .prefixedEnableDisable, help: "资源分析")
    var assets = true
    @Flag(inversion: .prefixedEnableDisable, help: "Pod 资源归因")
    var podResources = true
    @Flag(inversion: .prefixedEnableDisable, help: "Assets.car 拆解")
    var assetsCar = false
    @Flag(inversion: .prefixedEnableDisable, help: "重复资源检测")
    var duplicates = true
    @Flag(inversion: .prefixedEnableDisable, help: "无用资源检测")
    var unusedResources = true
    @Flag(inversion: .prefixedEnableDisable, help: "编译配置审计")
    var buildConfig = true
    @Flag(inversion: .prefixedEnableDisable, help: "App Thinning（需编译）")
    var thinning = false
    @Flag(inversion: .prefixedEnableDisable, help: "无用代码检测")
    var deadCode = true
    @Flag(inversion: .prefixedEnableDisable, help: "ObjC 未使用代码检测（需编译）")
    var objcUnused = false
    @Flag(inversion: .prefixedEnableDisable, help: "Swift 标准库嵌入检测")
    var swiftStdlib = true
    @Flag(inversion: .prefixedEnableDisable, help: "本地化语言审计")
    var localization = true

    @Flag(name: .customLong("enable-all"), help: "开启全部模块")
    var enableAll = false
    @Flag(name: .customLong("disable-all"), help: "关闭全部模块")
    var disableAll = false

    public func run() throws {
        var toggles = ModuleToggles()
        toggles.linkmap = linkmap
        toggles.assets = assets
        toggles.podResources = podResources
        toggles.assetsCar = assetsCar
        toggles.duplicates = duplicates
        toggles.unusedResources = unusedResources
        toggles.buildConfig = buildConfig
        toggles.thinning = thinning
        toggles.deadCode = deadCode
        toggles.objcUnused = objcUnused
        toggles.swiftStdlib = swiftStdlib
        toggles.localization = localization
        if enableAll { toggles.enableAll() }
        if disableAll { toggles.disableAll() }

        var effectiveTeam = team
        if let t = team, !t.isEmpty,
           t.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) == nil {
            Logger.warn("Team ID 格式不合法（应为 10 位大写字母数字），已忽略，退回自动检测")
            effectiveTeam = nil
        }

        let options = RunOptions(
            inputPath: path,
            configuration: configuration,
            teamID: effectiveTeam,
            keepBuild: keepBuild,
            outputDir: output,
            toggles: toggles
        )
        try Orchestrator(options: options).run()
    }
}

/// 运行参数集合。
public struct RunOptions {
    public let inputPath: String
    public let configuration: String
    public let teamID: String?
    public let keepBuild: Bool
    public let outputDir: String?
    public let toggles: ModuleToggles
}
