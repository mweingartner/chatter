#!/bin/sh
# Runs Chatter's integration tools (for example `remotion` staging) from the plugin.
# Search order: $CHATTER_TOOLS_BIN, a copy packaged with this plugin, then the installed app.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for candidate in "${CHATTER_TOOLS_BIN:-}" "$script_dir/chatter-tools" \
    "/Applications/Chatter.app/Contents/MacOS/chatter-tools" "$HOME/Applications/Chatter.app/Contents/MacOS/chatter-tools"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then exec "$candidate" "$@"; fi
done
echo "Chatter's tools (chatter-tools) were not found. Install Chatter, or set CHATTER_TOOLS_BIN to its path." >&2
exit 1
