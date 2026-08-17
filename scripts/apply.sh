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

win_mm="$dest/UI/AppKit/Interface/LadybirdWebViewWindow.mm"
if ! grep -q "SUZURI_GUEST_PORT" "$win_mm"; then
  python3 - "$win_mm" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """- (void)setIsVisible:(BOOL)flag
{
    [self.web_view handleVisibility:flag];
    [super setIsVisible:flag];
}

- (void)setIsMiniaturized:(BOOL)flag
{
    [self.web_view handleVisibility:!flag];
    [super setIsMiniaturized:flag];
}
"""
new = """- (void)setIsVisible:(BOOL)flag
{
    if (getenv("SUZURI_GUEST_PORT") != nullptr)
        flag = YES;
    [self.web_view handleVisibility:flag];
    [super setIsVisible:flag];
}

- (void)setIsMiniaturized:(BOOL)flag
{
    if (getenv("SUZURI_GUEST_PORT") != nullptr) {
        [self.web_view handleVisibility:YES];
        [super setIsMiniaturized:flag];
        return;
    }
    [self.web_view handleVisibility:!flag];
    [super setIsMiniaturized:flag];
}
"""
if old not in t:
    raise SystemExit("LadybirdWebViewWindow.mm: visibility setters not found — rebase overlay")
if "<cstdlib>" not in t:
    t = t.replace(
        "#import <Interface/LadybirdWebViewWindow.h>\n",
        "#import <Interface/LadybirdWebViewWindow.h>\n#include <cstdlib>\n",
        1,
    )
p.write_text(t.replace(old, new, 1))
print("patched", p)
PY
fi

del_mm="$dest/UI/AppKit/Application/ApplicationDelegate.mm"
if ! grep -q "SUZURI_GUEST_PORT" "$del_mm"; then
  python3 - "$del_mm" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
    return [(Application*)sender confirmStopActiveDownloads];
}
"""
new = """- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
    if (getenv("SUZURI_GUEST_PORT") != nullptr)
        return NO;
    return [(Application*)sender confirmStopActiveDownloads];
}
"""
if old not in t:
    raise SystemExit("ApplicationDelegate.mm: last-window handler not found — rebase overlay")
if "<cstdlib>" not in t:
    t = "#include <cstdlib>\n" + t
p.write_text(t.replace(old, new, 1))
print("patched", p)
PY
fi

if ! grep -q "Guest chrome owns the first document" "$del_mm"; then
  python3 - "$del_mm" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """    if (browser_options.devtools_port.has_value())
        [self onDevtoolsEnabled];

    Tab* tab = nil;
"""
new = """    if (browser_options.devtools_port.has_value())
        [self onDevtoolsEnabled];

    // Guest chrome owns the first document. A default about:newtab window
    // would flash on screen before the overlay can hide it.
    if (getenv("SUZURI_GUEST_PORT") != nullptr)
        return;

    Tab* tab = nil;
