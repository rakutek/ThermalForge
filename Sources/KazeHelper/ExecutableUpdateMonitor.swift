import Darwin
import Foundation
import MachO
import OSLog

/// A registered SMAppService daemon keeps running from its original vnode when
/// the containing app is replaced. Code-signing validation of that stale
/// process then fails because its on-disk executable is the new version. Watch
/// the launch path and exit safely so launchd's KeepAlive starts the new binary.
final class ExecutableUpdateMonitor: @unchecked Sendable {
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private enum MonitorError: Error {
        case executablePathUnavailable
        case executableAttributesUnavailable
    }

    private let executablePath: String
    private let originalIdentity: FileIdentity
    private let onReplacement: @Sendable () -> Void
    private let logger = Logger(subsystem: "com.producerguy.kaze", category: "lifecycle")
    private let queue = DispatchQueue(
        label: "com.producerguy.kaze.helper.executable-update",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var replacementDetected = false

    init(onReplacement: @escaping @Sendable () -> Void) throws {
        executablePath = try Self.currentExecutablePath()
        guard let identity = Self.fileIdentity(at: executablePath) else {
            throw MonitorError.executableAttributesUnavailable
        }
        originalIdentity = identity
        self.onReplacement = onReplacement
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + .seconds(1),
                repeating: .seconds(1),
                leeway: .milliseconds(250)
            )
            source.setEventHandler { [weak self] in
                self?.inspectExecutable()
            }
            timer = source
            source.resume()
        }
    }

    private func inspectExecutable() {
        guard !replacementDetected else { return }
        guard Self.fileIdentity(at: executablePath) == originalIdentity else {
            replacementDetected = true
            logger.notice("helper_executable_replaced path=\(self.executablePath, privacy: .public)")
            timer?.cancel()
            timer = nil
            onReplacement()
            return
        }
    }

    private static func currentExecutablePath() throws -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { throw MonitorError.executablePathUnavailable }

        var buffer = [CChar](repeating: 0, count: Int(size))
        let result = buffer.withUnsafeMutableBufferPointer {
            _NSGetExecutablePath($0.baseAddress, &size)
        }
        guard result == 0 else { throw MonitorError.executablePathUnavailable }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
            .standardizedFileURL.path
    }

    private static func fileIdentity(at path: String) -> FileIdentity? {
        var information = stat()
        guard lstat(path, &information) == 0 else { return nil }
        return FileIdentity(device: information.st_dev, inode: information.st_ino)
    }
}
