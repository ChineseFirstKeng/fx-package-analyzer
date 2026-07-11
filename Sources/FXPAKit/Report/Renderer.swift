import Foundation

/// 轻量渲染器 —— 1:1 复刻 lib/renderer.py：读取模板 + 占位符替换 + CSS/JS/数据注入。
public struct Renderer {
    private let css: String
    private let jsRender: String
    private let jsCommon: String

    public init() throws {
        css = try Resources.templateString("css/variables.css")
            + Resources.templateString("css/layout.css")
            + Resources.templateString("css/components.css")
        jsRender = try Resources.templateString("js/render.js")
        jsCommon = try Resources.templateString("js/common.js")
    }

    /// 渲染模板并写盘，返回 HTML 字符串。
    @discardableResult
    public func render(template templateName: String, data: JSONValue, outputPath: String?) throws -> String {
        var tpl = try Resources.templateString(templateName)

        if tpl.contains("/* CSS_INLINE */") {
            tpl = tpl.replacingOccurrences(of: "/* CSS_INLINE */", with: css)
        } else if tpl.contains("<!-- CSS_INLINE -->") {
            tpl = tpl.replacingOccurrences(of: "<!-- CSS_INLINE -->", with: css)
        }

        // 共享常量注入 render.js 前
        let sharedConstants = JSONValue.object([
            ("TREE_ICONS", dictToJSON(ReportConstants.treeIcons)),
            ("TREE_TYPE_LABELS", dictToJSON(ReportConstants.treeTypeLabels)),
            ("PALETTE", .array(ReportConstants.palette.map { .string($0) })),
        ])
        let sharedVar = "window.SHARED_CONSTANTS = " + Self.encode(sharedConstants) + ";\n"
        let jsRenderWithShared = sharedVar + jsRender

        tpl = tpl.replacingOccurrences(of: "/* RENDER_JS_INLINE */", with: jsRenderWithShared)
        tpl = tpl.replacingOccurrences(of: "/* COMMON_JS_INLINE */", with: jsCommon)
        tpl = tpl.replacingOccurrences(of: "<!-- RENDER_JS_INLINE -->", with: jsRenderWithShared)
        tpl = tpl.replacingOccurrences(of: "<!-- COMMON_JS_INLINE -->", with: jsCommon)

        let dataScript = "<script>window.REPORT_DATA = " + Self.encode(data) + ";</script>"
        if tpl.contains("<!-- REPORT_DATA -->") {
            tpl = tpl.replacingOccurrences(of: "<!-- REPORT_DATA -->", with: dataScript)
        } else {
            tpl = tpl.replacingOccurrences(of: "<div id=\"app\"></div>",
                                           with: "<div id=\"app\"></div>\n" + dataScript)
        }

        if let outputPath {
            let dir = (outputPath as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            try tpl.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        return tpl
    }

    private func dictToJSON(_ d: [String: String]) -> JSONValue {
        .object(d.map { ($0.key, .string($0.value)) })
    }

    /// 编码 JSONValue → 紧凑 JSON 字符串（保留非 ASCII，对齐 ensure_ascii=False）。
    /// 把 `<` 转成 `<`，防止字符串内含 `</script>` 提前闭合脚本块。
    static func encode(_ v: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(v), let s = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return s.replacingOccurrences(of: "<", with: "\\u003c")
    }
}
