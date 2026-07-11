import Foundation

/// 报告层共享常量 —— 复刻 lib/shared_constants.py 与 adapters.py 顶部常量。
public enum ReportConstants {
    /// 20 色调色板。
    public static let palette: [String] = [
        "#3b82f6", "#ef4444", "#10b981", "#f59e0b", "#8b5cf6",
        "#ec4899", "#06b6d4", "#84cc16", "#f97316", "#6366f1",
        "#14b8a6", "#a855f7", "#0ea5e9", "#f43f5e", "#d946ef",
        "#22d3ee", "#fb923c", "#a3e635", "#e879f9", "#64748b",
    ]

    /// 资源类别颜色（adapters.py CAT_COLORS）。
    public static let catColors: [String: String] = [
        "binary": "#3b82f6", "data": "#10b981", "images": "#f59e0b",
        "nib_storyboard": "#ec4899", "fonts": "#8b5cf6", "strings": "#14b8a6",
        "audio": "#f97316", "video": "#6366f1", "mlmodel": "#a855f7",
        "coredata": "#0ea5e9", "other": "#94a3b8",
    ]

    /// 统一报告条目类型标签（adapters.py TYPE_LABELS）。
    public static let typeLabels: [String: String] = [
        "main_app": "主工程可执行文件",
        "dynamic_framework": "动态库",
        "static_lib": "静态库",
        "system": "系统库",
        "spm": "SPM",
        "other": "其他",
    ]

    public static let mainAppLabel = "主工程可执行文件"

    /// 树节点图标（shared_constants.py TREE_ICONS）。
    public static let treeIcons: [String: String] = [
        "dir": "📁",
        "macho": "🖥", ".framework": "📦", ".dylib": "📦", ".a": "📦", ".bundle": "📦",
        "sym": "", "sym_objc": "", "sym_c": "", "sym_swift": "",
        "images": "🖼️", "fonts": "🔤", "data": "📋", "nib_storyboard": "📐",
        "audio": "🎵", "video": "🎬", "strings": "🌐", "asset_catalog": "🎨",
        "metal_shader": "⚡", "scripts": "📜", "mlmodel": "🤖", "coredata": "🗄️",
        "localization": "🌐", "other": "📄",
        ".png": "🖼️", ".jpg": "🖼️", ".jpeg": "🖼️", ".gif": "🖼️", ".webp": "🖼️",
        ".heic": "🖼️", ".bmp": "🖼️", ".tiff": "🖼️", ".ico": "🖼️", ".heif": "🖼️",
        ".pdf": "📄", ".svg": "📄",
        ".ttf": "🔤", ".otf": "🔤", ".ttc": "🔤", ".woff": "🔤", ".woff2": "🔤",
        ".storyboard": "📐", ".storyboardc": "📐", ".nib": "📐", ".xib": "📐",
        ".mp3": "🎵", ".wav": "🎵", ".m4a": "🎵", ".aac": "🎵", ".caf": "🎵",
        ".mp4": "🎬", ".mov": "🎬", ".m4v": "🎬",
        ".plist": "⚙️", ".json": "📋", ".xml": "📋",
        ".strings": "🌐", ".stringsdict": "🌐",
        ".entitlements": "🔑", ".mobileprovision": "🔑",
        ".xcprivacy": "🛡️",
        ".metal": "⚡", ".metallib": "⚡", ".mlmodel": "🤖", ".mlmodelc": "🤖",
        ".js": "📜", ".css": "🎨", ".html": "📄",
        ".mom": "🗄️", ".momd": "🗄️", ".omo": "🗄️",
        ".car": "🎨", ".bin": "📦", ".dat": "📦",
        "(无扩展名)": "❓",
    ]

    /// 树节点类型标签（shared_constants.py TREE_TYPE_LABELS）。
    public static let treeTypeLabels: [String: String] = [
        "dir": "目录", "macho": "可执行文件", ".framework": "动态库", ".dylib": "动态库",
        ".a": "静态库", ".bundle": "Bundle", ".car": "Asset Catalog",
        ".png": "图片", ".jpg": "图片", ".jpeg": "图片", ".gif": "图片", ".webp": "图片",
        ".heic": "图片", ".pdf": "矢量图", ".svg": "矢量图", ".plist": "配置",
        ".json": "数据", ".xml": "数据", ".strings": "本地化", ".stringsdict": "本地化",
        ".storyboard": "界面", ".nib": "界面", ".xib": "界面", ".ttf": "字体", ".otf": "字体",
        ".ttc": "字体", ".mp3": "音频", ".wav": "音频", ".m4a": "音频", ".mp4": "视频",
        ".mov": "视频", ".metal": "着色器", ".metallib": "着色器", ".mlmodel": "机器学习",
        ".entitlements": "签名", ".mobileprovision": "签名",
    ]

    /// 模块拆解树类型标签。
    public static var moduleBreakdownTypeLabels: JSONValue {
        func lb(_ label: String, _ color: String, _ bg: String) -> JSONValue {
            .object([("label", .string(label)), ("color", .string(color)), ("bg", .string(bg))])
        }
        return .object([
            ("main_project", lb("主工程", "#065f46", "#d1fae5")),
            ("static_lib", lb("静态库", "#92400e", "#fef3c7")),
            ("dynamic_framework", lb("动态库", "#065f46", "#d1fae5")),
            ("dir", lb("目录", "#475569", "#f1f5f9")),
            (".o", lb("目标文件", "#475569", "#f1f5f9")),
            ("macho", lb("可执行文件", "#991b1b", "#fef2f2")),
            (".framework", lb("动态库", "#065f46", "#d1fae5")),
            (".a", lb("静态库", "#92400e", "#fef3c7")),
            (".bundle", lb("资源Bundle", "#5b21b6", "#f3e8ff")),
            (".car", lb("Asset Catalog", "#047857", "#d1fae5")),
            (".png", lb("图片", "#0e7490", "#ecfeff")),
            (".plist", lb("配置", "#4338ca", "#eef2ff")),
            (".json", lb("数据", "#4338ca", "#eef2ff")),
            (".strings", lb("本地化", "#6d28d9", "#f5f3ff")),
            (".storyboard", lb("界面", "#6d28d9", "#f5f3ff")),
            (".nib", lb("界面", "#6d28d9", "#f5f3ff")),
            (".ttf", lb("字体", "#be185d", "#fdf2f8")),
            (".mp3", lb("音频", "#c2410c", "#fff7ed")),
            (".wav", lb("音频", "#c2410c", "#fff7ed")),
            (".mp4", lb("视频", "#c2410c", "#fff7ed")),
            (".mobileprovision", lb("签名", "#475569", "#f1f5f9")),
        ])
    }
}
