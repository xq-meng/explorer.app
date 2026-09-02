# Known issues

This document tracks user-visible limitations in the current Explorer.app preview. It is not a complete product backlog. Data-safety issues and release blockers take priority over convenience features.

## Distribution

- Prebuilt releases support Apple Silicon and require macOS 14 or later. Intel Macs must build from source.
- Release bundles are ad-hoc signed and are not notarized. Gatekeeper may quarantine the downloaded app; follow the quarantine instructions in the [README](../README.md#homebrew).
- There is no in-app updater. Homebrew and GitHub Release installations must be updated manually.

## File operations

- The operation queue and Undo/Redo history are held in memory per window tab. Closing that tab or quitting Explorer discards its history.
- Closing a tab or window, or quitting while an operation is running, now requires either keeping Explorer open or cancelling and waiting for the operation to stop.
- Copy and duplicate operations write to a hidden sibling first and expose the requested destination only after the staged item is complete. Interrupted partial stages are removed on launch; an already committed copy is retained.
- Replacement and move operations use identity-checked write-ahead recovery records. On launch, Explorer restores an uncommitted original destination or finishes a committed transfer without guessing from path names alone. Recovery records that cannot be processed safely are retained and reported.
- After an interrupted cross-volume move, Explorer removes the source only when its filesystem identity and recursive metadata signature still match the completed copy. If the source changed or cannot be verified, the complete destination and source are both preserved for manual review.
- Recovery protects against an app crash or forced quit, but it is not a full sudden-power-loss durability guarantee: copied data and journal updates are not recursively flushed to stable storage before the source is removed. Identity checks use filesystem metadata rather than a content hash, so deliberately preserving all checked metadata while changing bytes is outside this preview's guarantees.
- File mutations use `NSFileCoordinator`, but another client can still change or remove an item between separate operations in a batch. Explorer reports the resulting failure rather than silently overwriting.
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
