import Foundation
import CClang

/// ObjC 未使用代码检测 —— 复刻 analyze_objc_unused.py（libclang AST + receiver 类型追踪 + xib/plist 扫描）。
public struct ObjCUnusedAnalyzer: Analyzer {
    public var outputFileName: String { "objc_unused.json" }
    public var displayName: String { "objc_unused_analyzer" }
    public var fallbackJSON: String { #"{"unused_classes":[],"unused_methods":[],"dynamic_calls":[]}"# }

    public let config: PackageCheckConfig

    public init(config: PackageCheckConfig) {
        self.config = config
    }

    /// ObjC 未使用代码默认跳过目录（向后兼容：config 中无此配置时使用）。
    static let defaultSkipDirs: Set<String> = [".git", "DerivedData", "build", ".build", "node_modules", "__pycache__", "Target Support Files", "Pods", ".svn", ".hg"]

    static let baseTypes: Set<String> = [
        "id", "Class", "SEL", "BOOL", "void", "int", "float", "double", "char", "long", "short",
        "unsigned", "NSInteger", "NSUInteger", "CGFloat", "CGPoint", "CGSize", "CGRect", "NSRange",
        "NSString", "NSArray", "NSDictionary", "NSSet", "NSNumber", "NSObject", "NSCoder",
        "NSData", "NSDate", "NSError", "NSException", "NSURL", "NSIndexPath", "NSValue",
        "UIEdgeInsets", "CATransform3D", "CGColor", "CGImage",
    ]

    static let frameworkCallbacks: Set<String> = [
        "viewDidLoad", "viewWillAppear:", "viewDidAppear:", "viewWillDisappear:", "viewDidDisappear:",
        "viewWillLayoutSubviews", "viewDidLayoutSubviews", "loadView", "awakeFromNib",
        "initWithNibName:bundle:", "initWithCoder:", "initWithStyle:",
        "prepareForSegue:sender:", "unwindForSegue:towardsViewController:",
        "drawRect:", "layoutSubviews", "sizeThatFits:", "sizeToFit",
        "hitTest:withEvent:", "pointInside:withEvent:",
        "didMoveToSuperview", "willMoveToSuperview:", "didMoveToWindow", "willMoveToWindow:",
        "intrinsicContentSize", "alignmentRectForFrame:", "frameForAlignmentRect:",
        "tableView:numberOfRowsInSection:", "tableView:cellForRowAtIndexPath:",
        "tableView:didSelectRowAtIndexPath:", "tableView:heightForRowAtIndexPath:",
        "numberOfSectionsInTableView:", "tableView:titleForHeaderInSection:",
        "tableView:canEditRowAtIndexPath:", "tableView:commitEditingStyle:forRowAtIndexPath:",
        "tableView:viewForHeaderInSection:", "tableView:viewForFooterInSection:",
        "collectionView:numberOfItemsInSection:", "collectionView:cellForItemAtIndexPath:",
        "collectionView:didSelectItemAtIndexPath:", "numberOfSectionsInCollectionView:",
        "collectionView:viewForSupplementaryElementOfKind:atIndexPath:",
        "collectionView:layout:sizeForItemAtIndexPath:",
        "scrollViewDidScroll:", "scrollViewWillBeginDragging:", "scrollViewDidEndDragging:willDecelerate:",
        "application:didFinishLaunchingWithOptions:", "applicationDidBecomeActive:",
        "applicationWillResignActive:", "applicationDidEnterBackground:", "applicationWillEnterForeground:",
        "application:openURL:options:", "application:continueUserActivity:restorationHandler:",
        "init", "dealloc", "description", "hash", "isEqual:", "copyWithZone:", "mutableCopyWithZone:",
        "encodeWithCoder:", "doesNotRecognizeSelector:",
        "becomeFirstResponder", "resignFirstResponder", "canBecomeFirstResponder", "canResignFirstResponder",
        "setNeedsLayout", "setNeedsDisplay", "layoutIfNeeded",
        "removeFromSuperview", "addSubview:", "insertSubview:atIndex:",
    ]

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let astDir = context.astDir, ResourceScanner.isDir(astDir) else {
            throw AnalyzerError.missingInput("objc_unused 需要 .ast 目录")
        }
        let astFiles = ((try? FileManager.default.contentsOfDirectory(atPath: astDir)) ?? [])
            .filter { $0.hasSuffix(".ast") }.sorted()
        guard !astFiles.isEmpty else { throw AnalyzerError.missingInput("无 .ast 文件") }
        guard let lib = LibClang() else { throw AnalyzerError.missingInput("libclang 加载失败") }

        Logger.info("AST 目录: \(astDir)")
        let sourceDir = context.projectDir ?? astDir
        let scanDir = sourceDir

        // xib/storyboard/plist 静态扫描
        Logger.info("扫描 xib/storyboard/plist 中的静态引用 ...")
        let skipDirs = config.unusedCodeSkipDirs.isEmpty ? Self.defaultSkipDirs : config.unusedCodeSkipDirs
        let scanner = ObjCReferenceScanner(scanDir: scanDir, skipDirs: skipDirs)
        scanner.scan()
        Logger.info("静态扫描完成: \(scanner.foundClasses.count) 个类, \(scanner.foundSelectors.count) 个 selector (\(String(format: "%.1f", 0))s)")

        let a = ASTWalker(lib: lib)
        a.externalClasses = scanner.foundClasses
        a.externalSelectors = scanner.foundSelectors
        a.usedClasses.formUnion(scanner.foundClasses)
        a.usedSelectorsNoClass.formUnion(scanner.foundSelectors)

        // 计算 AST 总文件大小
        var astTotalSize = 0
        for f in astFiles {
            let fp = (astDir as NSString).appendingPathComponent(f)
            astTotalSize += ResourceScanner.fileSize(fp)
        }
        Logger.info("开始分析 \(astFiles.count) 个 AST 文件（\(ByteFormatter.fmt(astTotalSize))），串行处理 ...")
        let t0 = Date()
        var filesAnalyzed = 0, filesFailed = 0
        for f in astFiles {
            let tFile = Date()
            let fp = (astDir as NSString).appendingPathComponent(f)
            guard let idx = lib.createIndex(0, 0) else { filesFailed += 1; continue }
            defer { lib.disposeIndex(idx) }
            guard let tu = fp.withCString({ lib.createTU(idx, $0) }) else { filesFailed += 1; continue }
            a.walk(lib.tuCursor(tu), filepath: fp, parentClass: nil)
            lib.disposeTU(tu)
            filesAnalyzed += 1
            let elapsed = Date().timeIntervalSince(t0)
            Logger.info("[\(filesAnalyzed)/\(astFiles.count)] \(f)  ✅  \(String(format: "%.1f", Date().timeIntervalSince(tFile)))s (\(String(format: "%.0f", elapsed))s elapsed)")
        }
        let totalElapsed = Date().timeIntervalSince(t0)
        a.filesAnalyzed = filesAnalyzed; a.filesFailed = filesFailed
        a.injectFrameworkCallbacks()
        a.filterSystem()
        Logger.info("过滤后: \\(a.declaredClasses.count) 个类, \\(a.declaredMethods.count) 个方法")

        let unusedClasses = a.unusedClasses()
        let unusedMethods = a.unusedMethods()
        let summary = a.summary(unusedClasses: unusedClasses, unusedMethods: unusedMethods)

        // 为动态调用读取源码行（按文件缓存，避免重复读取）
        var sourceCache: [String: [String]] = [:]  // filepath → lines
        let enrichedCalls: [JSONValue] = a.dynamicCalls.compactMap { dc in
            guard FileManager.default.fileExists(atPath: dc.file) else {
                return .object([("file", .string(dc.file)), ("line", .int(dc.line)), ("source", .string("")), ("function", .string(dc.reason))])
            }
            if sourceCache[dc.file] == nil {
                sourceCache[dc.file] = (try? String(contentsOfFile: dc.file, encoding: .utf8))?.components(separatedBy: "\n") ?? []
            }
            let lines = sourceCache[dc.file] ?? []
            let idx = dc.line - 1
            let srcLine = (idx >= 0 && idx < lines.count) ? lines[idx].trimmingCharacters(in: .whitespaces) : ""
            return .object([("file", .string(dc.file)), ("line", .int(dc.line)), ("source", .string(srcLine)), ("function", .string(dc.reason))])
        }

        Logger.success("分析完成: \(filesAnalyzed)/\(astFiles.count) 成功, \(filesFailed) 失败, 耗时 \(String(format: "%.1f", totalElapsed))s")
        Logger.info("     声明 \(a.declaredClasses.count) 个类, \(a.declaredMethods.count) 个方法")
        return JSONValue.object([
            ("meta", .object([
                ("ast_dir", .string(astDir)), ("source_dir", .string(sourceDir)), ("scan_dir", .string(scanDir)),
                ("mode", .string("ast_file_enhanced")), ("generated_at", .string(DateUtil.now())),
                ("version", .string("2.0 — receiver type tracking + static scan")),
            ])),
            ("summary", summary),
            ("unused_classes", .array(unusedClasses)),
            ("skipped_dummy_classes", .array(a.skippedDummyClasses)),
            ("unused_methods", .array(unusedMethods)),
            ("dynamic_calls", .array(enrichedCalls)),
            ("external_refs", .object([
                ("classes_count", .int(scanner.foundClasses.count)),
                ("selectors_count", .int(scanner.foundSelectors.count)),
                ("breakdown", .object([
                    ("ib_custom_class", .int(scanner.detail.filter { $0.type == "ib_custom_class" }.count)),
                    ("ib_selector", .int(scanner.detail.filter { $0.type == "ib_selector" }.count)),
                ])),
            ])),
        ])
    }
}

