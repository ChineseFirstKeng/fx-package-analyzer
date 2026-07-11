import ArgumentParser
import Foundation

/// `fxpa init` —— 在当前目录生成默认 .package-check.json（复刻 package_analyzer.sh do_init）。
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "在当前目录生成默认 .package-check.json"
    )

    @Argument(help: "目标路径 (默认 ./.package-check.json)")
    var dest: String = "./.package-check.json"

    func run() throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: dest) {
            FileHandle.standardError.write(".package-check.json 已存在，覆盖？[y/N] ".data(using: .utf8)!)
            let answer = readLine() ?? ""
            switch answer.lowercased() {
            case "y", "yes": break
            default:
                print("已取消")
                return
            }
        }

        let defaultURL = Resources.defaultPackageCheck
        guard fm.fileExists(atPath: defaultURL.path) else {
            Logger.error("默认配置文件不存在: \(defaultURL.path)")
            throw ExitCode.failure
        }

        if fm.fileExists(atPath: dest) { try? fm.removeItem(atPath: dest) }
        try fm.copyItem(at: defaultURL, to: URL(fileURLWithPath: dest))
        print("已生成: \(dest)")

        print("""

          概览:       app_structure
          代码:       linkmap dead_code swift_stdlib
                      objc_unused (默认关闭)
          资源:       assets pod_resources duplicates unused_resources
                      localization
                      assets_car app_thinning (默认关闭)
          工程配置:   build_config
        """)
    }
}
