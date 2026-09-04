import Foundation

public enum CurveShape: String, Codable, Sendable {
    case linear
    case easeIn
    case sCurve
}

public struct ProfileCurve: Codable, Sendable, Equatable {
    public let stopTemperature: Double
    public let startTemperature: Double
    public let ceilingTemperature: Double
    public let maximumFraction: Double
    public let shape: CurveShape
    public let sustainedSeconds: Double
    public let rampUpRPMPerSecond: Double
    public let rampDownRPMPerSecond: Double

    public init(
        stopTemperature: Double,
        startTemperature: Double,
        ceilingTemperature: Double,
        maximumFraction: Double,
        shape: CurveShape,
        sustainedSeconds: Double,
        rampUpRPMPerSecond: Double,
        rampDownRPMPerSecond: Double
    ) throws {
        let values = [
            stopTemperature, startTemperature, ceilingTemperature, maximumFraction,
            sustainedSeconds, rampUpRPMPerSecond, rampDownRPMPerSecond,
        ]
        guard values.allSatisfy(\.isFinite),
              stopTemperature >= 20,
              startTemperature >= stopTemperature + 2,
              ceilingTemperature > startTemperature,
              ceilingTemperature <= 95,
              (0...1).contains(maximumFraction),
              sustainedSeconds >= 0,
              rampUpRPMPerSecond > 0,
              rampDownRPMPerSecond > 0
        else { throw DomainError.invalidTemperature(startTemperature) }

        self.stopTemperature = stopTemperature
        self.startTemperature = startTemperature
        self.ceilingTemperature = ceilingTemperature
        self.maximumFraction = maximumFraction
        self.shape = shape
        self.sustainedSeconds = sustainedSeconds
        self.rampUpRPMPerSecond = rampUpRPMPerSecond
        self.rampDownRPMPerSecond = rampDownRPMPerSecond
    }

    public func fraction(at temperature: Double) -> Double {
        guard temperature >= startTemperature else { return 0 }
        guard temperature < ceilingTemperature else { return maximumFraction }
        let position = min(max((temperature - startTemperature) / (ceilingTemperature - startTemperature), 0), 1)
        let shaped: Double
        switch shape {
        case .linear: shaped = position
        case .easeIn: shaped = position * position
        case .sCurve: shaped = position * position * (3 - 2 * position)
        }
        return min(max(shaped * maximumFraction, 0), maximumFraction)
    }
}

public extension ProfileID {
    var curve: ProfileCurve {
        get throws {
            switch self {
            case .performance:
                return try ProfileCurve(
                    stopTemperature: 48,
                    startTemperature: 52,
                    ceilingTemperature: 68,
                    maximumFraction: 0.90,
                    shape: .linear,
                    sustainedSeconds: 1,
                    rampUpRPMPerSecond: 500,
                    rampDownRPMPerSecond: 180
                )
            case .smart:
                return try ProfileCurve(
                    stopTemperature: 48,
                    startTemperature: 52,
                    ceilingTemperature: 85,
                    maximumFraction: 0.80,
                    shape: .sCurve,
                    sustainedSeconds: 2,
                    rampUpRPMPerSecond: 50,
                    rampDownRPMPerSecond: 50
                )
            }
        }
    }

    var controllerMode: ControllerMode {
        switch self {
        case .performance: .performance
        case .smart: .smart
        }
    }
}
