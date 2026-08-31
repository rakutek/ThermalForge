import Charts
import SwiftUI
import KazeDomain

/// Temperature and fan speed share one plot: the whole point of the app is that
/// one causes the other, and a metric toggle hid exactly that relationship.
/// The two series keep their own scales — orange on the leading axis, blue on
/// the trailing one — so each stays readable at its own magnitude.
/// The fans are averaged into a single line: on these machines they track each
/// other closely, so a per-fan picker asked for a choice that changed nothing.
///
/// Everything the plot draws is derived once per telemetry update into
/// `PlotModel`. Deriving it inside the marks instead meant every mark rescanned
/// the whole sample buffer to find its own scale, and the pointer republished a
/// selection on each mouse move — so tracking the cursor cost a few hundred
/// full-buffer scans per frame.
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
    @State private var selectedSampleID: UInt64?
    @State private var plot = PlotModel()

    private let thermalOrange = Color(red: 0.976, green: 0.451, blue: 0.086)
    private let coolingBlue = Color(red: 0.220, green: 0.741, blue: 0.973)
    private let safetyRed = Color(red: 0.937, green: 0.267, blue: 0.267)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            controls
            readout

            Group {
                if plot.points.isEmpty {
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
        .onAppear { rebuildPlot() }
        .onChange(of: plotInputs) { _, _ in rebuildPlot() }
        .onChange(of: sensorFamily) { _, _ in selectedSampleID = nil }
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

    /// The temperature series still picks a sensor family; the fan series has
    /// nothing left to choose, so it reads as a plain legend in the same shape.
    /// Both carry their series colour, which is the only thing tying a line to
    /// its axis and to its number in the readout.
    private var controls: some View {
        HStack(spacing: 6) {
            seriesButton(
                title: sensorFamily.displayName,
                systemImage: "thermometer.medium",
                color: thermalOrange,
                popover: .telemetrySensor
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(plot.sensorFamilies, id: \.self) { family in
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

            seriesCapsule(
                title: fanSeriesLabel,
                systemImage: "fan.fill",
                color: coolingBlue,
                showsChevron: false
            )
            .accessibilityElement()
            .accessibilityLabel("Fan series")
            .accessibilityValue(fanSeriesLabel)
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
            seriesCapsule(
                title: title,
                systemImage: systemImage,
                color: color,
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: presentationState.binding(for: popover), arrowEdge: .leading) {
            content()
        }
    }

    private func seriesCapsule(
        title: String,
        systemImage: String,
        color: Color,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 2)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
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
        let point = selectedPoint ?? plot.points.last
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(point?.temperature.map { String(format: "%.1f°C", $0) } ?? "—°C")
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(thermalOrange)

            Text(point?.fanActual.map { "\($0) rpm" } ?? "— rpm")
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(coolingBlue)

            if let target = point?.fanTarget {
                HStack(spacing: 4) {
                    dashedSwatch(coolingBlue)
                    Text("Target \(target)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if let point = selectedPoint {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(point.date, format: .dateTime.hour().minute().second())
                    Text(point.modeLabel)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(point.hasFault ? safetyRed : Color.secondary)
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
            if let limit = plot.visibleSafetyLimit {
                RuleMark(y: .value("Safety limit", limit))
                    .foregroundStyle(safetyRed.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .bottom, alignment: .leading, spacing: 2) {
                        Text("LIMIT \(Int(limit))°")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(safetyRed)
                    }
            }

            ForEach(plot.fanTargetSeries) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Fan target", point.value),
                    series: .value("Series", "Fan target")
                )
                .foregroundStyle(coolingBlue.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
                .interpolationMethod(.stepCenter)
            }

            ForEach(plot.fanActualSeries) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Fan", point.value),
                    series: .value("Series", "Fan")
                )
                .foregroundStyle(coolingBlue)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }

            ForEach(plot.temperatureSeries) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Temperature", point.value),
                    series: .value("Series", "Temperature")
                )
                .foregroundStyle(thermalOrange)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }

            if let latest = plot.fanActualSeries.last {
                PointMark(
                    x: .value("Latest time", latest.date),
                    y: .value("Latest fan", latest.value)
                )
                .foregroundStyle(coolingBlue)
                .symbolSize(24)
            }

            if let latest = plot.temperatureSeries.last {
                PointMark(
                    x: .value("Latest time", latest.date),
                    y: .value("Latest temperature", latest.value)
                )
                .foregroundStyle(thermalOrange)
                .symbolSize(24)
            }

            selectionRule
        }
        .chartXScale(domain: plot.timeDomain)
        .chartYScale(domain: plot.temperatureDomain)
        .chartXAxis { timeAxis }
        .chartYAxis { dualAxis }
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color.primary.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .chartXSelection(value: snappedSelection)
        .accessibilityLabel("\(sensorFamily.displayName) temperature and \(fanSeriesLabel.lowercased()) speed history")
        .accessibilityValue(chartAccessibilityValue)
    }

    /// `chartXSelection` publishes a new date on every pointer move, and each
    /// one rebuilds the chart. Snapping to the sample under the cursor means
    /// state only changes when the reading changes — a few times per sweep
    /// instead of every frame — and the marker lands on the point whose numbers
    /// the readout is showing.
    private var snappedSelection: Binding<Date?> {
        Binding(
            get: { selectedPoint?.date },
            set: { proposed in
                let id = proposed.flatMap { nearestPoint(to: $0)?.id }
                if id != selectedSampleID { selectedSampleID = id }
            }
        )
    }

    @ChartContentBuilder
    private var selectionRule: some ChartContent {
        if let point = selectedPoint {
            RuleMark(x: .value("Selected time", point.date))
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
        AxisMarks(values: plot.timeAxisValues) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(Color.primary.opacity(0.08))
            AxisValueLabel(format: .dateTime.hour().minute())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.secondary)
        }
    }

    /// Degrees on the left, RPM on the right. Both axes label the same plotted
    /// scale; the trailing labels convert back through `PlotModel.plot(rpm:)`.
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
                    Text(plot.rpmAxisLabel(at: plotted))
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(coolingBlue)
        }
    }

    // MARK: - Model

    /// The inputs that change what the plot looks like. Sample identity stands
    /// in for the buffer's contents: the helper only ever appends, so a new
    /// newest sample or a different count means new data.
    private struct PlotInputs: Equatable {
        let latestSampleID: UInt64?
        let sampleCount: Int
        let family: SensorFamily
        let sensorCount: Int
        let fanCount: Int
    }

    private var plotInputs: PlotInputs {
        PlotInputs(
            latestSampleID: samples.last?.id,
            sampleCount: samples.count,
            family: sensorFamily,
            sensorCount: inventory?.sensors.count ?? 0,
            fanCount: inventory?.fans.count ?? 0
        )
    }

    private func rebuildPlot() {
        let families = availableSensorFamilies
        guard families.contains(sensorFamily) else {
            // Writing the family re-triggers this through `plotInputs`.
            if let first = families.first { sensorFamily = first }
            return
        }
        plot = PlotModel(
            samples: samples,
            inventory: inventory,
            family: sensorFamily,
            families: families
        )
        if let selectedSampleID, !plot.points.contains(where: { $0.id == selectedSampleID }) {
            self.selectedSampleID = nil
        }
    }

    private var availableSensorFamilies: [SensorFamily] {
        let available = Set(inventory?.sensors.map(\.family) ?? samples.flatMap { $0.peakTemperatures.keys })
        let ordered: [SensorFamily] = [.cpu, .gpu, .memory, .storage, .power, .battery, .ambient, .other]
        let result = ordered.filter(available.contains)
        return result.isEmpty ? [.cpu] : result
    }

    private var fanSeriesLabel: String {
        plot.fanCount > 1 ? "Fans (avg)" : "Fan"
    }

    private var selectedPoint: PlotModel.Point? {
        guard let selectedSampleID else { return nil }
        return plot.points.first { $0.id == selectedSampleID }
    }

    private func nearestPoint(to date: Date) -> PlotModel.Point? {
        plot.points.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    private var chartAccessibilityValue: String {
        guard let latest = plot.points.last else { return "No samples" }
        let temperature = latest.temperature
            .map { String(format: "%.1f degrees Celsius", $0) } ?? "no temperature"
        let fan = latest.fanActual.map { "\($0) RPM" } ?? "no fan reading"
        return "Latest \(temperature), \(fan)"
    }
}