// MARK: AST 遍历器（复刻 ASTAnalyzer）

final class ASTWalker {
    let lib: LibClang
    var declaredClasses: [String: (file: String, line: Int, isProtocol: Bool)] = [:]
    var declaredClassOrder: [String] = []
    var declaredMethods: [String: (cls: String, sel: String, type: String, file: String, line: Int)] = [:]
    var declaredMethodOrder: [String] = []
    var usedSelectorsExact: [String: Set<String>] = [:]
    var usedSelectorsIdType = Set<String>()
    var usedSelectorsNoClass = Set<String>()
    var usedClasses = Set<String>()
    var classesWithCategory = Set<String>()
    var dynamicCalls: [(file: String, line: Int, reason: String)] = []
    var externalClasses = Set<String>()
    var externalSelectors = Set<String>()
    var filesAnalyzed = 0, filesFailed = 0
    private lazy var systemPaths: [String] = ASTWalker.computeSystemPaths()

    init(lib: LibClang) { self.lib = lib }

    static func computeSystemPaths() -> [String] {
        var paths = ["/Applications/Xcode.app/", "/System/Library/"]
        if let sdk = try? Shell.run("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), !sdk.isEmpty {
            paths.append(sdk)
        }
        return paths
    }
    private func isSystemPath(_ p: String) -> Bool { !p.isEmpty && systemPaths.contains { p.hasPrefix($0) } }
    private static let declKinds: Set<Int32> = [CK.objcInterfaceDecl, CK.objcProtocolDecl, CK.objcCategoryDecl,
                                                CK.objcInstanceMethodDecl, CK.objcClassMethodDecl, CK.objcPropertyDecl, CK.objcIvarDecl]

