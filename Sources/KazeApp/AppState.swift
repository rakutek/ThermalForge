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
    /// The raw reason behind `controlErrorMessage`, surfaced as a tooltip. The
    /// banner itself says what happened in the user's terms; the IPC wording
    /// belongs where someone goes looking for it.
    @Published private(set) var controlErrorDetail: String?
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
    /// The mode the user picked to run on. Maximum is deliberately excluded:
    /// it is a boost, so the mode to come back to is the one it interrupted.
    private var baseIntent: ControlIntent = .automatic
    private var baseRestoreAttempts = 0
    /// The lease this app most recently held. A status already in flight can
    /// still report it for a moment after control is handed back — the helper
    /// clears the lease only once the reset lands — and that is our own lease
    /// finishing rather than another client taking over.
    private var ownLeaseID: UUID?
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
        if let status { return status.mode.displayName }
        if isRecoveringHelper { return "Recovering…" }
        if pendingIntent != nil { return "Applying…" }
        return status?.mode.displayName ?? "Offline"
    }

    var hasExternalControlLease: Bool {
        guard !isPreviewMode, let leaseID = status?.leaseID else { return false }
        // A control change in flight already owns the UI — the mode row reads
        // "Applying…" — and the status it is about to replace still carries the
        // lease we are releasing.
        guard renewalTask == nil, pendingIntent == nil else { return false }
        return leaseID != ownLeaseID
    }

    var restrictsManagedModeSelection: Bool {
        guard let status else { return true }
        if isRecoveringHelper || isManagingHelper || pendingIntent != nil { return true }
        if status.fault != nil || hasExternalControlLease { return true }
        switch status.mode {
        case .starting, .safetyMaximum, .safetyCooling, .failSafeAutomatic,
             .failSafeMaximum, .unrecoveredFault, .fixed:
            return true
        default:
            return false
        }
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
        baseIntent = .automatic
        baseRestoreAttempts = 0
        stopRenewing()
        controlGeneration &+= 1
        controlErrorMessage = nil
        controlErrorDetail = nil
        isManagingHelper = true
        helperRegistration = "Removing…"
        Task {
            let service = SMAppService.daemon(plistName: IPCConstants.launchDaemonPlistName)
            if service.status == .enabled {
                do {
                    status = try await client.perform(.resetAutomatic)
                } catch {
                    automaticRegistrationSuppressed = false
                    UserDefaults.standard.set(
                        false,
                        forKey: "KazeAutomaticHelperRegistrationSuppressed"
                    )
                    errorMessage = "Helper was not removed because Apple Automatic cooling could not be confirmed: \(error)"
                    isManagingHelper = false
                    refreshRegistrationStatus()
                    return
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
                errorMessage = nil
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
        baseIntent = .profile(profile)
        baseRestoreAttempts = 0
        acquire(.profile(profile))
    }

    func maximum() {
        // `baseIntent` deliberately keeps whatever Maximum interrupted, so a
        // fallback returns there instead of to Apple Automatic.
        baseRestoreAttempts = 0
        acquire(.maximum)
    }

    func automatic() {
        baseIntent = .automatic
        baseRestoreAttempts = 0
        stopRenewing()
        controlGeneration &+= 1
        let generation = controlGeneration
        controlErrorMessage = nil
        controlErrorDetail = nil
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
        controlErrorDetail = nil
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
                    controlErrorDetail = nil
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
        ownLeaseID = leaseID
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
                    self.controlErrorDetail = nil
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

                    self.controlErrorMessage = "Reconnecting to the cooling controller…"
                    self.controlErrorDetail = "Lease renewal retry \(failureCount): \(errorDescription)"
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
            acceptObservedStatus(snapshot.status)
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
            acceptObservedStatus(newStatus)
            consecutiveConnectionFailures = 0
            registrationRecoveryAttempt = 0
            nextRegistrationRecoveryUptimeNanoseconds = 0
            isRecoveringHelper = false
            helperRecoveryMessage = nil
            errorMessage = nil
            refreshRegistrationStatus()
            restoreBaseIntentIfNeeded()
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

    /// Safety intervention or a hardware fail-safe ends the selected profile.
    /// Require an explicit user action before manual fan control can start again;
    /// silently re-arming while temperatures are volatile creates a cooling loop.
    private func acceptObservedStatus(_ newStatus: ControllerStatus) {
        status = newStatus
        guard case .profile = baseIntent, let fault = newStatus.fault else { return }
        switch newStatus.mode {
        case .safetyMaximum, .safetyCooling:
            let failedIntent = baseIntent.displayName
            baseIntent = .automatic
            baseRestoreAttempts = 0
            stopRenewing()
            ownLeaseID = nil
            controlErrorMessage = "\(failedIntent) stopped · Safety cooling is active"
            controlErrorDetail = fault.message
        case .failSafeAutomatic, .failSafeMaximum, .unrecoveredFault:
            let failedIntent = baseIntent.displayName
            baseIntent = .automatic
            baseRestoreAttempts = 0
            stopRenewing()
            ownLeaseID = nil
            controlErrorMessage = "\(failedIntent) stopped · Apple Automatic is active"
            controlErrorDetail = fault.message
        default:
            break
        }
    }

    /// The helper hands control back to Apple Automatic whenever a lease ends or
    /// safety cooling takes over — deliberately, since an app that stopped renewing
    /// must not keep driving the fans. Once it is back on plain automatic with no
    /// fault and no lease, the selected profile may be restored after a transient
    /// interruption. Safety and fail-safe transitions are filtered by
    /// `acceptObservedStatus` and always require explicit reacquisition.
    ///
    /// Maximum is not restored: it is a boost the user asked for once, and
    /// re-arming it unattended would keep the fans at full speed indefinitely.
    private func restoreBaseIntentIfNeeded() {
        guard case .profile = baseIntent else { return }
        guard !isPreviewMode, !isRecoveringHelper, !isManagingHelper else { return }
        guard pendingIntent == nil, renewalTask == nil else { return }
        guard let status, status.mode == .automatic,
              status.fault == nil, status.leaseID == nil else { return }
        // Repeated safety overrides would otherwise fight the restore forever.
        // Three tries is enough to ride out a lease hiccup; past that the user
        // decides, and picking any mode clears the count.
        guard baseRestoreAttempts < 3 else { return }
        baseRestoreAttempts += 1
        logger.notice(
            "base_intent_restore attempt=\(self.baseRestoreAttempts, privacy: .public) intent=\(self.baseIntent.displayName, privacy: .public)"
        )
        acquire(baseIntent)
    }

    private func isTerminalLeaseError(_ error: Error) -> Bool {
        guard case HelperClientError.remote(let remote) = error else { return false }
        return remote.code == "lease-not-owned" || remote.code == "lease-expired"
    }

    private func recordLostLease(reason: String, generation: UInt64) {
        guard generation == controlGeneration else { return }
        logger.error("lease_control_lost reason=\(reason, privacy: .public)")
        controlErrorMessage = "Cooling control ended · Apple Automatic is active"
        controlErrorDetail = "The control lease ended: \(reason)"
        renewalTask = nil
        endControlActivity()
    }

    private func refreshRegistrationStatus() {
        guard !isManagingHelper else { return }
        let service = SMAppService.daemon(plistName: IPCConstants.launchDaemonPlistName)
        helperRegistration = switch service.status {
        case .notRegistered: "Not registered"
        case .enabled: "Installed"
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