/// Every value the chart plots, resolved once per telemetry update: the marks
/// only read from here, so a pointer move costs a redraw rather than a pass
/// over the sample buffer for each of the hundreds of marks on screen.
private struct PlotModel {
    struct Point: Identifiable {
        let id: UInt64
        let date: Date
        let temperature: Double?
        let fanActual: Int?
        let fanTarget: Int?
        let modeLabel: String
        let hasFault: Bool
    }

    struct SeriesPoint: Identifiable {
        let id: UInt64
        let date: Date
        let value: Double
    }

    private(set) var points: [Point] = []
    private(set) var temperatureSeries: [SeriesPoint] = []
    private(set) var fanActualSeries: [SeriesPoint] = []
    private(set) var fanTargetSeries: [SeriesPoint] = []
    private(set) var timeAxisValues: [Date] = []
    private(set) var sensorFamilies: [SensorFamily] = [.cpu]
    private(set) var fanCount = 0
    private(set) var temperatureDomain: ClosedRange<Double> = 20...80
    private(set) var visibleSafetyLimit: Double?
    private var rpmRange: (lower: Double, upper: Double) = (0, 6_000)
    private var timeBounds: (first: Date, last: Date)?

    init() {}

    init(
        samples: [TelemetrySample],
        inventory: HardwareInventory?,
        family: SensorFamily,
        families: [SensorFamily]
    ) {
        sensorFamilies = families
        fanCount = max(inventory?.fans.count ?? 0, samples.last?.fanActualRPMs.count ?? 0)

        // One clock reading for the whole buffer. Sampling it per body pass slid
        // every point sideways on each redraw, which forced the chart to lay the
        // series out again even when no new telemetry had arrived.
        let nowUptime = DispatchTime.now().uptimeNanoseconds
        let nowWall = Date()
        points = samples.map { sample in
            let age = nowUptime >= sample.sampledAtUptimeNanoseconds
                ? Double(nowUptime - sample.sampledAtUptimeNanoseconds) / 1_000_000_000
                : 0
            return Point(
                id: sample.id,
                date: nowWall.addingTimeInterval(-age),
                temperature: sample.peakTemperatures[family],
                fanActual: Self.average(sample.fanActualRPMs),
                fanTarget: Self.average(sample.fanTargetRPMs),
                modeLabel: sample.mode.displayName,
                hasFault: sample.faultCode != nil
            )
        }
        guard !points.isEmpty else { return }

        let safetyLimit = inventory?.sensors
            .filter { $0.family == family }
            .map(\.safetyLimitCelsius)
            .min()
        let temperatures = points.compactMap(\.temperature)

        // Within 20° of the limit the chart pulls the limit line into view;
        // below that it stays zoomed on the readings, where the detail is.
        if let safetyLimit, let peak = temperatures.max(), peak >= safetyLimit - 20 {
            visibleSafetyLimit = safetyLimit
        }

        let lower = max(0, (temperatures.min() ?? 20) - 8)
        let observedUpper = (temperatures.max() ?? 80) + 5
        let upper = visibleSafetyLimit.map { max(observedUpper, $0 + 3) } ?? observedUpper
        temperatureDomain = lower...max(lower + 10, upper)

        rpmRange = Self.rpmRange(for: points, inventory: inventory)

        temperatureSeries = points.compactMap { point in
            point.temperature.map { SeriesPoint(id: point.id, date: point.date, value: $0) }
        }
        fanActualSeries = points.compactMap { point in
            point.fanActual.map { SeriesPoint(id: point.id, date: point.date, value: plot(rpm: $0)) }
        }
        fanTargetSeries = points.compactMap { point in
            point.fanTarget.map { SeriesPoint(id: point.id, date: point.date, value: plot(rpm: $0)) }
        }

        if let first = points.first?.date, let last = points.last?.date {
            timeBounds = (first, last)
            let span = last.timeIntervalSince(first)
            timeAxisValues = [0.2, 0.5, 0.8].map { first.addingTimeInterval(span * $0) }
        }
    }

