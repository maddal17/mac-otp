import AppKit
import MacOTPCore
import SwiftUI

enum PopoverTab: String, CaseIterable {
    case codes = "Коды"
    case audit = "Журнал"
    case settings = "Защита и MCP"
}

struct MenuBarRootView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var selectedTab: PopoverTab = .codes
    @State private var showingAddSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let errorBanner = viewModel.errorBanner {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
                Divider()
            }

            Group {
                switch selectedTab {
                case .codes:
                    AccountsTabView(
                        viewModel: viewModel,
                        onAddTapped: { showingAddSheet = true }
                    )
                case .audit:
                    AuditTabView(entries: viewModel.auditEntries)
                case .settings:
                    SettingsTabView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let toast = viewModel.toastMessage {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toast)
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.10))
            }

            Divider()
            footerBar
        }
        .frame(width: 390, height: 520)
        .sheet(isPresented: $showingAddSheet) {
            AddAccountSheetView(viewModel: viewModel, isPresented: $showingAddSheet)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.isUnlocked ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(viewModel.isUnlocked ? .green : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("MacOTP")
                    .font(.system(size: 13, weight: .bold))
                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $selectedTab) {
                ForEach(PopoverTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 225)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusSubtitle: String {
        if viewModel.isUnlocked {
            let mins = viewModel.remainingUnlockSeconds / 60
            let secs = viewModel.remainingUnlockSeconds % 60
            return String(format: "Открыто · %02d:%02d", mins, secs)
        }
        return "Заблокировано"
    }

    private var footerBar: some View {
        HStack {
            if viewModel.isUnlocked {
                Button {
                    Task { await viewModel.lockVault() }
                } label: {
                    Label("Заблокировать", systemImage: "lock.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    Task { await viewModel.unlockWithSystemAuth() }
                } label: {
                    Label("Touch ID / Пароль", systemImage: "touchid")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Spacer()

            Button {
                showingAddSheet = true
            } label: {
                Label("Добавить 2FA", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                viewModel.shutdown()
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Завершить работу MacOTP")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Accounts Tab

private struct AccountsTabView: View {
    @ObservedObject var viewModel: AppViewModel
    let onAddTapped: () -> Void
    @State private var inlinePin: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск сервиса или логина...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 10)

            if !viewModel.isUnlocked && viewModel.isQuickPinSet {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    SecureField("Быстрый PIN + Enter", text: $inlinePin)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit {
                            let entered = inlinePin
                            inlinePin = ""
                            Task { _ = await viewModel.unlockWithQuickPin(entered) }
                        }
                    Button("Открыть") {
                        let entered = inlinePin
                        inlinePin = ""
                        Task { _ = await viewModel.unlockWithQuickPin(entered) }
                    }
                    .controlSize(.small)
                    .disabled(inlinePin.isEmpty)
                }
                .padding(.horizontal, 12)
            }

            if viewModel.accounts.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("Нет добавленных 2FA-аккаунтов")
                        .font(.subheadline.weight(.semibold))
                    Text("Считайте QR-код прямо с экрана, вставьте ссылку otpauth:// или секретный ключ.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Button("Добавить первый аккаунт") {
                        onAddTapped()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                Spacer()
            } else if viewModel.filteredAccounts.isEmpty {
                Spacer()
                Text("Ничего не найдено по запросу «\(viewModel.searchQuery)»")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(viewModel.filteredAccounts) { account in
                            AccountRowCard(
                                account: account,
                                generated: viewModel.liveCodes[account.id],
                                isUnlocked: viewModel.isUnlocked,
                                onCopy: {
                                    Task { await viewModel.copyCode(for: account) }
                                },
                                onDelete: {
                                    Task { await viewModel.deleteAccount(account) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
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
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(generated.remainingSeconds <= 5 ? Color.orange : Color.accentColor)

                    CountdownRing(
                        remaining: generated.remainingSeconds,
                        period: generated.period
                    )
                    .frame(width: 24, height: 24)
                } else {
                    Text("••• •••")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isUnlocked ? "Нажмите, чтобы скопировать код" : "Нажмите для разблокировки и копирования кода")
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
                .stroke(Color.secondary.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    urgent ? Color.orange : Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(urgent ? .orange : .secondary)
        }
    }
}

// MARK: - Add / Import Sheet

private struct AddAccountSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isPresented: Bool

    @State private var mode: Int = 0 // 0 = QR / URI, 1 = Manual
    @State private var uriText: String = ""
    @State private var issuer: String = ""
    @State private var accountName: String = ""
    @State private var secretBase32: String = ""
    @State private var digits: Int = 6
    @State private var period: Int = 30
    @State private var algorithm: OTPAlgorithm = .sha1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Добавление 2FA-аккаунта")
                .font(.headline)

            Picker("", selection: $mode) {
                Text("QR-код / Ссылка").tag(0)
                Text("Вручную по ключу").tag(1)
            }
            .pickerStyle(.segmented)

            if mode == 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Быстрый импорт QR-кода (включая экспорт из Google Authenticator):")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button {
                            Task {
                                if await viewModel.scanQRFromScreen() {
                                    isPresented = false
                                }
                            }
                        } label: {
                            Label("С экрана", systemImage: "viewfinder")
                        }

                        Button {
                            Task {
                                if await viewModel.scanQRFromClipboard() {
                                    isPresented = false
                                }
                            }
                        } label: {
                            Label("Из буфера", systemImage: "doc.on.clipboard")
                        }

                        Button {
                            Task {
                                if await viewModel.scanQRFromFilePicker() {
                                    isPresented = false
                                }
                            }
                        } label: {
                            Label("Из файла...", systemImage: "photo")
                        }
                    }
                    .controlSize(.small)

                    Divider()

                    Text("Или вставьте ссылку `otpauth://` / `otpauth-migration://`:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("otpauth://totp/GitHub:user?secret=...", text: $uriText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Сервис (например: GitHub, AWS, Google)", text: $issuer)
                        .textFieldStyle(.roundedBorder)
                    TextField("Логин / Email (необязательно)", text: $accountName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Секретный ключ Base32 (JBSWY3DPEHPK3PXP)", text: $secretBase32)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    HStack(spacing: 10) {
                        Picker("Цифр", selection: $digits) {
                            Text("6").tag(6)
                            Text("8").tag(8)
                        }
                        Picker("Интервал", selection: $period) {
                            Text("30 сек").tag(30)
                            Text("60 сек").tag(60)
                        }
                        Picker("Алгоритм", selection: $algorithm) {
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
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Сохранить") {
                    Task {
                        if mode == 0 {
                            if await viewModel.importFromURI(uriText) {
                                isPresented = false
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
                                isPresented = false
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(mode == 0 ? uriText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : secretBase32.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 370)
    }
}

// MARK: - Audit Tab

private struct AuditTabView: View {
    let entries: [AuditEntry]
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss dd.MM"
        return f
    }()

    var body: some View {
        if entries.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Журнал событий пуст")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(badgeColor(for: item.outcome))
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("[\(item.channel.rawValue)] \(item.target)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(Self.formatter.string(from: item.timestamp))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(item.action) · \(item.detail.isEmpty ? item.outcome.rawValue : item.detail)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(12)
            }
        }
    }

    private func badgeColor(for outcome: AuditOutcome) -> Color {
        switch outcome {
        case .granted: return .green
        case .denied: return .red
        case .rateLimited: return .orange
        case .error: return .red
        case .info: return .blue
        }
    }
}

// MARK: - Settings & MCP Tab

private struct SettingsTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var newPin: String = ""
    @State private var backupPassword: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Изоляция ключей: \(viewModel.keyBackendLabel)")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Zero-Keychain режим: общая связка ключей macOS не затрагивается")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                GroupBox("Сессия и политика MCP") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Таймер разблокировки UI:", selection: Binding(
                            get: { viewModel.settings.uiSessionTTLSeconds },
                            set: { val in
                                var s = viewModel.settings
                                s.uiSessionTTLSeconds = val
                                Task { await viewModel.saveSettings(s) }
                            }
                        )) {
                            Text("Одноразово (0 сек)").tag(0)
                            Text("1 минута").tag(60)
                            Text("5 минут").tag(300)
                            Text("15 минут").tag(900)
                        }
                        .controlSize(.small)

                        Picker("Запросы от MCP:", selection: Binding(
                            get: { viewModel.settings.mcpAuthPolicy },
                            set: { val in
                                var s = viewModel.settings
                                s.mcpAuthPolicy = val
                                Task { await viewModel.saveSettings(s) }
                            }
                        )) {
                            Text("Подтверждать каждый код").tag(MCPAuthPolicy.alwaysAskPerRequest)
                            Text("Использовать открытую сессию").tag(MCPAuthPolicy.reuseActiveSession)
                        }
                        .controlSize(.small)

                        Toggle("Разрешать список сервисов через MCP без разблокировки", isOn: Binding(
                            get: { viewModel.settings.allowMCPListWhenLocked },
                            set: { val in
                                var s = viewModel.settings
                                s.allowMCPListWhenLocked = val
                                Task { await viewModel.saveSettings(s) }
                            }
                        ))
                        .font(.caption)

                        Toggle("Блокировать при сне / блокировке экрана Mac", isOn: Binding(
                            get: { viewModel.settings.autoLockOnSleepOrScreenLock },
                            set: { val in
                                var s = viewModel.settings
                                s.autoLockOnSleepOrScreenLock = val
                                Task { await viewModel.saveSettings(s) }
                            }
                        ))
                        .font(.caption)

                        Toggle("Очищать скопированный код из буфера через 30 сек", isOn: Binding(
                            get: { viewModel.settings.autoClearClipboard },
                            set: { val in
                                var s = viewModel.settings
                                s.autoClearClipboard = val
                                Task { await viewModel.saveSettings(s) }
                            }
                        ))
                        .font(.caption)
                    }
                    .padding(6)
                }

                GroupBox("Быстрый PIN (удобно при закрытой крышке MacBook)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(viewModel.isQuickPinSet
                             ? "Быстрый PIN активен (защита от перебора: сброс после 5 ошибок)."
                             : "Позволяет подтверждать выдачу кодов коротким PIN, когда Touch ID недоступен.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            SecureField("Новый PIN (4–12 симв.)", text: $newPin)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)

                            Button(viewModel.isQuickPinSet ? "Сменить" : "Задать") {
                                let pinToSet = newPin
                                newPin = ""
                                Task { _ = await viewModel.setupQuickPin(pinToSet) }
                            }
                            .controlSize(.small)
                            .disabled(newPin.count < 4)

                            if viewModel.isQuickPinSet {
                                Button("Отключить", role: .destructive) {
                                    Task { await viewModel.removeQuickPin() }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Подключение к MCP (Antigravity / Claude / Cursor)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Бинарный мост MCP:")
                            .font(.caption.weight(.semibold))
                        Text(viewModel.resolvedMCPBinaryPath())
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Button {
                            viewModel.copyMCPConfigSnippet()
                        } label: {
                            Label("Скопировать JSON для mcp_config.json", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Зашифрованный бэкап (AES-256-GCM)") {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Мастер-пароль бэкапа (мин. 6 симв.)", text: $backupPassword)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)

                        HStack(spacing: 8) {
                            Button("Экспорт...") {
                                let pwd = backupPassword
                                backupPassword = ""
                                Task { _ = await viewModel.exportBackupInteractive(password: pwd) }
                            }
                            .disabled(backupPassword.count < 6)

                            Button("Импорт...") {
                                let pwd = backupPassword
                                backupPassword = ""
                                Task { _ = await viewModel.importBackupInteractive(password: pwd) }
                            }
                            .disabled(backupPassword.count < 6)
                        }
                        .controlSize(.small)
                    }
                    .padding(6)
                }
            }
            .padding(12)
        }
    }
}
