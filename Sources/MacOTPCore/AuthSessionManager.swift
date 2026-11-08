import Foundation

public struct AuthChallengeRequest: Sendable {
    public let channel: AuditChannel
    public let reason: String
    public let serviceLabel: String?

    public init(channel: AuditChannel, reason: String, serviceLabel: String? = nil) {
        self.channel = channel
        self.reason = reason
        self.serviceLabel = serviceLabel
    }
}

public enum AuthGateError: LocalizedError, Equatable, Sendable {
    case cancelledOrDenied
    case rateLimited(retryAfterSeconds: Int)
    case cooldownActive(retryAfterSeconds: Int)
    case lockedDiscoveryDisabled

    public var errorDescription: String? {
        switch self {
        case .cancelledOrDenied:
            return "Аутентификация отклонена или отменена пользователем."
        case .rateLimited(let retry):
            return "Превышен лимит запросов кодов через MCP. Повторите через \(retry) сек."
        case .cooldownActive(let retry):
            return "Временная блокировка MCP после нескольких отклонённых подтверждений (\(retry) сек.)."
        case .lockedDiscoveryDisabled:
            return "Список аккаунтов через MCP скрыт настройками безопасности, пока хранилище заблокировано."
        }
    }
}

public typealias UserPresenceVerifier = @Sendable (AuthChallengeRequest) async throws -> Bool

