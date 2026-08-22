import Foundation
import Security

public enum CodeSigningPolicyError: Error, Sendable, CustomStringConvertible {
    case identityUnavailable(OSStatus)
    case unsignedProductionBuild

    public var description: String {
        switch self {
        case .identityUnavailable(let status): return "code identity unavailable: \(status)"
        case .unsignedProductionBuild: return "production IPC requires a Developer ID-signed build"
        }
    }
}

public enum DevelopmentMode {
    public static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["KAZE_DEVELOPMENT"] == "1" { return true }
        return Bundle.main.url(forResource: "development-build", withExtension: nil) != nil
    }
}

public enum CodeSigningPolicy {
    public static func helperRequirement(developmentMode: Bool = DevelopmentMode.isEnabled) throws -> String {
        try requirement(identifiers: [IPCConstants.helperIdentifier], developmentMode: developmentMode)
    }

    public static func authorizedClientRequirement(developmentMode: Bool = DevelopmentMode.isEnabled) throws -> String {
        try requirement(
            identifiers: [IPCConstants.appIdentifier, IPCConstants.cliIdentifier],
            developmentMode: developmentMode
        )
    }

    public static func currentTeamIdentifier() throws -> String? {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { throw CodeSigningPolicyError.identityUnavailable(status) }

        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw CodeSigningPolicyError.identityUnavailable(status)
        }

        var information: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard status == errSecSuccess, let dictionary = information as? [String: Any] else {
            throw CodeSigningPolicyError.identityUnavailable(status)
        }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func requirement(identifiers: [String], developmentMode: Bool) throws -> String {
        let identifierClause = identifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")

        if let team = try currentTeamIdentifier(), !team.isEmpty {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(identifierClause))"
        }
        guard developmentMode else { throw CodeSigningPolicyError.unsignedProductionBuild }

        // Explicitly development-only. Identifier-only requirements are spoofable
        // by another ad-hoc binary and must never be enabled in a release bundle.
        return "(\(identifierClause))"
    }
}
