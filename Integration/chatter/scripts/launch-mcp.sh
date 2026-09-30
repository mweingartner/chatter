#!/bin/sh
# Starts Chatter's stdio MCP bridge (a signed Swift executable).
# Search order: $CHATTER_MCP_BIN, a copy packaged with this plugin, then the installed app.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for candidate in "${CHATTER_MCP_BIN:-}" "$script_dir/chatter-mcp" \
    "/Applications/Chatter.app/Contents/MacOS/chatter-mcp" "$HOME/Applications/Chatter.app/Contents/MacOS/chatter-mcp"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then exec "$candidate"; fi
done
echo "Chatter's MCP bridge (chatter-mcp) was not found. Install Chatter, or set CHATTER_MCP_BIN to its path." >&2
exit 1