"""
if old not in t:
    raise SystemExit("ApplicationDelegate.mm: didFinishLaunching body not found — rebase overlay")
t = t.replace(old, new, 1)
old = """    [controller showWindow:nil];

    if (tab_for_location) {
"""
new = """    if (getenv("SUZURI_GUEST_PORT") != nullptr) {
        NSWindow* window = [controller window];
        [window setAlphaValue:0];
        [window setIgnoresMouseEvents:YES];
        [window setHasShadow:NO];
        [window setAnimationBehavior:NSWindowAnimationBehaviorNone];
        [controller showWindow:nil];
        [window setAlphaValue:0];
        [window orderBack:nil];
        [self.managed_tabs addObject:controller];
        return;
    }

    [controller showWindow:nil];

    if (tab_for_location) {
"""
if old not in t:
    raise SystemExit("ApplicationDelegate.mm: showWindow not found — rebase overlay")
p.write_text(t.replace(old, new, 1))
print("patched", p)
PY
fi

tabc="$dest/UI/AppKit/Interface/TabController.mm"
if ! grep -q "SUZURI_GUEST_PORT" "$tabc"; then
  python3 - "$tabc" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
needle = """- (void)windowDidChangeOcclusionState:(NSNotification*)notification
{
    [[[self tab] web_view] handleVisibility:([self.window occlusionState] & NSWindowOcclusionStateVisible) != 0];
}
"""
insert = """- (void)windowDidChangeOcclusionState:(NSNotification*)notification
{
    // Guest well is an off-screen helper. Occlusion would mark the page Hidden
    // and WebContent stops painting — the Suzuri pane stays blank.
    if (getenv("SUZURI_GUEST_PORT") != nullptr) {
        [[[self tab] web_view] handleVisibility:YES];
        return;
    }
    [[[self tab] web_view] handleVisibility:([self.window occlusionState] & NSWindowOcclusionStateVisible) != 0];
}
"""
if needle not in t:
    raise SystemExit("TabController.mm: occlusion handler not found — rebase overlay")
if "<cstdlib>" not in t:
    t = t.replace("#import <Interface/TabController.h>\n", "#import <Interface/TabController.h>\n#include <cstdlib>\n", 1)
p.write_text(t.replace(needle, insert, 1))
print("patched", p)
PY
fi

main="$dest/UI/AppKit/main.mm"
if grep -q "suzuri_guest_try_start" "$main" && ! grep -q "suzuri_guest_prepare_app" "$main"; then
  python3 - "$main" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
needle = "    auto app = TRY(Ladybird::Application::create(arguments));\n"
insert = needle + "    suzuri_guest_prepare_app();\n"
if needle not in t:
    raise SystemExit("main.mm: Application::create not found — rebase overlay")
p.write_text(t.replace(needle, insert, 1))
print("patched prepare_app", p)
PY
fi
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
    + "    suzuri_guest_prepare_app();\n"
)
if needle not in t:
    raise SystemExit("main.mm: Application::create not found — rebase overlay")
p.write_text(t.replace(needle, insert, 1))
print("patched", p)
PY
fi

bridge_cpp="$dest/UI/AppKit/Interface/LadybirdWebViewBridge.cpp"
if ! grep -q "SUZURI_GUEST_PORT" "$bridge_cpp"; then
  python3 - "$bridge_cpp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
if "<cstdlib>" not in t:
    t = t.replace(
        "#include <LibWebView/Application.h>\n",
        "#include <LibWebView/Application.h>\n#include <cstdlib>\n",
        1,
    )
old = """    m_device_pixel_ratio = device_pixel_ratio;
    m_display_id = display_id;
    m_maximum_frames_per_second = static_cast<double>(maximum_frames_per_second);
    set_page_background_color_to_system_canvas(is_using_dark_system_theme());
}
"""
new = """    m_device_pixel_ratio = device_pixel_ratio;
    m_display_id = display_id;
    m_maximum_frames_per_second = static_cast<double>(maximum_frames_per_second);
    set_page_background_color_to_system_canvas(is_using_dark_system_theme());
    // Guest chrome presents the compositor IOSurface. Start Visible so
    // initialize_client tells WebContent to paint before any window
    // occlusion can mark the document Hidden.
    if (getenv("SUZURI_GUEST_PORT") != nullptr)
        m_top_level_traversable.set_system_visibility_state(Web::HTML::VisibilityState::Visible);
}
"""
if old not in t:
    raise SystemExit("LadybirdWebViewBridge.cpp: constructor tail not found — rebase overlay")
t = t.replace(old, new, 1)
old = """    if (m_client_state.has_usable_bitmap) {
        shared_image_buffer = m_client_state.front_bitmap.shared_image_buffer.ptr();
        bitmap_size = m_client_state.front_bitmap.last_painted_size.to_type<int>();
    } else {
        shared_image_buffer = m_backup_shared_image_buffer.ptr();
        bitmap_size = m_backup_bitmap_size.to_type<int>();
    }
