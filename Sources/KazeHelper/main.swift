import Darwin
import Dispatch
import Foundation
import KazeDomain
import KazeHardware
import KazeIPC

do {
    guard geteuid() == 0 else {
        throw DomainError.hardwareFailure("the privileged helper must run as root")
    }

    let hardware = try SMCFanHardware()
    let controller = SafetyController(hardware: hardware)
    controller.start()

    let listener = NSXPCListener(machServiceName: IPCConstants.machServiceName)
    let delegate = HelperListenerDelegate(controller: controller)
    listener.delegate = delegate
    listener.setConnectionCodeSigningRequirement(
        try CodeSigningPolicy.authorizedClientRequirement()
    )

    let powerMonitor = PowerMonitor(controller: controller)
    try powerMonitor.start()

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
    withExtendedLifetime((delegate, powerMonitor, termination, interrupt)) {
        listener.activate()
        RunLoop.main.run()
    }
} catch {
    FileHandle.standardError.write(Data("KazeHelper: \(error)\n".utf8))
    Darwin.exit(1)
}