    var timeDomain: ClosedRange<Date> {
        guard let timeBounds else {
            let now = Date()
            return now.addingTimeInterval(-60)...now
        }
        let span = max(timeBounds.last.timeIntervalSince(timeBounds.first), 10)
        let padding = span * 0.025
        return timeBounds.first.addingTimeInterval(-padding)...timeBounds.last.addingTimeInterval(padding)
    }

    /// Places an RPM reading on the temperature scale that drives the plot, so
    /// both series can share one Y domain while keeping independent ranges.
    func plot(rpm: Int) -> Double {
        let rpmSpan = rpmRange.upper - rpmRange.lower
        let temperatureSpan = temperatureDomain.upperBound - temperatureDomain.lowerBound
        guard rpmSpan > 0, temperatureSpan > 0 else { return temperatureDomain.lowerBound }
        let fraction = (Double(rpm) - rpmRange.lower) / rpmSpan
        return temperatureDomain.lowerBound + fraction * temperatureSpan
    }

    func rpmAxisLabel(at plotted: Double) -> String {
        let temperatureSpan = temperatureDomain.upperBound - temperatureDomain.lowerBound
        guard temperatureSpan > 0 else { return "" }
        let fraction = (plotted - temperatureDomain.lowerBound) / temperatureSpan
        let rpm = rpmRange.lower + fraction * (rpmRange.upper - rpmRange.lower)
        guard rpm >= 0 else { return "" }
        return rpm >= 1_000
            ? String(format: "%.1fk", rpm / 1_000)
            : String(Int(rpm))
    }

    private static func rpmRange(
        for points: [Point],
        inventory: HardwareInventory?
    ) -> (lower: Double, upper: Double) {
        let ceiling = average(inventory?.fans.map(\.maximumRPM) ?? []).map(Double.init) ?? 6_000
        let readings = points.flatMap { [$0.fanActual, $0.fanTarget].compactMap { $0 } }
        guard let lowest = readings.min(), let highest = readings.max() else {
            return (0, ceiling)
        }
        let lower = max(Double(lowest) - 300, 0)
        let upper = max(ceiling, Double(highest) + 200)
        return (lower, max(upper, lower + 500))
    }

    /// The fans are reported as one line, so every reading here is their mean.
    private static func average(_ readings: [Int]) -> Int? {
        guard !readings.isEmpty else { return nil }
        return Int((Double(readings.reduce(0, +)) / Double(readings.count)).rounded())
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
