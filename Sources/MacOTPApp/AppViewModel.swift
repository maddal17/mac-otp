import AppKit
import Combine
import Foundation
import LocalAuthentication
import MacOTPCore
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var accounts: [OTPAccountMetadata] = []
    @Published var liveCodes: [UUID: GeneratedOTPCode] = [:]
    @Published var isUnlocked: Bool = false
    @Published var remainingUnlockSeconds: Int = 0
    @Published var searchQuery: String = ""
    @Published var settings: SecuritySettings = SecuritySettings()
    @Published var isQuickPinSet: Bool = false
    @Published var keyBackendLabel: String = ""
    @Published var auditEntries: [AuditEntry] = []
    @Published var toastMessage: String?
    @Published var errorBanner: String?

    var l10n: L10n {
        L10n(settings.language)
    }

    let vault: VaultStore
    let authCoordinator: NativeAuthCoordinator
    let authManager: AuthSessionManager
    private var ipcServer: UnixDomainSocketServer?
    private var uiRefreshTimer: Timer?
    private var sessionExpiryTimer: Timer?
    private var isPopoverVisible: Bool = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    var onLockStateChanged: ((Bool) -> Void)?
    var onTemporarilyHidePopover: (() -> Void)?
    var onRestorePopover: (() -> Void)?

    init() throws {
        let store = try VaultStore()
        let coordinator = NativeAuthCoordinator(vault: store)
        let manager = AuthSessionManager(
            vault: store,
            verifier: { request in
                await coordinator.verifyUserPresence(request)
            }
        )

        self.vault = store
        self.authCoordinator = coordinator
        self.authManager = manager

        setupIPCServer()
        setupSleepAndScreenLockObservers()

        Task {
            await reloadAllState()
        }
    }

    var filteredAccounts: [OTPAccountMetadata] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return accounts }
        return accounts.filter {
            $0.issuer.localizedCaseInsensitiveContains(q) ||
            $0.accountName.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - Daemon & Lifecycle

    private func setupIPCServer() {
        let dispatcher = DaemonIPCDispatcher(
            vault: vault,
            authManager: authManager,
            onAuditOrStateChanged: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.reloadAllState()
                }
            }
        )

        let socketPath = ProcessInfo.processInfo.environment["MACOTP_SOCKET_PATH"]
            ?? UnixDomainSocketServer.defaultSocketPath

        let server = UnixDomainSocketServer(socketPath: socketPath) { request in
            await dispatcher.dispatch(request)
        }

        do {
            try server.start()
            self.ipcServer = server
        } catch {
            self.errorBanner = error.localizedDescription
        }
    }

    private func setupSleepAndScreenLockObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        let sleepHandler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.settings.autoLockOnSleepOrScreenLock {
                    await self.lockVault(reason: "Автоблокировка при сне macOS")
                }
            }
        }
        workspaceObservers.append(
            wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: sleepHandler)
        )
        workspaceObservers.append(
            wsCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: sleepHandler)
        )

        let distCenter = DistributedNotificationCenter.default()
        distributedObservers.append(
            distCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.settings.autoLockOnSleepOrScreenLock {
                        await self.lockVault(reason: "Автоблокировка при блокировке экрана")
                    }
                }
            }
        )
    }

    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        if visible {
            Task {
                await reloadAllState()
            }
        } else {
            stopUIRefreshTimer()
            if !liveCodes.isEmpty {
                liveCodes.removeAll()
            }
        }
    }

    private func updateTimers() {
        // 1. Live 1s countdown timer ONLY runs when the Menu Bar popover is actually open AND unlocked
        if isPopoverVisible && isUnlocked {
            if uiRefreshTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.syncLockAndCodes()
                    }
                }
                timer.tolerance = 0.15
                uiRefreshTimer = timer
            }
        } else {
            stopUIRefreshTimer()
        }

        // 2. Single one-shot timer for session TTL expiration (zero background polling wakeups)
        sessionExpiryTimer?.invalidate()
        sessionExpiryTimer = nil
        if isUnlocked && remainingUnlockSeconds > 0 {
            let oneShot = Timer.scheduledTimer(
                withTimeInterval: TimeInterval(remainingUnlockSeconds) + 0.1,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.syncLockAndCodes()
                }
            }
            oneShot.tolerance = 1.0
            sessionExpiryTimer = oneShot
        }
    }

    private func stopUIRefreshTimer() {
        uiRefreshTimer?.invalidate()
        uiRefreshTimer = nil
    }

    func shutdown() {
        stopUIRefreshTimer()
        sessionExpiryTimer?.invalidate()
        sessionExpiryTimer = nil
        ipcServer?.stop()
    }

    // MARK: - State Refresh

    func reloadAllState() async {
        let fetchedAccounts = await vault.listAccounts()
        if accounts != fetchedAccounts { accounts = fetchedAccounts }

        let fetchedSettings = await vault.getSettings()
        if settings != fetchedSettings { settings = fetchedSettings }

        let fetchedPin = await vault.isQuickPinConfigured()
        if isQuickPinSet != fetchedPin { isQuickPinSet = fetchedPin }

        let fetchedBackend = (await vault.getKeyBackend()).rawValue
        if keyBackendLabel != fetchedBackend { keyBackendLabel = fetchedBackend }

        let fetchedAudit = await vault.getAuditEntries()
        if auditEntries != fetchedAudit { auditEntries = fetchedAudit }

        await syncLockAndCodes()
    }

    private func syncLockAndCodes() async {
        let unlockedNow = await authManager.isUnlocked()
        let remaining = await authManager.remainingUnlockSeconds()

        let changed = (unlockedNow != isUnlocked)
        if isUnlocked != unlockedNow { isUnlocked = unlockedNow }
        if remainingUnlockSeconds != remaining { remainingUnlockSeconds = remaining }

        if unlockedNow && isPopoverVisible {
            if let codes = try? await vault.generateAllCodes(at: Date()), liveCodes != codes {
                liveCodes = codes
            }
        } else {
            if !liveCodes.isEmpty {
                liveCodes.removeAll()
            }
        }

        updateTimers()

        if changed {
            onLockStateChanged?(unlockedNow)
            let fetchedAudit = await vault.getAuditEntries()
            if auditEntries != fetchedAudit { auditEntries = fetchedAudit }
        }
    }

    // MARK: - Unlock / Lock / Copy

    func isTouchIDCurrentlyAvailable() -> Bool {
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    func unlockWithSystemAuth() async {
        errorBanner = nil
        do {
            try await authManager.unlockUISession(reason: l10n.unlockVaultPrompt)
            await reloadAllState()
        } catch {
            errorBanner = error.localizedDescription
            auditEntries = await vault.getAuditEntries()
        }
    }

    func unlockWithQuickPin(_ pin: String) async -> Bool {
        errorBanner = nil
        do {
            try await authManager.unlockUISessionWithQuickPin(pin)
            await reloadAllState()
            return true
        } catch {
            errorBanner = error.localizedDescription
            isQuickPinSet = await vault.isQuickPinConfigured()
            auditEntries = await vault.getAuditEntries()
            return false
        }
    }

    func lockVault(reason: String = "Ручная блокировка") async {
        await authManager.lockImmediately(reason: reason)
        liveCodes.removeAll()
        await reloadAllState()
    }

    func copyCode(for account: OTPAccountMetadata) async {
        errorBanner = nil
        if !isUnlocked {
            do {
                try await authManager.unlockUISession(
                    reason: l10n.copyCodePrompt(account.displayTitle)
                )
                await syncLockAndCodes()
            } catch {
                errorBanner = error.localizedDescription
                auditEntries = await vault.getAuditEntries()
                return
            }
        }

        do {
            let generated = try await vault.generateCode(accountId: account.id, at: Date())
            writeClipboard(code: generated.code)
            await vault.recordAudit(
                channel: .ui,
                action: "copy_code",
                target: account.displayTitle,
                outcome: .granted,
                detail: "Clipboard"
            )
            auditEntries = await vault.getAuditEntries()
            showToast(l10n.codeCopiedToast(generated.formattedCode))

            if settings.uiSessionTTLSeconds == 0 {
                await lockVault(reason: "One-time TTL (0s)")
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func writeClipboard(code: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        let savedChangeCount = pb.changeCount

        guard settings.autoClearClipboard else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            if NSPasteboard.general.changeCount == savedChangeCount {
                NSPasteboard.general.clearContents()
            }
        }
    }

    // MARK: - Account Management & QR Import

    func addManualAccount(
        issuer: String,
        accountName: String,
        secret: String,
        digits: Int,
        period: Int,
        algorithm: OTPAlgorithm
    ) async -> Bool {
        errorBanner = nil
        do {
            let draft = OTPAccountDraft(
                issuer: issuer,
                accountName: accountName,
                secretBase32: secret,
                digits: digits,
                period: period,
                algorithm: algorithm
            )
            let created = try await vault.addAccount(draft)
            await vault.recordAudit(
                channel: .ui,
                action: "add_account",
                target: created.displayTitle,
                outcome: .info,
                detail: "Manual"
            )
            await reloadAllState()
            showToast(l10n.addedToast(created.displayTitle))
            return true
        } catch {
            errorBanner = error.localizedDescription
            return false
        }
    }

    func importFromURI(_ uriString: String) async -> Bool {
        errorBanner = nil
        do {
            let drafts = try OTPAuthParser.parseURI(uriString)
            let added = try await vault.importAccounts(drafts, deduplicate: true)
            await vault.recordAudit(
                channel: .ui,
                action: "import_uri",
                target: "\(added.count)",
                outcome: .info,
                detail: "URI / QR"
            )
            await reloadAllState()
            showToast(l10n.importedToast(added.count))
            return true
        } catch {
            errorBanner = error.localizedDescription
            return false
        }
    }

    func scanQRFromClipboard() async -> Bool {
        errorBanner = nil
        do {
            let payloads = try QRScannerService.scanFromClipboard()
            return await importDecodedQRPayloads(payloads)
        } catch {
            errorBanner = error.localizedDescription
            return false
        }
    }

    func scanQRFromScreen() async -> Bool {
        errorBanner = nil
        onTemporarilyHidePopover?()
        try? await Task.sleep(nanoseconds: 200_000_000)

        defer {
            onRestorePopover?()
        }

        do {
            let payloads = try await QRScannerService.scanInteractiveScreenSelection()
            return await importDecodedQRPayloads(payloads)
        } catch {
            if case QRScanError.screenCaptureCancelled = error {
                return false
            }
            errorBanner = error.localizedDescription
            return false
        }
    }

    func scanQRFromFilePicker() async -> Bool {
        errorBanner = nil
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .heic]
        panel.prompt = "Сканировать QR"

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        do {
            let payloads = try QRScannerService.scanFromImageURL(url)
            return await importDecodedQRPayloads(payloads)
        } catch {
            errorBanner = error.localizedDescription
            return false
        }
    }

    private func importDecodedQRPayloads(_ payloads: [String]) async -> Bool {
        var totalAdded = 0
        var anyParsed = false
        for raw in payloads {
            if let drafts = try? OTPAuthParser.parseURI(raw) {
                anyParsed = true
                if let added = try? await vault.importAccounts(drafts, deduplicate: true) {
                    totalAdded += added.count
                }
            }
        }
        guard anyParsed else {
            errorBanner = l10n.qrNoOTPDataError
            return false
        }
        await vault.recordAudit(
            channel: .ui,
            action: "import_qr",
            target: "\(totalAdded)",
            outcome: .info,
            detail: "QR"
        )
        await reloadAllState()
        showToast(l10n.importedToast(totalAdded))
        return true
    }

    func deleteAccount(_ account: OTPAccountMetadata) async {
        errorBanner = nil
        let approved = await authCoordinator.evaluateSystemOwnerAuth(
            reason: "\(l10n.deleteAccountAction) “\(account.displayTitle)”"
        )
        guard approved else { return }

        do {
            try await vault.deleteAccount(id: account.id)
            liveCodes.removeValue(forKey: account.id)
            await vault.recordAudit(
                channel: .ui,
                action: "delete_account",
                target: account.displayTitle,
                outcome: .info,
                detail: "Deleted"
            )
            await reloadAllState()
            showToast(l10n.deletedToast(account.primaryLabel))
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    // MARK: - Security Settings & Backup

    func saveSettings(_ updated: SecuritySettings) async {
        do {
            try await vault.updateSettings(updated)
            settings = updated
            showToast(L10n(updated.language).settingsSavedToast)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func setupQuickPin(_ newPin: String) async -> Bool {
        errorBanner = nil
        let approved = await authCoordinator.evaluateSystemOwnerAuth(
            reason: l10n.quickPinGroup
        )
        guard approved else { return false }

        do {
            try await vault.configureQuickPin(newPin)
            await vault.recordAudit(
                channel: .ui,
                action: "set_quick_pin",
                target: "Security",
                outcome: .info,
                detail: "Quick PIN enabled"
            )
            await reloadAllState()
            showToast(l10n.pinSetToast)
            return true
        } catch {
            errorBanner = error.localizedDescription
            return false
        }
    }

    func removeQuickPin() async {
        errorBanner = nil
        do {
            try await vault.disableQuickPin()
            await vault.recordAudit(
                channel: .ui,
                action: "disable_quick_pin",
                target: "Security",
                outcome: .info,
                detail: "Quick PIN disabled"
            )
            await reloadAllState()
            showToast(l10n.pinDisabledToast)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func exportBackupInteractive(password: String) async -> Bool {
        errorBanner = nil
        let approved = await authCoordinator.evaluateSystemOwnerAuth(
            reason: l10n.backupGroup
        )
        guard approved else { return false }

        do {
            let encryptedData = try await vault.exportEncryptedBackup(masterPassword: password)
            NSApp.activate(ignoringOtherApps: true)
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = "macotp-backup.macotpbackup"
            savePanel.canCreateDirectories = true
            savePanel.prompt = l10n.exportButton

            guard savePanel.runModal() == .OK, let url = savePanel.url else {
                return false
            }
            try encryptedData.write(to: url, options: .atomic)
            await vault.recordAudit(
                channel: .ui,
                action: "export_backup",
                target: url.lastPathComponent,
                outcome: .granted,
                detail: "AES-256-GCM"
            )
            await reloadAllState()
            showToast(l10n.backupSavedToast)
            return true
        } catch {
            errorBanner = error.localizedDescription
            return false
        }
    }

    func importBackupInteractive(password: String) async -> Bool {
        errorBanner = nil
        NSApp.activate(ignoringOtherApps: true)
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = l10n.importButton

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return false
        }

        do {
            let data = try Data(contentsOf: url)
            let imported = try await vault.importEncryptedBackup(data: data, masterPassword: password)
            await vault.recordAudit(
                channel: .ui,
                action: "import_backup",
                target: "\(imported.count)",
                outcome: .info,
                detail: "AES-256-GCM"
            )
            await reloadAllState()
            showToast(l10n.importedToast(imported.count))
            return true
        } catch {
            errorBanner = error.localizedDescription
            return false
        }
    }

    func resolvedMCPBinaryPath() -> String {
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = execURL.deletingLastPathComponent().appendingPathComponent("mac-otp-mcp")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling.path
        }
        return "/Applications/MacOTP.app/Contents/MacOS/mac-otp-mcp"
    }

    func copyMCPConfigSnippet() {
        let binPath = resolvedMCPBinaryPath()
        let snippet = """
        {
          "mcpServers": {
            "mac-otp": {
              "command": "\(binPath)",
              "args": []
            }
          }
        }
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
        showToast(l10n.mcpCopiedToast)
    }

    func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }
}
