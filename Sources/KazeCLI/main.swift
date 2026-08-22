import ArgumentParser
import Foundation
import KazeDomain
import KazeIPC

@main
struct KazeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kaze",
        abstract: "Secure fan control through the signed Kaze helper",
        version: KazeVersion.current,
        subcommands: [Status.self, Automatic.self, Profile.self, Maximum.self, SetRPM.self, HelperInfo.self]
    )
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show helper, sensor, and fan status")

    @Flag(name: .long, help: "Emit machine-readable JSON")
    var json = false

    func run() async throws {
        let status = try await HelperClient().perform(.status)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(status), as: UTF8.self))
            return
        }
        print("Kaze \(status.version) — \(status.mode.displayName)")
        if let fault = status.fault { print("FAULT: \(fault.code): \(fault.message)") }
        guard let sample = status.latestSample else {
            print("No hardware sample yet")
            return
        }
        for fan in sample.fans {
            print("Fan \(fan.index): \(fan.actualRPM) RPM (target \(fan.targetRPM), \(fan.mode.rawValue))")
        }
        for key in sample.temperatures.keys.sorted() {
            if let temperature = sample.temperatures[key] {
                print("\(key): \(String(format: "%.1f", temperature))°C")
            }
        }
    }
}

struct Automatic: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Return every fan to verified Apple automatic control"
    )

    func run() async throws {
        let client = HelperClient()
        let status = try await client.perform(.resetAutomatic)
        print("Verified automatic mode: \(status.mode.displayName)")
    }
}

struct Profile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a built-in profile while this command remains alive")

    @Argument(help: "balanced, performance, or smart")
    var name: String

    @Option(name: .long, help: "Maximum runtime in seconds (default: 3600)")
    var duration: Double = 3_600

    func run() async throws {
        guard let profile = ProfileID(rawValue: name) else {
            throw ValidationError("Unknown profile. Choose: \(ProfileID.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        try await LeaseRunner.run(intent: .profile(profile), durationSeconds: duration)
    }
}

struct Maximum: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "max",
        abstract: "Hold verified maximum cooling while this command remains alive"
    )

    @Option(name: .long, help: "Maximum runtime in seconds (default: 600)")
    var duration: Double = 600

    func run() async throws {
        try await LeaseRunner.run(intent: .maximum, durationSeconds: duration)
    }
}

struct SetRPM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Hold one validated RPM on every fan while this command remains alive"
    )

    @Argument(help: "RPM; must be inside every fan's reported range")
    var rpm: Int

    @Option(name: .long, help: "Maximum runtime in seconds (default: 600)")
    var duration: Double = 600

    func run() async throws {
        try await LeaseRunner.run(intent: .fixedRPM(rpm), durationSeconds: duration)
    }
}

struct HelperInfo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper",
        abstract: "Explain how to register the privileged helper"
    )

    func run() async throws {
        print("Open /Applications/Kaze.app and choose ‘Register / Update’.")
        print("macOS requires administrator approval in System Settings > Login Items.")
    }
}

private enum LeaseRunner {
    static func run(intent: ControlIntent, durationSeconds: Double) async throws {
        guard durationSeconds.isFinite, durationSeconds >= 1, durationSeconds <= 86_400 else {
            throw ValidationError("--duration must be between 1 and 86400 seconds")
        }

        let client = HelperClient()
        defer { client.invalidate() }

        let status = try await client.perform(.acquire(intent: intent, leaseSeconds: 20))
        guard let leaseID = status.leaseID else { throw HelperClientError.missingResult }
        print("Control active (\(status.mode.displayName)); exits safely on Ctrl-C.")

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(durationSeconds))
        while clock.now < deadline {
            let remaining = clock.now.duration(to: deadline)
            try await clock.sleep(for: min(remaining, .seconds(5)))
            if clock.now < deadline {
                _ = try await client.perform(.renew(leaseID: leaseID))
            }
        }

        _ = try await client.perform(.resetAutomatic)
        print("Duration complete; verified Apple automatic mode restored.")
    }
}
