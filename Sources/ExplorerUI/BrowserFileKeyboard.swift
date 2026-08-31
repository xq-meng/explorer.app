import AppKit

enum BrowserKeyboardCommand: Equatable {
    case navigation(BrowserNavigationCommand)
    case file(BrowserFileCommand)
}

enum BrowserFileKeyboard {
    static func command(from event: NSEvent) -> BrowserKeyboardCommand? {
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
    ) -> BrowserKeyboardCommand? {
        let modifiers = modifiers.intersection([.shift, .command, .option, .control])
        if charactersIgnoringModifiers == " ", modifiers.isEmpty {
            return .file(.quickLook)
        }

        switch deleteKey(charactersIgnoringModifiers: charactersIgnoringModifiers, specialKey: specialKey) {
        case .backward where modifiers.isEmpty:
            return .navigation(.back)
        case .forward where modifiers.isDisjoint(with: [.command, .option, .control]):
            return .file(modifiers.contains(.shift) ? .deletePermanently : .moveToTrash)
        default:
            return nil
        }
    }

    private static func deleteKey(
        charactersIgnoringModifiers: String?,
        specialKey: NSEvent.SpecialKey?
    ) -> DeleteKey? {
        switch specialKey {
        case .delete:
            return .backward
        case .deleteForward:
            return .forward
        default:
            switch charactersIgnoringModifiers {
            case "\u{8}", "\u{7F}": return .backward
            case "\u{F728}": return .forward
            default: return nil
            }
        }
    }

    private enum DeleteKey {
        case backward
        case forward
    }
}

final class BrowserFileTableView: NSTableView {
    var onKeyboardCommand: ((BrowserKeyboardCommand) -> Void)?

    override func keyDown(with event: NSEvent) {
        if let command = BrowserFileKeyboard.command(from: event) {
            onKeyboardCommand?(command)
            return
        }
        super.keyDown(with: event)
    }
}
