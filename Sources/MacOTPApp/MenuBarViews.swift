import AppKit
import MacOTPCore
import SwiftUI

private enum ActiveModalSheet: Identifiable {
    case addAccount
    case settings
    case audit

    var id: Int {
        switch self {
        case .addAccount: return 1
        case .settings: return 2
        case .audit: return 3
        }
    }
}

// MARK: - macOS 26 / 27 Liquid Glass Adaptive Modifiers

private extension View {
    @ViewBuilder
    func liquidGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let base: Glass = interactive ? .regular.interactive() : .regular
            let styled: Glass = tint != nil ? base.tint(tint) : base
            self.glassEffect(styled, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        self.background(.ultraThinMaterial, in: Capsule())
        #endif
    }

    @ViewBuilder
    func liquidGlassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
        #else
        if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
        #endif
    }
}

private struct AdaptiveGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

// MARK: - Root Popover View

struct MenuBarRootView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var activeSheet: ActiveModalSheet?
    @State private var isEnteringPin: Bool = false
    @State private var inlinePin: String = ""
    @State private var pendingCopyAccount: OTPAccountMetadata?

    private var l10n: L10n { viewModel.l10n }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if let errorBanner = viewModel.errorBanner {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(errorBanner)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        viewModel.errorBanner = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.14))
            }

            AccountsListView(
                viewModel: viewModel,
                l10n: l10n,
                onAccountClicked: { account in
                    handleAccountClick(account)
                },
                onAddTapped: {
                    activeSheet = .addAccount
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let toast = viewModel.toastMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toast)
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.14))
            }

            bottomActionBar
        }
        .frame(width: 350, height: 330)
        .onChange(of: viewModel.isUnlocked) { _, unlocked in
            if unlocked {
                isEnteringPin = false
                inlinePin = ""
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addAccount:
                AddAccountSheetView(
                    viewModel: viewModel,
                    l10n: l10n,
                    onClose: { activeSheet = nil }
                )
            case .settings:
                SettingsSheetView(
                    viewModel: viewModel,
                    l10n: l10n,
                    onClose: { activeSheet = nil }
                )
            case .audit:
                AuditSheetView(
                    entries: viewModel.auditEntries,
                    l10n: l10n,
                    onClose: { activeSheet = nil }
                )
            }
        }
    }

    // MARK: - Liquid Glass Top Chrome Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.isUnlocked ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(viewModel.isUnlocked ? .green : .secondary)

            Text("MacOTP")
                .font(.system(size: 13.5, weight: .bold, design: .rounded))

            Text(statusSubtitle)
                .font(.system(size: 10.5, weight: .semibold, design: viewModel.isUnlocked ? .monospaced : .default))
                .foregroundStyle(viewModel.isUnlocked ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .liquidGlassCapsule(tint: viewModel.isUnlocked ? .green.opacity(0.25) : nil)

            Spacer()

            Menu {
                Button {
                    activeSheet = .settings
                } label: {
                    Label(l10n.settingsAndSecurityMenu, systemImage: "slider.horizontal.3")
                }

                Button {
                    viewModel.copyMCPConfigSnippet()
                } label: {
                    Label(l10n.copyMCPConfigMenu, systemImage: "cpu")
                }

                Button {
                    activeSheet = .audit
                } label: {
                    Label(l10n.activityLogMenu, systemImage: "list.bullet.rectangle")
                }

                Divider()

                Button(role: .destructive) {
                    viewModel.shutdown()
                    NSApp.terminate(nil)
                } label: {
                    Label(l10n.quitAppMenu, systemImage: "power")
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(l10n.settingsTooltip)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var statusSubtitle: String {
        if viewModel.isUnlocked {
            let mins = viewModel.remainingUnlockSeconds / 60
            let secs = viewModel.remainingUnlockSeconds % 60
            return String(format: "%02d:%02d", mins, secs)
        }
        return l10n.locked
    }

    // MARK: - Liquid Glass Bottom Floating Action Bar

    private var bottomActionBar: some View {
        AdaptiveGlassContainer(spacing: 8) {
            if viewModel.isUnlocked {
                Button {
                    Task { await viewModel.lockVault() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                        Text(l10n.lockButton)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                }
                .liquidGlassButtonStyle(prominent: false)
                .controlSize(.regular)
            } else if isEnteringPin {
                HStack(spacing: 6) {
                    LocalMaskedField(
                        placeholder: l10n.enterPinPlaceholder,
                        text: $inlinePin,
                        autoFocus: true,
                        onSubmit: { submitInlinePin() },
                        onCancel: {
                            isEnteringPin = false
                            inlinePin = ""
                            pendingCopyAccount = nil
                        }
                    )
                    .frame(height: 26)

                    Button(l10n.openPinButton) {
                        submitInlinePin()
                    }
                    .liquidGlassButtonStyle(prominent: true)
                    .controlSize(.small)
                    .disabled(inlinePin.isEmpty)

                    Button {
                        isEnteringPin = false
                        inlinePin = ""
                        let target = pendingCopyAccount
                        pendingCopyAccount = nil
                        Task {
                            if let target {
                                await viewModel.copyCode(for: target)
                            } else {
                                await viewModel.unlockWithSystemAuth()
                            }
                        }
                    } label: {
                        Image(systemName: "touchid")
                            .font(.system(size: 13))
                    }
                    .liquidGlassButtonStyle(prominent: false)
                    .controlSize(.small)
                    .help(l10n.useSystemAuthTooltip)

                    Button {
                        isEnteringPin = false
                        inlinePin = ""
                        pendingCopyAccount = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(l10n.cancelButton)
                }
            } else {
                Button {
                    triggerUnlockFlow(afterUnlockCopy: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isTouchIDCurrentlyAvailable() ? "touchid" : "lock.open.fill")
                        Text(l10n.unlockButton)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                }
                .liquidGlassButtonStyle(prominent: true)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private func handleAccountClick(_ account: OTPAccountMetadata) {
        if viewModel.isUnlocked {
            Task { await viewModel.copyCode(for: account) }
        } else {
            triggerUnlockFlow(afterUnlockCopy: account)
        }
    }

    private func triggerUnlockFlow(afterUnlockCopy account: OTPAccountMetadata?) {
        if !viewModel.isTouchIDCurrentlyAvailable() && viewModel.isQuickPinSet {
            pendingCopyAccount = account
            inlinePin = ""
            isEnteringPin = true
        } else {
            Task {
                if let account {
                    await viewModel.copyCode(for: account)
                } else {
                    await viewModel.unlockWithSystemAuth()
                }
            }
        }
    }

    private func submitInlinePin() {
        let entered = inlinePin
        guard !entered.isEmpty else { return }
        inlinePin = ""
        let target = pendingCopyAccount
        Task {
            let ok = await viewModel.unlockWithQuickPin(entered)
            if ok {
                isEnteringPin = false
                pendingCopyAccount = nil
                if let target {
                    await viewModel.copyCode(for: target)
                }
            }
        }
    }
}

// MARK: - Accounts Content Layer + Integrated Plus Pill

private struct AccountsListView: View {
    @ObservedObject var viewModel: AppViewModel
    let l10n: L10n
    let onAccountClicked: (OTPAccountMetadata) -> Void
    let onAddTapped: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if viewModel.accounts.count > 1 || !viewModel.searchQuery.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField(l10n.searchPlaceholder, text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
                .padding(.horizontal, 14)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.filteredAccounts) { account in
                        AccountRowCard(
                            account: account,
                            generated: viewModel.liveCodes[account.id],
                            isUnlocked: viewModel.isUnlocked,
                            l10n: l10n,
                            onCopy: { onAccountClicked(account) },
                            onDelete: {
                                Task { await viewModel.deleteAccount(account) }
                            }
                        )
                    }

                    // Concentric '+' action inside the list
                    Button(action: onAddTapped) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                            if viewModel.accounts.isEmpty {
                                Text(l10n.addFirstAccount)
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .foregroundStyle(Color.primary.opacity(0.16))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(l10n.addAccountTooltip)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
    }
}

/// Content card following macOS 26/27 HIG: concentric continuous corners, non-glass translucent
/// content surface for high contrast typography, and subtle specular highlight border.
private struct AccountRowCard: View {
    let account: OTPAccountMetadata
    let generated: GeneratedOTPCode?
    let isUnlocked: Bool
    let l10n: L10n
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.primaryLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !account.secondaryLabel.isEmpty {
                        Text(account.secondaryLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isUnlocked, let generated {
                    Text(generated.formattedCode)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(generated.remainingSeconds <= 5 ? Color.orange : Color.accentColor)

                    CountdownRing(
                        remaining: generated.remainingSeconds,
                        period: generated.period
                    )
                    .frame(width: 22, height: 22)
                } else {
                    Text("••• •••")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.75))
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.085 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.16 : 0.09), lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(isUnlocked ? l10n.copyCodeAction : l10n.unlockAndCopyTooltip)
        .contextMenu {
            Button(l10n.copyCodeAction) { onCopy() }
            Button(l10n.copyMCPIdAction) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.id.uuidString, forType: .string)
            }
            Divider()
            Button(l10n.deleteAccountAction, role: .destructive) { onDelete() }
        }
    }
}

private struct CountdownRing: View {
    let remaining: Int
    let period: Int

    var body: some View {
        let progress = max(0.0, min(1.0, Double(remaining) / Double(max(1, period))))
        let urgent = remaining <= 5
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    urgent ? Color.orange : Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(urgent ? .orange : .secondary)
        }
    }
}

// MARK: - Add / Import Sheet

private struct AddAccountSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    let l10n: L10n
    let onClose: () -> Void

    @State private var mode: Int = 0
    @State private var uriText: String = ""
    @State private var issuer: String = ""
    @State private var accountName: String = ""
    @State private var secretBase32: String = ""
    @State private var digits: Int = 6
    @State private var period: Int = 30
    @State private var algorithm: OTPAlgorithm = .sha1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.newAccountTitle)
                .font(.headline)

            Picker("", selection: $mode) {
                Text(l10n.qrOrLinkTab).tag(0)
                Text(l10n.manualKeyTab).tag(1)
            }
            .pickerStyle(.segmented)

            if mode == 0 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                if await viewModel.scanQRFromScreen() {
                                    onClose()
                                }
                            }
                        } label: {
                            Label(l10n.scanScreenButton, systemImage: "viewfinder")
                        }

                        Button {
                            Task {
                                if await viewModel.scanQRFromClipboard() {
                                    onClose()
                                }
                            }
                        } label: {
                            Label(l10n.scanClipboardButton, systemImage: "doc.on.clipboard")
                        }

                        Button {
                            Task {
                                if await viewModel.scanQRFromFilePicker() {
                                    onClose()
                                }
                            }
                        } label: {
                            Label(l10n.scanFileButton, systemImage: "photo")
                        }
                    }
                    .controlSize(.small)

                    TextField("otpauth://totp/...", text: $uriText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(l10n.servicePlaceholder, text: $issuer)
                        .textFieldStyle(.roundedBorder)
                    TextField(l10n.loginPlaceholder, text: $accountName)
                        .textFieldStyle(.roundedBorder)
                    TextField(l10n.secretKeyPlaceholder, text: $secretBase32)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    HStack(spacing: 8) {
                        Picker(l10n.digitsLabel, selection: $digits) {
                            Text("6").tag(6)
                            Text("8").tag(8)
                        }
                        Picker(l10n.periodLabel, selection: $period) {
                            Text("30s").tag(30)
                            Text("60s").tag(60)
                        }
                        Picker("", selection: $algorithm) {
                            ForEach(OTPAlgorithm.allCases, id: \.self) { algo in
                                Text(algo.rawValue).tag(algo)
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }

            if let err = viewModel.errorBanner {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack {
                Spacer()
                Button(l10n.cancelButton) {
                    viewModel.errorBanner = nil
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button(l10n.saveButton) {
                    Task {
                        if mode == 0 {
                            if await viewModel.importFromURI(uriText) {
                                onClose()
                            }
                        } else {
                            if await viewModel.addManualAccount(
                                issuer: issuer,
                                accountName: accountName,
                                secret: secretBase32,
                                digits: digits,
                                period: period,
                                algorithm: algorithm
                            ) {
                                onClose()
                            }
                        }
                    }
                }
                .liquidGlassButtonStyle(prominent: true)
                .disabled(mode == 0 ? uriText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : secretBase32.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 325)
    }
}

// MARK: - Settings Modal Sheet

private struct SettingsSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    let l10n: L10n
    let onClose: () -> Void
    @State private var newPin: String = ""
    @State private var backupPassword: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(l10n.settingsTitle)
                    .font(.headline)
                Spacer()
                Button(l10n.doneButton) {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(l10n.hardwareKeysBadge(viewModel.keyBackendLabel))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    GroupBox(l10n.sessionAndMCPGroup) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker(l10n.languageLabel, selection: Binding(
                                get: { viewModel.settings.language },
                                set: { val in
                                    var s = viewModel.settings
                                    s.language = val
                                    Task { await viewModel.saveSettings(s) }
                                }
                            )) {
                                ForEach(AppLanguage.allCases, id: \.self) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .controlSize(.small)

                            Picker(l10n.uiSessionLabel, selection: Binding(
                                get: { viewModel.settings.uiSessionTTLSeconds },
                                set: { val in
                                    var s = viewModel.settings
                                    s.uiSessionTTLSeconds = val
                                    Task { await viewModel.saveSettings(s) }
                                }
                            )) {
                                Text(l10n.ttlOneTime).tag(0)
                                Text(l10n.ttl1Min).tag(60)
                                Text(l10n.ttl5Min).tag(300)
                                Text(l10n.ttl15Min).tag(900)
                            }
                            .controlSize(.small)

                            Picker(l10n.mcpModeLabel, selection: Binding(
                                get: { viewModel.settings.mcpAuthPolicy },
                                set: { val in
                                    var s = viewModel.settings
                                    s.mcpAuthPolicy = val
                                    Task { await viewModel.saveSettings(s) }
                                }
                            )) {
                                Text(l10n.mcpAskEveryTime).tag(MCPAuthPolicy.alwaysAskPerRequest)
                                Text(l10n.mcpShareSession).tag(MCPAuthPolicy.reuseActiveSession)
                            }
                            .controlSize(.small)

                            Toggle(l10n.lockOnSleepToggle, isOn: Binding(
                                get: { viewModel.settings.autoLockOnSleepOrScreenLock },
                                set: { val in
                                    var s = viewModel.settings
                                    s.autoLockOnSleepOrScreenLock = val
                                    Task { await viewModel.saveSettings(s) }
                                }
                            ))
                            .font(.caption)

                            Toggle(l10n.clearClipboardToggle, isOn: Binding(
                                get: { viewModel.settings.autoClearClipboard },
                                set: { val in
                                    var s = viewModel.settings
                                    s.autoClearClipboard = val
                                    Task { await viewModel.saveSettings(s) }
                                }
                            ))
                            .font(.caption)
                        }
                        .padding(4)
                    }

                    GroupBox(l10n.quickPinGroup) {
                        HStack(spacing: 6) {
                            LocalMaskedField(
                                placeholder: viewModel.isQuickPinSet ? l10n.changePinPlaceholder : l10n.newPinPlaceholder,
                                text: $newPin
                            )
                            .frame(height: 24)

                            Button(viewModel.isQuickPinSet ? l10n.updateButton : l10n.setButton) {
                                let pinToSet = newPin
                                newPin = ""
                                Task { _ = await viewModel.setupQuickPin(pinToSet) }
                            }
                            .controlSize(.small)
                            .disabled(newPin.count < 4)

                            if viewModel.isQuickPinSet {
                                Button(l10n.resetButton, role: .destructive) {
                                    Task { await viewModel.removeQuickPin() }
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(4)
                    }

                    GroupBox(l10n.backupGroup) {
                        HStack(spacing: 6) {
                            LocalMaskedField(
                                placeholder: l10n.backupPasswordPlaceholder,
                                text: $backupPassword
                            )
                            .frame(height: 24)

                            Button(l10n.exportButton) {
                                let pwd = backupPassword
                                backupPassword = ""
                                Task { _ = await viewModel.exportBackupInteractive(password: pwd) }
                            }
                            .disabled(backupPassword.count < 6)

                            Button(l10n.importButton) {
                                let pwd = backupPassword
                                backupPassword = ""
                                Task { _ = await viewModel.importBackupInteractive(password: pwd) }
                            }
                            .disabled(backupPassword.count < 6)
                        }
                        .controlSize(.small)
                        .padding(4)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 330, height: 300)
    }
}

// MARK: - Activity Log Modal Sheet

private struct AuditSheetView: View {
    let entries: [AuditEntry]
    let l10n: L10n
    let onClose: () -> Void

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss dd.MM"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(l10n.activityLogTitle)
                    .font(.headline)
                Spacer()
                Button(l10n.closeButton) {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }

            if entries.isEmpty {
                Spacer()
                Text(l10n.noActivityYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(entries) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(item.outcome == .granted ? Color.green : (item.outcome == .denied ? Color.red : Color.blue))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 4)

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text("[\(item.channel.rawValue)] \(item.target)")
                                            .font(.system(size: 11, weight: .semibold))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(Self.formatter.string(from: item.timestamp))
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(item.action) · \(item.detail.isEmpty ? item.outcome.rawValue : item.detail)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 325, height: 280)
    }
}
