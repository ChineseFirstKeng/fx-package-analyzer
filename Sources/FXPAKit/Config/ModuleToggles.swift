import Foundation

/// 模块启停开关。默认值对齐 package_analyzer.sh 顶部的 ENABLE_* 变量。
public struct ModuleToggles {
    public var linkmap = true
    public var assets = true
    public var podResources = true
    public var assetsCar = false
    public var duplicates = true
    public var unusedResources = true
    public var macho = true
    public var buildConfig = true
    public var thinning = false
    public var deadCode = true
    public var objcUnused = false
    public var swiftStdlib = true
    public var localization = true

    public init() {}

    public mutating func enableAll() {
        linkmap = true; assets = true; podResources = true; assetsCar = true
        duplicates = true; unusedResources = true; macho = true; buildConfig = true
        thinning = true; deadCode = true; objcUnused = true; swiftStdlib = true
        localization = true
    }

    public mutating func disableAll() {
        linkmap = false; assets = false; podResources = false; assetsCar = false
        duplicates = false; unusedResources = false; macho = false; buildConfig = false
        thinning = false; deadCode = false; objcUnused = false; swiftStdlib = false
        localization = false
    }
}
