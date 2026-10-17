import Darwin
import Foundation

/// Bounded command execution shared by the app's update preparation and its installer helper.
public enum UpdateCommand {
    public static let maximumOutputBytes = 1_000_000
    public static let defaultTimeout: TimeInterval = 60
    public static let helperOperationTimeout: TimeInterval = 360
    public static let preparationTimeout = helperOperationTimeout + defaultTimeout
    private static let readBlockBytes = 16_384
    private static let pollMilliseconds: Int32 = 50
    private static let terminationGrace: TimeInterval = 0.25
    private static let killGrace: TimeInterval = 2

    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = UpdateCommand.defaultTimeout,
        maxOutput: Int = maximumOutputBytes) throws -> String {
        guard timeout.isFinite, timeout > 0, maxOutput > 0,
            maxOutput <= maximumOutputBytes else { throw CommandError.invalidLimits }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CommandError.readFailed
        }
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data(), buffer = [UInt8](repeating: 0, count: readBlockBytes)
        var endOfOutput = false
        do {
            while true {
                // A nonblocking pipe keeps the deadline effective even when a tool emits nothing.
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard count <= maxOutput - output.count else { throw CommandError.outputLimit }
                    output.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    endOfOutput = true
                } else if errno == EINTR {
                    continue
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    throw CommandError.readFailed
                }
                if endOfOutput && exited.wait(timeout: .now()) == .success { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CommandError.timedOut }
                if count > 0 { continue }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = poll(&descriptor, 1, pollMilliseconds)
                if endOfOutput {
                    // EOF alone can precede process exit; avoid spinning on a closed pipe.
                    _ = exited.wait(timeout: .now() + Double(pollMilliseconds) / 1_000)
                }
            }
        } catch {
            try stop(process, exited: exited)
            throw error
        }
        guard process.terminationStatus == 0 else {
            throw CommandError.failed(process.terminationStatus,
                String(decoding: output.suffix(2_000), as: UTF8.self))
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func stop(_ process: Process, exited: DispatchGroup) throws {
        if !process.isRunning { return }
        process.terminate()
        if exited.wait(timeout: .now() + terminationGrace) == .success { return }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        guard exited.wait(timeout: .now() + killGrace) == .success else {
            throw CommandError.cleanupFailed
        }
    }

    private enum CommandError: LocalizedError {
        case invalidLimits, readFailed, outputLimit, timedOut, cleanupFailed
        case failed(Int32, String)
        var errorDescription: String? {
            switch self {
            case .invalidLimits: "The update command limits are invalid."
            case .readFailed: "The update command output could not be read."
            case .outputLimit: "The update command produced too much output."
            case .timedOut: "The update command timed out. Nothing further was installed."
            case .cleanupFailed: "The update command could not be stopped. The update was cancelled."
            case .failed(let status, let detail):
                "Update verification failed, exit \(status)." + (detail.isEmpty ? "" : " \(detail)")
            }
        }
    }
}
