import Foundation

/// 报告 context 构建辅助 —— 复刻 adapters.py 的 _col/_cell/_row/_donut/_section/_type_badge/_render_tree_html。
public enum Ctx {
    public static func col(_ label: String, _ sortable: Bool = false, _ sortType: String = "str", _ align: String? = nil) -> JSONValue {
        JSONValue.obj([
            ("label", .string(label)),
            ("sortable", .bool(sortable)),
            ("sortType", .string(sortType)),
            ("align", align.map { .string($0) }),
        ])
    }

    public static func cell(_ value: String, _ cls: String = "", title: String? = nil, style: String? = nil) -> JSONValue {
        JSONValue.obj([
            ("value", .string(value)),
            ("cls", .string(cls)),
            ("title", title.map { .string($0) }),
            ("style", style.map { .string($0) }),
        ])
    }

    public static func row(_ cells: [JSONValue], sortKey: Int = 0, attrs: [(String, String)]? = nil, className: String? = nil) -> JSONValue {
        JSONValue.obj([
            ("sort_key", .int(sortKey)),
            ("cells", .array(cells)),
            ("attrs", attrs.map { .object($0.map { ($0.0, .string($0.1)) }) }),
            ("class_name", className.map { .string($0) }),
        ])
    }

    /// sort_key 为字符串的行（如 build_config 按 key 排序）。
    public static func rowStr(_ cells: [JSONValue], sortKeyStr: String, attrs: [(String, String)]? = nil, className: String? = nil) -> JSONValue {
        JSONValue.obj([
            ("sort_key", .string(sortKeyStr)),
            ("cells", .array(cells)),
            ("attrs", attrs.map { .object($0.map { ($0.0, .string($0.1)) }) }),
            ("class_name", className.map { .string($0) }),
        ])
    }

    public static func donut(_ label: String, _ value: Int, _ color: String? = nil) -> JSONValue {
        JSONValue.object([
            ("label", .string(label)),
            ("value", .int(value)),
            ("color", color.map { .string($0) } ?? .null),
        ])
    }

    /// 构建 section（title/hint/explain 恒存在，其余可选）。
    public static func section(_ title: String, hint: String = "", explain: String = "",
                               banner: JSONValue? = nil, filter: JSONValue? = nil,
                               donut: JSONValue? = nil, table: JSONValue? = nil,
                               tree: JSONValue? = nil, treeList: JSONValue? = nil,
                               contentHtml: String? = nil) -> JSONValue {
        JSONValue.obj([
            ("title", .string(title)),
            ("hint", .string(hint)),
            ("explain", .string(explain)),
            ("banner", banner),
            ("filter", filter),
            ("donut", donut),
            ("table", table),
            ("tree", tree),
            ("tree_list", treeList),
            ("content_html", contentHtml.map { .string($0) }),
        ])
    }

    public static func typeBadge(_ libType: String) -> String {
        let label = ["static": "静态库", "dynamic": "动态库", "system": "系统库"][libType] ?? libType
        let cls = ["static": "static_lib", "dynamic": "dynamic_framework", "system": "system"][libType] ?? "other"
        return "<span class=\"type-badge type-\(cls)\">\(label)</span>"
    }

    /// 服务端渲染 LinkMap 文件树 HTML（复刻 _render_tree_html）。
    public static func renderTreeHTML(_ node: JSONValue, totalSize: Int, depth: Int = 0) -> String {
        let type = node["type"]?.stringValue ?? ""
        let isDir = type == "dir"
        let isExpand = node["is_expand"]?.boolValue ?? (depth == 0)
        let icon = ReportConstants.treeIcons[type] ?? "📄"
        let typeLabel = ReportConstants.treeTypeLabels[type] ?? (type.isEmpty ? "文件" : type)
        let size = node["size"]?.intValue ?? 0
        let pct = String(format: "%.1f%%", Double(size) / Double(max(totalSize, 1)) * 100)
        let rowCls = isDir ? "tree-row dir-row" : "tree-row"
        let toggleCls = isDir ? "tree-toggle" : "tree-toggle leaf"
        let onclick = isDir ? " onclick=\"toggleTreeNode(this)\"" : ""
        let name = node["name"]?.stringValue ?? ""
        let path = node["path"]?.stringValue ?? ""
        var h = "<div class=\"tree-node\" data-expand=\"\(isExpand ? "true" : "false")\">"
        h += "<div class=\"\(rowCls)\"\(onclick)>"
        let toggleIcon = (isDir && isExpand) ? "▼" : "▶"
        h += "<span class=\"\(toggleCls)\">\(toggleIcon)</span>"
        h += "<span class=\"tree-icon\">\(icon)</span>"
        h += "<span class=\"tree-name\">\(HTMLEscape.esc(name))</span>"
        h += "<span class=\"tree-type\">\(HTMLEscape.esc(typeLabel))</span>"
        h += "<span class=\"tree-size\">\(ByteFormatter.fmt(size))</span>"
        h += "<span class=\"tree-pct\">\(pct)</span>"
        h += "<span class=\"tree-path\" title=\"\(HTMLEscape.esc(path))\">\(HTMLEscape.esc(path))</span>"
        h += "</div>"
        let children = node["children"]?.arrayValue ?? []
        if isDir && !children.isEmpty {
            let dirs = children.filter { $0["type"]?.stringValue == "dir" }
                .sorted { ($0["size"]?.intValue ?? 0) > ($1["size"]?.intValue ?? 0) }
            let files = children.filter { $0["type"]?.stringValue != "dir" }
                .sorted { ($0["size"]?.intValue ?? 0) > ($1["size"]?.intValue ?? 0) }
            let display = isExpand ? "block" : "none"
            h += "<div class=\"tree-children\" style=\"display:\(display)\">"
            for child in dirs + files {
                h += renderTreeHTML(child, totalSize: totalSize, depth: depth + 1)
            }
            h += "</div>"
        }
        h += "</div>"
        return h
    }
}
