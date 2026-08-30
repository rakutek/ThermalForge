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
                try SensorDescriptor(key: "TC0P", family: .cpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "TG0P", family: .gpu, safetyLimitCelsius: 95),
                try SensorDescriptor(key: "TH0A", family: .storage, safetyLimitCelsius: 80),
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
                let storage = 43 + sin(elapsed / 41 + 0.5) * 2
                let target0 = Int(2_700 + max(cpu - 65, 0) * 115)
                let target1 = Int(2_500 + max(cpu - 65, 0) * 100)
                let age = UInt64(max(remaining, 0) * 1_000_000_000)
                return TelemetrySample(
                    sampledAtUptimeNanoseconds: now >= age ? now - age : 0,
                    mode: .smart,
                    peakTemperatures: [.cpu: cpu, .gpu: gpu, .storage: storage],
                    fanActualRPMs: [target0 - 90, target1 - 70],
                    fanTargetRPMs: [target0, target1],
                    faultCode: nil
                )
            }

            guard let latest = telemetry.last else { return nil }
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
                temperatures: [
                    "TC0P": latest.peakTemperatures[.cpu] ?? 0,
                    "TG0P": latest.peakTemperatures[.gpu] ?? 0,
                    "TH0A": latest.peakTemperatures[.storage] ?? 0,
                ]
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
