import Darwin
import Dispatch
import Foundation
import KazeDomain
import KazeHardware
import KazeIPC
import OSLog

do {
    let lifecycleLogger = Logger(subsystem: "com.producerguy.kaze", category: "lifecycle")
    guard geteuid() == 0 else {
        throw DomainError.hardwareFailure("the privileged helper must run as root")
    }

    let hardware = try SMCFanHardware()
    let controller = SafetyController(hardware: hardware)
    controller.start()
    lifecycleLogger.notice("helper_started version=\(KazeVersion.current, privacy: .public)")

    let listener = NSXPCListener(machServiceName: IPCConstants.machServiceName)
    let delegate = HelperListenerDelegate(controller: controller)
    listener.delegate = delegate
    listener.setConnectionCodeSigningRequirement(
        try CodeSigningPolicy.authorizedClientRequirement()
    )

    let powerMonitor = PowerMonitor(controller: controller)
    try powerMonitor.start()

    let executableUpdateMonitor: ExecutableUpdateMonitor?
    do {
        executableUpdateMonitor = try ExecutableUpdateMonitor {
            controller.shutdown()
            Darwin.exit(0)
        }
        executableUpdateMonitor?.start()
    } catch {
        executableUpdateMonitor = nil
        lifecycleLogger.error("helper_update_monitor_unavailable error=\(String(describing: error), privacy: .public)")
    }

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    termination.setEventHandler {
        controller.shutdown()
        Darwin.exit(0)
    }
    interrupt.setEventHandler {
        controller.shutdown()
        Darwin.exit(0)
    }
    termination.resume()
    interrupt.resume()

    // Strong references intentionally live for the daemon lifetime.
    withExtendedLifetime((delegate, powerMonitor, executableUpdateMonitor, termination, interrupt)) {
        listener.activate()
        RunLoop.main.run()
    }
} catch {
    FileHandle.standardError.write(Data("KazeHelper: \(error)\n".utf8))
    Darwin.exit(1)
}
