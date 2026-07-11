import Foundation

/// Apple 设备标识 → 用户可见名称（复刻 analyze_thinning.py DEVICE_NAMES）。
enum DeviceNames {
    static let map: [String: String] = [
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
        "iPhone9,1": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,3": "iPhone 7", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,3": "iPhone X",
        "iPhone10,4": "iPhone 8", "iPhone10,5": "iPhone 8 Plus", "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE 2",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE 3", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone 17 Air",
        "iPod9,1": "iPod touch 7",
        "iPad5,1": "iPad mini 4", "iPad5,2": "iPad mini 4", "iPad5,3": "iPad Air 2", "iPad5,4": "iPad Air 2",
        "iPad6,3": "iPad Pro 9.7\"", "iPad6,4": "iPad Pro 9.7\"", "iPad6,7": "iPad Pro 12.9\"", "iPad6,8": "iPad Pro 12.9\"",
        "iPad6,11": "iPad 5", "iPad6,12": "iPad 5",
        "iPad7,1": "iPad Pro 12.9\" 2", "iPad7,2": "iPad Pro 12.9\" 2", "iPad7,3": "iPad Pro 10.5\"", "iPad7,4": "iPad Pro 10.5\"",
        "iPad7,5": "iPad 6", "iPad7,6": "iPad 6", "iPad7,11": "iPad 7", "iPad7,12": "iPad 7",
        "iPad8,1": "iPad Pro 11\"", "iPad8,2": "iPad Pro 11\"", "iPad8,3": "iPad Pro 11\"", "iPad8,4": "iPad Pro 11\"",
        "iPad8,5": "iPad Pro 12.9\" 3", "iPad8,6": "iPad Pro 12.9\" 3", "iPad8,7": "iPad Pro 12.9\" 3", "iPad8,8": "iPad Pro 12.9\" 3",
        "iPad8,9": "iPad Pro 11\" 2", "iPad8,10": "iPad Pro 11\" 2", "iPad8,11": "iPad Pro 12.9\" 4", "iPad8,12": "iPad Pro 12.9\" 4",
        "iPad11,1": "iPad mini 5", "iPad11,2": "iPad mini 5", "iPad11,3": "iPad Air 3", "iPad11,4": "iPad Air 3",
        "iPad11,6": "iPad 8", "iPad11,7": "iPad 8",
        "iPad12,1": "iPad 9", "iPad12,2": "iPad 9",
        "iPad13,1": "iPad Air 4", "iPad13,2": "iPad Air 4",
        "iPad13,4": "iPad Pro 11\" 3", "iPad13,5": "iPad Pro 11\" 3", "iPad13,6": "iPad Pro 11\" 3", "iPad13,7": "iPad Pro 11\" 3",
        "iPad13,8": "iPad Pro 12.9\" 5", "iPad13,9": "iPad Pro 12.9\" 5", "iPad13,10": "iPad Pro 12.9\" 5", "iPad13,11": "iPad Pro 12.9\" 5",
        "iPad13,16": "iPad Air 5", "iPad13,17": "iPad Air 5",
        "iPad13,18": "iPad 10", "iPad13,19": "iPad 10",
        "iPad14,1": "iPad mini 6", "iPad14,2": "iPad mini 6",
        "iPad14,3-A": "iPad Air 11\" M2", "iPad14,3-B": "iPad Air 11\" M2", "iPad14,4-A": "iPad Air 13\" M2", "iPad14,4-B": "iPad Air 13\" M2",
        "iPad14,5-A": "iPad Pro 11\" M4", "iPad14,5-B": "iPad Pro 11\" M4", "iPad14,6-A": "iPad Pro 13\" M4", "iPad14,6-B": "iPad Pro 13\" M4",
        "iPad14,8": "iPad Air 11\" M3", "iPad14,9": "iPad Air 13\" M3",
        "iPad14,10": "iPad mini A17 Pro", "iPad14,11": "iPad mini A17 Pro",
        "iPad15,3": "iPad Pro 11\" M4", "iPad15,4": "iPad Pro 13\" M4",
        "iPad15,5": "iPad Air 11\" M3", "iPad15,6": "iPad Air 13\" M3",
        "iPad15,7": "iPad Pro 11\" M5", "iPad15,8": "iPad Pro 13\" M5",
        "iPad16,1": "iPad Air 11\" M3", "iPad16,2": "iPad Air 13\" M3",
        "iPad16,3-A": "iPad 11", "iPad16,3-B": "iPad 11",
        "iPad16,4-A": "iPad Pro 11\" M5", "iPad16,4-B": "iPad Pro 11\" M5",
        "iPad16,5-A": "iPad Pro 13\" M5", "iPad16,5-B": "iPad Pro 13\" M5",
        "iPad16,6-A": "iPad Air 11\" M3", "iPad16,6-B": "iPad Air 13\" M3",
        "RealityFamily22,1": "Apple Vision Pro",
        "MacFamily20,1": "Mac (Apple Silicon)",
    ]

    static func label(_ id: String) -> String { map[id] ?? id }

    /// 从设备 ID 列表生成人类可读变体标签（复刻 _gen_variant_label）。
    static func variantLabel(_ deviceIDs: [String]) -> String {
        if deviceIDs.isEmpty { return "" }
        if deviceIDs == ["Universal"] { return "通用版本 (Universal)" }
        var names: [String] = []
        var seen = Set<String>()
        for did in deviceIDs {
            let n = label(did)
            if !seen.contains(n) { names.append(n); seen.insert(n) }
        }
        let iphoneCount = deviceIDs.filter { $0.hasPrefix("iPhone") }.count
        let ipadCount = deviceIDs.filter { $0.hasPrefix("iPad") }.count
        let category = iphoneCount > ipadCount ? "iPhone" : (ipadCount > iphoneCount ? "iPad" : "")
        var sample = names.prefix(3).joined(separator: ", ")
        if names.count > 3 { sample += " (等 \(names.count) 款)" }
        return category.isEmpty ? sample : "\(category) — \(sample)"
    }
}
