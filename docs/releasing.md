# Releasing

Pushing a `v*` tag runs `.github/workflows/release.yml`. The workflow:

1. Checks that the tag matches `CFBundleShortVersionString` in `Resources/Info.plist`
2. Runs tests and packages an Apple Silicon `.app`
3. Publishes `Explorer-<version>-arm64.zip` as a GitHub prerelease
4. Updates `Casks/explorer-app.rb` in [`xq-meng/homebrew-tap`](https://github.com/xq-meng/homebrew-tap)

The published preview is ad-hoc signed and unnotarized. Homebrew users must follow the quarantine instructions in the [user README](../README.md#homebrew).

## First-time setup

Add a repository Actions secret named `HOMEBREW_TAP_TOKEN`. Use a fine-grained personal access token limited to the `xq-meng/homebrew-tap` repository with **Contents: Read and write** permission.

## Publish a preview

Update both version values in `Resources/Info.plist`, commit, then:

```bash
git tag v0.6.2
git push origin v0.6.2
```

Replace `0.6.2` with the version you just wrote to the plist.
