#!/bin/bash
# Install sub-agents to VPS
# Usage: SUB_AGENTS_HOST=root@<vps-ip> bash install-sub-agents-to-root.sh
set -euo pipefail
HOST="${SUB_AGENTS_HOST:-root@187.77.12.13}"
DEST="/root/.sub-agents"
echo "Installing sub-agents to $HOST:$DEST ..."
ssh "$HOST" "mkdir -p $DEST"
scp -r "$(dirname "$0")/../sub-agents/"* "$HOST:$DEST/"
ssh "$HOST" "chmod -R 444 $DEST && echo sub-agents installed at $DEST"
echo "Done."
