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

app_h="$dest/UI/AppKit/Application/Application.h"
if ! grep -q "create_platform_arguments" "$app_h"; then
  python3 - "$app_h" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
needle = "    virtual Core::EventLoop& create_platform_event_loop() override;\n"
insert = needle + (
    "\n"
    "    virtual void create_platform_arguments(Core::ArgsParser&) override;\n"
    "    virtual bool should_coordinate_browser_process() const override;\n"
)
if needle not in t:
    raise SystemExit("Application.h: create_platform_event_loop not found — rebase overlay")
p.write_text(t.replace(needle, insert, 1))
print("patched", p)
PY
fi

app_mm="$dest/UI/AppKit/Application/Application.mm"
if ! grep -q "suzuri-guest" "$app_mm"; then
  python3 - "$app_mm" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
inc = "#include <LibCore/ArgsParser.h>\n"
if inc in t and "<cstdlib>" not in t:
    t = t.replace(inc, inc + "#include <cstdlib>\n", 1)
needle = "Application::Application() = default;\n"
insert = needle + """
void Application::create_platform_arguments(Core::ArgsParser& args_parser)
{
    // Chrome always passes these; consume them so ArgsParser does not abort.
    static bool suzuri_guest = false;
    static u16 suzuri_port = 0;
    args_parser.add_option(suzuri_guest, "Run as a Suzuri guest pane", "suzuri-guest");
    args_parser.add_option(suzuri_port, "Suzuri guest TCP port", "port", 0, "port");
}

bool Application::should_coordinate_browser_process() const
{
    // A guest must be its own process, never a URL handed to a desktop Ladybird.
    return getenv("SUZURI_GUEST_PORT") == nullptr;
}

"""
if needle not in t:
    raise SystemExit("Application.mm: Application() = default not found — rebase overlay")
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
