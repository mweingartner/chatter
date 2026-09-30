#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build-app.sh
if pgrep -x Chatter >/dev/null; then
  pkill -TERM -x Chatter
  for i in {1..50}; do if ! pgrep -x Chatter >/dev/null; then break; fi; sleep 0.1; done
fi
if pgrep -x Chatter >/dev/null; then print -u2 'Chatter is still running. Stop it before installing.'; exit 1; fi
mkdir -p /Applications/Chatter.app
rsync -a --delete artifacts/Chatter.app/ /Applications/Chatter.app/
codesign --verify --deep --strict /Applications/Chatter.app
open /Applications/Chatter.app
