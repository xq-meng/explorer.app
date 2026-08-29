import AppKit

@MainActor
public enum BrowserPermanentDeleteAlert {
    enum Focus: Equatable, Sendable {
        case cancel
        case delete
    }

    enum Activation: Equatable, Sendable {
        case confirm
        case cancel
    }

    public static func confirm(
        itemCount: Int,
        itemName: String?,
        in window: NSWindow?
    ) async -> Bool {
        let alert = makeAlert(itemCount: itemCount, itemName: itemName)
        let navigation = PermanentDeleteAlertKeyNavigation(alert: alert)
        navigation.install()
        defer { navigation.invalidate() }
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertSecondButtonReturn
    }

    public static func makeAlert(itemCount: Int, itemName: String?) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        if itemCount == 1, let itemName, !itemName.isEmpty {
            alert.messageText = "Permanently delete “\(itemName)”?"
        } else {
            alert.messageText = "Permanently delete \(max(itemCount, 1)) items?"
        }
        alert.informativeText = "This cannot be undone. The items will not be moved to the Trash."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        let cancel = alert.buttons[0]
        let delete = alert.buttons[1]
        delete.hasDestructiveAction = true
        cancel.refusesFirstResponder = false
        delete.refusesFirstResponder = false
        // AppKit will not bind Return to a button titled "Cancel", and it also
        // strips Return from destructive buttons. Bind it explicitly so Enter
        // dismisses with the default (Cancel) action.
        applyFocus(.cancel, to: alert)
        return alert
    }

    nonisolated static func nextFocus(
        current: Focus,
        charactersIgnoringModifiers: String?,
        specialKey: NSEvent.SpecialKey?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Focus? {
        let modifiers = modifiers.intersection([.shift, .command, .option, .control])
        if isTabKey(charactersIgnoringModifiers: charactersIgnoringModifiers, keyCode: keyCode),
           modifiers.isEmpty || modifiers == .shift {
            return current == .cancel ? .delete : .cancel
        }
        guard modifiers.isEmpty else { return nil }
        if specialKey == .leftArrow || keyCode == 123 {
            return .cancel
        }
        if specialKey == .rightArrow || keyCode == 124 {
            return .delete
        }
        return nil
    }

    /// Return confirms the focused button; Escape always cancels. Sheets keep
    /// these even when the file list remains first responder.
    nonisolated static func activation(
        charactersIgnoringModifiers: String?,
        specialKey: NSEvent.SpecialKey?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Activation? {
        let modifiers = modifiers.intersection([.shift, .command, .option, .control])
        guard modifiers.isEmpty else { return nil }
        if isReturnKey(
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            specialKey: specialKey,
            keyCode: keyCode
        ) {
            return .confirm
        }
        if isEscapeKey(charactersIgnoringModifiers: charactersIgnoringModifiers, keyCode: keyCode) {
            return .cancel
        }
        return nil
    }

    /// Sheet key events often arrive with the document window, not the alert.
    nonisolated static func shouldHandleEvent(
        eventWindowID: ObjectIdentifier?,
        alertWindowID: ObjectIdentifier,
        sheetParentID: ObjectIdentifier?
    ) -> Bool {
        eventWindowID == alertWindowID || eventWindowID == sheetParentID
    }

    static func applyFocus(_ focus: Focus, to alert: NSAlert) {
        let cancel = alert.buttons[0]
        let delete = alert.buttons[1]
        let target = focus == .cancel ? cancel : delete
        if let cell = target.cell as? NSButtonCell {
            alert.window.defaultButtonCell = cell
        }
        // defaultButtonCell and hasDestructiveAction can rewrite equivalents.
        cancel.keyEquivalent = focus == .cancel ? "\r" : "\u{1b}"
        delete.keyEquivalent = focus == .delete ? "\r" : ""
        alert.window.makeFirstResponder(target)
    }

    nonisolated private static func isTabKey(charactersIgnoringModifiers: String?, keyCode: UInt16) -> Bool {
        keyCode == 48
            || charactersIgnoringModifiers == "\t"
            || charactersIgnoringModifiers == "\u{19}"
    }

    nonisolated private static func isReturnKey(
        charactersIgnoringModifiers: String?,
        specialKey: NSEvent.SpecialKey?,
        keyCode: UInt16
    ) -> Bool {
        keyCode == 36
            || keyCode == 76
            || charactersIgnoringModifiers == "\r"
            || charactersIgnoringModifiers == "\u{3}"
            || specialKey == .carriageReturn
            || specialKey == .enter
    }

    nonisolated private static func isEscapeKey(charactersIgnoringModifiers: String?, keyCode: UInt16) -> Bool {
        keyCode == 53 || charactersIgnoringModifiers == "\u{1b}"
    }
}

@MainActor
private final class PermanentDeleteAlertKeyNavigation {
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }

    private let alert: NSAlert
    private var focused = BrowserPermanentDeleteAlert.Focus.cancel
    private var monitor: Any?

    init(alert: NSAlert) {
        self.alert = alert
    }

    func install() {
        BrowserPermanentDeleteAlert.applyFocus(focused, to: alert)
        let navigation = Unchecked(value: self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let eventWindowID = event.window.map { ObjectIdentifier($0) }
            let charactersIgnoringModifiers = event.charactersIgnoringModifiers
            let specialKey = event.specialKey
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let consume = MainActor.assumeIsolated {
                navigation.value.handle(
                    eventWindowID: eventWindowID,
                    charactersIgnoringModifiers: charactersIgnoringModifiers,
                    specialKey: specialKey,
                    keyCode: keyCode,
                    modifiers: modifiers
                )
            }
            return consume ? nil : event
        }
    }

    func invalidate() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(
        eventWindowID: ObjectIdentifier?,
        charactersIgnoringModifiers: String?,
        specialKey: NSEvent.SpecialKey?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let parentID = alert.window.sheetParent.map { ObjectIdentifier($0) }
        guard BrowserPermanentDeleteAlert.shouldHandleEvent(
            eventWindowID: eventWindowID,
            alertWindowID: ObjectIdentifier(alert.window),
            sheetParentID: parentID
        ) else { return false }

        if let activation = BrowserPermanentDeleteAlert.activation(
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            specialKey: specialKey,
            keyCode: keyCode,
            modifiers: modifiers
        ) {
            switch activation {
            case .confirm:
                let button = focused == .cancel ? alert.buttons[0] : alert.buttons[1]
                button.performClick(nil)
            case .cancel:
                focused = .cancel
                BrowserPermanentDeleteAlert.applyFocus(.cancel, to: alert)
                alert.buttons[0].performClick(nil)
            }
            return true
        }

        guard let next = BrowserPermanentDeleteAlert.nextFocus(
            current: focused,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            specialKey: specialKey,
            keyCode: keyCode,
            modifiers: modifiers
        ) else {
            return false
        }
        focused = next
        BrowserPermanentDeleteAlert.applyFocus(next, to: alert)
        return true
    }
}
