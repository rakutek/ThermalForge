import SwiftUI
import KazeDomain

@main
struct KazeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(appState)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: iconName)
                if let temperature = peakDieTemperature {
                    Text("\(Int(temperature))°").font(.caption.monospaced())
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var peakDieTemperature: Double? {
        guard let status = appState.status else { return nil }
        let dieKeys = Set(status.inventory.sensors
            .filter { $0.family == .cpu || $0.family == .gpu }
            .map(\.key))
        return status.latestSample?.temperatures
            .filter { dieKeys.contains($0.key) }
            .values.max()
    }

    private var iconName: String {
        switch appState.status?.mode {
        case .safetyMaximum, .failSafeMaximum, .unrecoveredFault:
            "exclamationmark.triangle.fill"
        case .balanced, .performance, .smart, .fixed, .maximum:
            "fan.fill"
        default:
            "fan"
        }
    }
}
