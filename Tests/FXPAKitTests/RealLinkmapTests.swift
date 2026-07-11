import XCTest
@testable import FXPAKit

/// 用真实工程产物：验证 LinkMap 解析 + 重新生成完整报告（仅当文件存在时运行）。
/// 复用上次运行已产出的 Cytx-LinkMap.txt / app_structure.json / asset.json / pod_mapping.json，
/// 无需重新编译即可生成修复后的报告到 <dir>_fixed。
final class RealLinkmapTests: XCTestCase {
    func testRegenerateFixedReport() throws {
        let outDir = "/Users/shenzhoudiyikeng/Documents/gitCode/fx-package-analyzer/package_analysis_20260709_041016"
        let lmPath = outDir + "/pod_linkmaps/Cytx-LinkMap.txt"
        guard FileManager.default.fileExists(atPath: lmPath) else { throw XCTSkip("真实 LinkMap 不存在") }

        let fixed = outDir + "_fixed"
        try? FileManager.default.removeItem(atPath: fixed)
        try FileManager.default.createDirectory(atPath: fixed, withIntermediateDirectories: true)
        for f in ["app_structure.json", "pod_mapping.json", "build_env.json"] {
            try? FileManager.default.copyItem(atPath: outDir + "/" + f, toPath: fixed + "/" + f)
        }

        let config = PackageCheckConfig.loadDefault()

        // 重新扫描资源（源码目录），确保 asset/duplicate/unused JSON 与当前逻辑一致
        let srcDir = "/Users/shenzhoudiyikeng/Desktop/Cytx_副本"
        if ResourceScanner.isDir(srcDir) {
            let aCtx = AnalysisContext(
                appPath: nil, projectDir: srcDir, linkmapPath: nil, podLinkmapsDir: nil,
                xcarchivePath: nil, buildDir: nil, builtProductsDir: nil, scheme: "Cytx",
                configuration: "Release", outputDir: fixed, podMappingPath: nil,
                appIcon: "AppIcon", launchImage: "LaunchImage", config: config, thinningExportPath: nil)
            let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]
            try e.encode(AnyEncodable(try AssetsAnalyzer().run(context: aCtx))).write(to: URL(fileURLWithPath: fixed + "/asset.json"))
            try e.encode(AnyEncodable(try DuplicatesAnalyzer().run(context: aCtx))).write(to: URL(fileURLWithPath: fixed + "/duplicate_resource.json"))
            try e.encode(AnyEncodable(try UnusedResourcesAnalyzer().run(context: aCtx))).write(to: URL(fileURLWithPath: fixed + "/unused_resource.json"))
        } else {
            try? FileManager.default.copyItem(atPath: outDir + "/asset.json", toPath: fixed + "/asset.json")
        }

        // 解析主 LinkMap → linkmap.json
        let ctx = AnalysisContext(
            appPath: nil, projectDir: nil, linkmapPath: lmPath, podLinkmapsDir: nil,
            xcarchivePath: nil, buildDir: nil, builtProductsDir: nil, scheme: "Cytx",
            configuration: "Release", outputDir: fixed, podMappingPath: fixed + "/pod_mapping.json",
            appIcon: nil, launchImage: nil, config: config, thinningExportPath: nil)
        let result = try LinkMapAnalyzer().run(context: ctx)
        let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes]
        try enc.encode(AnyEncodable(result)).write(to: URL(fileURLWithPath: fixed + "/linkmap.json"))

        // Phase 2 分析器（.app + 工程；用保留的 Cytx.app + 源码目录）
        let savedApp = outDir + "/Cytx.app"
        let srcForApp = ResourceScanner.isDir(srcDir) ? srcDir : nil
        if ResourceScanner.isDir(savedApp) {
            let appCtx = AnalysisContext(
                appPath: savedApp, projectDir: srcForApp, linkmapPath: lmPath, podLinkmapsDir: nil,
                xcarchivePath: nil, buildDir: nil, builtProductsDir: nil, scheme: "Cytx",
                configuration: "Release", outputDir: fixed, podMappingPath: fixed + "/pod_mapping.json",
                appIcon: "AppIcon", launchImage: "LaunchImage", config: config, thinningExportPath: nil)
            try enc.encode(AnyEncodable(try SwiftStdlibAnalyzer().run(context: appCtx))).write(to: URL(fileURLWithPath: fixed + "/swift_stdlib.json"))
            try enc.encode(AnyEncodable(try LocalizationAnalyzer().run(context: appCtx))).write(to: URL(fileURLWithPath: fixed + "/localization.json"))
        }
        if let srcForApp {
            let projCtx = AnalysisContext(
                appPath: nil, projectDir: srcForApp, linkmapPath: nil, podLinkmapsDir: nil,
                xcarchivePath: nil, buildDir: nil, builtProductsDir: nil, scheme: "Cytx",
                configuration: "Release", outputDir: fixed, podMappingPath: fixed + "/pod_mapping.json",
                appIcon: nil, launchImage: nil, config: config, thinningExportPath: nil)
            if let r = try? PodResourcesAnalyzer().run(context: projCtx) {
                try enc.encode(AnyEncodable(r)).write(to: URL(fileURLWithPath: fixed + "/pod_resource.json"))
            }
            if let r = try? BuildConfigAnalyzer().run(context: projCtx) {
                try enc.encode(AnyEncodable(r)).write(to: URL(fileURLWithPath: fixed + "/build_config_audit.json"))
            }
            if let r = try? DeadCodeAnalyzer().run(context: projCtx) {
                try enc.encode(AnyEncodable(r)).write(to: URL(fileURLWithPath: fixed + "/dead_code.json"))
            }
        }

        // 渲染全部报告
        try RenderPipeline(outputDir: fixed).renderAll(appName: "Cytx")

        let store = ReportStore(fixed)
        let pm = store.load("pod_modules.json")!
        let mods = pm["modules"]?.arrayValue ?? []
        print("✅ 修复后报告已生成:", fixed + "/unified_report.html")
        print("   模块拆解模块数:", mods.count)
        XCTAssertGreaterThan(mods.count, 0, "模块拆解不应为空")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixed + "/pod_modules_report.html"))
    }
}
