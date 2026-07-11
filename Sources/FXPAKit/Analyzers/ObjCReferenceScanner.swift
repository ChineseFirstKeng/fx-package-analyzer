import Foundation

/// xib/storyboard/plist 静态引用扫描 —— 复刻 analyze_objc_unused.py 的 ReferenceScanner。
final class ObjCReferenceScanner {
    struct Detail { let file: String; let line: Int; let type: String; let value: String }
    let scanDir: String
    let skipDirs: Set<String>
    var foundClasses = Set<String>()
    var foundSelectors = Set<String>()
    var detail: [Detail] = []

    init(scanDir: String, skipDirs: Set<String>) {
        self.scanDir = scanDir
        self.skipDirs = skipDirs
    }

    func scan() {
        scanIBFiles()
        scanPlistFiles()
        scanStringsFiles()
    }

    private func walk(_ visit: (String) -> Void) {
        guard let en = FileManager.default.enumerator(atPath: scanDir) else { return }
        for case let rel as String in en {
            let comps = rel.components(separatedBy: "/")
            if comps.contains(where: { self.skipDirs.contains($0) }) { continue }
            visit((scanDir as NSString).appendingPathComponent(rel))
        }
    }

    // .xib / .storyboard：customClass / selector / property 属性
    private func scanIBFiles() {
        walk { path in
            guard path.hasSuffix(".xib") || path.hasSuffix(".storyboard") else { return }
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for (attr, handler) in [("customClass", 0), ("selector", 1), ("property", 2)] {
                guard let re = try? NSRegularExpression(pattern: "\(attr)=\"([^\"]+)\"") else { continue }
                let ns = content as NSString
                for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                    let v = ns.substring(with: m.range(at: 1))
                    switch handler {
                    case 0:
                        foundClasses.insert(v); detail.append(Detail(file: path, line: 0, type: "ib_custom_class", value: v))
                    case 1:
                        foundSelectors.insert(v); detail.append(Detail(file: path, line: 0, type: "ib_selector", value: v))
                    default:
                        foundSelectors.insert(v)
                        if !v.isEmpty { foundSelectors.insert("set" + v.prefix(1).uppercased() + v.dropFirst() + ":") }
                    }
                }
            }
        }
    }

    // .plist：类名样式字符串
    private func scanPlistFiles() {
        walk { path in
            guard path.hasSuffix(".plist") else { return }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return }
            extractClassNames(obj)
        }
    }

    private func extractClassNames(_ value: Any) {
        if let s = value as? String {
            if s.range(of: #"^[A-Z][a-zA-Z0-9_]{1,80}$"#, options: .regularExpression) != nil {
                let excluded: Set<String> = ["YES", "NO", "True", "False", "true", "false", "iPhone", "iPad", "Mac", "iOS", "tvOS", "macOS", "DEBUG", "RELEASE", "Default", "Standard"]
                if !excluded.contains(s) { foundClasses.insert(s) }
            }
        } else if let d = value as? [String: Any] {
            for v in d.values { extractClassNames(v) }
        } else if let a = value as? [Any] {
            for v in a { extractClassNames(v) }
        }
    }

    // .storyboard.strings / .xib.strings：类名
    private func scanStringsFiles() {
        walk { path in
            guard path.hasSuffix(".storyboard.strings") || path.hasSuffix(".xib.strings") else { return }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            guard let re = try? NSRegularExpression(pattern: #""([^"]+)"\s*=\s*"([^"]*)""#) else { return }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 2 {
                let val = ns.substring(with: m.range(at: 2))
                if val.range(of: #"^[A-Z][a-zA-Z0-9_]{1,60}$"#, options: .regularExpression) != nil { foundClasses.insert(val) }
            }
        }
    }
}
