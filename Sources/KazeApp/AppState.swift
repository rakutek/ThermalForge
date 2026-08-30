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
    @Published private(set) var helperRecoveryMessage: String?
    @Published private(set) var helperRegistration = "Checking…"
    @Published private(set) var isRecoveringHelper = false
    @Published private(set) var isManagingHelper = false
    @Published private(set) var pendingIntent: ControlIntent?
    @Published private(set) var telemetrySamples: [TelemetrySample] = []
    @Published private(set) var telemetryErrorMessage: String?
    @Published private(set) var telemetryWindow: TelemetryWindow = .fiveMinutes
    @Published var launchAtLogin = false

    private let client = HelperClient()
    private let logger = Logger(subsystem: "com.producerguy.kaze", category: "lease")
    private var pollTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var controlGeneration: UInt64 = 0
    private var controlActivity: ControlActivity?
    private var consecutiveConnectionFailures = 0
    private var registrationRecoveryAttempt = 0
    private var nextRegistrationRecoveryUptimeNanoseconds: UInt64 = 0
    private var automaticRegistrationSuppressed = UserDefaults.standard.bool(
        forKey: "KazeAutomaticHelperRegistrationSuppressed"
    )

    private let leaseSeconds: Double = 20
    private let renewalIntervalSeconds: Double = 5
    private let renewalRetryIntervalSeconds: Double = 0.5
    private let renewalRequestTimeoutSeconds: Double = 2
    private let automaticRepairFailureThreshold = 3

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
        if isRecoveringHelper { return "Recovering…" }
        return status?.mode.displayName ?? "Offline"
    }

    init() {
#if DEBUG
        if isPreviewMode, let preview = KazePreviewData.make(window: telemetryWindow) {
            status = preview.status
            telemetrySamples = preview.telemetry
            helperRegistration = "Preview"
            return
        }
#endif
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshRegistrationStatus()
        startPolling()
        startTelemetryPolling()
    }

    deinit {
        pollTask?.cancel()
        telemetryTask?.cancel()
        renewalTask?.cancel()
        registrationTask?.cancel()
        controlActivity?.end()
        client.invalidate()
    }

    func registerHelper() {
        automaticRegistrationSuppressed = false
        UserDefaults.standard.set(false, forKey: "KazeAutomaticHelperRegistrationSuppressed")
        beginRegistrationRecovery(forceRestart: true, userInitiated: true)
    }

    func unregisterHelper() {
        automaticRegistrationSuppressed = true
        UserDefaults.standard.set(true, forKey: "KazeAutomaticHelperRegistrationSuppressed")
        registrationTask?.cancel()
        registrationTask = nil
        stopRenewing()
        controlGeneration &+= 1
        controlErrorMessage = nil
        isManagingHelper = true
        helperRegistration = "Removing…"
        Task {
            let service = SMAppService.daemon(plistName: IPCConstants.launchDaemonPlistName)
            var restoreError: Error?
            if service.status == .enabled {
                do {
                    status = try await client.perform(.resetAutomatic)
                } catch {
                    restoreError = error
                }
            }

            client.invalidate()
            do {
                if service.status != .notRegistered && service.status != .notFound {
                    try await service.unregister()
                }
                status = nil
                telemetrySamples = []
                helperRecoveryMessage = nil
                errorMessage = restoreError.map {
                    "The helper was removed, but automatic restore could not be confirmed: \($0)"
                }
            } catch {
                errorMessage = "Helper removal failed: \(error.localizedDescription)"
            }
            isRecoveringHelper = false
            isManagingHelper = false
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
                if (error as? HelperClientError)?.isConnectionFailure == true {
                    handleConnectionFailure(String(describing: error))
                } else {
                    errorMessage = String(describing: error)
                }
            }
            if generation == controlGeneration { pendingIntent = nil }
        }
    }

    func disconnect() {
        stopRenewing()
        controlGeneration &+= 1
        pollTask?.cancel()
        telemetryTask?.cancel()
        client.invalidate()
    }

    func setTelemetryWindow(_ window: TelemetryWindow) {
        guard telemetryWindow != window else { return }
        telemetryWindow = window
#if DEBUG
        if isPreviewMode, let preview = KazePreviewData.make(window: window) {
            status = preview.status
            telemetrySamples = preview.telemetry
            return
        }
#endif
        startTelemetryPolling()
    }

    private var isPreviewMode: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["KAZE_UI_PREVIEW"] == "1"
