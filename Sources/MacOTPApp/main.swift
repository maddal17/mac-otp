import AppKit
import Foundation
import MacOTPCore
import SwiftUI

@MainActor
final class MacOTPAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var viewModel: AppViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let socketPath = ProcessInfo.processInfo.environment["MACOTP_SOCKET_PATH"]
            ?? UnixDomainSocketServer.defaultSocketPath

        // Prevent duplicate daemon instances
        if UnixDomainSocketClient.isDaemonAlive(socketPath: socketPath) {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        installStandardEditMenu()

        do {
            let vm = try AppViewModel()
            self.viewModel = vm

            vm.authCoordinator.isPopoverCurrentlyShown = { [weak self] in
                self?.popover.isShown ?? false
            }
            vm.onLockStateChanged = { [weak self] unlocked in
                self?.updateStatusIcon(unlocked: unlocked)
            }
            vm.onTemporarilyHidePopover = { [weak self] in
                self?.popover.performClose(nil)
            }
            vm.onRestorePopover = { [weak self] in
                self?.showPopover()
            }

            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 390, height: 520)
            popover.contentViewController = NSHostingController(rootView: MenuBarRootView(viewModel: vm))

            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.action = #selector(togglePopover(_:))
                button.target = self
            }
            self.statusItem = item
            updateStatusIcon(unlocked: false)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Ошибка запуска MacOTP"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.shutdown()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusIcon(unlocked: Bool) {
        guard let button = statusItem?.button else { return }
        let symbolName = unlocked ? "checkmark.shield.fill" : "lock.shield"
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MacOTP")
        img?.isTemplate = true
        button.image = img
        button.toolTip = unlocked ? "MacOTP (Разблокировано)" : "MacOTP (Заблокировано)"
    }

    /// Ensures Cmd+C / Cmd+V / Cmd+X / Cmd+A work inside all SwiftUI text fields in an accessory app.
    private func installStandardEditMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MacOTP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = MacOTPAppDelegate()
app.delegate = delegate
app.run()
