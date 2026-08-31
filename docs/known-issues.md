# Known issues

This document tracks user-visible limitations in the current Explorer.app preview. It is not a complete product backlog. Data-safety issues and release blockers take priority over convenience features.

## Distribution

- Prebuilt releases support Apple Silicon and require macOS 14 or later. Intel Macs must build from source.
- Release bundles are ad-hoc signed and are not notarized. Gatekeeper may quarantine the downloaded app; follow the quarantine instructions in the [README](../README.md#homebrew).
- There is no in-app updater. Homebrew and GitHub Release installations must be updated manually.

## File operations

- The operation queue and Undo/Redo history are held in memory per window tab. Closing that tab or quitting Explorer discards its history.
- Closing a tab or window, or quitting while an operation is running, is not yet guarded by a confirmation or recovery workflow. Cancel the operation and wait for it to stop before closing Explorer.
- A crash or forced quit during a copy, move, or replacement can leave a partial destination or a hidden `.explorer-replace-*` recovery item beside the destination. Explorer does not yet scan for or recover these artifacts at launch.
- File mutations do not yet use `NSFileCoordinator`. Concurrent changes from another Explorer window, Finder, document apps, iCloud, or other File Provider clients can race with an operation.
- Replacement operations and permanent deletion are intentionally not undoable. Shift-Delete permanently removes selected items after confirmation.
- A batch can complete partially when a later item fails. The footer reports the result, but there is not yet a persistent operation-details view.

Keep a separate backup of important data while using preview builds. Do not test destructive operations on the only copy of a file.

## Browsing and state restoration

- Directory loading currently builds and sorts a complete snapshot before showing it. The 100,000-item performance target has not been validated, and very large or slow directories may take noticeable time.
- Explorer restores the window frame, sidebar width, global view mode, preview visibility, hidden-file setting, and Favorites. It does not restore open windows and tabs, the selected tab, per-tab history and sorting, selection, or scroll position.
- External directory changes trigger a delayed full refresh. Selection is preserved when possible, but scroll position can move after a refresh or a high-frequency change burst.
- The sidebar is a list of location shortcuts, not an expandable directory tree. Network does not discover remote servers; mounted network volumes appear with other mounted volumes.

## Search, cloud files, and drag and drop

- Search is limited to 1,000 results. It uses Spotlight when available and recursively enumerates the current folder tree when Spotlight is unavailable or returns no matches.
- iCloud and third-party File Provider placeholders are not proactively downloaded. Opening, previewing, or operating on a cloud-only item depends on the provider and current network state.
- File URL drag and drop and AppKit file promises are implemented, but the Finder, Mail, Safari, Photos, SMB, and third-party File Provider compatibility matrix is not complete.

## Accessibility and localization

- The interface is currently English-only and does not include localization resources.
- Core controls have accessibility labels and status announcements, but a complete VoiceOver, Full Keyboard Access, high-contrast, and reduced-motion audit has not been completed.

Before publishing a preview, use the [regression checklist](regression-checklist.md). When reporting a problem, include the Explorer version, macOS version, storage/provider type, the operation being performed, and whether another app was accessing the same files.
