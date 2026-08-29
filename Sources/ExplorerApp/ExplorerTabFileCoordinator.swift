import AppKit
import ExplorerOperations
import ExplorerUI
import Foundation

@MainActor
final class ExplorerTabFileCoordinator {
    weak var host: ExplorerTabFileWorking?

    func perform(_ command: BrowserFileCommand) {
        guard let host, host.canPerformFileCommand(command) else { return }
        switch command {
        case .open:
            openSelection()
        case .openInNewTab:
            host.selectedRows.filter(\.isNavigable).forEach {
                host.emit(.openLocationInNewTab(.directory($0.url)))
            }
        case let .openWith(applicationURL):
            openSelection(with: applicationURL)
        case .revealInFinder:
            let urls = host.selection.isEmpty
                ? [host.currentDirectoryURL].compactMap { $0 }
                : Array(host.selection)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .copyPath:
            copyPaths(
                host.selection.isEmpty
                    ? [host.currentDirectoryURL].compactMap { $0 }
                    : Array(host.selection)
            )
        case .addToFavorites:
            guard let url = host.favoriteURLToAdd() else { return }
            host.emit(.addFavorite(url))
        case .newFolder:
            guard let currentDirectoryURL = host.currentDirectoryURL else { return }
            createNewFolder(in: currentDirectoryURL)
        case .rename:
            guard let source = host.selection.first else { return }
            if host.viewMode != .details { host.setViewMode(.details) }
            host.beginRenaming(source)
        case .copy:
            writeClipboard(intent: .copy)
        case .cut:
            writeClipboard(intent: .cut)
        case .paste:
            pasteClipboardContents()
        case .duplicate:
            guard let currentDirectoryURL = host.currentDirectoryURL else { return }
            for source in host.selection {
                host.submit(
                    .duplicate(source: source, to: currentDirectoryURL, conflictPolicy: .keepBoth),
                    completion: nil,
                    finished: nil
                )
            }
        case .moveToTrash:
            host.submit(.trash(sources: Array(host.selection)), completion: nil, finished: nil)
        case .deletePermanently:
            let urls = Array(host.selection)
            Task { [weak self] in
                await self?.confirmAndDelete(urls)
            }
        case .quickLook:
            host.toggleQuickLook()
        }
    }

    func open(_ row: BrowserFileRow) {
        guard let host else { return }
        if row.isNavigable {
            host.request(.directory(row.url), origin: .newLocation)
            return
        }
        if !NSWorkspace.shared.open(row.url) {
            host.showStatus("Unable to open \(row.name) with its default application.")
        }
    }

    func createNewFolder(in parentURL: URL) {
        guard let host else { return }
        let parent = parentURL.standardizedFileURL
        host.submit(.createFolder(at: parent, name: "New Folder", conflictPolicy: .keepBoth), completion: { [weak host] result in
            guard let host,
                  let destination = result.items.first(where: { $0.status == .completed })?.destination else { return }
            host.loadSidebarChildren(of: parent)
            guard host.currentDirectoryURL == parent else { return }
            host.selection = [destination]
            host.pendingInlineRenameURL = destination
        }, finished: nil)
    }

    func copyPaths(_ urls: [URL]) {
        guard let host else { return }
        let paths = urls.map(\.path).joined(separator: "\n")
        guard !paths.isEmpty else { return }
        NSPasteboard.general.setString(paths, forType: .string)
        let noun = urls.count == 1 ? "path" : "paths"
        host.showStatus("Copied \(urls.count) \(noun).")
    }

    func accept(_ drop: BrowserFileDrop) -> Bool {
        guard let host else { return false }
        guard let destination = drop.destinationURL ?? host.currentDirectoryURL else { return false }
        guard !drop.urls.contains(where: { source in
            let sourcePath = source.standardizedFileURL.path
            let destinationPath = destination.standardizedFileURL.path
            return destinationPath.hasPrefix(sourcePath + "/")
        }) else {
            host.showStatus("Cannot drop a folder into one of its descendants.")
            return false
        }
        let operation: FileOperation
        switch drop.intent {
        case .copy:
            operation = .copy(sources: drop.urls, to: destination, conflictPolicy: .ask)
        case .move:
            operation = .move(sources: drop.urls, to: destination, conflictPolicy: .ask)
        }
        host.submit(operation, completion: nil, finished: nil)
        return true
    }

