import Foundation
import IOKit.pwr_mgt
import KazeDomain

final class PowerMonitor: @unchecked Sendable {
    private let controller: SafetyController
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(controller: SafetyController) {
        self.controller = controller
    }

    func start() throws {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            pointer,
            &notificationPort,
            { reference, _, messageType, argument in
                guard let reference else { return }
                let monitor = Unmanaged<PowerMonitor>.fromOpaque(reference).takeUnretainedValue()
                monitor.receive(messageType: messageType, argument: argument)
            },
            &notifier
        )
        guard rootPort != 0, let notificationPort else {
            throw DomainError.hardwareFailure("power notification registration failed")
        }
        let source = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    deinit {
        if notifier != 0 { IOObjectRelease(notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }

    private func receive(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let poweredOn: UInt32 = 0xe0000300
        let willSleep: UInt32 = 0xe0000280
        let canSleep: UInt32 = 0xe0000270
        switch messageType {
        case poweredOn:
            controller.handleWake()
        case willSleep, canSleep:
            IOAllowPowerChange(rootPort, numericCast(Int(bitPattern: argument)))
        default:
            break
        }
    }
}
