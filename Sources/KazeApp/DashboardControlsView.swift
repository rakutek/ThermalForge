import SwiftUI
import KazeDomain

@MainActor
final class DashboardPresentationState: ObservableObject {
    @Published private(set) var activePopover: DashboardPopover?

    func binding(for popover: DashboardPopover) -> Binding<Bool> {
        Binding(
            get: { self.activePopover == popover },
            set: { isPresented in
                if isPresented {
                    self.activePopover = popover
                } else if self.activePopover == popover {
                    self.activePopover = nil
                }
            }
        )
    }

    func toggle(_ popover: DashboardPopover) {
        activePopover = activePopover == popover ? nil : popover
    }

    func present(_ popover: DashboardPopover) {
        activePopover = popover
    }

    func dismiss(_ popover: DashboardPopover) {
        if activePopover == popover { activePopover = nil }
    }
}

enum DashboardPopover: Equatable {
    case settings
    case sensorDetails
    case telemetrySensor
    case alertDetails
}

struct CoolingModeControlView: View {
    let status: ControllerStatus?
    let pendingIntent: ControlIntent?
    let isDisabled: Bool
    let hasExternalControl: Bool
    let onSelectProfile: (ProfileID) -> Void
    let onMaximum: () -> Void
    let onAutomatic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("MODE")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(CoolingModeOption.profileOptions) { option in
                        modeButton(option)
                    }
                }
                .padding(2)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

                modeButton(.maximum)
                    .frame(width: 52)
                    .padding(2)
                    .background(
                        Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Cooling mode")
            .accessibilityHint(modeDescription)
        }
        .help(modeDescription)
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func modeButton(_ option: CoolingModeOption) -> some View {
        let selected = confirmedOption == option
        let applying = pendingOption == option
        return Button {
            switch option {
            case .automatic: onAutomatic()
            case .balanced: onSelectProfile(.balanced)
            case .smart: onSelectProfile(.smart)
            case .performance: onSelectProfile(.performance)
            case .maximum: onMaximum()
            }
        } label: {
            Text(option.shortName)
                .font(.caption.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 26)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.primary.opacity(0.09) : Color.clear)
                }
                .overlay {
                    if applying && !selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(option.accent.opacity(0.8), lineWidth: 1)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Every option keeps a faint accent so the row reads left
                    // to right as quiet → hard cooling; the selected one is the
                    // only solid, full-width mark.
                    Capsule()
                        .fill(option.accent)
                        .frame(width: selected ? 18 : 11, height: 2)
                        .padding(.bottom, 2)
                        .opacity(selected ? 1 : 0.55)
                }
        }
        .buttonStyle(.plain)
        .disabled(option != .automatic && isDisabled)
        .help(option.description)
        .accessibilityLabel(option.fullName)
        .accessibilityHint(option.description)
        .accessibilityValue(
            selected ? "Selected" : (applying ? "Applying" : "Not selected")
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var confirmedOption: CoolingModeOption? {
        guard let status else { return nil }
        return CoolingModeOption(intent: status.intent)
    }

    private var pendingOption: CoolingModeOption? {
        pendingIntent.flatMap(CoolingModeOption.init(intent:))
    }

    private var modeDescription: String {
        if let pendingIntent, let option = CoolingModeOption(intent: pendingIntent) {
            if let confirmedOption {
                return "\(confirmedOption.fullName) active · Applying \(option.fullName)…"
            }
            return "Applying \(option.fullName)…"
        }
        guard let status else { return "Waiting for the cooling controller." }
        if hasExternalControl {
            return "Another Kaze client currently owns cooling control."
        }
        switch status.mode {
        case .safetyMaximum, .safetyCooling:
            return "Safety cooling is temporarily overriding the selected mode."
        case .failSafeAutomatic, .failSafeMaximum, .unrecoveredFault:
            return "Fail-safe control is active until hardware control recovers."
        case .fixed:
            return "A fixed fan speed is active from another Kaze client."
        case .starting:
            return "The cooling controller is starting."
        default:
            return confirmedOption?.description ?? "Choose how Kaze manages fan speed."
        }
    }
}

