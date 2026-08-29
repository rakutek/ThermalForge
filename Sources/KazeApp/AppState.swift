import Foundation
import OSLog
import ServiceManagement
import SwiftUI
import KazeDomain
import KazeIPC

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var status: ControllerStatus?
    @Published private(set) var errorMessage: String?
    @Published private(set) var controlErrorMessage: String?
    @Published private(set) var helperRegistration = "Checking…"
    @Published private(set) var pendingIntent: ControlIntent?
    @Published var launchAtLogin = false

    private let client = HelperClient()
    private let logger = Logger(subsystem: "com.producerguy.kaze", category: "lease")
    private var pollTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var controlGeneration: UInt64 = 0
    private var controlActivity: ControlActivity?

    private let leaseSeconds: Double = 20
    private let renewalIntervalSeconds: Double = 5
    private let renewalRetryIntervalSeconds: Double = 0.5
    private let renewalRequestTimeoutSeconds: Double = 2

    var modeDisplayName: String {
        if let status {
            switch status.mode {
            case .safetyMaximum, .safetyCooling, .failSafeAutomatic, .failSafeMaximum, .unrecoveredFault:
                return status.mode.displayName
            default:
                break
            }
        }
        if let pendingIntent { return "\(pendingIntent.displayName)…" }
        return status?.mode.displayName ?? "Offline"
    }

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshRegistrationStatus()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
        renewalTask?.cancel()
        controlActivity?.end()
        client.invalidate()
    }

    func registerHelper() {
        do {
            let service = SMAppService.daemon(plistName: IPCConstants.launchDaemonPlistName)
            if service.status != .enabled {
                try service.register()
            }
            errorMessage = nil
        } catch {
            let registrationError = error as NSError
            errorMessage = "Helper registration failed (\(registrationError.domain) \(registrationError.code)): \(registrationError.localizedDescription)"
            logger.error(
                "helper_registration_failed domain=\(registrationError.domain, privacy: .public) code=\(registrationError.code, privacy: .public)"
            )
        }
        refreshRegistrationStatus()
    }

    func unregisterHelper() {
        stopRenewing()
        controlGeneration &+= 1
        controlErrorMessage = nil
        Task {
            do {
                let service = SMAppService.daemon(plistName: IPCConstants.launchDaemonPlistName)
                if service.status == .enabled {
                    status = try await client.perform(.resetAutomatic)
                }
                if service.status != .notRegistered {
                    try await service.unregister()
                }
                errorMessage = nil
            } catch {
                errorMessage = "Automatic restore or helper removal failed: \(error.localizedDescription)"
            }
            refreshRegistrationStatus()
        }
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            errorMessage = "Login item update failed: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func selectProfile(_ profile: ProfileID) {
        acquire(.profile(profile))
    }

    func maximum() {
        acquire(.maximum)
    }

    func automatic() {
        stopRenewing()
        controlGeneration &+= 1
        let generation = controlGeneration
        controlErrorMessage = nil
        pendingIntent = .automatic
        Task {
            do {
                let newStatus = try await client.perform(.resetAutomatic)
                guard generation == controlGeneration else { return }
                status = newStatus
                errorMessage = nil
            } catch {
                guard generation == controlGeneration else { return }
                errorMessage = String(describing: error)
            }
            if generation == controlGeneration { pendingIntent = nil }
        }
    }

    func disconnect() {
        stopRenewing()
        controlGeneration &+= 1
        pollTask?.cancel()
        client.invalidate()
    }

    private func acquire(_ intent: ControlIntent) {
        stopRenewing()
        controlGeneration &+= 1
        let generation = controlGeneration
        controlErrorMessage = nil
        pendingIntent = intent
        Task {
            defer {
                if generation == controlGeneration { pendingIntent = nil }
            }
            do {
                let newStatus = try await client.perform(
                    .acquire(intent: intent, leaseSeconds: leaseSeconds)
                )
                guard generation == controlGeneration else { return }
                status = newStatus
                errorMessage = nil
                guard let leaseID = newStatus.leaseID,
                      let expiresAt = newStatus.leaseExpiresAtUptimeNanoseconds else {
                    controlErrorMessage = "The helper did not return a control lease."
                    return
                }
                startRenewing(leaseID, expiresAt: expiresAt, generation: generation)
            } catch {
                guard generation == controlGeneration else { return }
                errorMessage = String(describing: error)
            }
        }
    }

    private func startRenewing(_ leaseID: UUID, expiresAt: UInt64, generation: UInt64) {
        stopRenewing()
        beginControlActivity()
        renewalTask = Task { [weak self] in
            var deadline = expiresAt
            var failureCount = 0
            var nextDelay = self?.renewalIntervalSeconds ?? 5

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(nextDelay))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self,
                      generation == self.controlGeneration else { return }

                do {
                    let renewed = try await self.client.perform(
                        .renew(leaseID: leaseID),
                        timeoutSeconds: self.renewalRequestTimeoutSeconds
                    )
                    guard !Task.isCancelled, generation == self.controlGeneration else { return }
                    guard renewed.leaseID == leaseID,
                          let renewedDeadline = renewed.leaseExpiresAtUptimeNanoseconds else {
                        self.recordLostLease(
                            reason: "the helper no longer owns this lease",
                            generation: generation
                        )
                        return
                    }

                    if failureCount > 0 {
                        self.logger.notice(
                            "lease_renew_recovered failures=\(failureCount, privacy: .public)"
                        )
                    }
                    self.status = renewed
                    self.controlErrorMessage = nil
                    deadline = renewedDeadline
                    failureCount = 0
                    nextDelay = self.renewalIntervalSeconds
                } catch {
                    guard !Task.isCancelled, generation == self.controlGeneration else { return }
                    failureCount += 1
                    let remaining = self.remainingNanoseconds(until: deadline)
                    let errorDescription = String(describing: error)

                    self.logger.error(
                        "lease_renew_failed attempt=\(failureCount, privacy: .public) remaining_ms=\(remaining / 1_000_000, privacy: .public) error=\(errorDescription, privacy: .public)"
                    )

                    if self.isTerminalLeaseError(error) || remaining == 0 {
                        self.recordLostLease(reason: errorDescription, generation: generation)
                        return
                    }

                    self.controlErrorMessage = "Control connection is unstable; retrying lease renewal (\(failureCount))."
                    let remainingSeconds = Double(remaining) / 1_000_000_000
                    nextDelay = min(
                        self.renewalRetryIntervalSeconds,
                        max(remainingSeconds / 2, 0.05)
                    )
                }
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOperation(.status)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func runOperation(_ operation: HelperOperation, clearErrorOnSuccess: Bool = true) async {
        do {
            status = try await client.perform(operation)
            if clearErrorOnSuccess { errorMessage = nil }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func stopRenewing() {
        renewalTask?.cancel()
        renewalTask = nil
        endControlActivity()
    }

    private func beginControlActivity() {
        guard controlActivity == nil else { return }
        controlActivity = ControlActivity()
    }

    private func endControlActivity() {
        guard let controlActivity else { return }
        controlActivity.end()
        self.controlActivity = nil
    }

    private func remainingNanoseconds(until deadline: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return deadline > now ? deadline - now : 0
    }

    private func isTerminalLeaseError(_ error: Error) -> Bool {
        guard case HelperClientError.remote(let remote) = error else { return false }
        return remote.code == "lease-not-owned" || remote.code == "lease-expired"
    }

    private func recordLostLease(reason: String, generation: UInt64) {
        guard generation == controlGeneration else { return }
        logger.error("lease_control_lost reason=\(reason, privacy: .public)")
        controlErrorMessage = "Control lease ended: \(reason)"
        renewalTask = nil
        endControlActivity()
    }

    private func refreshRegistrationStatus() {
        let service = SMAppService.daemon(plistName: IPCConstants.launchDaemonPlistName)
        helperRegistration = switch service.status {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Needs approval"
        case .notFound: "Not registered"
        @unknown default: "Unknown"
        }
    }
}

private final class ControlActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    init() {
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Maintain the active Kaze fan-control lease"
        )
    }

    deinit {
        end()
    }

    func end() {
        lock.lock()
        let current = token
        token = nil
        lock.unlock()
        if let current {
            ProcessInfo.processInfo.endActivity(current)
        }
    }
}
