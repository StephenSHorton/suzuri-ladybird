#!/usr/bin/env bash
# Build a relocatable Ladybird.app zip for `suzuri guest install ladybird`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-}"
if [[ -z "$src" ]]; then
  if [[ -n "${LADYBIRD_SOURCE_DIR:-}" && -d "$LADYBIRD_SOURCE_DIR/Build/release/bin/Ladybird.app" ]]; then
    src="$LADYBIRD_SOURCE_DIR/Build/release/bin/Ladybird.app"
  elif [[ -d "$HOME/projects/ladybird/Build/release/bin/Ladybird.app" ]]; then
    src="$HOME/projects/ladybird/Build/release/bin/Ladybird.app"
  fi
fi
if [[ -z "$src" || ! -d "$src" ]]; then
  echo "usage: $0 /path/to/Ladybird.app" >&2
  exit 1
fi
src="$(cd "$src" && pwd)"

arch="$(uname -m)"
case "$arch" in
  arm64) plat=macos-arm64 ;;
  x86_64) plat=macos-amd64 ;;
  *) plat="macos-$arch" ;;
esac

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -a "$src" "$stage/Ladybird.app"

macos="$stage/Ladybird.app/Contents/MacOS"
if [[ -d "$macos" ]]; then
  for bin in "$macos"/*; do
    [[ -f "$bin" && -x "$bin" ]] || continue
    install_name_tool -add_rpath "@executable_path/../lib" "$bin" 2>/dev/null || true
  done
fi

out="$root/dist/suzuri-ladybird-${plat}.zip"
mkdir -p "$root/dist"
rm -f "$out"
(cd "$stage" && zip -qry "$out" Ladybird.app)
echo "wrote $out ($(du -h "$out" | awk '{print $1}'))"