#else
        false
#endif
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
                if (error as? HelperClientError)?.isConnectionFailure == true {
                    handleConnectionFailure(String(describing: error))
                } else {
                    errorMessage = String(describing: error)
                }
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
                await self.refreshHelperStatus()
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
            }
        }
    }

    private func startTelemetryPolling() {
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshTelemetry()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshTelemetry() async {
        guard !isRecoveringHelper else {
            telemetryErrorMessage = nil
            return
        }
        let requestedWindow = telemetryWindow
        do {
            let snapshot = try await client.fetchTelemetry(
                windowSeconds: requestedWindow.rawValue,
                maximumPoints: 180
            )
            guard !Task.isCancelled, requestedWindow == telemetryWindow else { return }
            status = snapshot.status
            telemetrySamples = snapshot.samples
            telemetryErrorMessage = nil
        } catch {
            guard !Task.isCancelled, requestedWindow == telemetryWindow else { return }
            if (error as? HelperClientError)?.isConnectionFailure == true {
                telemetryErrorMessage = nil
            } else {
                telemetryErrorMessage = "History unavailable: \(error)"
            }
        }
    }

    private func refreshHelperStatus() async {
        do {
            let newStatus = try await client.perform(.status)
            guard newStatus.version == KazeVersion.current else {
                handleConnectionFailure(
                    "helper version \(newStatus.version) does not match app version \(KazeVersion.current)"
                )
                return
            }

            if consecutiveConnectionFailures > 0 {
                logger.notice(
                    "helper_connection_recovered failures=\(self.consecutiveConnectionFailures, privacy: .public)"
                )
            }
            status = newStatus
            consecutiveConnectionFailures = 0
            registrationRecoveryAttempt = 0
            nextRegistrationRecoveryUptimeNanoseconds = 0
            isRecoveringHelper = false
            helperRecoveryMessage = nil
            errorMessage = nil
            refreshRegistrationStatus()
        } catch {
            handleConnectionFailure(String(describing: error))
        }
    }

    private func handleConnectionFailure(_ detail: String) {
        consecutiveConnectionFailures += 1
        if consecutiveConnectionFailures >= 2 { status = nil }
        errorMessage = nil
        telemetryErrorMessage = nil
        isRecoveringHelper = true
        helperRecoveryMessage = isManagingHelper
            ? "Restarting the privileged helper…"
            : "Reconnecting to the privileged helper automatically…"

        if consecutiveConnectionFailures == 1
            || consecutiveConnectionFailures == automaticRepairFailureThreshold {
            logger.error(
                "helper_connection_failed attempt=\(self.consecutiveConnectionFailures, privacy: .public) detail=\(detail, privacy: .public)"
            )
        }

        let service = SMAppService.daemon(plistName: IPCConstants.launchDaemonPlistName)
        refreshRegistrationStatus()
        switch service.status {
        case .requiresApproval:
            isRecoveringHelper = false
            helperRecoveryMessage = "Allow Kaze in System Settings > General > Login Items, then it will reconnect automatically."
        case .notRegistered, .notFound:
            guard !automaticRegistrationSuppressed else {
                isRecoveringHelper = false
                helperRecoveryMessage = "The privileged helper is not registered."
                return
            }
            beginRegistrationRecovery(forceRestart: false, userInitiated: false)
        case .enabled:
            guard consecutiveConnectionFailures >= automaticRepairFailureThreshold else { return }
            beginRegistrationRecovery(forceRestart: true, userInitiated: false)
        @unknown default:
            helperRecoveryMessage = "The privileged helper is unavailable; Kaze will keep retrying."
        }
    }

    private func beginRegistrationRecovery(forceRestart: Bool, userInitiated: Bool) {
        guard registrationTask == nil else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        guard userInitiated || now >= nextRegistrationRecoveryUptimeNanoseconds else { return }

        if userInitiated {
            nextRegistrationRecoveryUptimeNanoseconds = 0
            errorMessage = nil
        } else {
            registrationRecoveryAttempt += 1
            let exponent = min(registrationRecoveryAttempt - 1, 4)
            let cooldownSeconds = min(30 * (1 << exponent), 300)
            nextRegistrationRecoveryUptimeNanoseconds = now
                &+ UInt64(cooldownSeconds) * 1_000_000_000
        }

        isRecoveringHelper = true
        isManagingHelper = true
        helperRegistration = forceRestart ? "Restarting…" : "Registering…"
        helperRecoveryMessage = forceRestart
            ? "Restarting the privileged helper…"
            : "Registering the privileged helper…"

        registrationTask = Task { [weak self] in
            guard let self else { return }
            await self.recoverRegistration(forceRestart: forceRestart, userInitiated: userInitiated)
        }
    }

    private func recoverRegistration(forceRestart: Bool, userInitiated: Bool) async {
        defer {
            registrationTask = nil
            isManagingHelper = false
            refreshRegistrationStatus()
        }

        let service = SMAppService.daemon(plistName: IPCConstants.launchDaemonPlistName)
        do {
            if forceRestart && service.status == .enabled {
                let restarted = await restartHelperInPlace()
                if !restarted && service.status == .enabled {
                    // Helpers from versions before the in-place restart protocol
                    // need one migration restart. Approval is retained, but smd
                    // may briefly reject registration while unregister settles.
                    try await service.unregister()
                    try await registerWithRetry(service)
                }
            } else if service.status != .enabled {
                try await registerWithRetry(service)
            }

            client.invalidate()
            helperRecoveryMessage = service.status == .requiresApproval
                ? "Allow Kaze in System Settings > General > Login Items, then it will reconnect automatically."
                : "Privileged helper restarted; reconnecting…"
            isRecoveringHelper = service.status != .requiresApproval
            logger.notice(
                "helper_registration_recovery_completed restart=\(forceRestart, privacy: .public)"
            )
        } catch {
            let registrationError = error as NSError
            logger.error(
                "helper_registration_recovery_failed domain=\(registrationError.domain, privacy: .public) code=\(registrationError.code, privacy: .public)"
            )
            helperRecoveryMessage = service.status == .requiresApproval
                ? "Allow Kaze in System Settings > General > Login Items, then it will reconnect automatically."
                : "Automatic helper repair failed; Kaze will retry."
            isRecoveringHelper = service.status != .requiresApproval
            if userInitiated {
                errorMessage = "Helper update failed (\(registrationError.domain) \(registrationError.code)): \(registrationError.localizedDescription)"
            }
        }
    }

    private func restartHelperInPlace() async -> Bool {
        _ = try? await client.perform(.restartForUpdate, timeoutSeconds: 2)
        client.invalidate()

        for attempt in 0..<4 {
            do {
                try await Task.sleep(for: .milliseconds(400 + attempt * 250))
                let restartedStatus = try await client.perform(.status, timeoutSeconds: 1)
                if restartedStatus.version == KazeVersion.current {
                    status = restartedStatus
                    return true
                }
            } catch {
                client.invalidate()
            }
        }
        return false
    }

    private func registerWithRetry(_ service: SMAppService) async throws {
        var lastError: Error?
        for attempt in 0..<6 {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(min(250 * (1 << attempt), 2_000)))
            }
            do {
                try service.register()
                return
            } catch {
                lastError = error
                if service.status == .requiresApproval { throw error }
            }
        }
        throw lastError ?? HelperRegistrationRecoveryError.retryExhausted
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
        guard !isManagingHelper else { return }
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

enum TelemetryWindow: Double, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3_600

    var id: Double { rawValue }

    var shortLabel: String {
        switch self {
        case .oneMinute: "1m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        case .oneHour: "1h"
        }
    }
}

private enum HelperRegistrationRecoveryError: Error {
    case retryExhausted
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
