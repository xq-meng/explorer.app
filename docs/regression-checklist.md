# Release regression checklist

Run this checklist for every preview release. Perform destructive checks only inside a disposable test directory containing generated test data.

## Test record

- Explorer version and build:
- Commit and tag:
- macOS version:
- Mac model and architecture:
- Local filesystem and case sensitivity:
- External, network, or cloud providers tested:
- Tester and date:

## Automated gate

- [ ] The working tree contains only the intended release changes.
- [ ] `CFBundleShortVersionString`, `CFBundleVersion`, and the release tag are consistent.
- [ ] `swift test -Xswiftc -warnings-as-errors` passes.
- [ ] `swift build -c release -Xswiftc -warnings-as-errors` passes.
- [ ] `./scripts/package-app.sh` produces `.build/artifacts/Explorer.app`.
- [ ] `plutil -lint .build/artifacts/Explorer.app/Contents/Info.plist` passes.
- [ ] `codesign --verify --deep --strict .build/artifacts/Explorer.app` passes.
- [ ] The packaged binary and archive architecture match the advertised release architecture.
- [ ] Documentation links resolve and the [known issues](known-issues.md) match the release.

## Launch and navigation

- [ ] Launching normally opens My Computer without an empty or white content area.
- [ ] My Computer shows Favorites, mounted volumes, capacity information, and available network locations.
- [ ] Favorites, volumes, and network tiles on My Computer support the same location context menu as the sidebar and route actions to the active pane.
- [ ] Sidebar shortcuts open their locations without expanding as a directory tree.
- [ ] The window has one shared sidebar outside the pane split; its shortcuts navigate only the active pane.
- [ ] Back, Forward, Up, Refresh, breadcrumbs, and Command-L path entry navigate correctly.
- [ ] Opening one or more folders through Finder or Launch Services creates the expected tabs.
- [ ] New windows and tabs start with one pane and have independent paths, histories, and selections.
- [ ] Command-Backslash toggles dual-pane mode; Command-Shift-Backslash switches the highlighted active pane without changing either path.
- [ ] The split-view button beside Details/Icons opens a second pane; clicking it in either pane closes the split and keeps that pane.
- [ ] Every newly opened split starts with equal-width left and right panes; dragging the divider still resizes them normally.
- [ ] Clicking either pane's toolbar, address bar, file area, preview, or empty background moves the subtle active-pane indicator and command routing to that pane.
- [ ] Each pane keeps independent navigation, sorting, search, and selection; closing the split retains the active pane.
- [ ] Relaunch starts with one pane even if the previous window was using dual-pane mode.
- [ ] Closing tabs, closing the final tab, and quitting the app do not crash.
- [ ] Closing a tab/window or quitting during an operation defaults to keeping Explorer open; confirming cancellation waits for the queue to stop.

## Views and selection

- [ ] Details and Icons views show the same items and preserve selection when switching.
- [ ] Name, Size, Modified, and Kind sorting work in both ascending and descending order.
- [ ] Hidden Files and Preview Pane menu items show the correct checkmarks and update every open tab.
- [ ] The preview divider disappears when the preview pane is hidden and returns at a usable width.
- [ ] Single selection, multiple selection, Select All, keyboard navigation, and context-click targeting work.
- [ ] Cut and hidden items are visually dimmed without losing hover, selection, or drop feedback.
- [ ] Cloud-only items show their cloud badge without changing the row layout.

## Search and preview

- [ ] Search finds immediate and nested matches in the current folder tree.
- [ ] Clearing search restores the directory contents and valid selection.
- [ ] Navigating or closing a tab during search does not display stale results.
- [ ] Space opens and closes Quick Look for the current selection.
- [ ] The preview pane updates when selection changes and handles unsupported files gracefully.
- [ ] Rapid icon-view scrolling does not accumulate thumbnails for offscreen items.

## File operations

- [ ] Backspace navigates to the previous location without mutating the selection.
- [ ] New Folder creates a folder and begins inline rename.
- [ ] Rename, Copy, Cut, Paste, Duplicate, and internal drag and drop operate on the intended items and destination.
- [ ] F5 copies and F6 moves the active pane selection to the other pane, with conflicts and progress handled by the normal operation queue.
- [ ] Same-name conflicts exercise Replace, Keep Both, Skip, Stop, and Apply to All.
- [ ] A failed replacement restores the original destination.
- [ ] Simulated `backupCreated` recovery restores the original destination, and simulated `replacementCompleted` recovery keeps the replacement and removes its backup.
- [ ] Cancelling or failing a copy removes its exact `.explorer-stage-*` partial item and never exposes a partial requested destination.
- [ ] Simulated recovery before staged-copy commit discards the temporary item; recovery after the atomic commit keeps the complete destination.
- [ ] A replacement rename interrupted after its source move keeps the new destination; interruption before that move restores the old destination without removing the source.
- [ ] Cross-volume move recovery removes an unchanged regular-file or folder source only after validating the committed destination; a source whose file or descendant metadata changed is preserved.
- [ ] Corrupt or unavailable recovery records are retained and reported instead of discarded.
- [ ] A cross-volume move copies successfully before removing the source.
- [ ] The operation footer shows queued/running progress and Cancel stops the selected operation safely.
- [ ] After cancellation completes, closing the operation's window does not leave an active or hidden operation.
- [ ] Undo and Redo round-trip supported create, rename, copy, move, duplicate, and Trash operations.
- [ ] Delete moves items to the Trash.
- [ ] Shift-Delete defaults to Cancel; confirming permanently removes only the selected disposable test items.
- [ ] Permission errors, missing sources, read-only destinations, and unavailable volumes produce understandable errors without silent overwrite.

## External integration

- [ ] Creating, renaming, and deleting an item in Finder refreshes the current Explorer folder.
- [ ] Concurrent Finder and Explorer mutations complete through file coordination or produce a clear error without silent overwrite.
- [ ] Dragging file URLs to and from Finder works with expected copy/move behavior and Option-key override.
- [ ] At least one file-promise source, such as Mail or Safari, can drop into a disposable directory.
- [ ] Mounting and unmounting an external or network volume refreshes My Computer and the sidebar.
- [ ] If available, browse, search, preview, copy, and rename an iCloud item, including one initially cloud-only.

## Appearance and accessibility

- [ ] Light and Dark appearances remain readable with no clipped controls.
- [ ] Full Keyboard Access can reach the toolbar, path field, sidebar, file view, preview, and confirmation dialogs.
- [ ] VoiceOver announces navigation controls, folder contents, selection, operation progress, and destructive confirmations.
- [ ] Window resizing and full screen keep the tab strip, sidebar, content, and preview usable.

## Release publication

- [ ] The GitHub Actions CI run passes for the release commit.
- [ ] The release workflow publishes the expected prerelease archive.
- [ ] The GitHub asset version and SHA-256 match the Homebrew Cask.
- [ ] Installing or upgrading through Homebrew launches the published build after following the documented quarantine step.
- [ ] Release notes link to the current [known issues](known-issues.md).

## Stop-ship conditions

Do not publish when any of the following is reproducible:

- Silent overwrite, data loss, deletion of an unintended item, or removal of a move source before its copy completes.
- A crash or hang in launch, navigation, preview, conflict handling, or a supported file operation.
- Stale asynchronous results appearing in the wrong folder or tab.
- Failure of the automated gate, package signature verification, or release/Homebrew checksum synchronization.
