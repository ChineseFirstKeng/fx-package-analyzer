import XCTest
@testable import FXPAKit
import CClang

final class LibClangProbeTests: XCTestCase {
    func testLoadAndWalkProbeAst() throws {
        guard FileManager.default.fileExists(atPath: "/tmp/probe.ast") else { throw XCTSkip("probe.ast 不存在") }
        guard let lib = LibClang() else { XCTFail("libclang 加载失败"); return }
        guard let idx = lib.createIndex(0, 0) else { XCTFail("createIndex 失败"); return }
        defer { lib.disposeIndex(idx) }
        guard let tu = "/tmp/probe.ast".withCString({ lib.createTU(idx, $0) }) else { XCTFail("createTU 失败"); return }
        defer { lib.disposeTU(tu) }

        var lines: [String] = []
        func walk(_ c: CXCursorT, _ depth: Int) {
            for child in lib.children(c) {
                let kind = lib.cursorKind(child)
                let (file, line) = lib.location(child)
                if file.contains("/probe.m") {
                    lines.append("\(String(repeating: "  ", count: depth))kind=\(kind) '\(lib.spelling(child))' @\(line)")
                    if depth < 2 { walk(child, depth + 1) }
                }
            }
        }
        walk(lib.tuCursor(tu), 0)
        print("=== probe.ast 用户节点 ===")
        for l in lines.prefix(50) { print(l) }
        XCTAssertTrue(lines.contains { $0.contains("kind=11") && $0.contains("Foo") }, "应识别 ObjCInterfaceDecl Foo")
        XCTAssertTrue(lines.contains { $0.contains("kind=16") }, "应识别实例方法声明")
    }
}

extension LibClangProbeTests {
    func testObjCUnusedOnProbe() throws {
        guard FileManager.default.fileExists(atPath: "/tmp/objc_probe/probe.ast") else { throw XCTSkip("probe.ast 不存在") }
        let ctx = AnalysisContext(appPath: nil, projectDir: "/tmp", linkmapPath: nil, podLinkmapsDir: nil,
            xcarchivePath: nil, buildDir: nil, builtProductsDir: nil, scheme: nil, configuration: "Release",
            outputDir: NSTemporaryDirectory(), podMappingPath: nil, appIcon: nil, launchImage: nil,
            config: .loadDefault(), thinningExportPath: nil, astDir: "/tmp/objc_probe")
        let r = try ObjCUnusedAnalyzer().run(context: ctx)
        let v = JSONValue.parse(try JSONEncoder().encode(AnyEncodable(r)))!
        let s = v["summary"]!
        let methods = (v["unused_methods"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        print("my objc: declared_classes=\(s["declared_classes"]?.intValue ?? -1) declared_methods=\(s["declared_methods"]?.intValue ?? -1) unused_classes=\(s["unused_classes"]?.intValue ?? -1) unused_methods=\(s["unused_methods"]?.intValue ?? -1)")
        print("my unused_methods:", methods)
        XCTAssertTrue(methods.contains("-[Foo unusedMethod]"))
    }
}
