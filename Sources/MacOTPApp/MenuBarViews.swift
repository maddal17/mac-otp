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

struct MenuBarRootView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var activeSheet: ActiveModalSheet?
    @State private var isEnteringPin: Bool = false
    @State private var inlinePin: String = ""
    @State private var pendingCopyAccount: OTPAccountMetadata?

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
                .background(Color.orange.opacity(0.12))
            }

            AccountsListView(
                viewModel: viewModel,
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
                .background(Color.green.opacity(0.12))
            }

            Divider()
                .opacity(0.5)

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
                    onClose: { activeSheet = nil }
                )
            case .settings:
                SettingsSheetView(
                    viewModel: viewModel,
                    onClose: { activeSheet = nil }
                )
            case .audit:
                AuditSheetView(
                    entries: viewModel.auditEntries,
                    onClose: { activeSheet = nil }
                )
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.isUnlocked ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(viewModel.isUnlocked ? .green : .secondary)

            Text("MacOTP")
                .font(.system(size: 13, weight: .bold))

            Text(statusSubtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(viewModel.isUnlocked ? .green : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(viewModel.isUnlocked ? Color.green.opacity(0.12) : Color.secondary.opacity(0.10))
                )

            Spacer()

            Menu {
                Button {
                    activeSheet = .settings
                } label: {
                    Label("Настройки и защита...", systemImage: "slider.horizontal.3")
                }

                Button {
                    viewModel.copyMCPConfigSnippet()
                } label: {
                    Label("Скопировать конфиг MCP", systemImage: "cpu")
                }

                Button {
                    activeSheet = .audit
                } label: {
                    Label("Журнал событий...", systemImage: "list.bullet.rectangle")
                }

                Divider()

                Button(role: .destructive) {
                    viewModel.shutdown()
                    NSApp.terminate(nil)
                } label: {
                    Label("Выйти из MacOTP", systemImage: "power")
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Настройки и дополнительно")
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 6)
    }

    private var statusSubtitle: String {
        if viewModel.isUnlocked {
            let mins = viewModel.remainingUnlockSeconds / 60
            let secs = viewModel.remainingUnlockSeconds % 60
            return String(format: "%02d:%02d", mins, secs)
        }
        return "Заблокировано"
    }

    // MARK: - State-Changing Bottom Primary Bar

    @ViewBuilder
    private var bottomActionBar: some View {
        if viewModel.isUnlocked {
            Button {
                Task { await viewModel.lockVault() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text("Заблокировать")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        } else if isEnteringPin {
            HStack(spacing: 6) {
                LocalMaskedField(
                    placeholder: "Введите PIN + Enter",
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

                Button("Открыть") {
                    submitInlinePin()
                }
                .buttonStyle(.borderedProminent)
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
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Использовать системный пароль / Touch ID")

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
                .help("Отмена")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        } else {
            Button {
                triggerUnlockFlow(afterUnlockCopy: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isTouchIDCurrentlyAvailable() ? "touchid" : "lock.open.fill")
                    Text("Разблокировать")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
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

// MARK: - Accounts List with Integrated Plus Button

private struct AccountsListView: View {
    @ObservedObject var viewModel: AppViewModel
    let onAccountClicked: (OTPAccountMetadata) -> Void
    let onAddTapped: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if viewModel.accounts.count > 1 || !viewModel.searchQuery.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Поиск...", text: $viewModel.searchQuery)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 14)
            }

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(viewModel.filteredAccounts) { account in
                        AccountRowCard(
                            account: account,
                            generated: viewModel.liveCodes[account.id],
                            isUnlocked: viewModel.isUnlocked,
                            onCopy: { onAccountClicked(account) },
                            onDelete: {
                                Task { await viewModel.deleteAccount(account) }
                            }
                        )
                    }

                    // Clean inline '+' card directly inside the list
                    Button(action: onAddTapped) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                            if viewModel.accounts.isEmpty {
                                Text("Добавить первый аккаунт")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .foregroundStyle(Color.secondary.opacity(0.28))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Добавить новый аккаунт")
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
        }
    }
}

private struct AccountRowCard: View {
    let account: OTPAccountMetadata
    let generated: GeneratedOTPCode?
    let isUnlocked: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

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
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isUnlocked ? "Скопировать код" : "Разблокировать и скопировать код")
        .contextMenu {
            Button("Скопировать код") { onCopy() }
            Button("Скопировать ID для MCP") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.id.uuidString, forType: .string)
            }
            Divider()
            Button("Удалить аккаунт...", role: .destructive) { onDelete() }
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
            Text("Новый аккаунт")
                .font(.headline)

            Picker("", selection: $mode) {
                Text("QR-код / Ссылка").tag(0)
                Text("Вручную по ключу").tag(1)
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
                            Label("С экрана", systemImage: "viewfinder")
                        }

                        Button {
                            Task {
                                if await viewModel.scanQRFromClipboard() {
                                    onClose()
                                }
                            }
                        } label: {
                            Label("Из буфера", systemImage: "doc.on.clipboard")
                        }

                        Button {
                            Task {
                                if await viewModel.scanQRFromFilePicker() {
                                    onClose()
                                }
                            }
                        } label: {
                            Label("Файл...", systemImage: "photo")
                        }
                    }
                    .controlSize(.small)

                    TextField("otpauth://totp/...", text: $uriText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Сервис (GitHub, VPN, AWS)", text: $issuer)
                        .textFieldStyle(.roundedBorder)
                    TextField("Логин / Email", text: $accountName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Секретный ключ Base32", text: $secretBase32)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    HStack(spacing: 8) {
                        Picker("Цифр", selection: $digits) {
                            Text("6").tag(6)
                            Text("8").tag(8)
                        }
                        Picker("Шаг", selection: $period) {
                            Text("30с").tag(30)
                            Text("60с").tag(60)
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
                Button("Отмена") {
                    viewModel.errorBanner = nil
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("Сохранить") {
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
                .buttonStyle(.borderedProminent)
                .disabled(mode == 0 ? uriText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : secretBase32.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Settings Modal Sheet (Opened via Gear Menu)

private struct SettingsSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    let onClose: () -> Void
    @State private var newPin: String = ""
    @State private var backupPassword: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Настройки и защита")
                    .font(.headline)
                Spacer()
                Button("Готово") {
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
                        Text("Ключи: \(viewModel.keyBackendLabel) (Zero-Keychain)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                    GroupBox("Сессия и MCP") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Сессия UI:", selection: Binding(
                                get: { viewModel.settings.uiSessionTTLSeconds },
                                set: { val in
                                    var s = viewModel.settings
                                    s.uiSessionTTLSeconds = val
                                    Task { await viewModel.saveSettings(s) }
                                }
                            )) {
                                Text("Одноразово (0с)").tag(0)
                                Text("1 мин").tag(60)
                                Text("5 мин").tag(300)
                                Text("15 мин").tag(900)
                            }
                            .controlSize(.small)

                            Picker("Режим MCP:", selection: Binding(
                                get: { viewModel.settings.mcpAuthPolicy },
                                set: { val in
                                    var s = viewModel.settings
                                    s.mcpAuthPolicy = val
                                    Task { await viewModel.saveSettings(s) }
                                }
                            )) {
                                Text("Спрашивать каждый раз").tag(MCPAuthPolicy.alwaysAskPerRequest)
                                Text("Общая сессия с UI").tag(MCPAuthPolicy.reuseActiveSession)
                            }
                            .controlSize(.small)

                            Toggle("Блокировать при сне Mac", isOn: Binding(
                                get: { viewModel.settings.autoLockOnSleepOrScreenLock },
                                set: { val in
                                    var s = viewModel.settings
                                    s.autoLockOnSleepOrScreenLock = val
                                    Task { await viewModel.saveSettings(s) }
                                }
                            ))
                            .font(.caption)

                            Toggle("Очищать буфер через 30 сек", isOn: Binding(
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

                    GroupBox("Быстрый PIN (при закрытой крышке)") {
                        HStack(spacing: 6) {
                            LocalMaskedField(
                                placeholder: viewModel.isQuickPinSet ? "Сменить PIN" : "Новый PIN (4–12)",
                                text: $newPin
                            )
                            .frame(height: 24)

                            Button(viewModel.isQuickPinSet ? "Обновить" : "Задать") {
                                let pinToSet = newPin
                                newPin = ""
                                Task { _ = await viewModel.setupQuickPin(pinToSet) }
                            }
                            .controlSize(.small)
                            .disabled(newPin.count < 4)

                            if viewModel.isQuickPinSet {
                                Button("Сброс", role: .destructive) {
                                    Task { await viewModel.removeQuickPin() }
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(4)
                    }

                    GroupBox("Резервная копия (AES-256-GCM)") {
                        HStack(spacing: 6) {
                            LocalMaskedField(
                                placeholder: "Пароль (мин. 6 симв.)",
                                text: $backupPassword
                            )
                            .frame(height: 24)

                            Button("Экспорт") {
                                let pwd = backupPassword
                                backupPassword = ""
                                Task { _ = await viewModel.exportBackupInteractive(password: pwd) }
                            }
                            .disabled(backupPassword.count < 6)

                            Button("Импорт") {
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
        .frame(width: 325, height: 295)
    }
}

// MARK: - Audit Modal Sheet (Opened via Gear Menu)

private struct AuditSheetView: View {
    let entries: [AuditEntry]
    let onClose: () -> Void

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss dd.MM"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Журнал событий")
                    .font(.headline)
                Spacer()
                Button("Закрыть") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }

            if entries.isEmpty {
                Spacer()
                Text("Событий пока нет")
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
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 325, height: 280)
    }
}
