import SwiftUI
import KazeDomain

struct CurrentReadingsView: View {
    let sample: HardwareSample
    let inventory: HardwareInventory

    @EnvironmentObject private var presentationState: DashboardPresentationState

    private let temperatureColumns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 4
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header

            LazyVGrid(columns: fanColumns, spacing: 6) {
                ForEach(sample.fans, id: \.index) { fan in
                    FanReadingCell(fan: fan, isCompact: usesCompactFanGrid)
                }
            }

            HStack(spacing: 6) {
                Text("THERMAL ZONES")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }

            LazyVGrid(columns: temperatureColumns, spacing: 6) {
                ForEach(temperatureSummaries) { summary in
                    TemperatureReadingCell(summary: summary)
                }
            }
        }
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

    private var usesCompactFanGrid: Bool {
        sample.fans.count > 2
    }

    private var fanColumns: [GridItem] {
        let columnCount = usesCompactFanGrid ? 4 : max(min(sample.fans.count, 2), 1)
        return Array(
            repeating: GridItem(.flexible(), spacing: 6),
            count: columnCount
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("LIVE READINGS")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            Text("\(sample.fans.count) fans · \(sensorDetailRows.count) sensors")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                presentationState.toggle(.sensorDetails)
            } label: {
                Label("Details", systemImage: "list.bullet")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Show individual hardware sensors")
            .accessibilityLabel("Show individual sensor details")
            .popover(
                isPresented: presentationState.binding(for: .sensorDetails),
                arrowEdge: .leading
            ) {
                SensorDetailsPopover(rows: sensorDetailRows)
            }
        }
    }

    private var temperatureSummaries: [TemperatureSummary] {
        readingFamilyOrder.compactMap { family in
            let rows = sensorDetailRows.filter { $0.family == family }
            guard !rows.isEmpty else { return nil }
            let headrooms = rows.compactMap { row -> Double? in
                guard let value = row.value, let limit = row.safetyLimit else { return nil }
                return limit - value
            }
            let loads = rows.compactMap { row -> Double? in
                guard let value = row.value, let limit = row.safetyLimit, limit > 0 else { return nil }
                return value / limit
            }
            return TemperatureSummary(
                family: family,
                hottest: rows.compactMap(\.value).max(),
                minimumHeadroom: headrooms.min(),
                thermalLoad: CGFloat(min(max(loads.max() ?? 0, 0), 1)),
                sensorCount: rows.count,
                unavailableCount: rows.filter(\.isUnavailable).count
            )
        }
    }

    private var sensorDetailRows: [SensorDetailReading] {
        let knownKeys = Set(inventory.sensors.map(\.key))
        var seeds = inventory.sensors.map { descriptor in
            SensorDetailSeed(
                key: descriptor.key,
                family: descriptor.family,
                value: sample.temperatures[descriptor.key],
                safetyLimit: descriptor.safetyLimitCelsius,
                isUnavailable: sample.failedSensorKeys.contains(descriptor.key)
                    || sample.temperatures[descriptor.key] == nil
            )
        }

        let extraKeys = Set(sample.temperatures.keys)
            .union(sample.failedSensorKeys)
            .subtracting(knownKeys)
        seeds += extraKeys.map { key in
            SensorDetailSeed(
                key: key,
                family: .other,
                value: sample.temperatures[key],
                safetyLimit: nil,
                isUnavailable: sample.failedSensorKeys.contains(key)
                    || sample.temperatures[key] == nil
            )
        }

        return readingFamilyOrder.flatMap { family in
            let familySeeds = seeds
                .filter { $0.family == family }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            return familySeeds.map { seed in
                SensorDetailReading(
                    key: seed.key,
                    family: family,
                    value: seed.value,
                    safetyLimit: seed.safetyLimit,
                    isUnavailable: seed.isUnavailable
                )
            }
        }
    }
}

private struct FanReadingCell: View {
    let fan: FanReading
    let isCompact: Bool

    private let coolingBlue = Color(red: 0.220, green: 0.741, blue: 0.973)

    var body: some View {
        Group {
            if isCompact {
                compactContent
            } else {
                regularContent
            }
        }
        .padding(.horizontal, isCompact ? 6 : 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: isCompact ? 38 : 40, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("Fan \(fan.index + 1) · \(fan.mode.readingsName) · target \(fan.targetRPM) RPM")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fan \(fan.index + 1), \(fan.mode.readingsName)")
        .accessibilityValue("\(fan.actualRPM) RPM, target \(fan.targetRPM) RPM")
    }

    private var regularContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                fanLabel(longForm: true)
                Spacer(minLength: 4)
                Text(fan.mode.readingsName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(fan.actualRPM)")
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                Text("RPM")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("Target \(fan.targetRPM)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            fanLabel(longForm: false)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(fan.actualRPM)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                Spacer(minLength: 1)
                Text("→\(fan.targetRPM)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fanLabel(longForm: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "fan.fill")
                .font(.caption2)
                .foregroundStyle(coolingBlue)
            Text(longForm ? "Fan \(fan.index + 1)" : "F\(fan.index + 1)")
                .font(.caption.weight(.medium))
        }
    }
}

private struct TemperatureReadingCell: View {
    let summary: TemperatureSummary

    private let thermalOrange = Color(red: 0.976, green: 0.451, blue: 0.086)
    private let safetyRed = Color(red: 0.937, green: 0.267, blue: 0.267)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: summary.family.readingsIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusColor)
                Text(summary.family.readingsName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if summary.unavailableCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(thermalOrange)
                        .help("\(summary.unavailableCount) unavailable")
                }
            }

            Text(summary.hottest.map { String(format: "%.1f°", $0) } ?? "—°")
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(summary.state == .danger ? safetyRed : Color.primary)

