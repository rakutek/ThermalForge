import Charts
import SwiftUI
import KazeDomain

struct TelemetryChartView: View {
    let samples: [TelemetrySample]
    let inventory: HardwareInventory?
    let window: TelemetryWindow
    let errorMessage: String?
    let onSelectWindow: (TelemetryWindow) -> Void

    @State private var metric: ChartMetric = .temperature
    @State private var sensorFamily: SensorFamily = .cpu
    @State private var fanOffset = 0
    @State private var selectedDate: Date?
    @State private var showsSeriesPicker = false

    private let thermalOrange = Color(red: 0.976, green: 0.451, blue: 0.086)
    private let coolingBlue = Color(red: 0.220, green: 0.741, blue: 0.973)
    private let safetyRed = Color(red: 0.937, green: 0.267, blue: 0.267)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            controls
            readout

            Group {
                if datedSamples.isEmpty {
                    emptyState
                } else if metric == .temperature {
                    temperatureChart
                } else {
                    fanChart
                }
            }
            .frame(height: 164)

            windowPicker

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .onChange(of: metric) { _, _ in
            selectedDate = nil
            showsSeriesPicker = false
        }
        .onChange(of: sensorFamily) { _, _ in selectedDate = nil }
        .onChange(of: fanOffset) { _, _ in selectedDate = nil }
        .onAppear { normalizeSelections() }
        .onChange(of: availableSensorFamilies) { _, _ in normalizeSelections() }
        .onChange(of: availableFans.count) { _, _ in normalizeSelections() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("THERMAL TRACE")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(samples.isEmpty ? Color.secondary : Color.green)
                .frame(width: 6, height: 6)
            Text(samples.isEmpty ? "WAITING" : "LIVE")
                .font(.caption2.monospaced().weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ChartMetric.allCases) { item in
                    Button {
                        metric = item
                    } label: {
                        Label(item.label, systemImage: item.icon)
                            .font(.caption.weight(metric == item ? .semibold : .regular))
                            .foregroundStyle(metric == item ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background {
                                Capsule()
                                    .fill(metric == item ? Color.primary.opacity(0.09) : Color.clear)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(metric == item ? "Selected" : "Not selected")
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.045), in: Capsule())

            Button {
                showsSeriesPicker = true
            } label: {
                selectorLabel(metric == .temperature ? sensorFamily.displayName : selectedFanLabel)
            }
            .buttonStyle(.plain)
            .frame(width: metric == .temperature ? 106 : 92)
            .popover(isPresented: $showsSeriesPicker, arrowEdge: .top) {
                seriesPicker
            }
        }
    }

    private var seriesPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            if metric == .temperature {
                ForEach(availableSensorFamilies, id: \.self) { family in
                    seriesChoice(
                        family.displayName,
                        selected: sensorFamily == family
                    ) {
                        sensorFamily = family
                        showsSeriesPicker = false
                    }
                }
            } else {
                ForEach(Array(availableFans.enumerated()), id: \.offset) { offset, fan in
                    seriesChoice(
                        "Fan \(fan.index)",
                        selected: fanOffset == offset
                    ) {
                        fanOffset = offset
                        showsSeriesPicker = false
                    }
                }
            }
        }
        .padding(6)
        .frame(minWidth: 132)
    }

    private func seriesChoice(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(thermalOrange)
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectorLabel(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var readout: some View {
        let point = selectedPoint ?? datedSamples.last
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if metric == .temperature {
                Text(temperatureValue(in: point).map { String(format: "%.1f°C", $0) } ?? "—°C")
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(thermalOrange)
                if let values = temperatureValues, !values.isEmpty {
                    Text("min \(values.min() ?? 0, specifier: "%.0f")°  max \(values.max() ?? 0, specifier: "%.0f")°")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(fanActualValue(in: point).map { "\($0) RPM" } ?? "— RPM")
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(coolingBlue)
                if let target = fanTargetValue(in: point) {
                    Text("target \(target)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(thermalOrange)
                }
            }
            Spacer()
            if let point {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(point.date, format: .dateTime.hour().minute().second())
                    Text(point.sample.mode.displayName)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(point.sample.faultCode == nil ? Color.secondary : safetyRed)
            }
        }
        .frame(height: 34)
    }

    private var temperatureChart: some View {
        Chart {
            if let limit = temperatureSafetyLimit {
                RuleMark(y: .value("Safety limit", limit))
                    .foregroundStyle(safetyRed.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("LIMIT \(Int(limit))°")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(safetyRed)
                    }
            }

            ForEach(datedSamples) { point in
                if let temperature = temperatureValue(in: point) {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Temperature", temperature)
                    )
                    .foregroundStyle(thermalOrange)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                }
            }

            if let latest = datedSamples.last,
               let temperature = temperatureValue(in: latest) {
                PointMark(
                    x: .value("Latest time", latest.date),
                    y: .value("Latest temperature", temperature)
                )
                .foregroundStyle(thermalOrange)
                .symbolSize(24)
            }

            selectionRule
        }
        .chartXScale(domain: timeDomain)
        .chartYScale(domain: temperatureDomain)
        .chartXAxis { timeAxis }
        .chartYAxis { temperatureAxis }
        .chartPlotStyle { plotArea in
            plotArea
                .background(thermalOrange.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel("\(sensorFamily.displayName) temperature history")
        .accessibilityValue(temperatureAccessibilityValue)
    }

    private var fanChart: some View {
        Chart {
            ForEach(datedSamples) { point in
                if let actual = fanActualValue(in: point) {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Actual RPM", actual),
                        series: .value("Reading", "Actual")
                    )
                    .foregroundStyle(coolingBlue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                }
                if let target = fanTargetValue(in: point) {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Target RPM", target),
                        series: .value("Reading", "Target")
                    )
                    .foregroundStyle(thermalOrange.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
                    .interpolationMethod(.stepCenter)
                }
            }

            if let latest = datedSamples.last,
               let actual = fanActualValue(in: latest) {
                PointMark(
                    x: .value("Latest time", latest.date),
                    y: .value("Latest RPM", actual)
                )
                .foregroundStyle(coolingBlue)
                .symbolSize(24)
            }

            selectionRule
        }
        .chartXScale(domain: timeDomain)
        .chartYScale(domain: fanDomain)
        .chartXAxis { timeAxis }
        .chartYAxis { rpmAxis }
        .chartPlotStyle { plotArea in
            plotArea
                .background(coolingBlue.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel("Fan speed history")
        .accessibilityValue(fanAccessibilityValue)
    }

    @ChartContentBuilder
    private var selectionRule: some ChartContent {
        if let selectedDate {
            RuleMark(x: .value("Selected time", selectedDate))
                .foregroundStyle(Color.primary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(thermalOrange)
            Text(errorMessage == nil ? "Collecting the first history samples…" : "No history to display")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
    }

    private var windowPicker: some View {
        HStack(spacing: 4) {
            Text("RANGE")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            ForEach(TelemetryWindow.allCases) { option in
                Button(option.shortLabel) { onSelectWindow(option) }
                    .buttonStyle(.plain)
                    .font(.caption.monospaced().weight(option == window ? .semibold : .regular))
                    .foregroundStyle(option == window ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        Capsule()
                            .fill(option == window ? Color.primary.opacity(0.09) : Color.clear)
                    }
                    .accessibilityLabel("Show the last \(option.accessibilityLabel)")
            }
        }
    }

    @AxisContentBuilder
    private var timeAxis: some AxisContent {
        AxisMarks(values: timeAxisValues) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(Color.primary.opacity(0.08))
            AxisValueLabel(format: .dateTime.hour().minute())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.secondary)
        }
    }

    @AxisContentBuilder
    private var temperatureAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(Color.primary.opacity(0.08))
            AxisValueLabel {
                if let degrees = value.as(Double.self) {
                    Text("\(Int(degrees))°")
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Color.secondary)
        }
    }

    @AxisContentBuilder
    private var rpmAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(Color.primary.opacity(0.08))
            AxisValueLabel {
                if let rpm = value.as(Int.self) {
                    Text(rpm >= 1_000 ? "\(rpm / 1_000)k" : "\(rpm)")
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Color.secondary)
        }
    }

    private var datedSamples: [DatedTelemetrySample] {
        let now = DispatchTime.now().uptimeNanoseconds
        let date = Date()
        return samples.map { sample in
            let age = now >= sample.sampledAtUptimeNanoseconds
                ? Double(now - sample.sampledAtUptimeNanoseconds) / 1_000_000_000
                : 0
            return DatedTelemetrySample(sample: sample, date: date.addingTimeInterval(-age))
        }
    }

    private var selectedPoint: DatedTelemetrySample? {
        guard let selectedDate else { return nil }
        return datedSamples.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private var timeDomain: ClosedRange<Date> {
        guard let first = datedSamples.first?.date,
              let last = datedSamples.last?.date else {
            let now = Date()
            return now.addingTimeInterval(-60)...now
        }
        let span = max(last.timeIntervalSince(first), 10)
        let padding = span * 0.025
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    private var timeAxisValues: [Date] {
        guard let first = datedSamples.first?.date,
              let last = datedSamples.last?.date else { return [] }
        let span = last.timeIntervalSince(first)
        return [0.2, 0.5, 0.8].map { fraction in
            first.addingTimeInterval(span * fraction)
        }
    }

    private var availableSensorFamilies: [SensorFamily] {
        let available = Set(inventory?.sensors.map(\.family) ?? samples.flatMap { $0.peakTemperatures.keys })
        let ordered: [SensorFamily] = [.cpu, .gpu, .memory, .storage, .power, .battery, .ambient, .other]
        let result = ordered.filter(available.contains)
        return result.isEmpty ? [.cpu] : result
    }

    private var availableFans: [FanLimits] {
        inventory?.fans ?? []
    }

    private var selectedFanLabel: String {
        guard availableFans.indices.contains(fanOffset) else { return "Fan" }
        return "Fan \(availableFans[fanOffset].index)"
    }

    private var temperatureValues: [Double]? {
        let values = datedSamples.compactMap { temperatureValue(in: $0) }
        return values.isEmpty ? nil : values
    }

    private var temperatureSafetyLimit: Double? {
        inventory?.sensors
            .filter { $0.family == sensorFamily }
            .map(\.safetyLimitCelsius)
            .min()
    }

    private var temperatureDomain: ClosedRange<Double> {
        let values = temperatureValues ?? []
        let lower = max(0, (values.min() ?? 20) - 8)
        let observedUpper = (values.max() ?? 80) + 5
        let upper = max(observedUpper, (temperatureSafetyLimit ?? observedUpper) + 3)
        return lower...max(lower + 10, upper)
    }

    private var fanDomain: ClosedRange<Int> {
        let inventoryMaximum = availableFans.indices.contains(fanOffset)
            ? availableFans[fanOffset].maximumRPM
            : 6_000
        let observedMaximum = datedSamples.compactMap { point in
            max(fanActualValue(in: point) ?? 0, fanTargetValue(in: point) ?? 0)
        }.max() ?? 0
        return 0...max(1_000, inventoryMaximum, observedMaximum)
    }

    private func temperatureValue(in point: DatedTelemetrySample?) -> Double? {
        point?.sample.peakTemperatures[sensorFamily]
    }

    private func fanActualValue(in point: DatedTelemetrySample?) -> Int? {
        guard let point, point.sample.fanActualRPMs.indices.contains(fanOffset) else { return nil }
        return point.sample.fanActualRPMs[fanOffset]
    }

    private func fanTargetValue(in point: DatedTelemetrySample?) -> Int? {
        guard let point, point.sample.fanTargetRPMs.indices.contains(fanOffset) else { return nil }
        return point.sample.fanTargetRPMs[fanOffset]
    }

    private func normalizeSelections() {
        if !availableSensorFamilies.contains(sensorFamily),
           let first = availableSensorFamilies.first {
            sensorFamily = first
        }
        if fanOffset >= availableFans.count {
            fanOffset = max(availableFans.count - 1, 0)
        }
    }

    private var temperatureAccessibilityValue: String {
        guard let latest = datedSamples.last, let value = temperatureValue(in: latest) else {
            return "No temperature samples"
        }
        return "Latest \(String(format: "%.1f", value)) degrees Celsius"
    }

    private var fanAccessibilityValue: String {
        guard let latest = datedSamples.last, let value = fanActualValue(in: latest) else {
            return "No fan samples"
        }
        return "Latest \(value) RPM"
    }
}

private struct DatedTelemetrySample: Identifiable {
    let sample: TelemetrySample
    let date: Date

    var id: UInt64 { sample.id }
}

private enum ChartMetric: String, CaseIterable, Identifiable {
    case temperature
    case fan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .temperature: "Temperature"
        case .fan: "Fan"
        }
    }

    var icon: String {
        switch self {
        case .temperature: "thermometer.medium"
        case .fan: "fan"
        }
    }
}

private extension SensorFamily {
    var displayName: String {
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
}

private extension TelemetryWindow {
    var accessibilityLabel: String {
        switch self {
        case .oneMinute: "one minute"
        case .fiveMinutes: "five minutes"
        case .fifteenMinutes: "fifteen minutes"
        case .oneHour: "one hour"
        }
    }
}
