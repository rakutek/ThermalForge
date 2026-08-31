#if DEBUG
import Foundation
import KazeDomain

enum KazePreviewData {
    static func make(window: TelemetryWindow) -> (
        status: ControllerStatus,
        telemetry: [TelemetrySample]
    )? {
        do {
            let fans = [
                try FanLimits(index: 0, minimumRPM: 1_200, maximumRPM: 6_000),
                try FanLimits(index: 1, minimumRPM: 1_400, maximumRPM: 5_500),
            ]
            let sensors = [
                try SensorDescriptor(key: "TCDX", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "TCHP", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "TCMb", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tp01", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tp02", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tp03", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tp04", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tp05", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tp06", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tp07", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tp08", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tp09", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tp0A", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tg05", family: .gpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tg0D", family: .gpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tg0L", family: .gpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tg0T", family: .gpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tg0f", family: .gpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tg0j", family: .gpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "Tm02", family: .memory, safetyLimitCelsius: 90),
                try SensorDescriptor(key: "Tm06", family: .memory, safetyLimitCelsius: 90),
                try SensorDescriptor(key: "TH0A", family: .storage, safetyLimitCelsius: 80),
                try SensorDescriptor(key: "TPDX", family: .power, safetyLimitCelsius: 90),
                try SensorDescriptor(key: "TB0T", family: .battery, safetyLimitCelsius: 60),
                try SensorDescriptor(key: "TAOL", family: .ambient, safetyLimitCelsius: 100, required: false),
                try SensorDescriptor(key: "TA0P", family: .ambient, safetyLimitCelsius: 100, required: false),
            ]
            let inventory = try HardwareInventory(fans: fans, sensors: sensors)
            let pointCount = min(max(Int(window.rawValue / 2) + 1, 2), 180)
            let step = window.rawValue / Double(pointCount - 1)
            let now = DispatchTime.now().uptimeNanoseconds

            let telemetry = (0..<pointCount).map { index in
                let elapsed = Double(index) * step
                let remaining = window.rawValue - elapsed
                let cpu = 66 + sin(elapsed / 23) * 7 + sin(elapsed / 7) * 2
                let gpu = 59 + sin(elapsed / 29 + 1.2) * 5
                let memory = 51 + sin(elapsed / 33 + 0.9) * 3
                let storage = 43 + sin(elapsed / 41 + 0.5) * 2
                let power = 47 + sin(elapsed / 37 + 0.3) * 3
                let battery = 35 + sin(elapsed / 53 + 0.7)
                let ambient = 29 + sin(elapsed / 61 + 0.4)
                let target0 = Int(2_700 + max(cpu - 65, 0) * 115)
                let target1 = Int(2_500 + max(cpu - 65, 0) * 100)
                let age = UInt64(max(remaining, 0) * 1_000_000_000)
                return TelemetrySample(
                    sampledAtUptimeNanoseconds: now >= age ? now - age : 0,
                    mode: .smart,
                    peakTemperatures: [
                        .cpu: cpu,
                        .gpu: gpu,
                        .memory: memory,
                        .storage: storage,
                        .power: power,
                        .battery: battery,
                        .ambient: ambient,
                    ],
                    fanActualRPMs: [target0 - 90, target1 - 70],
                    fanTargetRPMs: [target0, target1],
                    faultCode: nil
                )
            }

            guard let latest = telemetry.last else { return nil }
            let temperatures: [String: Double] = Dictionary(uniqueKeysWithValues: sensors.compactMap {
                sensor -> (String, Double)? in
                let familyOffset = sensors
                    .filter { $0.family == sensor.family }
                    .firstIndex { $0.key == sensor.key } ?? 0
                guard let peak = latest.peakTemperatures[sensor.family] else { return nil }
                return (sensor.key, peak - Double(familyOffset % 3) * 0.8)
            })
            let sample = try HardwareSample(
                fans: [
                    FanReading(
                        index: 0,
                        actualRPM: latest.fanActualRPMs[0],
                        targetRPM: latest.fanTargetRPMs[0],
                        mode: .manual
                    ),
                    FanReading(
                        index: 1,
                        actualRPM: latest.fanActualRPMs[1],
                        targetRPM: latest.fanTargetRPMs[1],
                        mode: .manual
                    ),
                ],
                temperatures: temperatures
            )
            let status = ControllerStatus(
                mode: .smart,
                intent: .profile(.smart),
                leaseID: UUID(),
                leaseExpiresAtUptimeNanoseconds: now + 20_000_000_000,
                inventory: inventory,
                latestSample: sample,
                fault: nil
            )
            return (status, telemetry)
        } catch {
            return nil
        }
    }
}
#endif
