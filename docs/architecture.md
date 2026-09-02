# Architecture

Explorer.app is an AppKit application with actor-backed browsing and file-operation modules. The interface direction is informed by [ronhash10/MacExplorer](https://github.com/ronhash10/MacExplorer), an MIT-licensed SwiftUI project. That repository is a product reference only; it is not vendored as a source dependency.

```text
ExplorerApp         Lifecycle, dependency composition, tabs, and persisted state
├── ExplorerUI      Presentation-only AppKit views and browser commands
├── ExplorerBrowsing  Directory loading, search, volumes, monitoring, thumbnails
│   └── ExplorerCore  Sendable filesystem models and provider contracts
└── ExplorerOperations  Mutations, queue, clipboard, conflict safety, Undo plans
```

`ExplorerUI` has no dependency on filesystem modules. `ExplorerApp` is the only composition root. Browsing and operation actors run blocking work away from the main actor and publish immutable results for the app to map into presentation data.

## Safety principles

- Never overwrite a destination silently.
- Coordinate mutations with other macOS file clients through `NSFileCoordinator`.
- Journal replacement phases before moving the existing destination, then
  restore or finalize the transaction on the next launch after interruption.
- Copy into a hidden sibling and journal its filesystem identity before an
  atomic destination commit; cross-volume moves remove their source only after
  the committed destination and unchanged source have been verified.
- Run Undo/Redo through the same conflict validation; replacement operations are intentionally not recorded as undoable.
- Move across volumes by copying successfully before removing the source.
- Send normal deletion to the Trash.
- Compose two independent tab sessions for dual-pane browsing. Window-level
  command routing follows the highlighted active pane, while F5/F6 transfers
  target the other pane through the shared safe operation queue.
- Keep Favorites, volumes, and network locations in one window-level sidebar
  outside the pane split. Sidebar actions route to the active session, so the
  two file panes remain structurally equal.
- Keep the dual-pane snapshot format and validation boundary versioned for
  explicit restoration flows. Normal window and tab creation deliberately
  starts with one pane and does not consume a previously saved split session.
- Keep long-running I/O cancellable and off the main thread.
- Treat filesystem notifications as invalidation signals and verify disk state again.
- Do not use path strings as the sole identity of a file.