public actor AuthSessionManager {
    private let vault: VaultStore
    private let verifier: UserPresenceVerifier
    private let nowProvider: @Sendable () -> Date

    private var unlockedUntil: Date?
    private var mcpRequestTimestamps: [Date] = []
    private var consecutiveMCPDenials: Int = 0
    private var mcpCooldownUntil: Date?
    private var isPromptInFlight: Bool = false
    private var promptWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        vault: VaultStore,
        verifier: @escaping UserPresenceVerifier,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.vault = vault
        self.verifier = verifier
        self.nowProvider = nowProvider
    }

    // MARK: - Session State

    public func isUnlocked() -> Bool {
        guard let until = unlockedUntil else { return false }
        if nowProvider() < until {
            return true
        }
        unlockedUntil = nil
        return false
    }

    public func remainingUnlockSeconds() -> Int {
        guard let until = unlockedUntil else { return 0 }
        let diff = Int(ceil(until.timeIntervalSince(nowProvider())))
        if diff <= 0 {
            unlockedUntil = nil
            return 0
        }
        return diff
    }

    public func lockImmediately(reason: String = "Ручная или системная блокировка") async {
        let wasUnlocked = isUnlocked()
        unlockedUntil = nil
        if wasUnlocked {
            await vault.recordAudit(
                channel: .system,
                action: "lock",
                target: "Vault",
                outcome: .info,
                detail: reason
            )
        }
    }

    /// Unlocks the UI session via Touch ID / System Password / Quick PIN.
    public func unlockUISession(reason: String = "Разблокировать хранилище 2FA-кодов") async throws {
        if isUnlocked() { return }

        let settings = await vault.getSettings()
        let approved = try await runSerializedChallenge(
            AuthChallengeRequest(channel: .ui, reason: reason, serviceLabel: nil)
        )

        guard approved else {
            await vault.recordAudit(
                channel: .ui,
                action: "unlock",
                target: "Vault",
                outcome: .denied,
                detail: "Отменено пользователем"
            )
            throw AuthGateError.cancelledOrDenied
        }

        let ttl = max(5, settings.uiSessionTTLSeconds == 0 ? 15 : settings.uiSessionTTLSeconds)
        unlockedUntil = nowProvider().addingTimeInterval(TimeInterval(ttl))

        await vault.recordAudit(
            channel: .ui,
            action: "unlock",
            target: "Vault",
            outcome: .granted,
            detail: "TTL \(ttl) сек."
        )
    }

    /// Unlocks UI session directly using verified Quick PIN without invoking OS biometric sheet.
    public func unlockUISessionWithQuickPin(_ pin: String) async throws {
        do {
            try await vault.verifyQuickPin(pin)
        } catch {
            await vault.recordAudit(
                channel: .ui,
                action: "unlock_pin",
                target: "Vault",
                outcome: .denied,
                detail: error.localizedDescription
            )
            throw error
        }

        let settings = await vault.getSettings()
        let ttl = max(5, settings.uiSessionTTLSeconds == 0 ? 15 : settings.uiSessionTTLSeconds)
        unlockedUntil = nowProvider().addingTimeInterval(TimeInterval(ttl))

        await vault.recordAudit(
            channel: .ui,
            action: "unlock_pin",
            target: "Vault",
            outcome: .granted,
            detail: "Быстрый PIN (TTL \(ttl) сек.)"
        )
    }

    // MARK: - Authorized Operations for MCP

    public func mcpListAccounts(query: String?) async throws -> [OTPAccountMetadata] {
        let settings = await vault.getSettings()
        if !settings.allowMCPListWhenLocked && !isUnlocked() {
            let approved = try await runSerializedChallenge(
                AuthChallengeRequest(
                    channel: .mcp,
                    reason: "MCP запрашивает список доступных 2FA-сервисов",
                    serviceLabel: "Список аккаунтов"
                )
            )
            guard approved else {
                await vault.recordAudit(
                    channel: .mcp,
                    action: "list_accounts",
                    target: query ?? "*",
                    outcome: .denied
                )
                throw AuthGateError.cancelledOrDenied
            }
            if settings.uiSessionTTLSeconds > 0 {
                unlockedUntil = nowProvider().addingTimeInterval(TimeInterval(settings.uiSessionTTLSeconds))
            }
        }
        return await vault.listAccounts(query: query)
    }

    public func mcpGetCode(
        accountQuery: String,
        waitForFreshWindow: Bool = true
    ) async throws -> (OTPAccountMetadata, GeneratedOTPCode) {
        let now = nowProvider()
        let settings = await vault.getSettings()

        // 1. Check anti-fatigue denial cooldown
        if let cooldown = mcpCooldownUntil {
            if now < cooldown {
                let retry = max(1, Int(ceil(cooldown.timeIntervalSince(now))))
                await vault.recordAudit(
                    channel: .mcp,
                    action: "get_code",
                    target: accountQuery,
                    outcome: .rateLimited,
                    detail: "Активен cooldown (\(retry) сек.)"
                )
                throw AuthGateError.cooldownActive(retryAfterSeconds: retry)
            } else {
                mcpCooldownUntil = nil
                consecutiveMCPDenials = 0
            }
        }

        // 2. Check sliding-window rate limit (60s)
        mcpRequestTimestamps.removeAll { now.timeIntervalSince($0) >= 60.0 }
        let maxPerMin = max(1, settings.mcpMaxRequestsPerMinute)
        if mcpRequestTimestamps.count >= maxPerMin {
            let oldest = mcpRequestTimestamps[0]
            let retry = max(1, Int(ceil(60.0 - now.timeIntervalSince(oldest))))
            await vault.recordAudit(
                channel: .mcp,
                action: "get_code",
                target: accountQuery,
                outcome: .rateLimited,
                detail: "Лимит \(maxPerMin)/мин."
            )
            throw AuthGateError.rateLimited(retryAfterSeconds: retry)
        }

        // 3. Resolve account BEFORE prompting Touch ID so typos or ambiguous queries don't trigger unnecessary prompts
        let lookup = await vault.lookupAccount(accountQuery)
        let account: OTPAccountMetadata
        switch lookup {
        case .notFound:
            throw VaultStoreError.accountNotFound(accountQuery)
        case .ambiguous(let candidates):
            throw VaultStoreError.ambiguousAccount(candidates.map { "\($0.displayTitle) [id: \($0.id.uuidString)]" })
        case .matched(let found):
            account = found
        }

        mcpRequestTimestamps.append(now)

        // 4. Enforce MCP authorization policy
        let needsExplicitPrompt: Bool
        switch settings.mcpAuthPolicy {
        case .alwaysAskPerRequest:
            needsExplicitPrompt = true
        case .reuseActiveSession:
            needsExplicitPrompt = !isUnlocked()
        }

        if needsExplicitPrompt {
            let promptReason = "Выдать 2FA-код для «\(account.displayTitle)» (запрос через MCP)"
            let approved = try await runSerializedChallenge(
                AuthChallengeRequest(
                    channel: .mcp,
                    reason: promptReason,
                    serviceLabel: account.displayTitle
                )
            )
            guard approved else {
                consecutiveMCPDenials += 1
                if consecutiveMCPDenials >= 3 {
                    mcpCooldownUntil = nowProvider().addingTimeInterval(30)
                }
                await vault.recordAudit(
                    channel: .mcp,
                    action: "get_code",
                    target: account.displayTitle,
                    outcome: .denied,
                    detail: "Отклонено пользователем"
                )
                throw AuthGateError.cancelledOrDenied
            }

            consecutiveMCPDenials = 0
            if settings.mcpAuthPolicy == .reuseActiveSession && settings.uiSessionTTLSeconds > 0 {
                unlockedUntil = nowProvider().addingTimeInterval(TimeInterval(settings.uiSessionTTLSeconds))
            }
        }

        // 5. Smart freshness window: avoid returning codes with < N seconds left that expire mid-paste
        var issueDate = nowProvider()
        var generated = try await vault.generateCode(accountId: account.id, at: issueDate)
        let minRemaining = max(0, min(10, settings.mcpMinRemainingSeconds))

        if waitForFreshWindow && minRemaining > 0 && generated.remainingSeconds <= minRemaining {
            let sleepNanos = UInt64(generated.remainingSeconds) * 1_000_000_000 + 150_000_000
            try? await Task.sleep(nanoseconds: sleepNanos)
            issueDate = nowProvider()
            generated = try await vault.generateCode(accountId: account.id, at: issueDate)
        }

        await vault.recordAudit(
            channel: .mcp,
            action: "get_code",
            target: account.displayTitle,
            outcome: .granted,
            detail: "Выдан код (осталось \(generated.remainingSeconds) сек.)"
        )

        return (account, generated)
    }

    // MARK: - Single-Flight Prompt Serialization

    private func runSerializedChallenge(_ request: AuthChallengeRequest) async throws -> Bool {
        while isPromptInFlight {
            await withCheckedContinuation { continuation in
                promptWaiters.append(continuation)
            }
        }
        isPromptInFlight = true
        defer {
            isPromptInFlight = false
            let waiters = promptWaiters
            promptWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        return try await verifier(request)
    }
}
