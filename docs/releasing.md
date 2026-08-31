# Releasing

Pushing a `v*` tag runs `.github/workflows/release.yml`. The workflow:

1. Checks that the tag matches `CFBundleShortVersionString` in `Resources/Info.plist`
2. Runs tests and packages an Apple Silicon `.app`
3. Publishes `Explorer-<version>-arm64.zip` as a GitHub prerelease
4. Updates `Casks/explorer-app.rb` in [`xq-meng/homebrew-tap`](https://github.com/xq-meng/homebrew-tap)

The published preview is ad-hoc signed and unnotarized. Homebrew users must follow the quarantine instructions in the [user README](../README.md#homebrew).

## Before publishing

1. Update the [known issues](known-issues.md) for user-visible limitations introduced, fixed, or verified by the release.
2. Complete and retain a copy of the [regression checklist](regression-checklist.md).
3. Confirm the release commit is on `main`, CI passes, and the working tree is clean.
4. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.

## First-time setup

Add a repository Actions secret named `HOMEBREW_TAP_TOKEN`. Use a fine-grained personal access token limited to the `xq-meng/homebrew-tap` repository with **Contents: Read and write** permission.

## Publish a preview

After the checks above and the version-bump commit, create and push the tag. For example:

```bash
git tag -a v0.6.3 -m "Explorer 0.6.3"
git push origin v0.6.3
```

Replace `0.6.3` with the version written to the plist. After the workflow finishes, verify that the GitHub asset version and SHA-256 match the Homebrew Cask, then link the release notes to the current [known issues](known-issues.md).
