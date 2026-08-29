import SwiftUI
import KazeDomain

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kaze").font(.headline)
                Spacer()
                Text(appState.modeDisplayName)
                    .font(.caption.monospaced())
                    .foregroundStyle(stateColor)
            }

            if let fault = appState.status?.fault {
                Label(fault.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = appState.controlErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if let sample = appState.status?.latestSample {
                Text("FANS").font(.caption2).foregroundStyle(.secondary)
                ForEach(sample.fans, id: \.index) { fan in
                    HStack {
                        Text("Fan \(fan.index)")
                        Spacer()
                        Text("\(fan.actualRPM) / \(fan.targetRPM) RPM").font(.body.monospaced())
                        Text(fan.mode.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Text("TEMPERATURES").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(sample.temperatures.keys.sorted(), id: \.self) { key in
                    if let value = sample.temperatures[key] {
                        HStack {
                            Text(key).font(.body.monospaced())
                            Spacer()
                            Text("\(value, specifier: "%.1f")°C")
                                .font(.body.monospaced())
                                .foregroundStyle(value >= 90 ? .red : .primary)
                        }
                    }
                }
            } else {
                Text("Waiting for the signed helper…").foregroundStyle(.secondary)
            }

            Divider()

            Text("MODE").font(.caption2).foregroundStyle(.secondary)
            HStack {
                ForEach(ProfileID.allCases, id: \.self) { profile in
                    Button(profile.rawValue.capitalized) { appState.selectProfile(profile) }
                }
            }
            HStack {
                Button("Maximum") { appState.maximum() }.tint(.orange)
                Button("Apple Automatic") { appState.automatic() }
            }

            Divider()

            HStack {
                Text("Privileged helper")
                Spacer()
                Text(appState.helperRegistration).foregroundStyle(.secondary)
            }
            HStack {
                Button("Register / Update") { appState.registerHelper() }
                Button("Unregister") { appState.unregisterHelper() }
                Button("Open Settings") { appState.openLoginItemSettings() }
            }

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                )
            )

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 380)
    }

    private var stateColor: Color {
        if appState.pendingIntent != nil { return .orange }
        return switch appState.status?.mode {
        case .safetyMaximum, .safetyCooling, .failSafeMaximum, .unrecoveredFault: .red
        case .maximum, .fixed, .balanced, .performance, .smart: .orange
        case .automatic, .failSafeAutomatic: .green
        default: .secondary
        }
    }
}
