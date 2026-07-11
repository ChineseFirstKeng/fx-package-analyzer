import XCTest
@testable import FXPAKit

/// 端到端集成：真实 LinkMap + 资源 → 分析器 → 渲染管线 → HTML。
final class FullPipelineTests: XCTestCase {
    var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "fxpa_it_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    func testEndToEndRender() throws {
        let outputDir = tmp + "/out"
        let projectDir = tmp + "/proj"
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // 1. 资源工程：一个松散 png
        let img = projectDir + "/logo.png"
        FileManager.default.createFile(atPath: img, contents: Data(count: 4096))

        // 2. 样例 LinkMap（主工程 Demo + Pod AFNetworking）
        let linkmap = tmp + "/Demo-LinkMap.txt"
        let lmText = """
        # Path: /tmp/Demo.app/Demo
        # Arch: arm64

        # Object files:
        [  0] linker synthesized
        [  1] /DD/Build/Demo.build/Objects-normal/arm64/AppDelegate.o
        [  2] /Users/x/Pods/AFNetworking/AFURLSessionManager.o

        # Sections:
        0x100004000\t0x00002000\t__TEXT\t__text
        0x100006000\t0x00000400\t__TEXT\t__cstring

        # Symbols:
        0x100004000\t0x00001800\t[  1] -[AppDelegate application:didFinishLaunching:]
        0x100005800\t0x00000800\t[  2] -[AFURLSessionManager init]
        0x100006000\t0x00000400\t[  1] literal string
        """
        try lmText.write(toFile: linkmap, atomically: true, encoding: .utf8)

        let config = PackageCheckConfig.loadDefault()
        let ctx = AnalysisContext(
            appPath: nil, projectDir: projectDir, linkmapPath: linkmap, podLinkmapsDir: nil,
            xcarchivePath: nil, buildDir: nil, builtProductsDir: nil, scheme: "Demo",
            configuration: "Release", outputDir: outputDir, podMappingPath: nil,
            appIcon: nil, launchImage: nil, config: config, thinningExportPath: nil)

        // 3. 运行核心分析器，写 JSON
        try writeResult(LinkMapAnalyzer(), ctx, outputDir)
        try writeResult(AssetsAnalyzer(), ctx, outputDir)
        // app_structure：用一个最小 .app
        let app = tmp + "/Demo.app"
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: app + "/Demo", contents: Data([0xCF, 0xFA, 0xED, 0xFE] + Array(repeating: 0, count: 100)))
        let appCtx = AnalysisContext(
            appPath: app, projectDir: projectDir, linkmapPath: nil, podLinkmapsDir: nil,
            xcarchivePath: nil, buildDir: nil, builtProductsDir: nil, scheme: "Demo",
            configuration: "Release", outputDir: outputDir, podMappingPath: nil,
            appIcon: nil, launchImage: nil, config: config, thinningExportPath: nil)
        try writeResult(AppStructureAnalyzer(), appCtx, outputDir)

        // 4. 渲染
        let pipeline = try RenderPipeline(outputDir: outputDir)
        try pipeline.renderAll(appName: "Demo")

        // 5. 断言
        let store = ReportStore(outputDir)
        // linkmap.json：两个模块（Demo + AFNetworking）
        let lm = store.load("linkmap.json")!
        let modNames = (lm["modules"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(modNames.contains("Demo"))
        XCTAssertTrue(modNames.contains("AFNetworking"))

        // pod_modules.json：模块非空
        let pm = store.load("pod_modules.json")!
        XCTAssertFalse((pm["modules"]?.arrayValue ?? []).isEmpty)

        // unified_report.json：entries 含主工程（Demo→主工程可执行文件）
        let unified = store.load("unified_report.json")!
        let entryNames = (unified["entries"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(entryNames.contains(ReportConstants.mainAppLabel), "应把 Demo 识别为主工程，实际: \(entryNames)")
        XCTAssertTrue(entryNames.contains("AFNetworking"))

        // asset.json：by_source 含 logo.png 来源
        let asset = store.load("asset.json")!
        XCTAssertEqual(asset["total_size"]?.intValue, 4096)

        // HTML 产物存在且含关键内容
        for f in ["unified_report.html", "overview_report.html", "pod_modules_report.html", "asset_report.html"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputDir + "/" + f), "缺少 \(f)")
        }
        let podHTML = try String(contentsOfFile: outputDir + "/pod_modules_report.html", encoding: .utf8)
        XCTAssertTrue(podHTML.contains("AFNetworking"), "pod_modules 报告应含模块名")
    }

    private func writeResult(_ analyzer: Analyzer, _ ctx: AnalysisContext, _ dir: String) throws {
        let result = try analyzer.run(context: ctx)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try enc.encode(AnyEncodable(result))
        try data.write(to: URL(fileURLWithPath: dir + "/" + analyzer.outputFileName))
    }
}
