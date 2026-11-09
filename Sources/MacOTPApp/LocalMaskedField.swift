import AppKit
import SwiftUI

/// Lightweight native masked input that never instantiates `NSSecureTextField`, preventing macOS
/// from spawning the `SafariPlatformSupport.Helper` ("Заполнить автоматически") XPC process.
struct LocalMaskedField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var autoFocus: Bool = false
    var onSubmit: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    func makeNSView(context: Context) -> MaskedInputNSView {
        let view = MaskedInputNSView()
        view.placeholder = placeholder
        view.text = text
        view.onTextChanged = { updated in
            if text != updated {
                text = updated
            }
        }
        view.onSubmit = onSubmit
        view.onCancel = onCancel

        if autoFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
        return view
    }

    func updateNSView(_ nsView: MaskedInputNSView, context: Context) {
        nsView.placeholder = placeholder
        if nsView.text != text {
            nsView.text = text
            nsView.needsDisplay = true
        }
        nsView.onSubmit = onSubmit
        nsView.onCancel = onCancel
    }
}

final class MaskedInputNSView: NSView {
    var placeholder: String = "" {
        didSet { if oldValue != placeholder { needsDisplay = true } }
    }
    var text: String = "" {
        didSet { if oldValue != text { needsDisplay = true } }
    }
    var onTextChanged: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    private var selectAllActive: Bool = false

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .exterior }
        set {}
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }

    override func drawFocusRingMask() {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        path.fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selectAllActive = false
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        selectAllActive = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        bgPath.fill()

        NSColor.separatorColor.setStroke()
        bgPath.lineWidth = 1
        bgPath.stroke()

        let isEmpty = text.isEmpty
        let displayString = isEmpty ? placeholder : String(repeating: "•", count: text.count)
        let font = isEmpty
            ? NSFont.systemFont(ofSize: 12)
            : NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let color = isEmpty
            ? NSColor.placeholderTextColor
            : (selectAllActive ? NSColor.selectedMenuItemTextColor : NSColor.labelColor)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrStr = NSAttributedString(string: displayString, attributes: attrs)
        let strSize = attrStr.size()
        let textRect = NSRect(
            x: 8,
            y: floor((bounds.height - strSize.height) / 2.0),
            width: max(0, bounds.width - 16),
            height: strSize.height
        )

        if !isEmpty && selectAllActive {
            let highlightRect = NSRect(
                x: 6,
                y: textRect.minY - 1,
                width: min(strSize.width + 4, bounds.width - 12),
                height: strSize.height + 2
            )
            NSColor.selectedTextBackgroundColor.setFill()
            NSBezierPath(roundedRect: highlightRect, xRadius: 3, yRadius: 3).fill()
        }

        attrStr.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "v":
                if let pasted = NSPasteboard.general.string(forType: .string) {
                    let clean = pasted.filter { !$0.isNewline }
                    if selectAllActive {
                        text = clean
                        selectAllActive = false
                    } else {
                        text.append(clean)
                    }
                    onTextChanged?(text)
                }
                return true
            case "a":
                if !text.isEmpty {
                    selectAllActive = true
                    needsDisplay = true
                }
                return true
            case "c", "x":
                // Never allow copying/cutting masked secrets
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 36, 76: // Return / Enter
            selectAllActive = false
            onSubmit?()
            return
        case 53: // Escape
            selectAllActive = false
            onCancel?()
            return
        case 51: // Delete / Backspace
            if flags.contains(.command) || selectAllActive {
                text = ""
                selectAllActive = false
            } else if !text.isEmpty {
                text.removeLast()
            }
            onTextChanged?(text)
            return
        case 48: // Tab
            if flags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        default:
            break
        }

        guard let chars = event.characters, !chars.isEmpty else { return }
        let printable = chars.filter { ch in
            guard let scalar = ch.unicodeScalars.first else { return false }
            return !CharacterSet.controlCharacters.contains(scalar)
        }
        guard !printable.isEmpty else { return }

        if selectAllActive {
            text = printable
            selectAllActive = false
        } else {
            text.append(printable)
        }
        onTextChanged?(text)
    }
}
