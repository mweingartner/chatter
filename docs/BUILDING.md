# Building and distributing Chatter

## Requirements

Apple Silicon, macOS 26+, and Xcode with Swift 6.2+ and the macOS 26 SDK. Run `xcodebuild -version` and `swift --version` to check the selected toolchain. On a fresh Xcode install, finish its first-launch setup and install the Metal Toolchain component if requested. No Homebrew, Python, CUDA, Node, or Git submodule initialization is needed for Chatter's build or runtime.

## Build and test

```sh
swift test
scripts/build-app.sh
```

The app is written to `artifacts/Chatter.app`. Four executables and all SwiftPM resource bundles are included. The standard script uses `.release-build` and ad-hoc signing, so it works without the author's certificates. Override the build directory with `CHATTER_BUILD_PATH`.

To install a build locally, `scripts/install-app.sh` rebuilds, quits the running app, installs to `/Applications/Chatter.app`, verifies its signature, and opens it. Existing user data is not replaced. Changing signing identity may require granting microphone permissions again.

## Package a release

```sh
CHATTER_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
CHATTER_NOTARY_PROFILE='your-existing-profile' scripts/package-release.sh
```

Output is under `artifacts/releases/<version>/`: an app ZIP, a portable plugin ZIP, license/notice files, release notes, and `SHA256SUMS`. The script uses only repository/build files. It never reads a user's Chatter data directory. The ZIP contains the full runtime; models are downloaded separately in the app.

For a notarized distribution, set `CHATTER_SIGN_IDENTITY` to a valid `Developer ID Application: ...` identity and `CHATTER_NOTARY_PROFILE` to an existing `notarytool` Keychain profile. The script requests a timestamp, submits to Apple, waits for success, staples the app, and repackages before checksumming. Keep credentials out of source control. The first public release used ad-hoc signing. Starting with 3.1, production packaging refuses to proceed without both credentials. For local testing only, `scripts/package-release.sh --development` creates an explicitly separate archive under `artifacts/development/`; it is not a notarized release.

Do not describe a successful `codesign --verify` as notarization. An ad-hoc signature verifies integrity but does not establish a trusted publisher to Gatekeeper.

## Dependency maintenance

`Vendor/dependencies.json` records the original URLs and commit revisions; `Vendor/Upstream-Package.resolved` preserves the upstream version lock. The root package overrides all 12 required packages with local paths. Their manifests/source remain unmodified; optional upstream documentation, Xet transport, Linux, and dependency test targets are not part of Chatter's standard build.

When updating, replace complete snapshots, preserve license and attribution files, include MLX's populated `mlx` and `mlx-c` source directories, and record revisions. Exclude nested `.git`, caches, model weights, and local data. Rebuild from an empty scratch directory and verify that every resolved package has `fileSystem` kind. A cache-only successful build is insufficient evidence.

`Vendor/SHA256SUMS` inventories vendored regular files; verify it with `shasum -a 256 -c Vendor/SHA256SUMS`. Symlinks are recorded separately in `Vendor/symlinks.json`. The inventory is relative to the repository root.

## Optional tests

The standard tests use checked-in synthetic audio fixtures. To exercise on-device transcription with a private recording, set `CHATTER_TEST_RECORDING` to its absolute path and optionally `CHATTER_TEST_TRANSCRIPT` to an expected substring. Installed English speech assets are required. Recordings are not part of the source distribution.

After model setup, `chatter-tools verify plugin --bridge /Applications/Chatter.app/Contents/MacOS/chatter-mcp --voice Ryan --output /tmp/chatter-check.json` validates the live MCP catalog and generates a short WAV. Use the full tools executable path inside the app bundle. Generated outputs and reports are private local artifacts, not release contents.

## Security verification

Run `python3 scripts/security-audit.py` for vendored integrity, source-data exclusions, current advisory queries and a CycloneDX inventory. Python is a development/CI tool only; the installed runtime remains native Swift. `--offline` checks integrity and source contents but does not claim an advisory check. GitHub Actions runs the audit on changes and weekly, with read-only repository permissions. New nested native snapshots must also update `scripts/security-native-components.json`.

Use an isolated `CHATTER_DATA_ROOT` for service probes. Do not run queue/connection stress tests against a user's live service. The TLS/client credential, database migration, audio privacy and model-integrity regression tests are included in `swift test`.
