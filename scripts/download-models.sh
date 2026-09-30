#!/bin/zsh
# Downloads (or verifies and repairs) Chatter's pinned speech models. Resumable and SHA-256 checked.
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --product chatter-tools
"$(swift build -c release --show-bin-path)/chatter-tools" models install "$@"
