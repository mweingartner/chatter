#!/bin/zsh
# Produce the distributable app and portable plugin without reading user data.
set -euo pipefail
cd "${0:A:h:h}"
# Public releases must identify their publisher and pass Apple's notarization service.
# Explicit development archives stay local and are never called production releases.
mode="${1:-production}"
if [[ "$mode" != "--development" ]]; then
  if [[ "$mode" != "production" || "${CHATTER_SIGN_IDENTITY:-}" != "Developer ID Application:"* || -z "${CHATTER_NOTARY_PROFILE:-}" ]]; then
    print -u2 'Production packaging requires CHATTER_SIGN_IDENTITY (Developer ID Application) and CHATTER_NOTARY_PROFILE. Use --development only for local testing.'
    exit 1
  fi
fi
./scripts/build-app.sh
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
out="$PWD/artifacts/releases/$version"
if [[ "$mode" == "--development" ]]; then out="$PWD/artifacts/development/$version"; fi
mkdir -p "$out"
archive="$out/Chatter-$version-macOS-arm64.zip"
forbidden=(artifacts/Chatter.app/**/*Tests.bundle(N) artifacts/Chatter.app/**/__pycache__(N)
           artifacts/Chatter.app/**/*.wav(N) artifacts/Chatter.app/**/*.safetensors(N)
           artifacts/Chatter.app/**/api-token(N) artifacts/Chatter.app/**/voices.json(N))
if (( ${#forbidden} )); then
  print -u2 'Release rejected: test resources or user/model data found in the app bundle.'
  exit 1
fi
ditto -c -k --sequesterRsrc --keepParent artifacts/Chatter.app "$archive"
if [[ -n "${CHATTER_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$archive" --keychain-profile "$CHATTER_NOTARY_PROFILE" --wait
  xcrun stapler staple artifacts/Chatter.app
  xcrun stapler validate artifacts/Chatter.app
  spctl --assess --type execute --verbose=2 artifacts/Chatter.app
  ditto -c -k --sequesterRsrc --keepParent artifacts/Chatter.app "$archive"
fi
plugin_stage=$(mktemp -d "$PWD/artifacts/plugin-stage.XXXXXX")
trap 'rm -rf "$plugin_stage"' EXIT
mkdir "$plugin_stage/chatter"
rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store' Integration/chatter/ "$plugin_stage/chatter/"
ditto -c -k --keepParent "$plugin_stage/chatter" "$out/chatter-plugin-$version.zip"
cp LICENSE NOTICE "$out/"
cp docs/RELEASE_NOTES.md "$out/README.txt"
(
  cd "$out"
  shasum -a 256 "Chatter-$version-macOS-arm64.zip" "chatter-plugin-$version.zip" LICENSE NOTICE README.txt > SHA256SUMS
)
printf 'Release files: %s\n' "$out"
