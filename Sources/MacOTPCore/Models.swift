import Foundation

public enum OTPAlgorithm: String, Codable, CaseIterable, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

/// Non-sensitive metadata stored alongside encrypted secrets so the UI and discovery endpoints
/// can list and filter accounts without exposing or decrypting secret material.
public struct OTPAccountMetadata: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var issuer: String
    public var accountName: String
    public var digits: Int
    public var period: Int
    public var algorithm: OTPAlgorithm
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        issuer: String,
        accountName: String,
        digits: Int = 6,
        period: Int = 30,
        algorithm: OTPAlgorithm = .sha1,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.issuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
        self.createdAt = createdAt
    }

    public var displayTitle: String {
        if !issuer.isEmpty && !accountName.isEmpty {
            return "\(issuer) (\(accountName))"
        } else if !issuer.isEmpty {
            return issuer
        } else if !accountName.isEmpty {
            return accountName
        }
        return "Account \(id.uuidString.prefix(6))"
    }

    public var primaryLabel: String {
        !issuer.isEmpty ? issuer : (!accountName.isEmpty ? accountName : "Unknown Service")
    }

    public var secondaryLabel: String {
        !issuer.isEmpty ? accountName : ""
    }
}

/// Complete input payload used only transiently during import/creation or encrypted backup export.
public struct OTPAccountDraft: Codable, Equatable, Sendable {
    public var issuer: String
    public var accountName: String
    public var secretBase32: String
    public var digits: Int
    public var period: Int
    public var algorithm: OTPAlgorithm

    public init(
        issuer: String,
        accountName: String,
        secretBase32: String,
        digits: Int = 6,
        period: Int = 30,
        algorithm: OTPAlgorithm = .sha1
    ) {
        self.issuer = issuer
        self.accountName = accountName
        self.secretBase32 = secretBase32
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }
}

public struct GeneratedOTPCode: Codable, Equatable, Sendable {
    public let accountId: UUID
    public let code: String
    public let period: Int
    public let remainingSeconds: Int
    public let issuedAt: Date

    public init(
        accountId: UUID,
        code: String,
        period: Int,
        remainingSeconds: Int,
        issuedAt: Date = Date()
    ) {
        self.accountId = accountId
        self.code = code
        self.period = period
        self.remainingSeconds = remainingSeconds
        self.issuedAt = issuedAt
    }

    public var formattedCode: String {
        guard code.count >= 6 else { return code }
        let mid = code.count / 2
        let left = code.prefix(mid)
        let right = code.suffix(code.count - mid)
        return "\(left) \(right)"
    }
}

public enum MCPAuthPolicy: String, Codable, CaseIterable, Sendable {
    /// Every MCP code generation call prompts Touch ID / PIN explicitly with the requested service name.
    case alwaysAskPerRequest = "always_ask"
    /// Reuses an active unlocked grace period if currently unlocked; otherwise prompts Touch ID / PIN.
    case reuseActiveSession = "reuse_session"
}

public struct SecuritySettings: Codable, Equatable, Sendable {
    /// Grace period in seconds for UI unlock (0 = lock immediately / per action).
    public var uiSessionTTLSeconds: Int
    /// Authorization policy for incoming MCP requests.
    public var mcpAuthPolicy: MCPAuthPolicy
    /// Whether `list_2fa_accounts` via MCP can return account labels while vault is locked.
    public var allowMCPListWhenLocked: Bool
    /// Minimum remaining validity seconds for MCP codes; if fewer seconds remain, waits for next window.
    public var mcpMinRemainingSeconds: Int
    /// Maximum MCP code requests allowed per 60-second sliding window.
    public var mcpMaxRequestsPerMinute: Int
    /// Automatically revoke unlocked session on macOS sleep or screen lock.
    public var autoLockOnSleepOrScreenLock: Bool
    /// Automatically clear copied OTP code from clipboard after 30 seconds.
    public var autoClearClipboard: Bool

    public init(
        uiSessionTTLSeconds: Int = 300,
        mcpAuthPolicy: MCPAuthPolicy = .alwaysAskPerRequest,
        allowMCPListWhenLocked: Bool = true,
        mcpMinRemainingSeconds: Int = 4,
        mcpMaxRequestsPerMinute: Int = 6,
        autoLockOnSleepOrScreenLock: Bool = true,
        autoClearClipboard: Bool = true
    ) {
        self.uiSessionTTLSeconds = uiSessionTTLSeconds
        self.mcpAuthPolicy = mcpAuthPolicy
        self.allowMCPListWhenLocked = allowMCPListWhenLocked
        self.mcpMinRemainingSeconds = mcpMinRemainingSeconds
        self.mcpMaxRequestsPerMinute = mcpMaxRequestsPerMinute
        self.autoLockOnSleepOrScreenLock = autoLockOnSleepOrScreenLock
        self.autoClearClipboard = autoClearClipboard
    }
}

public enum AuditChannel: String, Codable, Sendable {
    case ui = "UI"
    case mcp = "MCP"
    case system = "SYSTEM"
}

public enum AuditOutcome: String, Codable, Sendable {
    case granted = "GRANTED"
    case denied = "DENIED"
    case rateLimited = "RATE_LIMITED"
    case error = "ERROR"
    case info = "INFO"
}

public struct AuditEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var channel: AuditChannel
    public var action: String
    public var target: String
    public var outcome: AuditOutcome
    public var detail: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        channel: AuditChannel,
        action: String,
        target: String,
        outcome: AuditOutcome,
        detail: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.channel = channel
        self.action = action
        self.target = target
        self.outcome = outcome
        self.detail = detail
    }
}
