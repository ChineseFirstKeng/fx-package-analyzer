import XCTest
@testable import FXPAKit

/// Assets.car / App Thinning 对真实产物验证（仅当文件存在时运行）。
final class AssetsCarThinningTests: XCTestCase {
    let base = "/Users/shenzhoudiyikeng/Documents/gitCode/fx-package-analyzer/package_analysis_20260709_041016"

    func testAssetsCarVsPython() throws {
        let app = base + "/Cytx.app"
        guard ResourceScanner.isDir(app) else { throw XCTSkip("Cytx.app 不存在") }
        let ctx = AnalysisContext(appPath: app, projectDir: nil, linkmapPath: nil, podLinkmapsDir: nil,
            xcarchivePath: nil, buildDir: nil, builtProductsDir: nil, scheme: nil, configuration: "Release",
            outputDir: NSTemporaryDirectory(), podMappingPath: nil, appIcon: nil, launchImage: nil,
            config: .loadDefault(), thinningExportPath: nil)
        let result = try AssetsCarAnalyzer().run(context: ctx)
        let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes]
        let data = try enc.encode(AnyEncodable(result))
        try data.write(to: URL(fileURLWithPath: "/tmp/my_car.json"))
        let v = JSONValue.parse(data)!
        let meta = v["meta"]!
        print("assets_car: car=\(meta["car_files_found"]?.intValue ?? -1) assets=\(meta["total_asset_count"]?.intValue ?? -1) total=\(meta["total_size"]?.intValue ?? -1) types=\((v["type_summary"]?.objectPairs ?? []).count) dups=\((v["duplicates"]?.arrayValue ?? []).count) scale=\((v["scale_analysis"]?.arrayValue ?? []).count)")
        XCTAssertEqual(meta["total_asset_count"]?.intValue, 339)
        XCTAssertEqual(meta["total_size"]?.intValue, 6576268)
        XCTAssertEqual((v["type_summary"]?.objectPairs ?? []).count, 4)
    }

    func testAppThinningEmptyWhenNoReport() throws {
        let app = base + "/Cytx.app"
        guard ResourceScanner.isDir(app) else { throw XCTSkip("Cytx.app 不存在") }
        // 无 .xcarchive 报告时：variants 为空（faithful）
        let ctx = AnalysisContext(appPath: app, projectDir: nil, linkmapPath: nil, podLinkmapsDir: nil,
            xcarchivePath: nil, buildDir: nil, builtProductsDir: nil, scheme: nil, configuration: "Release",
            outputDir: NSTemporaryDirectory(), podMappingPath: nil, appIcon: nil, launchImage: nil,
            config: .loadDefault(), thinningExportPath: nil)
        let result = try AppThinningAnalyzer().run(context: ctx)
        let enc = JSONEncoder()
        let v = JSONValue.parse(try enc.encode(AnyEncodable(result)))!
        // .app 输入 → asset_thinning 有条目，variants 空
        print("app_thinning: variants=\((v["variants"]?.arrayValue ?? []).count) asset_entries=\(v["summary"]?["asset_thinning_entries"]?.intValue ?? -1)")
        XCTAssertEqual((v["variants"]?.arrayValue ?? []).count, 0)
    }
}
