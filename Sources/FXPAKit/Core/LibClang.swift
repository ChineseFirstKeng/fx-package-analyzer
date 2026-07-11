import Foundation
import CClang

/// CXCursorKind（clang-c/Index.h 稳定枚举值）。
enum CK {
    static let objcInterfaceDecl: Int32 = 11
    static let objcCategoryDecl: Int32 = 12
    static let objcProtocolDecl: Int32 = 13
    static let objcPropertyDecl: Int32 = 14
    static let objcIvarDecl: Int32 = 15
    static let objcInstanceMethodDecl: Int32 = 16
    static let objcClassMethodDecl: Int32 = 17
    static let objcSuperClassRef: Int32 = 40
    static let objcProtocolRef: Int32 = 41
    static let objcClassRef: Int32 = 42
    static let typeRef: Int32 = 43
    static let declRefExpr: Int32 = 101
    static let memberRefExpr: Int32 = 102
    static let callExpr: Int32 = 103
    static let objcMessageExpr: Int32 = 104
    static let stringLiteral: Int32 = 109
    static let objcImplementationDecl: Int32 = 18
    static let objcCategoryImplDecl: Int32 = 19
}

/// CXTypeKind（部分）。
enum TK { static let invalid: Int32 = 0; static let objcId: Int32 = 27 }

/// libclang 运行时绑定 —— dlopen 当前 Xcode 的 libclang.dylib（xcrun 定位，读写同版本）。
final class LibClang {
    private let handle: UnsafeMutableRawPointer

    let createIndex: fn_createIndex
    let disposeIndex: fn_disposeIndex
    let createTU: fn_createTU
    let disposeTU: fn_disposeTU
    let tuCursor: fn_tuCursor
    let visitChildren: fn_visitChildren
    let cursorKind: fn_cursorKind
    let cursorSpelling: fn_cursorSpelling
    let getCStringFn: fn_getCString
    let disposeString: fn_disposeString
    let cursorLocation: fn_cursorLocation
    let spellingLocation: fn_spellingLocation
    let getFileName: fn_getFileName
    let cursorTypeFn: fn_cursorType
    let canonicalType: fn_canonicalType
    let pointeeType: fn_pointeeType
    let typeDeclaration: fn_typeDeclaration
    let cursorReferenced: fn_cursorReferenced
    let numArguments: fn_numArguments
    let getArgument: fn_getArgument
    let typeSpellingFn: fn_typeSpelling

    /// 定位 libclang.dylib（xcrun 推导 + 常见路径）。
    static func locate() -> String? {
        if let clang = try? Shell.run("/usr/bin/xcrun", ["--find", "clang"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), !clang.isEmpty {
            let lib = ((clang as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent + "/lib/libclang.dylib"
            if FileManager.default.fileExists(atPath: lib) { return lib }
        }
        for p in ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libclang.dylib",
                  "/Library/Developer/CommandLineTools/usr/lib/libclang.dylib"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    init?() {
        guard let path = LibClang.locate(), let h = dlopen(path, RTLD_NOW) else { return nil }
        handle = h
        func sym<T>(_ name: String, _ t: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let f1 = sym("clang_createIndex", fn_createIndex.self),
            let f2 = sym("clang_disposeIndex", fn_disposeIndex.self),
            let f3 = sym("clang_createTranslationUnit", fn_createTU.self),
            let f4 = sym("clang_disposeTranslationUnit", fn_disposeTU.self),
            let f5 = sym("clang_getTranslationUnitCursor", fn_tuCursor.self),
            let f6 = sym("clang_visitChildren", fn_visitChildren.self),
            let f7 = sym("clang_getCursorKind", fn_cursorKind.self),
            let f8 = sym("clang_getCursorSpelling", fn_cursorSpelling.self),
            let f9 = sym("clang_getCString", fn_getCString.self),
            let f10 = sym("clang_disposeString", fn_disposeString.self),
            let f11 = sym("clang_getCursorLocation", fn_cursorLocation.self),
            let f12 = sym("clang_getSpellingLocation", fn_spellingLocation.self),
            let f13 = sym("clang_getFileName", fn_getFileName.self),
            let f14 = sym("clang_getCursorType", fn_cursorType.self),
            let f15 = sym("clang_getCanonicalType", fn_canonicalType.self),
            let f16 = sym("clang_getPointeeType", fn_pointeeType.self),
            let f17 = sym("clang_getTypeDeclaration", fn_typeDeclaration.self),
            let f18 = sym("clang_getCursorReferenced", fn_cursorReferenced.self),
            let f19 = sym("clang_Cursor_getNumArguments", fn_numArguments.self),
            let f20 = sym("clang_Cursor_getArgument", fn_getArgument.self),
            let f21 = sym("clang_getTypeSpelling", fn_typeSpelling.self)
        else { return nil }
        createIndex = f1; disposeIndex = f2; createTU = f3; disposeTU = f4; tuCursor = f5
        visitChildren = f6; cursorKind = f7; cursorSpelling = f8; getCStringFn = f9; disposeString = f10
        cursorLocation = f11; spellingLocation = f12; getFileName = f13; cursorTypeFn = f14
        canonicalType = f15; pointeeType = f16; typeDeclaration = f17; cursorReferenced = f18
        numArguments = f19; getArgument = f20; typeSpellingFn = f21
    }

    // MARK: 封装

    func spelling(_ c: CXCursorT) -> String { str(cursorSpelling(c)) }
    func typeSpelling(_ t: CXTypeT) -> String { str(typeSpellingFn(t)) }
    private func str(_ s: CXStringT) -> String {
        guard let c = getCStringFn(s) else { disposeString(s); return "" }
        let out = String(cString: c); disposeString(s); return out
    }
    func location(_ c: CXCursorT) -> (String, Int) {
        var file: CXFileT? = nil; var line: UInt32 = 0; var col: UInt32 = 0; var off: UInt32 = 0
        spellingLocation(cursorLocation(c), &file, &line, &col, &off)
        let name = file != nil ? str(getFileName(file)) : ""
        return (name, Int(line))
    }
    func children(_ c: CXCursorT) -> [CXCursorT] {
        final class Box { var arr: [CXCursorT] = [] }
        let box = Box()
        _ = visitChildren(c, { cursor, _, data in
            Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().arr.append(cursor)
            return 1 // continue（不递归）
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.arr
    }
}
