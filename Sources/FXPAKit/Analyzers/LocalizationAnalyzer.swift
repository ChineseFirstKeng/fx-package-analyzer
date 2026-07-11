import Foundation

/// 本地化语言审计 —— 1:1 复刻 analyze_localization.py。
public struct LocalizationAnalyzer: Analyzer {
    public var outputFileName: String { "localization.json" }
    public var displayName: String { "localization_analyzer" }
    public var printSummary: ((Encodable) -> Void)? {
        { (r_: Encodable) in
            guard let r = r_ as? LocalizationResult else { return }
            let s = r.summary
            Logger.plain("")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  本地化语言审计")
            Logger.plain(String(repeating: "=", count: 60))
            Logger.plain("  语言数:      \(s.language_count)")
            Logger.plain("  本地化大小:  \(ByteFormatter.fmt(s.total_localization_size))")
            Logger.plain("  .lproj 目录: \(s.lproj_dir_count)")
            if s.source_keys_count > 0 { Logger.plain("  源码 key 引用: \(s.source_keys_count)") }
            if s.unused_keys.values.reduce(0,+) > 0 { Logger.plain("  未使用 key:  \(s.unused_keys.values.reduce(0,+))") }
            Logger.plain("")
            let sorted = r.languages.sorted { $0.value.total_size > $1.value.total_size }
            if !sorted.isEmpty {
                Logger.plain("  语言                  文件数        总大小     占比")
                Logger.plain("  ---------------- ------ ---------- ------")
                for (_, info) in sorted {
                    let pct = Double(info.total_size) / Double(max(s.total_localization_size, 1)) * 100
                    Logger.plain("  " + String(info.display_name.prefix(16)).padding(toLength: 16, withPad: " ", startingAt: 0) + " " + String(format: "%6d", info.file_count) + " " + ByteFormatter.fmt(info.total_size).padding(toLength: 10, withPad: " ", startingAt: 0) + " " + String(format: "%5.1f%%", pct))
                }
            }
            Logger.plain("")
        }
    }
    public var fallbackJSON: String { #"{"languages":{}}"# }

    public init() {}

    public func run(context: AnalysisContext) throws -> Encodable {
        guard let appPath = context.appPath, ResourceScanner.isDir(appPath) else {
            throw AnalyzerError.missingInput("localization 需要 .app 路径")
        }
        Logger.info("开始本地化语言审计 ...")
        // 收集 .lproj 目录
        var lprojDirs: [(path: String, langCode: String, relPath: String)] = []
        if let en = FileManager.default.enumerator(atPath: appPath) {
            for case let rel as String in en {
                let base = (rel as NSString).lastPathComponent
                if base.hasSuffix(".lproj") {
                    let full = (appPath as NSString).appendingPathComponent(rel)
                    lprojDirs.append((path: full, langCode: base.replacingOccurrences(of: ".lproj", with: ""), relPath: rel))
                }
            }
        }

        // 按语言聚合
        var langs: [String: LocLanguageInfo] = [:]
        var totalSize = 0
        for lproj in lprojDirs {
            let lang = lproj.langCode
            if langs[lang] == nil {
                langs[lang] = LocLanguageInfo(lang_code: lang, display_name: lang, lproj_count: 0,
                                              total_size: 0, file_count: 0, strings_count: 0, strings_size: 0,
                                              stringsdict_count: 0, stringsdict_size: 0, nib_count: 0, nib_size: 0,
                                              image_count: 0, image_size: 0, other_count: 0, other_size: 0, files: [])
            }
            var info = langs[lang]!
            info.lproj_count += 1
            if let en = FileManager.default.enumerator(atPath: lproj.path) {
                for case let rel as String in en {
                    let fp = (lproj.path as NSString).appendingPathComponent(rel)
                    guard !ResourceScanner.isDir(fp) else { continue }
                    let size = ResourceScanner.fileSize(fp)
                    let ext = "." + (rel as NSString).pathExtension.lowercased()
                    // path 相对 .app（对齐 os.path.relpath(fp, app_path)）
                    let appRelPath = (lproj.relPath as NSString).appendingPathComponent(rel)
                    info.total_size += size; info.file_count += 1
                    info.files.append(LocFile(name: (rel as NSString).lastPathComponent, path: appRelPath, size: size, ext: ext))
                    totalSize += size
                    switch ext {
                    case ".stringsdict": info.stringsdict_count += 1; info.stringsdict_size += size
                    case ".strings", ".stringsdata": info.strings_count += 1; info.strings_size += size
                    case ".nib", ".storyboardc", ".xib", ".storyboard": info.nib_count += 1; info.nib_size += size
                    case ".png", ".jpg", ".jpeg", ".heic", ".pdf", ".svg": info.image_count += 1; info.image_size += size
                    default: info.other_count += 1; info.other_size += size
                    }
                }
            }
            langs[lang] = info
        }

        // 源码引用扫描（可选）
        var sourceKeys = Set<String>()
        var unusedKeys: [String: [LocUnusedKeyEntry]] = [:]
        if let srcDir = context.projectDir, ResourceScanner.isDir(srcDir) {
            Logger.info("扫描源码中的本地化引用 ...")
            let pattern = try! NSRegularExpression(pattern: #"@?"([^"]{1,200})"|'([^']{1,200})'"#)
            if let en = FileManager.default.enumerator(atPath: srcDir) {
                for case let rel as String in en {
                    let comps = rel.components(separatedBy: "/")
                    if comps.contains(where: { $0.hasPrefix(".") || $0 == "DerivedData" || $0 == "build" || $0 == ".git" }) { continue }
                    let ext = "." + (rel as NSString).pathExtension.lowercased()
                    if ![".swift", ".m", ".mm", ".h"].contains(ext) { continue }
                    let full = (srcDir as NSString).appendingPathComponent(rel)
                    guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
                    let ns = content as NSString
                    for m in pattern.matches(in: content, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                        let r1 = m.range(at: 1), r2 = m.numberOfRanges > 2 ? m.range(at: 2) : NSRange(location: NSNotFound, length: 0)
                        let key: String
                        if r1.location != NSNotFound && r1.length > 0 { key = ns.substring(with: r1) }
                        else if r2.location != NSNotFound && r2.length > 0 { key = ns.substring(with: r2) }
                        else { continue }
                        if !key.trimmingCharacters(in: .whitespaces).isEmpty { sourceKeys.insert(key) }
                    }
                }
            }
            // 检测未使用 key（对齐 Python：无 source key 时直接跳过，避免误报全部）
            if !sourceKeys.isEmpty {
                for (lang, info) in langs {
                    var unused: [LocUnusedKeyEntry] = []
                    for f in info.files where f.ext == ".strings" {
                        let fp = (appPath as NSString).appendingPathComponent(f.path)
                        guard let content = try? String(contentsOfFile: fp, encoding: .utf8) else { continue }
                        let keyRe = try! NSRegularExpression(pattern: #""([^"]+)"\s*=\s*"[^"]*"\s*;"#)
                        let ns = content as NSString
                        for m in keyRe.matches(in: content, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                            let k = ns.substring(with: m.range(at: 1))
                            if !sourceKeys.contains(k) { unused.append(LocUnusedKeyEntry(key: k, file: f.path)) }
                        }
                    }
                    if !unused.isEmpty { unusedKeys[lang] = unused }
                }
            }
        }

        // 建议（对齐 _generate_recommendations）
        var recs: [LocRecommendation] = []
        if langs.isEmpty {
            recs.append(.init(type: "ok", title: "未发现本地化资源", detail: ".app 中未找到 .lproj 目录。"))
        } else {
            if langs.count > 10 {
                recs.append(.init(type: "warning", title: "支持 \(langs.count) 种语言，建议审查是否都需要",
                    detail: "当前支持 \(langs.count) 种语言，本地化资源总计 \(ByteFormatter.fmt(totalSize))。\n如果某些语言的用户量极低，可考虑移除以减小包体积。"))
            }
            for (_, info) in langs.sorted(by: { $0.value.total_size > $1.value.total_size }) where info.total_size > 2 * 1024 * 1024 {
                recs.append(.init(type: "warning", title: "\(info.display_name) 本地化资源过大: \(ByteFormatter.fmt(info.total_size))",
                    detail: "该语言包含 \(info.file_count) 个文件。\n- .strings 文件: \(info.strings_count) 个, \(ByteFormatter.fmt(info.strings_size))\n- NIB/Storyboard: \(info.nib_count) 个, \(ByteFormatter.fmt(info.nib_size))\n- 图片: \(info.image_count) 个, \(ByteFormatter.fmt(info.image_size))\n建议检查是否有不必要的资源本地化。"))
            }
            let totalUnused = unusedKeys.values.reduce(0) { $0 + $1.count }
            if totalUnused > 0 {
                recs.append(.init(type: "info", title: "发现 \(totalUnused) 个可能未使用的本地化 key",
                    detail: "以下语言中有 .strings key 未在源码中找到引用，可能是废弃的翻译。"))
            }
            if !langs.keys.contains(where: { $0.lowercased() == "base" }) {
                recs.append(.init(type: "info", title: "未使用 Base internationalization",
                    detail: "建议使用 Base internationalization（Base.lproj）来管理 Storyboard/XIB 的本地化，可减少重复资源。"))
            }
        }

        Logger.info("源码中收集到 \(sourceKeys.count) 个字符串字面量")
        Logger.success("审计完成: \(langs.count) 种语言, 总计 \(ByteFormatter.fmt(totalSize))")
        let absApp = URL(fileURLWithPath: appPath).standardized.path
        return LocalizationResult(
            meta: .init(app_path: absApp, source_dir: context.projectDir.map { URL(fileURLWithPath: $0).standardized.path }, generated_at: DateUtil.now()),
            summary: LocSummary(app_path: absApp, language_count: langs.count, total_localization_size: totalSize,
                                lproj_dir_count: lprojDirs.count, source_keys_count: sourceKeys.count,
                                recommendations: recs, unused_keys: unusedKeys.mapValues { $0.count }),
            languages: langs, unused_keys: unusedKeys)
    }
}
