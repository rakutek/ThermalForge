import Foundation
import ServiceManagement
import SwiftUI
import KazeDomain
import KazeIPC

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var status: ControllerStatus?
    @Published private(set) var errorMessage: String?
    @Published private(set) var helperRegistration = "Checking…"
    @Published private(set) var pendingIntent: ControlIntent?
    @Published var launchAtLogin = false

    private let client = HelperClient()
    private var pollTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?

    var modeDisplayName: String {
        if let status {
            switch status.mode {
            case .safetyMaximum, .failSafeAutomatic, .failSafeMaximum, .unrecoveredFault:
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
            let error = error as NSError
            errorMessage = "Helper registration failed (\(error.domain) \(error.code)): \(error.localizedDescription)"
        }
        refreshRegistrationStatus()
    }

    func unregisterHelper() {
        renewalTask?.cancel()
        renewalTask = nil
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
        renewalTask?.cancel()
        renewalTask = nil
        pendingIntent = .automatic
        Task {
            await runOperation(.resetAutomatic)
            pendingIntent = nil
        }
    }

    func disconnect() {
        renewalTask?.cancel()
        pollTask?.cancel()
        client.invalidate()
    }

    private func acquire(_ intent: ControlIntent) {
        renewalTask?.cancel()
        renewalTask = nil
        pendingIntent = intent
        Task {
            defer { pendingIntent = nil }
            do {
                let newStatus = try await client.perform(.acquire(intent: intent, leaseSeconds: 20))
                status = newStatus
                errorMessage = nil
                if let leaseID = newStatus.leaseID { startRenewing(leaseID) }
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func startRenewing(_ leaseID: UUID) {
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                do {
                    self.status = try await self.client.perform(.renew(leaseID: leaseID))
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = "Control lease was lost: \(error)"
                    return
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
