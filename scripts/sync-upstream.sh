#!/usr/bin/env bash
# Record the current LadybirdBrowser/ladybird master SHA in UPSTREAM.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sha="$(git ls-remote https://github.com/LadybirdBrowser/ladybird.git refs/heads/master | awk '{print substr($1,1,12)}')"
date="$(date -u +%Y-%m-%d)"
cat > "$root/UPSTREAM" <<EOF
# Ladybird commit this overlay is written against.
# Pull with: scripts/sync-upstream.sh
repo=https://github.com/LadybirdBrowser/ladybird.git
sha=$sha
date=$date
note=refreshed by scripts/sync-upstream.sh
EOF
echo "UPSTREAM -> $sha"