    func accept(_ drop: BrowserPromisedFileDrop) -> Bool {
        guard let host else { return false }
        guard let destination = drop.destinationURL ?? host.currentDirectoryURL else { return false }
        guard !drop.receivers.isEmpty else { return false }
        let staging: URL
        do {
            staging = try FilePromiseDropCoordinator.makeStagingDirectory()
        } catch {
            host.showStatus(error.localizedDescription)
            return false
        }

        let receivers = drop.receivers
        let queue = host.filePromiseQueue
        host.showStatus("Receiving dropped files…")
        Task { [weak host] in
            do {
                let urls = try await FilePromiseDropCoordinator.receivePromisedFiles(
                    receivers,
                    into: staging,
                    operationQueue: queue
                )
                guard let host else {
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
                guard !urls.isEmpty else {
                    host.showStatus(FilePromiseDropError.empty.localizedDescription)
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
                host.submit(
                    .move(sources: urls, to: destination, conflictPolicy: .ask),
                    completion: nil,
                    finished: { try? FileManager.default.removeItem(at: staging) }
                )
            } catch {
                host?.showStatus(error.localizedDescription)
                try? FileManager.default.removeItem(at: staging)
            }
        }
        return true
    }

    func writeClipboard(intent: FileClipboardIntent) {
        guard let host else { return }
        do {
            switch intent {
            case .copy: try host.clipboard.copy(Array(host.selection))
            case .cut: try host.clipboard.cut(Array(host.selection))
            }
            host.showStatus(
                "\(host.selection.count) \(host.selection.count == 1 ? "item" : "items") \(intent == .copy ? "copied" : "cut")."
            )
        } catch {
            host.showStatus(error.localizedDescription)
        }
    }

    func pasteClipboardContents() {
        guard let host, let currentDirectoryURL = host.currentDirectoryURL,
              let contents = host.clipboard.read() else { return }
        let operation: FileOperation
        switch contents.intent {
        case .copy:
            operation = .copy(sources: contents.urls, to: currentDirectoryURL, conflictPolicy: .ask)
        case .cut:
            operation = .move(sources: contents.urls, to: currentDirectoryURL, conflictPolicy: .ask)
        }
        host.submit(operation, completion: nil, finished: nil)
    }

    func synchronizeCutPresentation() {
        guard let host else { return }
        guard let contents = host.clipboard.read(), contents.intent == .cut else {
            host.setCutURLs([])
            return
        }
        host.setCutURLs(Set(contents.urls))
    }

    private func openSelection() {
        guard let host else { return }
        let rows = host.selectedRows
        if rows.count == 1, let row = rows.first {
            open(row)
            return
        }
        for row in rows {
            if row.isNavigable {
                host.emit(.openLocationInNewTab(.directory(row.url)))
            } else if !NSWorkspace.shared.open(row.url) {
                host.showStatus("Unable to open \(row.name) with its default application.")
            }
        }
    }

    private func openSelection(with applicationURL: URL) {
        guard let host else { return }
        let urls = host.selectedRows.map(\.url)
        guard !urls.isEmpty else { return }
        Task { [weak host] in
            do {
                _ = try await NSWorkspace.shared.open(
                    urls,
                    withApplicationAt: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                host?.showStatus(
                    "Unable to open with \(applicationURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    private func confirmAndDelete(_ urls: [URL]) async {
        guard let host, !urls.isEmpty else { return }
        let confirmed = await BrowserPermanentDeleteAlert.confirm(
            itemCount: urls.count,
            itemName: urls.count == 1 ? urls[0].lastPathComponent : nil,
            in: host.hostWindow
        )
        guard confirmed else { return }
        host.submit(.delete(sources: urls), completion: nil, finished: nil)
    }
}
