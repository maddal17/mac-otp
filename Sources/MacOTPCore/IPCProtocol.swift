import Foundation

public enum IPCCommand: String, Codable, Sendable {
    case ping
    case status
    case listAccounts = "list_accounts"
    case getCode = "get_code"
}

public struct IPCRequest: Codable, Sendable {
    public var id: UUID
    public var command: IPCCommand
    public var query: String?
    public var waitForFreshWindow: Bool?

    public init(
        id: UUID = UUID(),
        command: IPCCommand,
        query: String? = nil,
        waitForFreshWindow: Bool? = nil
    ) {
        self.id = id
        self.command = command
        self.query = query
        self.waitForFreshWindow = waitForFreshWindow
    }
}

public struct IPCDaemonStatus: Codable, Equatable, Sendable {
    public var running: Bool
    public var unlocked: Bool
    public var remainingUnlockSeconds: Int
    public var accountCount: Int
    public var mcpAuthPolicy: MCPAuthPolicy
    public var allowMCPListWhenLocked: Bool

    public init(
        running: Bool,
        unlocked: Bool,
        remainingUnlockSeconds: Int,
        accountCount: Int,
        mcpAuthPolicy: MCPAuthPolicy,
        allowMCPListWhenLocked: Bool
    ) {
        self.running = running
        self.unlocked = unlocked
        self.remainingUnlockSeconds = remainingUnlockSeconds
        self.accountCount = accountCount
        self.mcpAuthPolicy = mcpAuthPolicy
        self.allowMCPListWhenLocked = allowMCPListWhenLocked
    }
}

public struct IPCCodeResult: Codable, Equatable, Sendable {
    public var account: OTPAccountMetadata
    public var generated: GeneratedOTPCode

    public init(account: OTPAccountMetadata, generated: GeneratedOTPCode) {
        self.account = account
        self.generated = generated
    }
}

public struct IPCResponse: Codable, Sendable {
    public var id: UUID
    public var ok: Bool
    public var errorMessage: String?
    public var status: IPCDaemonStatus?
    public var accounts: [OTPAccountMetadata]?
    public var codeResult: IPCCodeResult?

    public init(
        id: UUID,
        ok: Bool,
        errorMessage: String? = nil,
        status: IPCDaemonStatus? = nil,
        accounts: [OTPAccountMetadata]? = nil,
        codeResult: IPCCodeResult? = nil
    ) {
        self.id = id
        self.ok = ok
        self.errorMessage = errorMessage
        self.status = status
        self.accounts = accounts
        self.codeResult = codeResult
    }
}
