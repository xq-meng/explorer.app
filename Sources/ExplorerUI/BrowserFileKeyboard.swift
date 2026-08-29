import AppKit

enum BrowserFileKeyboard {
    static func command(from event: NSEvent) -> BrowserFileCommand? {
        command(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            specialKey: event.specialKey,
            modifiers: event.modifierFlags
        )
    }

    static func command(
        charactersIgnoringModifiers: String?,
        specialKey: NSEvent.SpecialKey?,
        modifiers: NSEvent.ModifierFlags
    ) -> BrowserFileCommand? {
        let modifiers = modifiers.intersection([.shift, .command, .option, .control])
        guard isDeleteKey(charactersIgnoringModifiers: charactersIgnoringModifiers, specialKey: specialKey),
              modifiers.isDisjoint(with: [.command, .option, .control]) else {
            return nil
        }
        return modifiers.contains(.shift) ? .deletePermanently : .moveToTrash
    }

    private static func isDeleteKey(
        charactersIgnoringModifiers: String?,
        specialKey: NSEvent.SpecialKey?
    ) -> Bool {
        if specialKey == .delete || specialKey == .deleteForward {
            return true
        }
        return charactersIgnoringModifiers == "\u{7F}" || charactersIgnoringModifiers == "\u{F728}"
    }
}

final class BrowserFileTableView: NSTableView {
    var onFileKeyCommand: ((BrowserFileCommand) -> Void)?

    override func keyDown(with event: NSEvent) {
        if let command = BrowserFileKeyboard.command(from: event) {
            onFileKeyCommand?(command)
            return
        }
        super.keyDown(with: event)
    }
}
