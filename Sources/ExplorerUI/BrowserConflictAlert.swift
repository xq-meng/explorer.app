import AppKit

@MainActor
public enum BrowserConflictAlert {
    public static func present(
        prompt: BrowserConflictPrompt,
        in window: NSWindow?
    ) async -> BrowserConflictDecision {
        let (alert, applyToAllButton) = makeAlert(prompt: prompt)
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return decision(from: response, applyToAll: applyToAllButton.state == .on)
    }

    public static func makeAlert(prompt: BrowserConflictPrompt) -> (NSAlert, NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(prompt.destinationName)” already exists in “\(prompt.destinationFolder)”."
        alert.informativeText = informativeText(for: prompt)
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Stop")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[3].keyEquivalent = "\u{1b}"
        alert.buttons[2].hasDestructiveAction = true

        let applyToAll = NSButton(
            checkboxWithTitle: applyToAllTitle(remainingItemCount: prompt.remainingItemCount),
            target: nil,
            action: nil
        )
        applyToAll.setAccessibilityLabel("Apply this choice to all remaining items")
        if prompt.remainingItemCount > 0 {
            applyToAll.frame.size = applyToAll.fittingSize
            alert.accessoryView = applyToAll
        }
        return (alert, applyToAll)
    }

    public static func decision(
        from response: NSApplication.ModalResponse,
        applyToAll: Bool
    ) -> BrowserConflictDecision {
        let choice: BrowserConflictChoice
        switch response {
        case .alertFirstButtonReturn: choice = .keepBoth
        case .alertSecondButtonReturn: choice = .skip
        case .alertThirdButtonReturn: choice = .replace
        default: choice = .stop
        }
        return BrowserConflictDecision(choice: choice, applyToAll: applyToAll && choice != .stop)
    }

    private static func informativeText(for prompt: BrowserConflictPrompt) -> String {
        var text = "\(prompt.operationTitle) cannot use that name without replacing the existing item, keeping both files, or skipping “\(prompt.sourceName)”."
        if prompt.remainingItemCount > 0 {
            let itemLabel = prompt.remainingItemCount == 1 ? "item remains" : "items remain"
            text += " \(prompt.remainingItemCount) more \(itemLabel) in this operation."
        }
        return text
    }

    private static func applyToAllTitle(remainingItemCount: Int) -> String {
        remainingItemCount == 1
            ? "Do this for the remaining item"
            : "Do this for all remaining items"
    }
}
