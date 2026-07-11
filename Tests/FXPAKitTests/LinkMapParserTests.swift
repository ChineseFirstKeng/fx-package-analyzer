import XCTest
@testable import FXPAKit

final class LinkMapParserTests: XCTestCase {
    /// 用一小段真实格式的 LinkMap 文本验证三段解析与模块归属。
    func testParseSmallLinkMap() throws {
        let text = """
        # Path: /tmp/Demo.app/Demo
        # Arch: arm64

        # Object files:
        [  0] linker synthesized
        [  1] /Users/x/DerivedData/Demo.build/Objects-normal/arm64/ViewController.o
        [  2] /Users/x/Pods/AFNetworking/AFHTTPSessionManager.o
        [  3] /Users/x/libStuff.a(Helper.o)

        # Sections:
        0x100004000\t0x00001000\t__TEXT\t__text
        0x100005000\t0x00000200\t__TEXT\t__stubs

        # Symbols:
        0x100004000\t0x00000800\t[  1] -[ViewController viewDidLoad]
        0x100004800\t0x00000400\t[  2] -[AFHTTPSessionManager init]
        0x100004C00\t0x00000400\t[  3] _helperFunc
        0x100005000\t0x00000200\tcompact unwind info
        # Dead Stripped Symbols:
        0x0\t0x00000010\t[  1] _deadFunc
        """
        // 写入临时文件
        let tmp = NSTemporaryDirectory() + "test_linkmap_\(UUID().uuidString).txt"
        try text.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let parser = LinkMapParser(path: tmp)
        try parser.parse()

        // Sections 总大小 = 0x1000 + 0x200 = 4608
        XCTAssertEqual(parser.totalSize, 0x1000 + 0x200)
        // 4 个 object files（含 id 0）
        XCTAssertEqual(parser.objectFileCount, 4)
        // 4 个符号（Dead Stripped 被排除，compact unwind 无 file_id 但仍计入符号总数）
        XCTAssertEqual(parser.symbols.count, 4)

        let modules = parser.getModules()
        let names = modules.map { $0.name }
        // 归属：ViewController.o → Demo（.build 规则）；AFHTTPSessionManager → AFNetworking（/Pods/）；Helper → Stuff（.a lib 去前缀）
        XCTAssertTrue(names.contains("Demo"))
        XCTAssertTrue(names.contains("AFNetworking"))
        XCTAssertTrue(names.contains("Stuff"))
        // 模块按大小降序：Demo(0x800) 最大
        XCTAssertEqual(modules.first?.name, "Demo")

        // lib_type：Demo 含真实 .o → static；Stuff 是 .a( → static
        let stuff = modules.first { $0.name == "Stuff" }
        XCTAssertEqual(stuff?.lib_type, "static")
    }

    func testGuessModuleRules() {
        XCTAssertEqual(LinkMapParser.guessModule("/x/libAFNetworking.a(Foo.o)"), "AFNetworking")
        XCTAssertEqual(LinkMapParser.guessModule("/x/Pods/SDWebImage/Bar.o"), "SDWebImage")
        // 真实 Xcode 路径：Pods.build 与 MyPod.build 间有中间目录，findall 取最后一个 → MyPod
        XCTAssertEqual(LinkMapParser.guessModule("/DD/Build/Pods.build/Release-iphoneos/MyPod.build/Objects-normal/arm64/Baz.o"), "MyPod")
        XCTAssertEqual(LinkMapParser.guessModule("/x/Alamofire.framework/Alamofire"), "Alamofire")
        XCTAssertEqual(LinkMapParser.guessModule("linker synthesized"), "linker synthesized")
    }

    func testByteFormatter() {
        XCTAssertEqual(ByteFormatter.fmt(0), "0 B")
        XCTAssertEqual(ByteFormatter.fmt(1024), "1.00 KB")
        XCTAssertEqual(ByteFormatter.fmt(1_048_576), "1.00 MB")
    }
}

extension LinkMapParserTests {
    func testPodLinkmapFrameworkName() throws {
        let tmp = NSTemporaryDirectory() + "podlm_\(UUID().uuidString)"
        let podDir = tmp + "/pod_linkmaps"
        try FileManager.default.createDirectory(atPath: podDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // 主 linkmap（空壳）
        let mainLM = tmp + "/Main-LinkMap.txt"
        try "# Path: /x/Demo.app/Demo\n# Object files:\n[  0] linker synthesized\n# Sections:\n0x0\t0x10\t__TEXT\t__text\n# Symbols:\n0x0\t0x10\t[  0] _s\n".write(toFile: mainLM, atomically: true, encoding: .utf8)
        // Pod linkmap，文件名带 -LinkMap.txt，首行 # Path 指向 framework 二进制
        let podLM = podDir + "/SDWebImage-LinkMap.txt"
        try "# Path: /DD/Build/SDWebImage.framework/SDWebImage\n# Arch: arm64\n# Object files:\n[  0] linker synthesized\n[  1] /Pods/SDWebImage/SDWebImage.build/x/SDImageCache.o\n# Sections:\n0x100\t0x200\t__TEXT\t__text\n# Symbols:\n0x100\t0x200\t[  1] -[SDImageCache init]\n".write(toFile: podLM, atomically: true, encoding: .utf8)

        let ctx = AnalysisContext(appPath: nil, projectDir: nil, linkmapPath: mainLM, podLinkmapsDir: podDir,
            xcarchivePath: nil, buildDir: nil, builtProductsDir: nil, scheme: nil, configuration: "Release",
            outputDir: tmp, podMappingPath: nil, appIcon: nil, launchImage: nil, config: .loadDefault(), thinningExportPath: nil)
        let r = try LinkMapAnalyzer().run(context: ctx)
        let v = JSONValue.parse(try JSONEncoder().encode(AnyEncodable(r)))!
        let names = (v["modules"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        print("pod linkmap 模块名:", names)
        XCTAssertTrue(names.contains("SDWebImage"), "Pod 框架名应为 SDWebImage")
        XCTAssertFalse(names.contains(where: { $0.contains("LinkMap.txt") }), "不应出现带 .txt 的模块名")
    }
}
