#!/usr/bin/env bash
# Copy Guest/Suzuri into a Ladybird checkout and patch AppKit.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:-}"
if [[ -z "$dest" || ! -d "$dest/UI/AppKit" ]]; then
  echo "usage: $0 /path/to/ladybird" >&2
  echo "  (tree must contain UI/AppKit)" >&2
  exit 1
fi

mkdir -p "$dest/UI/AppKit/Suzuri/AppKit"
cp "$root/Guest/Suzuri/Framebuffer.h" "$dest/UI/AppKit/Suzuri/"
cp "$root/Guest/Suzuri/Framebuffer.cpp" "$dest/UI/AppKit/Suzuri/"
cp "$root/Guest/Suzuri/Protocol.h" "$dest/UI/AppKit/Suzuri/"
cp "$root/Guest/Suzuri/Protocol.cpp" "$dest/UI/AppKit/Suzuri/"
cp "$root/Guest/Suzuri/AppKit/SuzuriGuest.h" "$dest/UI/AppKit/Suzuri/AppKit/"
cp "$root/Guest/Suzuri/AppKit/SuzuriGuest.mm" "$dest/UI/AppKit/Suzuri/AppKit/"

cmake="$dest/UI/AppKit/CMakeLists.txt"
if ! grep -q "Suzuri/Protocol.cpp" "$cmake"; then
  python3 - "$cmake" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
needle = "    Utilities/ExternalURLHandler.mm\n"
insert = needle + (
    "    Suzuri/Framebuffer.cpp\n"
    "    Suzuri/Protocol.cpp\n"
    "    Suzuri/AppKit/SuzuriGuest.mm\n"
)
if needle not in t:
    raise SystemExit("CMakeLists.txt: ExternalURLHandler.mm not found — rebase overlay")
p.write_text(t.replace(needle, insert, 1))
print("patched", p)
PY
fi

main="$dest/UI/AppKit/main.mm"
if ! grep -q "suzuri_guest_try_start" "$main"; then
  python3 - "$main" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
inc = "#import <Utilities/ApplicationIcon.h>\n"
hook_inc = inc + "#import <Suzuri/AppKit/SuzuriGuest.h>\n"
if inc not in t:
    raise SystemExit("main.mm: ApplicationIcon include not found — rebase overlay")
t = t.replace(inc, hook_inc, 1)
needle = "    auto app = TRY(Ladybird::Application::create(arguments));\n"
insert = (
    "    suzuri_guest_try_start(arguments.argc, arguments.argv);\n"
    + needle
)
if needle not in t:
    raise SystemExit("main.mm: Application::create not found — rebase overlay")
p.write_text(t.replace(needle, insert, 1))
print("patched", p)
PY
fi

echo "overlay applied under $dest/UI/AppKit/Suzuri"
echo "build Ladybird as usual, then point suzuri's ladybird.json command at the Ladybird binary."
