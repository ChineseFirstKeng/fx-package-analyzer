import Foundation

/// Mach-O 魔数识别 —— 复刻 lib/macho_utils.py 的 is_macho()。
/// 读取文件前 4 字节，匹配 6 个魔数之一。
public enum MachOMagic {
    /// 6 个魔数（32/64 位 LE/BE + Universal LE/BE）
    private static let magics: Set<[UInt8]> = [
        [0xFE, 0xED, 0xFA, 0xCE], // 32-bit LE  MH_MAGIC
        [0xFE, 0xED, 0xFA, 0xCF], // 64-bit LE  MH_MAGIC_64
        [0xCE, 0xFA, 0xED, 0xFE], // 32-bit BE  MH_CIGAM
        [0xCF, 0xFA, 0xED, 0xFE], // 64-bit BE  MH_CIGAM_64
        [0xCA, 0xFE, 0xBA, 0xBE], // Universal LE  FAT_MAGIC
        [0xBE, 0xBA, 0xFE, 0xCA], // Universal BE  FAT_CIGAM
    ]

    public static func isMachO(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 4), data.count == 4 else { return false }
        return magics.contains(Array(data))
    }
}