            Text(summary.headroomLabel)
                .font(.system(size: 10, weight: summary.state == .normal ? .regular : .medium))
                .foregroundStyle(headroomColor)
                .lineLimit(1)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(statusColor)
                        .frame(width: max(2, proxy.size.width * summary.thermalLoad))
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(summary.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.family.readingsName) temperature")
        .accessibilityValue(summary.accessibilityValue)
    }

    private var statusColor: Color {
        switch summary.state {
        case .normal, .warning: thermalOrange
        case .danger: safetyRed
        case .unavailable: .secondary
        }
    }

    private var headroomColor: Color {
        switch summary.state {
        case .normal: .secondary
        case .warning: thermalOrange
        case .danger: safetyRed
        case .unavailable: .orange
        }
    }
}

private struct SensorDetailsPopover: View {
    let rows: [SensorDetailReading]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sensor details")
                    .font(.headline)
                Spacer()
                Text("\(rows.count) total")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Hardware IDs are kept here for diagnostics.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        HStack(spacing: 5) {
                            Image(systemName: group.family.readingsIcon)
                            Text(group.family.readingsName.uppercased())
                            Spacer()
                            Text("\(group.rows.count)")
                                .monospacedDigit()
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, group.id == groups.first?.id ? 0 : 10)
                        .padding(.bottom, 3)

                        ForEach(group.rows) { row in
                            HStack(spacing: 8) {
                                Text("Sensor ID")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(row.key)
                                    .font(.caption.monospaced().weight(.medium))

                                Spacer()

                                if let value = row.value {
                                    Text("\(value, specifier: "%.1f")°C")
                                        .font(.caption.monospacedDigit().weight(.medium))
                                } else {
                                    Text("Unavailable")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 5)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(group.family.readingsName) sensor ID \(row.key)")
                            .accessibilityValue(row.value.map {
                                String(format: "%.1f degrees Celsius", $0)
                            } ?? "Unavailable")

                            if row.id != group.rows.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(
            width: 300,
            height: min(max(CGFloat(rows.count) * 39 + 76, 160), 340)
        )
    }

    private var groups: [SensorDetailGroup] {
        readingFamilyOrder.compactMap { family in
            let familyRows = rows.filter { $0.family == family }
            guard !familyRows.isEmpty else { return nil }
            return SensorDetailGroup(family: family, rows: familyRows)
        }
    }
}

private struct TemperatureSummary: Identifiable {
    let family: SensorFamily
    let hottest: Double?
    let minimumHeadroom: Double?
    let thermalLoad: CGFloat
    let sensorCount: Int
    let unavailableCount: Int

    var id: String { family.rawValue }

    var state: TemperatureState {
        guard hottest != nil else { return .unavailable }
        guard let headroom = minimumHeadroom else { return .normal }
        if headroom <= 0 { return .danger }
        if headroom <= 10 { return .warning }
        return .normal
    }

    var headroomLabel: String {
        guard hottest != nil else { return "Unavailable" }
        guard let headroom = minimumHeadroom else { return "No limit" }
        if headroom < -1 { return String(format: "%.0f° over limit", abs(headroom)) }
        if headroom < 0 { return "<1° over limit" }
        if headroom == 0 { return "At limit" }
        if headroom < 1 { return "<1° to limit" }
        return String(format: "%.0f° to limit", headroom)
    }

    var helpText: String {
        guard let hottest else { return "No reading available" }
        guard let headroom = minimumHeadroom else {
            return String(format: "Hottest reading %.1f°C", hottest)
        }
        if headroom < 0 {
            return String(
                format: "Hottest %.1f°C · %.1f°C above the closest safety limit",
                hottest,
                abs(headroom)
            )
        }
        if headroom == 0 {
            return String(format: "Hottest %.1f°C · at the safety limit", hottest)
        }
        return String(
            format: "Hottest %.1f°C · %.1f°C to the closest safety limit",
            hottest,
            headroom
        )
    }

    var accessibilityValue: String {
        guard let hottest else { return "No reading available" }
        let sensorNoun = sensorCount == 1 ? "sensor" : "sensors"
        var value = String(
            format: "%.1f degrees Celsius across %d %@, %@",
            hottest,
            sensorCount,
            sensorNoun,
            headroomLabel
        )
        if unavailableCount > 0 {
            value += ", \(unavailableCount) unavailable"
        }
        return value
    }
}

private enum TemperatureState {
    case normal
    case warning
    case danger
    case unavailable
}

private struct SensorDetailSeed {
    let key: String
    let family: SensorFamily
    let value: Double?
    let safetyLimit: Double?
    let isUnavailable: Bool
}

private struct SensorDetailReading: Identifiable {
    let key: String
    let family: SensorFamily
    let value: Double?
    let safetyLimit: Double?
    let isUnavailable: Bool

    var id: String { key }
}

private struct SensorDetailGroup: Identifiable {
    let family: SensorFamily
    let rows: [SensorDetailReading]

    var id: String { family.rawValue }
}

private let readingFamilyOrder: [SensorFamily] = [
    .cpu, .gpu, .memory, .storage, .power, .battery, .ambient, .other,
]

private extension SensorFamily {
    var readingsName: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .power: "Power"
        case .battery: "Battery"
        case .ambient: "Ambient"
        case .other: "Other"
        }
    }

    var readingsIcon: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .power: "bolt.fill"
        case .battery: "battery.100"
        case .ambient: "thermometer.medium"
        case .other: "ellipsis.circle"
        }
    }
}

private extension FanMode {
    var readingsName: String {
        switch self {
        case .automatic, .system: "Automatic"
        case .manual: "Manual"
        case .unknown: "Unknown"
        }
    }
}
