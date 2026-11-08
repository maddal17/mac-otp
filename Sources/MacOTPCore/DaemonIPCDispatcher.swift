import Foundation

public struct DaemonIPCDispatcher: Sendable {
    private let vault: VaultStore
    private let authManager: AuthSessionManager
    private let onAuditOrStateChanged: (@Sendable () -> Void)?

    public init(
        vault: VaultStore,
        authManager: AuthSessionManager,
        onAuditOrStateChanged: (@Sendable () -> Void)? = nil
    ) {
        self.vault = vault
        self.authManager = authManager
        self.onAuditOrStateChanged = onAuditOrStateChanged
    }

    public func dispatch(_ request: IPCRequest) async -> IPCResponse {
        switch request.command {
        case .ping:
            return IPCResponse(id: request.id, ok: true)

        case .status:
            let settings = await vault.getSettings()
            let accounts = await vault.listAccounts()
            let unlocked = await authManager.isUnlocked()
            let remaining = await authManager.remainingUnlockSeconds()
            let status = IPCDaemonStatus(
                running: true,
                unlocked: unlocked,
                remainingUnlockSeconds: remaining,
                accountCount: accounts.count,
                mcpAuthPolicy: settings.mcpAuthPolicy,
                allowMCPListWhenLocked: settings.allowMCPListWhenLocked
            )
            return IPCResponse(id: request.id, ok: true, status: status)

        case .listAccounts:
            do {
                let list = try await authManager.mcpListAccounts(query: request.query)
                onAuditOrStateChanged?()
                return IPCResponse(id: request.id, ok: true, accounts: list)
            } catch {
                onAuditOrStateChanged?()
                return IPCResponse(id: request.id, ok: false, errorMessage: error.localizedDescription)
            }

        case .getCode:
            guard let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                return IPCResponse(
                    id: request.id,
                    ok: false,
                    errorMessage: "Не указано имя сервиса или ID аккаунта."
                )
            }
            do {
                let waitFresh = request.waitForFreshWindow ?? true
                let (account, generated) = try await authManager.mcpGetCode(
                    accountQuery: query,
                    waitForFreshWindow: waitFresh
                )
                onAuditOrStateChanged?()
                return IPCResponse(
                    id: request.id,
                    ok: true,
                    codeResult: IPCCodeResult(account: account, generated: generated)
                )
            } catch {
                onAuditOrStateChanged?()
                return IPCResponse(id: request.id, ok: false, errorMessage: error.localizedDescription)
            }
        }
    }
}
