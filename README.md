# Explorer.app

Explorer.app is a native macOS file manager that combines the navigation and productivity model of Windows Explorer with macOS system conventions and frameworks.

The project is in active development. See [ROADMAP.md](ROADMAP.md) for scope, milestones, quality gates, and planned releases.

## Current prototype

The current implementation provides:

- an AppKit application shell with independent tabs and navigation history;
- asynchronous local directory browsing, mounted volumes, details and icon views;
- visible-item Quick Look thumbnails with cancellation and a bounded memory cache;
- a lazy folder tree that follows navigation, clickable/editable breadcrumbs, and `Command-L` address entry;
- current-folder search, directory change monitoring, an embedded/toggleable Quick Look pane, and file URL drag/drop;
- an Explorer-style status bar with item, selection, and selected-size summaries;
- a queued, testable file-operation engine for create, rename, copy, move, duplicate, paste, and Trash;
- safe Undo/Redo plans routed back through the same operation queue and conflict checks;
- custom Favorites plus tab-path and selected-tab restoration between launches;
- sortable file columns, per-tab view/sort restoration, and a Settings window for hidden files and preview defaults;
- an original multi-resolution macOS application icon;
- Swift unit, integration, cancellation, conflict, and filesystem-safety tests.

This is a development prototype, not the roadmap's Beta release. The directory
tree still needs large-volume performance validation; the Spotlight backend,
file promises, sandbox access, signing, and notarization remain planned work.

## Product reference

The interface direction is informed by
[ronhash10/MacExplorer](https://github.com/ronhash10/MacExplorer), an MIT-licensed
SwiftUI project. Explorer.app keeps its own AppKit presentation and actor-backed
browsing/operation modules; the reference repository is not vendored as a source
dependency.

## Requirements

- macOS 14 or later
- A recent Xcode release with Swift 6 support

## Build and run

The development project uses Swift Package Manager so it can be opened directly in Xcode or built from Terminal:

```bash
swift build
swift test
swift run ExplorerApp
```

For a normal macOS application bundle, package an ad-hoc-signed development build:

```bash
./scripts/package-app.sh
./scripts/run-app.sh
```

The bundle is written to `.build/artifacts/Explorer.app`. It is suitable for
local development; Developer ID signing, notarization, and a distributable DMG
remain release work.

## Publishing a preview release

Pushing a `v*` tag runs the release workflow. It verifies that the tag matches
`CFBundleShortVersionString`, tests and packages the app on Apple Silicon,
publishes `Explorer-<version>-arm64.zip` as a GitHub prerelease, and updates
`Casks/explorer-app.rb` in
[`xq-meng/homebrew-tap`](https://github.com/xq-meng/homebrew-tap).

Before publishing for the first time, add a repository Actions secret named
`HOMEBREW_TAP_TOKEN`. Use a fine-grained personal access token limited to the
`xq-meng/homebrew-tap` repository with **Contents: Read and write** permission.

To publish after updating both version values in `Resources/Info.plist`:

```bash
git tag v0.3.0
git push origin v0.3.0
```

The published preview remains ad-hoc signed and unnotarized. Homebrew users must
follow the trust and quarantine instructions documented by the tap.

## Useful commands

- `Command-L`: edit the current path
- `Command-Shift-P`: toggle the preview pane
- `Command-Shift-.`: show or hide hidden files
- `Command-Control-D`: add the current folder to Favorites
- `Command-Z` / `Command-Shift-Z`: undo or redo a completed file operation
- `Space`: open the selected item in the Quick Look panel

## Architecture

```text
ExplorerApp         Lifecycle, dependency composition, tabs, and persisted state
├── ExplorerUI      Presentation-only AppKit views and browser commands
├── ExplorerBrowsing  Directory loading, search, volumes, monitoring, thumbnails
│   └── ExplorerCore  Sendable filesystem models and provider contracts
└── ExplorerOperations  Mutations, queue, clipboard, conflict safety, Undo plans
```

`ExplorerUI` has no dependency on filesystem modules. `ExplorerApp` is the only
composition root; browsing and operation actors run blocking work away from the
main actor and publish immutable results for the app to map into presentation data.

## Safety principles

- Never overwrite a destination silently.
- Run Undo/Redo through the same conflict validation; replacement operations are intentionally not recorded as undoable.
- Move across volumes by copying successfully before removing the source.
- Send normal deletion to the Trash.
- Keep long-running I/O cancellable and off the main thread.
- Treat filesystem notifications as invalidation signals and verify disk state again.
- Do not use path strings as the sole identity of a file.
