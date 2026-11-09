import AppKit
import Foundation
import LocalAuthentication
import MacOTPCore
import SwiftUI

@MainActor
final class NativeAuthCoordinator {
    private let vault: VaultStore
    var isPopoverCurrentlyShown: () -> Bool = { false }

    init(vault: VaultStore) {
        self.vault = vault
    }

    func verifyUserPresence(_ request: AuthChallengeRequest) async -> Bool {
        let previousApp = NSWorkspace.shared.frontmostApplication
        let popoverOpen = isPopoverCurrentlyShown()

        defer {
            if !popoverOpen, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp.activate()
            }
        }

        let bioCheckContext = LAContext()
        var bioError: NSError?
        let touchIDReady = bioCheckContext.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &bioError
        )
        let hasQuickPin = await vault.isQuickPinConfigured()

        // In closed clamshell mode (Touch ID unavailable), prefer Quick PIN HUD if configured,
        // with one-click fallback to macOS System Authentication.
        if !touchIDReady && hasQuickPin {
            let hudOutcome = await presentQuickPinHUD(request: request)
            switch hudOutcome {
            case .approved:
                return true
            case .denied:
                return false
            case .fallbackToSystemAuth:
                return await evaluateSystemOwnerAuth(reason: request.reason)
            }
        }

        return await evaluateSystemOwnerAuth(reason: request.reason)
    }

    func evaluateSystemOwnerAuth(reason: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let context = LAContext()
        context.localizedCancelTitle = "Отклонить"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Floating Quick PIN Authorization HUD

    private enum PinHUDOutcome {
        case approved
        case denied
        case fallbackToSystemAuth
    }

    private func presentQuickPinHUD(request: AuthChallengeRequest) async -> PinHUDOutcome {
        NSApp.activate(ignoringOtherApps: true)

        return await withCheckedContinuation { continuation in
            let panel = KeyableFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 230),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .modalPanel
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true

            var didResolve = false
            let finish: @MainActor (PinHUDOutcome) -> Void = { outcome in
                guard !didResolve else { return }
                didResolve = true
                panel.orderOut(nil)
                panel.close()
                continuation.resume(returning: outcome)
            }

            let rootView = QuickPinHUDView(
                request: request,
                vault: vault,
                onApproved: { finish(.approved) },
                onDenied: { finish(.denied) },
                onSystemFallback: { finish(.fallbackToSystemAuth) }
            )

            panel.contentView = NSHostingView(rootView: rootView)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

private final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct QuickPinHUDView: View {
    let request: AuthChallengeRequest
    let vault: VaultStore
    let onApproved: @MainActor () -> Void
    let onDenied: @MainActor () -> Void
    let onSystemFallback: @MainActor () -> Void

    @State private var pin: String = ""
    @State private var errorMessage: String?
    @State private var isVerifying: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: request.channel == .mcp ? "cpu.fill" : "lock.shield.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(request.channel == .mcp ? Color.orange : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(request.channel == .mcp ? "Подтверждение запроса MCP" : "Разблокировка MacOTP")
                        .font(.headline)
                    if let service = request.serviceLabel {
                        Text(service)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text(request.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }

            LocalMaskedField(
                placeholder: "Введите быстрый PIN",
                text: $pin,
                autoFocus: true,
                onSubmit: { submitPin() },
                onCancel: { onDenied() }
            )
            .frame(height: 28)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("Touch ID недоступен (крышка закрыта). Введите PIN или используйте пароль macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button("Пароль macOS") {
                    onSystemFallback()
                }
                .buttonStyle(.link)
                .font(.caption)

                Spacer()

                Button("Отклонить") {
                    onDenied()
                }
                .keyboardShortcut(.cancelAction)

                Button("Подтвердить") {
                    submitPin()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pin.isEmpty || isVerifying)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submitPin() {
        guard !pin.isEmpty, !isVerifying else { return }
        isVerifying = true
        let entered = pin
        Task { @MainActor in
            do {
                try await vault.verifyQuickPin(entered)
                onApproved()
            } catch let storeErr as VaultStoreError where storeErr == .quickPinLockedOut {
                isVerifying = false
                onSystemFallback()
            } catch {
                pin = ""
                errorMessage = error.localizedDescription
                isVerifying = false
            }
        }
    }
}
