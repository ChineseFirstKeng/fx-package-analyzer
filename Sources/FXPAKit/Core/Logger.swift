import Foundation

/// 终端日志器 —— 复刻 lib/common.sh 的配色日志函数。
/// 所有日志写 stderr，保持 stdout 纯净（与 Python 版一致）。
/// 支持同步写入一个日志文件（tee 模式，对齐原脚本的 `exec > >(tee -a build.log)`）。
public enum Logger {
    // ANSI 配色（对齐 common.sh）
    private static let red = "\u{001B}[0;31m"
    private static let green = "\u{001B}[0;32m"
    private static let yellow = "\u{001B}[1;33m"
    private static let blue = "\u{001B}[0;34m"
    private static let bold = "\u{001B}[1m"
    private static let nc = "\u{001B}[0m"

    /// 是否启用彩色（非 TTY 时自动关闭）
    public static var colored: Bool = isatty(fileno(stderr)) != 0
    /// 额外写入的日志文件（tee 模式）。设为 nil 则不写。
    public static var logFileHandle: FileHandle?

    private static func emit(_ s: String) {
        let line = s + "\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
            logFileHandle?.write(data)
        }
    }

    private static func wrap(_ code: String, _ text: String) -> String {
        colored ? "\(code)\(text)\(nc)" : text
    }

    public static func info(_ msg: String)    { emit("\(wrap(blue, "[INFO]")) \(msg)") }
    public static func success(_ msg: String) { emit("\(wrap(green, "[OK]"))   \(msg)") }
    public static func warn(_ msg: String)    { emit("\(wrap(yellow, "[WARN]")) \(msg)") }
    public static func error(_ msg: String)   { emit("\(wrap(red, "[ERR]"))  \(msg)") }
    public static func header(_ msg: String)  { emit("\n\(wrap(bold, "═══ \(msg) ═══"))") }

    /// 直接打印一行（不加前缀），用于横幅等
    public static func plain(_ msg: String = "") { emit(msg) }
}