    func walk(_ cursor: CXCursorT, filepath: String, parentClass: String?) {
        for node in lib.children(cursor) {
            let kind = lib.cursorKind(node)
            let (locFileRaw, line) = lib.location(node)
            let locFile = locFileRaw.isEmpty ? filepath : locFileRaw

            if ASTWalker.declKinds.contains(kind) && isSystemPath(locFile) { continue }

            switch kind {
            case CK.objcInterfaceDecl:
                let name = lib.spelling(node)
                if !name.isEmpty { addClass(name, file: locFile, line: line, isProtocol: false) }
                walk(node, filepath: locFile, parentClass: name)
            case CK.objcProtocolDecl:
                let name = lib.spelling(node)
                if !name.isEmpty { addClass(name, file: locFile, line: line, isProtocol: true) }
                walk(node, filepath: locFile, parentClass: name)
            case CK.objcCategoryDecl:
                var extended: String? = nil
                for child in lib.children(node) where lib.cursorKind(child) == CK.objcClassRef && !lib.spelling(child).isEmpty {
                    extended = lib.spelling(child); break
                }
                let parentCls = extended ?? (lib.spelling(node).isEmpty ? "Unknown" : lib.spelling(node))
                walk(node, filepath: locFile, parentClass: parentCls)
                if let ext = extended {
                    usedClasses.insert(ext)
                    addClass(ext, file: locFile, line: line, isProtocol: false)
                }
            case CK.objcInstanceMethodDecl:
                let sel = lib.spelling(node)
                if !sel.isEmpty, let cn = parentClass, !cn.isEmpty { addMethod(cn, sel, "-", locFile, line) }
                walk(node, filepath: locFile, parentClass: parentClass)
            case CK.objcClassMethodDecl:
                let sel = lib.spelling(node)
                if let cn = parentClass, !cn.isEmpty, sel == "load" || sel == "initialize" {
                    usedSelectorsExact[cn, default: []].insert(sel)
                }
                if !sel.isEmpty, let cn = parentClass, !cn.isEmpty { addMethod(cn, sel, "+", locFile, line) }
                walk(node, filepath: locFile, parentClass: parentClass)
            case CK.objcPropertyDecl:
                let pn = lib.spelling(node)
                if !pn.isEmpty {
                    let setter = "set" + pn.prefix(1).uppercased() + pn.dropFirst() + ":"
                    usedSelectorsNoClass.insert(pn); usedSelectorsNoClass.insert(setter)
                    if let pc = parentClass { usedSelectorsExact[pc, default: []].insert(pn); usedSelectorsExact[pc, default: []].insert(setter) }
                }
                walk(node, filepath: filepath, parentClass: parentClass)
            case CK.objcMessageExpr:
                handleMessage(node, parentClass: parentClass)
                walk(node, filepath: filepath, parentClass: parentClass)
            case CK.callExpr:
                handleCall(node)
                walk(node, filepath: filepath, parentClass: parentClass)
            case CK.typeRef:
                let tn = lib.spelling(node)
                if !tn.isEmpty && !ObjCUnusedAnalyzer.baseTypes.contains(tn) { usedClasses.insert(tn) }
                walk(node, filepath: filepath, parentClass: parentClass)
            case CK.objcClassRef, CK.objcProtocolRef:
                let s = lib.spelling(node)
                if !s.isEmpty { usedClasses.insert(s) }
                walk(node, filepath: filepath, parentClass: parentClass)
            default:
                walk(node, filepath: filepath, parentClass: parentClass)
            }
        }
    }