"""
new = """    if (m_client_state.has_usable_bitmap) {
        shared_image_buffer = m_client_state.front_bitmap.shared_image_buffer.ptr();
        bitmap_size = m_client_state.front_bitmap.last_painted_size.to_type<int>();
    } else {
        shared_image_buffer = m_backup_shared_image_buffer.ptr();
        bitmap_size = m_backup_bitmap_size.to_type<int>();
    }
    // Backing stores exist before the first present. Guest chrome can
    // import that IOSurface as soon as the compositor allocates it.
    if (!shared_image_buffer && m_client_state.front_bitmap.shared_image_buffer) {
        shared_image_buffer = m_client_state.front_bitmap.shared_image_buffer.ptr();
        bitmap_size = m_viewport_size;
    }
"""
if old not in t:
    raise SystemExit("LadybirdWebViewBridge.cpp: paintable() body not found — rebase overlay")
p.write_text(t.replace(old, new, 1))
print("patched", p)
PY
fi

view_mm="$dest/UI/AppKit/Interface/LadybirdWebView.mm"
if ! grep -A2 "handleResize" "$view_mm" | grep -q "SUZURI_GUEST_PORT"; then
  python3 - "$view_mm" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
if "<cstdlib>" not in t:
    t = t.replace(
        "#include <LibWebView/Utilities.h>\n",
        "#include <LibWebView/Utilities.h>\n#include <cstdlib>\n",
        1,
    )
old = """- (void)handleResize
{
    auto size = Ladybird::ns_size_to_gfx_size([[self window] frame].size);
"""
new = """- (void)handleResize
{
    if (getenv("SUZURI_GUEST_PORT") != nullptr)
        return;
    auto size = Ladybird::ns_size_to_gfx_size([[self window] frame].size);
"""
if old not in t:
    raise SystemExit("LadybirdWebView.mm: handleResize not found — rebase overlay")
p.write_text(t.replace(old, new, 1))
print("patched", p)
PY
fi

if ! grep -A3 "windowDidResize" "$tabc" | grep -q "SUZURI_GUEST_PORT"; then
  python3 - "$tabc" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """- (void)windowDidResize:(NSNotification*)notification
{
    [self.autocomplete close];
"""
new = """- (void)windowDidResize:(NSNotification*)notification
{
    if (getenv("SUZURI_GUEST_PORT") != nullptr)
        return;
    [self.autocomplete close];
"""
if old not in t:
    raise SystemExit("TabController.mm: windowDidResize not found — rebase overlay")
p.write_text(t.replace(old, new, 1))
print("patched", p)
PY
fi

if ! grep -A3 "handleDisplayRefreshRateChange" "$view_mm" | grep -q "mainScreen"; then
  python3 - "$view_mm" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """- (void)handleDisplayRefreshRateChange
{
    auto* screen = [[self window] screen];
    m_web_view_bridge->set_display_metadata([screen maximumFramesPerSecond], display_id_for_screen(screen));
}
"""
new = """- (void)handleDisplayRefreshRateChange
{
    auto* screen = [[self window] screen] ?: [NSScreen mainScreen];
    m_web_view_bridge->set_display_metadata([screen maximumFramesPerSecond], display_id_for_screen(screen));
}
"""
if old not in t:
    raise SystemExit("LadybirdWebView.mm: handleDisplayRefreshRateChange not found — rebase overlay")
p.write_text(t.replace(old, new, 1))
print("patched", p)
PY
fi

if ! grep -q 'screen] == nil' "$tabc"; then
  python3 - "$tabc" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = """- (void)windowDidChangeScreen:(NSNotification*)notification
{
    [[[self tab] web_view] handleDisplayRefreshRateChange];
}
"""
new = """- (void)windowDidChangeScreen:(NSNotification*)notification
{
    if (getenv("SUZURI_GUEST_PORT") != nullptr && [self.window screen] == nil)
        return;
    [[[self tab] web_view] handleDisplayRefreshRateChange];
}
"""
if old not in t:
    raise SystemExit("TabController.mm: windowDidChangeScreen not found — rebase overlay")
p.write_text(t.replace(old, new, 1))
print("patched", p)
PY
fi

echo "overlay applied under $dest/UI/AppKit/Suzuri"
echo "build Ladybird as usual, then point suzuri's ladybird.json command at the Ladybird binary."
