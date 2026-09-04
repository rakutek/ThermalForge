import SwiftUI
import KazeDomain

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var presentationState: DashboardPresentationState

    var body: some View {
        VStack(spacing: 0) {
            header

            if let alert = dashboardAlerts.first {
                alertView(
                    alert,
                    additionalAlerts: Array(dashboardAlerts.dropFirst())
                )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            CoolingModeControlView(
                status: appState.status,
                pendingIntent: appState.pendingIntent,
                isDisabled: appState.restrictsManagedModeSelection,
                hasExternalControl: appState.hasExternalControlLease,
                onSelectProfile: appState.selectProfile,
                onMaximum: appState.maximum,
                onAutomatic: appState.automatic
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let status = appState.status, let sample = status.latestSample {
                    CurrentReadingsView(sample: sample, inventory: status.inventory)
                        .layoutPriority(1)
                } else {
                    HStack(spacing: 8) {
                        if appState.isRecoveringHelper {
                            ProgressView().controlSize(.small)
                        }
                        Text(appState.isRecoveringHelper
                            ? "Restoring…"
                            : "Connecting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }

                TelemetryChartView(
                    samples: appState.telemetrySamples,
                    inventory: appState.status?.inventory,
                    window: appState.telemetryWindow,
                    errorMessage: appState.telemetryErrorMessage,
                    onSelectWindow: appState.setTelemetryWindow
                )
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 430, height: 750)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text("Kaze")
                .font(.system(.title3, design: .rounded).weight(.semibold))

            Spacer()

            ControllerStatusPill(
                title: appState.modeDisplayName,
                systemImage: stateSymbol,
                color: stateColor,
                isWorking: appState.pendingIntent != nil || appState.isRecoveringHelper
            )

            Button {
                presentationState.toggle(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Kaze settings")
            .accessibilityLabel("Open Kaze settings")
            .popover(
                isPresented: presentationState.binding(for: .settings),
                arrowEdge: .leading
            ) {
                AppSettingsPopoverView(
                    helperRegistration: appState.helperRegistration,
                    isManagingHelper: appState.isManagingHelper,
                    launchAtLogin: Binding(
                        get: { appState.launchAtLogin },
                        set: { appState.setLaunchAtLogin($0) }
                    ),
                    onRegisterHelper: appState.registerHelper,
                    onUnregisterHelper: appState.unregisterHelper,
                    onOpenLoginItemSettings: appState.openLoginItemSettings,
                    onQuit: { NSApplication.shared.terminate(nil) }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func alertView(
        _ alert: DashboardAlert,
        additionalAlerts: [DashboardAlert] = []
    ) -> some View {
        StatusBannerView(
            message: alert.message,
            systemImage: alert.systemImage,
            color: alert.color,
            actionTitle: alert.actionTitle,
            action: alert.action,
            additionalCount: additionalAlerts.count,
            onShowAdditional: additionalAlerts.isEmpty
                ? nil
                : { presentationState.present(.alertDetails) }
        )
        .help(alert.help ?? alert.message)
        .popover(
            isPresented: presentationState.binding(for: .alertDetails),
            arrowEdge: .leading
        ) {
            AlertDetailsPopover(alerts: additionalAlerts)
        }
    }

    private var dashboardAlerts: [DashboardAlert] {
        var alerts: [DashboardAlert] = []

        if let modeAlert = controllerModeAlert {
            alerts.append(modeAlert)
        } else if let fault = appState.status?.fault {
            alerts.append(
                DashboardAlert(
                    id: "fault",
                    message: fault.message,
                    systemImage: "exclamationmark.triangle.fill",
                    color: .red
                )
            )
        }

        if let message = appState.helperRecoveryMessage {
            let helperAction = helperAlertAction
            alerts.append(
                DashboardAlert(
                    id: "helper",
                    message: message,
                    systemImage: appState.isRecoveringHelper
                        ? "arrow.triangle.2.circlepath"
                        : "exclamationmark.circle",
                    color: appState.isRecoveringHelper ? .orange : .red,
                    actionTitle: helperAction?.title,
                    action: helperAction?.action
                )
            )
        }

        if let error = appState.errorMessage {
            alerts.append(
                DashboardAlert(
                    id: "app-error",
                    message: error,
                    systemImage: "xmark.circle.fill",
                    color: .red
                )
            )
        }

        if let error = appState.controlErrorMessage {
            alerts.append(
                DashboardAlert(
                    id: "control-error",
                    message: error,
                    systemImage: "exclamationmark.circle",
                    color: .orange,
                    actionTitle: "Restore Auto",
                    action: appState.automatic,
                    help: appState.controlErrorDetail
                )
            )
        }

        return alerts
    }

    private var controllerModeAlert: DashboardAlert? {
        guard let status = appState.status else { return nil }
        let faultHelp = status.fault?.message

        switch status.mode {
        case .safetyMaximum:
            return DashboardAlert(
                id: "safety-maximum",
                message: "Safety limit · Maximum cooling",
                systemImage: "exclamationmark.triangle.fill",
                color: .red,
                help: faultHelp ?? "Safety limit reached. Fans are running at maximum."
            )
        case .safetyCooling:
            return DashboardAlert(
                id: "safety-cooling",
                message: "Cooling down · Safety control",
                systemImage: "thermometer.high",
                color: .red,
                help: faultHelp ?? "Temperatures are recovering. Safety cooling remains active."
            )
        case .failSafeAutomatic:
            return DashboardAlert(
                id: "fail-safe-automatic",
                message: "Control failed · Apple Automatic",
                systemImage: "exclamationmark.shield.fill",
                color: .red,
                help: faultHelp ?? "Hardware control failed. Apple Automatic cooling is active."
            )
        case .failSafeMaximum:
            return DashboardAlert(
                id: "fail-safe-maximum",
                message: "Control failed · Maximum cooling",
                systemImage: "exclamationmark.shield.fill",
                color: .red,
                help: faultHelp ?? "Hardware control failed. Maximum cooling is active."
            )
        case .unrecoveredFault:
            return DashboardAlert(
                id: "unrecovered-fault",
                message: "Control offline",
                systemImage: "xmark.shield.fill",
                color: .red,
                actionTitle: "Restore Auto",
                action: appState.automatic,
                help: faultHelp ?? "Cooling control could not recover. Restore Apple Automatic."
            )
        case .fixed:
            return DashboardAlert(
                id: "fixed-control",
                message: "Fixed speed · Another Kaze client",
                systemImage: "person.2.fill",
                color: .orange,
                actionTitle: "Restore Auto",
                action: appState.automatic
            )
        default:
            if appState.hasExternalControlLease {
                return DashboardAlert(
                    id: "external-control",
                    message: "Controlled by another Kaze client",
                    systemImage: "person.2.fill",
                    color: .orange,
                    actionTitle: "Restore Auto",
                    action: appState.automatic
                )
            }
            return nil
        }
    }

    private var helperAlertAction: (title: String, action: () -> Void)? {
        switch appState.helperRegistration {
        case "Needs approval":
            return ("Open Settings", appState.openLoginItemSettings)
        case "Not registered":
            return ("Install Helper", appState.registerHelper)
        default:
            if appState.helperRecoveryMessage?.localizedCaseInsensitiveContains("failed") == true {
                return ("Retry", appState.registerHelper)
            }
            return nil
        }
    }

    /// Mirrors the menu bar icon: a filled fan whenever Kaze is driving the
    /// hardware, a hollow one while Apple's controller is, and a shield or
    /// warning when safety control has taken over.
    private var stateSymbol: String {
        switch appState.status?.mode {
        case .safetyMaximum, .safetyCooling, .failSafeAutomatic, .failSafeMaximum:
            "exclamationmark.triangle.fill"
        case .unrecoveredFault:
            "xmark.shield.fill"
        case .performance, .smart, .fixed, .maximum:
            "fan.fill"
        default:
            "fan"
        }
    }

    private var stateColor: Color {
        switch appState.status?.mode {
        case .safetyMaximum, .safetyCooling, .failSafeAutomatic,
             .failSafeMaximum, .unrecoveredFault:
            return .red
        default:
            break
        }
        if appState.pendingIntent != nil || appState.isRecoveringHelper { return .orange }
        // Same ramp as the mode row, so the pill and the selected mode always
        // read as the same colour.
        guard let intent = appState.status?.intent,
              let option = CoolingModeOption(intent: intent) else { return .secondary }
        return option.accent
    }
}

private struct DashboardAlert: Identifiable {
    let id: String
    let message: String
    let systemImage: String
    let color: Color
    var actionTitle: String?
    var action: (() -> Void)?
    var help: String?
}

private struct AlertDetailsPopover: View {
    let alerts: [DashboardAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alerts")
                .font(.headline)

            ForEach(alerts) { alert in
                VStack(alignment: .leading, spacing: 6) {
                    Label(alert.message, systemImage: alert.systemImage)
                        .font(.caption)
                        .foregroundStyle(alert.color)
                        .fixedSize(horizontal: false, vertical: true)

                    if let actionTitle = alert.actionTitle, let action = alert.action {
                        Button(actionTitle, action: action)
                            .controlSize(.small)
                    }
                }

                if alert.id != alerts.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}
