import Charts
import SwiftUI
import KazeDomain

/// Temperature and fan speed share one plot: the whole point of the app is that
/// one causes the other, and a metric toggle hid exactly that relationship.
/// The two series keep their own scales — orange on the leading axis, blue on
/// the trailing one — so each stays readable at its own magnitude.
struct TelemetryChartView: View {
    let samples: [TelemetrySample]
    let inventory: HardwareInventory?
    let window: TelemetryWindow
    let errorMessage: String?
    let onSelectWindow: (TelemetryWindow) -> Void

    @EnvironmentObject private var presentationState: DashboardPresentationState

    // MenuBarExtra may reconstruct its content as status polling publishes new
    // values. Keep the selected series outside that transient view lifetime.
    @AppStorage("KazeTelemetrySensorFamily") private var sensorFamily: SensorFamily = .cpu
    @AppStorage("KazeTelemetryFanOffset") private var fanOffset = 0
    @State private var selectedDate: Date?

    private let thermalOrange = Color(red: 0.976, green: 0.451, blue: 0.086)
    private let coolingBlue = Color(red: 0.220, green: 0.741, blue: 0.973)
    private let safetyRed = Color(red: 0.937, green: 0.267, blue: 0.267)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            controls
            readout

            Group {
                if datedSamples.isEmpty {
                    emptyState
                } else {
                    unifiedChart
                }
            }
            .frame(minHeight: 72, maxHeight: .infinity)
        }
        .padding(9)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .onChange(of: sensorFamily) { _, _ in selectedDate = nil }
        .onChange(of: fanOffset) { _, _ in selectedDate = nil }
        .onAppear { normalizeSelections() }
        .onChange(of: availableSensorFamilies) { _, _ in normalizeSelections() }
        .onChange(of: availableFans.count) { _, _ in normalizeSelections() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("HISTORY")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let errorMessage {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(errorMessage)
                    .accessibilityLabel(errorMessage)
            }
            rangePicker
        }
    }

    /// One picker per series. Each carries its series colour, which is the only
    /// thing tying a line to its axis and to its number in the readout.
    private var controls: some View {
        HStack(spacing: 6) {
            seriesButton(
                title: sensorFamily.displayName,
                systemImage: "thermometer.medium",
                color: thermalOrange,
                popover: .telemetrySensor
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(availableSensorFamilies, id: \.self) { family in
                        seriesChoice(family.displayName, selected: sensorFamily == family) {
                            sensorFamily = family
                            presentationState.dismiss(.telemetrySensor)
                        }
                    }
                }
                .padding(6)
                .frame(minWidth: 132)
            }
            .accessibilityLabel("Temperature series")

            seriesButton(
                title: selectedFanLabel,
                systemImage: "fan.fill",
                color: coolingBlue,
                popover: .telemetryFan
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(availableFans.enumerated()), id: \.offset) { offset, fan in
                        seriesChoice("Fan \(fan.index + 1)", selected: fanOffset == offset) {
                            fanOffset = offset
                            presentationState.dismiss(.telemetryFan)
                        }
                    }
                }
                .padding(6)
                .frame(minWidth: 132)
            }
            .accessibilityLabel("Fan series")
        }
    }

    private func seriesButton<Content: View>(
        title: String,
        systemImage: String,
        color: Color,
        popover: DashboardPopover,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Button {
            presentationState.present(popover)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(color)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(color.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: presentationState.binding(for: popover), arrowEdge: .leading) {
            content()
        }
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

    /// Both current values, coloured to match their line and their axis.
    private var readout: some View {
        let point = selectedPoint ?? datedSamples.last
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(temperatureValue(in: point).map { String(format: "%.1f°C", $0) } ?? "—°C")
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(thermalOrange)

            Text(fanActualValue(in: point).map { "\($0) rpm" } ?? "— rpm")
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(coolingBlue)

            if let target = fanTargetValue(in: point) {
                HStack(spacing: 4) {
                    dashedSwatch(coolingBlue)
                    Text("Target \(target)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if selectedDate != nil, let point {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(point.date, format: .dateTime.hour().minute().second())
                    Text(point.sample.mode.displayName)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(point.sample.faultCode == nil ? Color.secondary : safetyRed)
            }
        }
        .frame(height: 28)
    }

    private func dashedSwatch(_ color: Color) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule()
                    .fill(color)
                    .frame(width: 4, height: 2)
            }
        }
        .accessibilityHidden(true)
    }

    private var unifiedChart: some View {
        Chart {
            if showsSafetyLimit, let limit = temperatureSafetyLimit {
                RuleMark(y: .value("Safety limit", limit))
                    .foregroundStyle(safetyRed.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .bottom, alignment: .leading, spacing: 2) {
                        Text("LIMIT \(Int(limit))°")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(safetyRed)
                    }
            }

            ForEach(datedSamples) { point in
                if let target = fanTargetValue(in: point) {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Fan target", plot(rpm: target)),
                        series: .value("Series", "Fan target")
                    )
                    .foregroundStyle(coolingBlue.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
                    .interpolationMethod(.stepCenter)
                }

                if let actual = fanActualValue(in: point) {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Fan", plot(rpm: actual)),
                        series: .value("Series", "Fan")
                    )
                    .foregroundStyle(coolingBlue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                }

                if let temperature = temperatureValue(in: point) {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Temperature", temperature),
                        series: .value("Series", "Temperature")
                    )
                    .foregroundStyle(thermalOrange)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                }
            }

            if let latest = datedSamples.last {
                if let actual = fanActualValue(in: latest) {
                    PointMark(
                        x: .value("Latest time", latest.date),
                        y: .value("Latest fan", plot(rpm: actual))
                    )
                    .foregroundStyle(coolingBlue)
                    .symbolSize(24)
                }
                if let temperature = temperatureValue(in: latest) {
                    PointMark(
                        x: .value("Latest time", latest.date),
                        y: .value("Latest temperature", temperature)
                    )
                    .foregroundStyle(thermalOrange)
                    .symbolSize(24)
                }
            }

            selectionRule
        }
        .chartXScale(domain: timeDomain)
        .chartYScale(domain: temperatureDomain)
        .chartXAxis { timeAxis }
        .chartYAxis { dualAxis }
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color.primary.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel("\(sensorFamily.displayName) temperature and \(selectedFanLabel) speed history")
        .accessibilityValue(chartAccessibilityValue)
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
            Text(errorMessage == nil ? "Collecting…" : "No data")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
    }

    private var rangePicker: some View {
        HStack(spacing: 1) {
            ForEach(TelemetryWindow.allCases) { option in
                Button(option.shortLabel) { onSelectWindow(option) }
                    .buttonStyle(.plain)
                    .font(.caption2.monospaced().weight(option == window ? .semibold : .regular))
                    .foregroundStyle(option == window ? Color.primary : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule()
                            .fill(option == window ? Color.primary.opacity(0.09) : Color.clear)
                    }
                    .accessibilityLabel("Show the last \(option.accessibilityLabel)")
                    .accessibilityValue(option == window ? "Selected" : "Not selected")
                    .accessibilityAddTraits(option == window ? .isSelected : [])
            }
        }
    }

    @AxisContentBuilder
    private var timeAxis: some AxisContent {
        AxisMarks(values: timeAxisValues) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(Color.primary.opacity(0.08))
            AxisValueLabel(format: .dateTime.hour().minute())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.secondary)
        }
    }

    /// Degrees on the left, RPM on the right. Both axes label the same plotted
    /// scale; the trailing labels convert back through `plot(rpm:)`.
    @AxisContentBuilder
    private var dualAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(Color.primary.opacity(0.08))
            AxisValueLabel {
                if let degrees = value.as(Double.self) {
                    Text("\(Int(degrees))°")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(thermalOrange)
        }

        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
            AxisValueLabel {
                if let plotted = value.as(Double.self) {
                    Text(rpmAxisLabel(at: plotted))
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(coolingBlue)
        }
    }

    // MARK: - Scale mapping

    /// Places an RPM reading on the temperature scale that drives the plot, so
    /// both series can share one Y domain while keeping independent ranges.
    private func plot(rpm: Int) -> Double {
        let rpmSpan = rpmRange.upper - rpmRange.lower
        let temperatureSpan = temperatureDomain.upperBound - temperatureDomain.lowerBound
        guard rpmSpan > 0, temperatureSpan > 0 else { return temperatureDomain.lowerBound }
        let fraction = (Double(rpm) - rpmRange.lower) / rpmSpan
        return temperatureDomain.lowerBound + fraction * temperatureSpan
    }

    private func rpmAxisLabel(at plotted: Double) -> String {
        let temperatureSpan = temperatureDomain.upperBound - temperatureDomain.lowerBound
        guard temperatureSpan > 0 else { return "" }
        let fraction = (plotted - temperatureDomain.lowerBound) / temperatureSpan
        let rpm = rpmRange.lower + fraction * (rpmRange.upper - rpmRange.lower)
        guard rpm >= 0 else { return "" }
        return rpm >= 1_000
            ? String(format: "%.1fk", rpm / 1_000)
            : String(Int(rpm))
    }

    private var rpmRange: (lower: Double, upper: Double) {
        let ceiling = Double(
            availableFans.indices.contains(fanOffset)
                ? availableFans[fanOffset].maximumRPM
                : 6_000
        )
        let readings = datedSamples.flatMap { point in
            [fanActualValue(in: point), fanTargetValue(in: point)].compactMap { $0 }
        }
        guard let lowest = readings.min(), let highest = readings.max() else {
            return (0, ceiling)
        }
        let lower = max(Double(lowest) - 300, 0)
        let upper = max(ceiling, Double(highest) + 200)
        return (lower, max(upper, lower + 500))
    }

    // MARK: - Data

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
        return "Fan \(availableFans[fanOffset].index + 1)"
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

    /// Within 20° of the limit the chart pulls the limit line into view; below
    /// that it stays zoomed on the readings, where the detail actually is.
    private var showsSafetyLimit: Bool {
        guard let limit = temperatureSafetyLimit,
              let peak = temperatureValues?.max() else { return false }
        return peak >= limit - 20
    }

    private var temperatureDomain: ClosedRange<Double> {
        let values = temperatureValues ?? []
        let lower = max(0, (values.min() ?? 20) - 8)
        let observedUpper = (values.max() ?? 80) + 5
        let upper = showsSafetyLimit
            ? max(observedUpper, (temperatureSafetyLimit ?? observedUpper) + 3)
            : observedUpper
        return lower...max(lower + 10, upper)
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

    private var chartAccessibilityValue: String {
        guard let latest = datedSamples.last else { return "No samples" }
        let temperature = temperatureValue(in: latest)
            .map { String(format: "%.1f degrees Celsius", $0) } ?? "no temperature"
        let fan = fanActualValue(in: latest).map { "\($0) RPM" } ?? "no fan reading"
        return "Latest \(temperature), \(fan)"
    }
}

private struct DatedTelemetrySample: Identifiable {
    let sample: TelemetrySample
    let date: Date

    var id: UInt64 { sample.id }
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
