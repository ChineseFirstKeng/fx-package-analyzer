import Foundation

/// explain JSON 加载与渲染 —— 复刻 adapters.py 的 _REPORT_EXPLAINS / load_report_explains / _render_explain_block。
public enum Explains {
    /// base_name → [file_stem: var_name]
    static let reportExplains: [String: [(String, String)]] = [
        "asset": [
            ("asset_category", "explain_category"),
            ("asset_category_detail", "explain_category_detail"),
            ("asset_filetype", "explain_filetype"),
            ("asset_code_resource", "explain_code_resource"),
            ("asset_all_files", "explain_all_files"),
        ],
        "assets_car": [
            ("assets_car_asset_type", "assets_car_asset_type"),
            ("assets_car_type_detail", "assets_car_type_detail"),
            ("assets_car_largest", "assets_car_largest"),
            ("assets_car_duplicate", "assets_car_duplicate"),
            ("assets_car_scale", "assets_car_scale"),
        ],
        "linkmap": [
            ("linkmap_module_overview", "explain_module_overview"),
            ("linkmap_optimization_tips", "explain_optimization_tips"),
            ("linkmap_macho_sections", "explain_macho_sections"),
            ("linkmap_module_detail", "explain_module_detail"),
            ("linkmap_source_file", "explain_source_file"),
        ],
        "macho_dependency": [
            ("macho_binary", "explain_macho_binary"),
            ("macho_issues", "explain_macho_issues"),
        ],
        "duplicate_resource": [("duplicate_explain", "explain")],
        "dead_code": [("dead_code_explain", "dead_code_explain")],
        "swift_stdlib": [("swift_stdlib_explain", "swift_stdlib_explain")],
        "unused_resource": [("unused_resource_explain", "explain")],
        "app_thinning": [("thinning_explain", "explain")],
        "build_config_audit": [("build_config_explain", "explain")],
        "pod_resource": [("pod_resource_explain", "explain")],
        "module_breakdown": [("module_breakdown_explain", "explain")],
        "objc_unused": [("objc_unused_explain", "explain")],
        "localization": [("localization_explain", "explain")],
        "overview": [
            ("app_structure_explain", "app_structure_explain"),
            ("overview_kpi_explain", "overview_kpi_explain"),
        ],
    ]

    /// 加载某报告的所有 explain JSON。
    public static func load(_ baseName: String) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (fileStem, varName) in reportExplains[baseName] ?? [] {
            if let data = Resources.explainData(fileStem),
               let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
                result[varName] = v
            }
        }
        return result
    }

    /// 渲染 explain JSON 为 HTML 片段（复刻 _render_explain_block）。
    public static func renderBlock(_ data: JSONValue?) -> String {
        guard let data, let steps = data["steps"]?.arrayValue, !steps.isEmpty else { return "" }
        var parts: [String] = []
        if let title = data["title"]?.stringValue, !title.isEmpty {
            parts.append("<b>&#12304;\(title)&#12305;</b><br><br>")
        }
        for step in steps {
            let t = step["type"]?.stringValue ?? "step"
            let title = step["title"]?.stringValue ?? ""
            switch t {
            case "step", "":
                let desc = (step["desc"]?.stringValue ?? "").replacingOccurrences(of: "\n", with: "<br>")
                parts.append("<b>\(title)</b><br>\(desc)<br><br>")
            case "items":
                parts.append("<b>\(title)&#65306;</b><br>")
                for item in step["items"]?.arrayValue ?? [] {
                    parts.append("- \(item.stringValue ?? "")<br>")
                }
                parts.append("<br>")
            case "kv":
                parts.append("<b>\(title)&#65306;</b><br>")
                for pair in step["pairs"]?.arrayValue ?? [] {
                    let arr = pair.arrayValue ?? []
                    let a = arr.first?.stringValue ?? ""
                    let b = arr.count > 1 ? (arr[1].stringValue ?? "") : ""
                    parts.append("\(a) → \(b)<br>")
                }
                parts.append("<br>")
            case "code":
                parts.append("<b>\(title)&#65306;</b><br><pre>\(step["code"]?.stringValue ?? "")</pre><br>")
            case "text":
                let desc = (step["desc"]?.stringValue ?? "").replacingOccurrences(of: "\n", with: "<br>")
                parts.append("\(desc)<br><br>")
            default:
                break
            }
        }
        return parts.joined()
    }
}