struct StatusBannerView: View {
    let message: String
    let systemImage: String
    let color: Color
    var actionTitle: String?
    var action: (() -> Void)?
    var additionalCount = 0
    var onShowAdditional: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Label(message, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(message)

            Spacer(minLength: 4)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.mini)
            }

            if additionalCount > 0, let onShowAdditional {
                Button(action: onShowAdditional) {
                    Text("\(additionalCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(color, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Show \(additionalCount) additional alerts")
                .accessibilityLabel("Show \(additionalCount) additional alerts")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 1)
        }
    }
}

struct ControllerStatusPill: View {
    let title: String
    let systemImage: String
    let color: Color
    let isWorking: Bool

    var body: some View {
        Group {
            if isWorking {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 28, height: 28)
        .background(color.opacity(0.12), in: Circle())
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Controller status")
        .accessibilityValue(title)
    }
}

struct AppSettingsPopoverView: View {
    let helperRegistration: String
    let isManagingHelper: Bool
    @Binding var launchAtLogin: Bool
    let onRegisterHelper: () -> Void
    let onUnregisterHelper: () -> Void
    let onOpenLoginItemSettings: () -> Void
    let onQuit: () -> Void

    @State private var confirmsHelperRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Kaze settings")
                    .font(.headline)
                Spacer()
                Text("v\(KazeVersion.current)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            settingsSectionLabel("GENERAL")

            Toggle("Launch at Login", isOn: $launchAtLogin)

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                settingsSectionLabel("COOLING SERVICE")

                HStack(spacing: 7) {
                    Label("Privileged helper", systemImage: "lock.shield.fill")
                        .font(.body.weight(.medium))
                    Spacer()
                    if isManagingHelper {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(helperRegistration)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Repair or Update Helper", action: onRegisterHelper)
                    .controlSize(.small)
                    .disabled(isManagingHelper)

                Button(action: onOpenLoginItemSettings) {
                    HStack {
                        Text("Open Login Item Settings")
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.caption2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isManagingHelper)

                Button("Remove Helper…", role: .destructive) {
                    confirmsHelperRemoval = true
                }
                .buttonStyle(.plain)
                .disabled(isManagingHelper)
            }

            Divider()

            settingsSectionLabel("APPLICATION")

            HStack {
                Text("Menu bar application")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit Kaze", action: onQuit)
                    .controlSize(.small)
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .alert("Remove privileged helper?", isPresented: $confirmsHelperRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Restore Automatic & Remove", role: .destructive, action: onUnregisterHelper)
        } message: {
            Text(
                "Kaze will first confirm Apple Automatic cooling, then stop control and remove the privileged helper."
            )
        }
    }

    private func settingsSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

enum CoolingModeOption: String, CaseIterable, Identifiable {
    case automatic
    case balanced
    case smart
    case performance
    case maximum

    var id: String { rawValue }

    static let profileOptions: [CoolingModeOption] = [
        .automatic, .balanced, .smart, .performance,
    ]

    init?(intent: ControlIntent) {
        switch intent {
        case .automatic: self = .automatic
        case .profile(.balanced): self = .balanced
        case .profile(.smart): self = .smart
        case .profile(.performance): self = .performance
        case .maximum: self = .maximum
        case .fixedRPM: return nil
        }
    }

    var shortName: String {
        switch self {
        case .automatic: "Auto"
        case .balanced: "Balanced"
        case .smart: "Smart"
        case .performance: "Performance"
        case .maximum: "Max"
        }
    }

    var fullName: String {
        switch self {
        case .automatic: "Apple Automatic"
        case .balanced: "Balanced"
        case .smart: "Smart"
        case .performance: "Performance"
        case .maximum: "Maximum"
        }
    }

    var description: String {
        switch self {
        case .automatic: "Apple manages fan speed using the system controller."
        case .balanced: "Quieter cooling for everyday work."
        case .smart: "Adapts to sustained heat and fast temperature rises."
        case .performance: "Responds earlier to keep temperatures lower."
        case .maximum: "Runs every fan at maximum speed."
        }
    }

    /// Ordered cool to hot so the mode row doubles as an intensity scale.
    var accent: Color {
        switch self {
        case .automatic: Color(red: 0.204, green: 0.780, blue: 0.349)
        case .balanced: Color(red: 0.157, green: 0.682, blue: 0.616)
        case .smart: Color(red: 0.949, green: 0.718, blue: 0.157)
        case .performance: Color(red: 0.976, green: 0.451, blue: 0.086)
        case .maximum: Color(red: 0.937, green: 0.267, blue: 0.267)
        }
    }
}
