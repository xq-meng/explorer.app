# Development

## Requirements

- macOS 14 or later
- Xcode 26.4.1 for parity with CI releases, or another recent Xcode with Swift 6 support

Open `Package.swift` in Xcode, or work from Terminal with Swift Package Manager.

## Build and run

```bash
swift build
swift test -Xswiftc -warnings-as-errors
swift run ExplorerApp
```

For a normal macOS application bundle:

```bash
./scripts/package-app.sh
./scripts/run-app.sh
```

The bundle is written to `.build/artifacts/Explorer.app`. It is ad-hoc signed and suitable for local development.

Before publishing a preview, complete the [release regression checklist](regression-checklist.md). It includes the strict-warning build, package verification, destructive-operation smoke tests in disposable data, and external-integration checks.

## App icon

After changing the 1024×1024 app-icon master, regenerate the multi-resolution resource:

```bash
./scripts/generate-app-icon.sh
```

The master must remain full-canvas and opaque so current macOS versions do not add a second system backdrop.

## Continuous integration

Pushes and pull requests run `.github/workflows/ci.yml`, which builds and tests
on macOS 26 with Xcode 26.4.1 and the macOS 26.4 SDK.

Preview releases are documented in [releasing.md](releasing.md). Product scope and milestones are in [roadmap.md](roadmap.md), and current limitations are tracked in [known-issues.md](known-issues.md).
