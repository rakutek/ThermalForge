import Darwin
import Foundation
import KazeHardware

@main
enum KazeRecovery {
    static func main() {
        do {
            guard geteuid() == 0 else {
                throw RecoveryError.usage("Run with sudo: kaze-recovery auto|max")
            }
            guard CommandLine.arguments.count == 2 else {
                throw RecoveryError.usage("Usage: kaze-recovery auto|max")
            }

            let hardware = try SMCFanHardware()
            switch CommandLine.arguments[1] {
            case "auto":
                do {
                    let fanCount = try verifiedAutomatic(hardware)
                    print("Verified Apple automatic mode on \(fanCount) fan(s).")
                } catch let automaticError {
                    do {
                        let fanCount = try verifiedMaximum(hardware)
                        FileHandle.standardError.write(Data(
                            "Automatic recovery failed (\(automaticError)); verified maximum cooling on \(fanCount) fan(s).\n".utf8
                        ))
                        Darwin.exit(2)
                    } catch let maximumError {
                        throw RecoveryError.verification(
                            "automatic recovery failed (\(automaticError)); maximum fallback failed (\(maximumError))"
                        )
                    }
                }
            case "max":
                do {
                    let fanCount = try verifiedMaximum(hardware)
                    print("Verified maximum cooling on \(fanCount) fan(s).")
                } catch let maximumError {
                    do {
                        _ = try verifiedAutomatic(hardware)
                    } catch let automaticError {
                        throw RecoveryError.verification(
                            "maximum cooling failed (\(maximumError)); automatic fallback failed (\(automaticError))"
                        )
                    }
                    throw RecoveryError.verification(
                        "maximum cooling failed (\(maximumError)); Apple automatic mode was restored"
                    )
                }
            default:
                throw RecoveryError.usage("Usage: kaze-recovery auto|max")
            }
        } catch {
            FileHandle.standardError.write(Data("kaze-recovery: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func verifiedAutomatic(_ hardware: SMCFanHardware) throws -> Int {
        let sample = try hardware.restoreAutomatic()
        guard sample.fans.allSatisfy({ $0.mode.isAutomatic }) else {
            throw RecoveryError.verification("one or more fans remain manual")
        }
        return sample.fans.count
    }

    private static func verifiedMaximum(_ hardware: SMCFanHardware) throws -> Int {
        let sample = try hardware.applyMaximum()
        guard sample.fans.allSatisfy({ $0.mode == .manual }) else {
            throw RecoveryError.verification("maximum cooling did not verify")
        }
        return sample.fans.count
    }
}

private enum RecoveryError: Error, CustomStringConvertible {
    case usage(String)
    case verification(String)

    var description: String {
        switch self {
        case .usage(let message), .verification(let message): message
        }
    }
}
