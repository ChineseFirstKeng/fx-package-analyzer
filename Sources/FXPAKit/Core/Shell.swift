import Foundation

/// 外部命令执行封装 —— 统一通过 Process 调用 xcodebuild/otool/lipo/assetutil 等。
public struct Shell {
    public struct Result {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public var ok: Bool { exitCode == 0 }
    }

    public enum ShellError: Error, CustomStringConvertible {
        case launchFailed(String)
        case timedOut(String)
        public var description: String {
            switch self {
            case .launchFailed(let m): return "命令启动失败: \(m)"
            case .timedOut(let m): return "命令超时: \(m)"
            }
        }
    }

    /// 同步执行命令。
    /// - Parameters:
    ///   - launchPath: 可执行文件绝对路径（如 /usr/bin/otool）
    ///   - arguments: 参数列表
    ///   - environment: 追加/覆盖的环境变量
    ///   - currentDirectory: 工作目录
    ///   - timeout: 超时秒数（nil 表示不限制）
    @discardableResult
    public static func run(
        _ launchPath: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env
        }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // 后台线程各自 readDataToEndOfFile，避免管道缓冲写满死锁 + handler 收尾竞争
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "fxpa.shell.io", attributes: .concurrent)
        ioQueue.async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        ioQueue.async(group: group) { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed("\(launchPath): \(error.localizedDescription)")
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    break
                }
                usleep(20_000)
            }
        }
        process.waitUntilExit()
        group.wait()  // 等待两个读取线程读完 EOF

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// 便捷：执行 `xcodebuild`。
    @discardableResult
    public static func xcodebuild(_ arguments: [String], timeout: TimeInterval? = nil) throws -> Result {
        try run("/usr/bin/xcodebuild", arguments, timeout: timeout)
    }

    /// 执行命令并将 stdout/stderr 直接继承到当前终端（用于长时间构建，实时可见）。
    /// 返回退出码。
    @discardableResult
    public static func runInheriting(
        _ launchPath: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        replaceEnvironment: Bool = false,
        currentDirectory: String? = nil
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let environment {
            if replaceEnvironment {
                process.environment = environment   // 完全替换（用于净化 Ruby 环境等）
            } else {
                var env = ProcessInfo.processInfo.environment
                for (k, v) in environment { env[k] = v }
                process.environment = env
            }
        }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        // 不设置 pipe → 继承父进程的 stdout/stderr
        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed("\(launchPath): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