    private func addClass(_ name: String, file: String, line: Int, isProtocol: Bool) {
        if declaredClasses[name] == nil {
            declaredClassOrder.append(name)
            declaredClasses[name] = (file, line, isProtocol)
        }
    }
    private func addMethod(_ cn: String, _ sel: String, _ type: String, _ file: String, _ line: Int) {
        let k = "\(cn)-\(sel)"
        if declaredMethods[k] == nil { declaredMethodOrder.append(k); declaredMethods[k] = (cn, sel, type, file, line) }
    }

    // MARK: receiver 解析

    private func resolveReceiver(_ cursor: CXCursorT, _ parentClass: String?) -> (String?, String) {
        let kids = lib.children(cursor)
        guard let receiver = kids.first else { return (nil, "unknown") }
        let rk = lib.cursorKind(receiver)
        if rk == CK.objcClassRef {
            let s = lib.spelling(receiver); return s.isEmpty ? (nil, "unknown") : (s, "exact")
        }
        if rk == CK.objcSuperClassRef { return parentClass != nil ? (parentClass, "exact") : (nil, "unknown") }
        if rk == CK.declRefExpr {
            if lib.spelling(receiver) == "self" { return parentClass != nil ? (parentClass, "exact") : (nil, "unknown") }
            let t = lib.canonicalType(lib.cursorTypeFn(receiver))
            if t.kind == TK.objcId { return (nil, "id") }
            if t.kind != TK.invalid {
                let decl = lib.typeDeclaration(lib.pointeeType(t))
                let ds = lib.spelling(decl)
                if !ds.isEmpty { return (ds, "exact") }
                let sp = lib.typeSpelling(t)
                if !sp.isEmpty && sp != "id" && sp != "instancetype" && sp.range(of: #"^[A-Z][a-zA-Z0-9_]+$"#, options: .regularExpression) != nil {
                    return (sp, "exact")
                }
            }
            return (nil, "unknown")
        }
        if rk == CK.objcMessageExpr || rk == CK.callExpr {
            let t = lib.canonicalType(lib.cursorTypeFn(receiver))
            if t.kind == TK.objcId { return (nil, "id") }
            if t.kind != TK.invalid {
                let ds = lib.spelling(lib.typeDeclaration(lib.pointeeType(t)))
                if !ds.isEmpty { return (ds, "exact") }
            }
            return (nil, "unknown")
        }
        let rs = lib.spelling(receiver)
        if !rs.isEmpty && rs.range(of: #"^[A-Z][a-zA-Z0-9_]+$"#, options: .regularExpression) != nil { return (rs, "exact") }
        return (nil, "unknown")
    }

    private func handleMessage(_ node: CXCursorT, parentClass: String?) {
        let sel = lib.spelling(node)
        let (className, recvType) = resolveReceiver(node, parentClass)
        if !sel.isEmpty {
            if recvType == "exact", let cn = className { usedSelectorsExact[cn, default: []].insert(sel); usedClasses.insert(cn) }
            else if recvType == "id" { usedSelectorsIdType.insert(sel) }
            else { usedSelectorsNoClass.insert(sel) }
        }
        for child in lib.children(node) where lib.cursorKind(child) == CK.objcClassRef {
            let s = lib.spelling(child); if !s.isEmpty { usedClasses.insert(s) }
            return
        }
    }

    private func handleCall(_ node: CXCursorT) {
        let callee = lib.cursorReferenced(node)
        let fn = lib.spelling(callee)
        guard ["NSClassFromString", "NSSelectorFromString", "NSProtocolFromString"].contains(fn) else { return }
        let n = lib.numArguments(node)
        if n > 0 {
            for i in 0..<n {
                let arg = lib.getArgument(node, UInt32(i))
                if lib.cursorKind(arg) == CK.stringLiteral {
                    var v = lib.spelling(arg)
                    if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                    if v.hasPrefix("@\"") { v = String(v.dropFirst(2)); if v.hasSuffix("\"") { v = String(v.dropLast()) } }
                    if fn == "NSSelectorFromString" { usedSelectorsNoClass.insert(v) } else { usedClasses.insert(v) }
                } else {
                    let (file, line) = lib.location(node)
                    dynamicCalls.append((file, line, "\(fn) 参数是变量"))
                }
            }
        }
        // 对齐 Python：零参数调用不记录 dynamic_call
    }

    // MARK: 收尾

    func injectFrameworkCallbacks() { usedSelectorsNoClass.formUnion(ObjCUnusedAnalyzer.frameworkCallbacks) }

    func filterSystem() {
        func thirdParty(_ f: String) -> Bool {
            if f.isEmpty { return false }
            for p in systemPaths where f.hasPrefix(p) { return true }
            return false
        }
        for name in declaredClassOrder where thirdParty(declaredClasses[name]?.file ?? "") { declaredClasses[name] = nil }
        declaredClassOrder = declaredClassOrder.filter { declaredClasses[$0] != nil }
        for k in declaredMethodOrder where thirdParty(declaredMethods[k]?.file ?? "") { declaredMethods[k] = nil }
        declaredMethodOrder = declaredMethodOrder.filter { declaredMethods[$0] != nil }
        dynamicCalls = dynamicCalls.filter { !thirdParty($0.file) }
    }

    func unusedClasses() -> [JSONValue] {
        var result: [JSONValue] = []
        var skippedDummy: [JSONValue] = []  // PodsDummy_ 占位类，单独标记
        for name in declaredClassOrder.sorted() {
            guard let info = declaredClasses[name], !info.isProtocol else { continue }
            if usedClasses.contains(name) || externalClasses.contains(name) { continue }
            // 过滤 PodsDummy_ 占位类（CocoaPods 自动生成，非业务代码）
            if name.hasPrefix("PodsDummy_") {
                skippedDummy.append(JSONValue.object([
                    ("name", .string(name)),
                    ("file", .string(info.file)), ("line", .int(info.line)),
                    ("kind", .string("class")),
                    ("reason", .string("CocoaPods 自动生成的占位类，不含业务代码")),
                ]))
                continue
            }
            result.append(JSONValue.object([("name", .string(name)), ("file", .string(info.file)), ("line", .int(info.line)),
                                             ("kind", .string("class"))]))
        }
        skippedDummyClasses = skippedDummy
        return result
    }

    /// PodsDummy_ 占位类（被过滤，不计入未使用统计）
    var skippedDummyClasses: [JSONValue] = []

    func unusedMethods() -> [JSONValue] {
        var result: [JSONValue] = []
        for k in declaredMethodOrder {
            guard let m = declaredMethods[k] else { continue }
            if m.type == "+" && (m.sel == "load" || m.sel == "initialize") { continue }
            if m.type == "-" && m.sel.hasPrefix("init") { continue }
            if usedSelectorsExact[m.cls]?.contains(m.sel) == true { continue }
            let displayName = "\(m.type)[\(m.cls) \(m.sel)]"
            result.append(JSONValue.object([("name", .string(displayName)), ("class", .string(m.cls)), ("selector", .string(m.sel)),
                                             ("type", .string(m.type)), ("file", .string(m.file)), ("line", .int(m.line)),
                                             ("kind", .string("method"))]))
        }
        return result.sorted { ($0["name"]?.stringValue ?? "") < ($1["name"]?.stringValue ?? "") }
    }

    func summary(unusedClasses uc: [JSONValue], unusedMethods um: [JSONValue]) -> JSONValue {
        let exactTotal = usedSelectorsExact.values.reduce(0) { $0 + $1.count }
        return .object([
            ("files_analyzed", .int(filesAnalyzed)), ("files_failed", .int(filesFailed)),
            ("declared_classes", .int(declaredClasses.count)), ("declared_methods", .int(declaredMethods.count)),
            ("used_classes", .int(usedClasses.count + externalClasses.count)),
            ("used_selectors_exact", .int(exactTotal)),
            ("used_selectors_id_type", .int(usedSelectorsIdType.count)),
            ("used_selectors_no_class", .int(usedSelectorsNoClass.count)),
            ("used_selectors_total", .int(exactTotal + usedSelectorsIdType.count + usedSelectorsNoClass.count)),
            ("unused_classes", .int(uc.count)),
            ("unused_methods", .int(um.count)),
            ("dynamic_calls", .int(dynamicCalls.count)),
            ("total_unused", .int(uc.count + um.count)),
            ("external_refs_classes", .int(externalClasses.count)),
            ("external_refs_selectors", .int(externalSelectors.count)),
            ("skipped_dummy_classes", .int(skippedDummyClasses.count)),
        ])
    }
}
