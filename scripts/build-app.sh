#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
scratch="${CHATTER_BUILD_PATH:-$PWD/.release-build}"
swift build --scratch-path "$scratch" -c release
bin_dir=$(swift build --scratch-path "$scratch" -c release --show-bin-path)
app="$PWD/artifacts/Chatter.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Chatter" "$app/Contents/MacOS/Chatter"
# Helpers live beside the app executable: the speech engine, the stdio MCP bridge and tools.
helpers=(chatter-engine chatter-mcp chatter-tools)
for helper in $helpers; do cp "$bin_dir/$helper" "$app/Contents/MacOS/$helper"; done
# MLX loads its Metal kernels from this SwiftPM resource bundle in the app's Resources.
# Xcode's SwiftPM build also emits test resource bundles; never ship those.
for bundle in "$bin_dir/"*.bundle(N); do
  [[ "${bundle:t}" == *Tests.bundle ]] && continue
  ditto "$bundle" "$app/Contents/Resources/${bundle:t}"
done
test -f "$app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
rsync -a docs/ "$app/Contents/Resources/docs/"
if [[ -d Integration ]]; then rsync -a --delete --delete-excluded --exclude '__pycache__' Integration/ "$app/Contents/Resources/Integration/"; fi
cp Info.plist "$app/Contents/Info.plist"
cp LICENSE NOTICE "$app/Contents/Resources/"
if [[ -f assets/Chatter.icns ]]; then cp assets/Chatter.icns "$app/Contents/Resources/Chatter.icns"; fi
identity="${CHATTER_SIGN_IDENTITY:--}"
timestamp=(--timestamp=none)
if [[ "$identity" == "Developer ID Application:"* ]]; then timestamp=(--timestamp); fi
# Hardened runtime everywhere; the app keeps only its microphone entitlement.
for helper in $helpers; do codesign --force --options runtime $timestamp --sign "$identity" "$app/Contents/MacOS/$helper"; done
codesign --force --options runtime $timestamp --sign "$identity" --entitlements Chatter.entitlements "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
