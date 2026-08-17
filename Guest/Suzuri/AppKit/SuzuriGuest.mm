#include "SuzuriGuest.h"
#include "../Framebuffer.h"
#include "../Protocol.h"

#include <Application/ApplicationDelegate.h>
#include <Interface/LadybirdWebView.h>
#include <Interface/LadybirdWebViewBridge.h>
#include <Interface/Tab.h>
#include <LibGfx/Bitmap.h>
#include <LibGfx/Rect.h>
#include <LibWeb/HTML/ActivateTab.h>
#include <LibWeb/Page/InputEvent.h>
#include <LibWeb/UIEvents/KeyCode.h>
#include <LibWeb/UIEvents/MouseButton.h>
#include <AK/Optional.h>
#include <AK/Types.h>
#include <LibWeb/HTML/VisibilityState.h>
#include <LibWebView/ViewImplementation.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <thread>
#include <vector>

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CGWindow.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach.h>

extern "C" mach_port_t bootstrap_port;
extern "C" kern_return_t bootstrap_look_up(mach_port_t, char const*, mach_port_t*);

#if !__has_feature(objc_arc)
#    error "Suzuri guest requires ARC"
#endif

// One long-lived Ladybird. Socket thread owns TCP. AppKit work is on the
// main queue. The compositor already paints an IOSurface; chrome samples it.
// There is no user-facing Ladybird window.

namespace {

struct GuestRuntime {
    Suzuri::Session* session { nullptr };
    Suzuri::Framebuffer fb;
    std::string url;
    float scale { 1 };
    LadybirdWebView* hooked { nil };
    std::chrono::steady_clock::time_point last_blit {};
    bool window_tuned { false };
    bool load_issued { false };
    bool observers { false };
    bool timer { false };
    int no_tab_logs { 0 };
    bool force_blit { false };
    std::uint32_t blit_hash { 0 };
    std::chrono::steady_clock::time_point scrolling_until {};
    std::chrono::steady_clock::time_point resizing_until {};
    std::chrono::steady_clock::time_point last_viewport {};
    bool viewport_pending { false };
    bool visibility_forced { false };
    std::chrono::steady_clock::time_point settling_until {};
    std::uint32_t surface_seq { 0 };
    std::uint64_t last_iosurface_id { 0 };
    std::chrono::steady_clock::time_point last_blit_skip {};
};

GuestRuntime g_rt;
bool g_is_guest { false };
mach_port_t g_chrome_port { MACH_PORT_NULL };

bool send_surface_port(IOSurfaceRef surf)
{
    if (g_chrome_port == MACH_PORT_NULL || surf == nullptr)
        return false;
    mach_port_t sp = IOSurfaceCreateMachPort(surf);
    if (sp == MACH_PORT_NULL)
        return false;
    struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port;
    } msg {};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    msg.header.msgh_size = sizeof(msg);
    msg.header.msgh_remote_port = g_chrome_port;
    msg.header.msgh_local_port = MACH_PORT_NULL;
    msg.header.msgh_id = 1;
    msg.body.msgh_descriptor_count = 1;
    msg.port.name = sp;
    msg.port.disposition = MACH_MSG_TYPE_MOVE_SEND;
    msg.port.type = MACH_MSG_PORT_DESCRIPTOR;
    auto kr = mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(msg), 0,
        MACH_PORT_NULL, 0, MACH_PORT_NULL);
    if (kr != MACH_MSG_SUCCESS) {
        mach_port_deallocate(mach_task_self(), sp);
        return false;
    }
    return true;
}

void copy_iosurface_to_fb(IOSurfaceRef surf)
{
    if (surf == nullptr || g_rt.fb.width == 0 || g_rt.fb.height == 0)
        return;
    auto* dest = Suzuri::map_pixels(g_rt.fb);
    if (!dest)
        return;
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, nullptr);
    auto* src = static_cast<std::uint8_t const*>(IOSurfaceGetBaseAddress(surf));
    if (!src) {
        IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, nullptr);
        return;
    }
    auto src_bpr = IOSurfaceGetBytesPerRow(surf);
    auto sw = IOSurfaceGetWidth(surf);
    auto sh = IOSurfaceGetHeight(surf);
    auto dw = static_cast<std::size_t>(g_rt.fb.width);
    auto dh = static_cast<std::size_t>(g_rt.fb.height);
    auto rows = std::min<std::size_t>(sh, dh);
    auto cols = std::min<std::size_t>(sw, dw);
    for (std::size_t y = 0; y < rows; ++y)
        std::memcpy(dest + y * dw * 4, src + y * src_bpr, cols * 4);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, nullptr);
    Suzuri::publish_szfb(g_rt.fb);
    if (g_rt.session)
        g_rt.session->send_surface(g_rt.fb);
}

Tab* active_tab();
Ladybird::WebViewBridge* bridge_for(Tab* tab);

void pin_page_visible(Tab* tab)
{
    if (tab == nil)
        return;
    [tab.web_view handleVisibility:YES];
    if (auto* bridge = bridge_for(tab))
        bridge->set_system_visibility_state(Web::HTML::VisibilityState::Visible);
}

// Hidden → Visible so WebContent cannot miss the first Visible IPC
// (set_system_visibility_state no-ops when the UI process already
// thinks the page is Visible).
void force_page_visible(Tab* tab)
{
    if (tab == nil)
        return;
    if (auto* bridge = bridge_for(tab)) {
        bridge->set_system_visibility_state(Web::HTML::VisibilityState::Hidden);
        bridge->set_system_visibility_state(Web::HTML::VisibilityState::Visible);
    }
    [tab.web_view handleVisibility:YES];
    g_rt.visibility_forced = true;
}

void apply_display_metadata(Ladybird::WebViewBridge* bridge)
{
    if (!bridge)
        return;
    NSScreen* screen = [NSScreen mainScreen];
    if (screen == nil)
        return;
    u64 fps = 60;
    if ([screen respondsToSelector:@selector(maximumFramesPerSecond)])
        fps = static_cast<u64>(std::max<NSInteger>(1, screen.maximumFramesPerSecond));
    NSNumber* num = screen.deviceDescription[@"NSScreenNumber"];
    AK::Optional<u64> display_id;
    if (num)
        display_id = static_cast<u64>(num.unsignedIntValue);
    bridge->set_display_metadata(fps, display_id);
}

void hide_guest_window(NSWindow* window)
{
    if (window == nil)
        return;
    [window setRestorable:NO];
    [window setFrameAutosaveName:@""];
    [window setExcludedFromWindowsMenu:YES];
    [window setHasShadow:NO];
    [window setIgnoresMouseEvents:YES];
    [window setAlphaValue:0];
    [window setCollectionBehavior:NSWindowCollectionBehaviorTransient
            | NSWindowCollectionBehaviorIgnoresCycle
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorCanJoinAllSpaces];
    [window setAnimationBehavior:NSWindowAnimationBehaviorNone];
    // Stay attached to a real display. orderOut clears the window's
    // screen (display_id / vsync) and AppKit marks the view Hidden,
    // so WebContent never presents an IOSurface. Chrome is still the
    // presenter; this window is only a compositor source.
    [window orderBack:nil];
}

void hide_all_guest_windows()
{
    if (NSApp == nil)
        return;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow* keep = nil;
    if (auto* tab = active_tab())
        keep = [tab.web_view window];
    for (NSWindow* window in [NSApp windows]) {
        if (keep != nil && window == keep) {
            hide_guest_window(window);
            continue;
        }
        // Startup / popup windows (the gray 800×600). Keep the web view.
        [window setReleasedWhenClosed:NO];
        [window setAnimationBehavior:NSWindowAnimationBehaviorNone];
        [window setAlphaValue:0];
        [window setIgnoresMouseEvents:YES];
        [window orderOut:nil];
    }
    pin_page_visible(active_tab());
}

__attribute__((format(printf, 1, 2)))
void slog(char const* fmt, ...)
{
    FILE* f = std::fopen("/tmp/suzuri-ladybird-overlay.log", "a");
    if (!f)
        return;
    std::fprintf(f, "%lld ", static_cast<long long>(time(nullptr)));
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(f, fmt, ap);
    va_end(ap);
    std::fputc('\n', f);
    std::fclose(f);
}

void attach_chrome_mach(std::string const& name)
{
    if (name.empty())
        return;
    mach_port_t port = MACH_PORT_NULL;
    auto kr = bootstrap_look_up(bootstrap_port, name.c_str(), &port);
    if (kr != KERN_SUCCESS || port == MACH_PORT_NULL) {
        slog("mach look_up %s fail %d", name.c_str(), static_cast<int>(kr));
        return;
    }
    if (g_chrome_port != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), g_chrome_port);
    g_chrome_port = port;
    slog("mach look_up %s ok", name.c_str());
}

bool is_internal_url(std::string const& url)
{
    if (url.size() >= 6) {
        auto a = url[0] | 0x20;
        auto b = url[1] | 0x20;
        auto c = url[2] | 0x20;
        auto d = url[3] | 0x20;
        auto e = url[4] | 0x20;
        if (a == 'a' && b == 'b' && c == 'o' && d == 'u' && e == 't' && url[5] == ':')
            return true;
    }
    return false;
}

Tab* active_tab()
{
    ApplicationDelegate* delegate = [NSApp delegate];
    if (delegate == nil)
        return nil;
    if (auto* tab = [delegate activeTab])
        return tab;
    if ([delegate tabCount] > 0)
        return nil;
    // Wait for a real URL so we never spawn Ladybird's about:newtab.
    if (g_rt.url.empty() || is_internal_url(g_rt.url))
        return nil;
    if (g_rt.no_tab_logs < 8) {
        slog("no tab — creating");
        ++g_rt.no_tab_logs;
    }
    (void)[delegate createNewTab:Web::HTML::ActivateTab::Yes fromTab:nil];
    return [delegate activeTab];
}

Ladybird::WebViewBridge* bridge_for(Tab* tab)
{
    if (tab == nil)
        return nullptr;
    return static_cast<Ladybird::WebViewBridge*>(&[[tab web_view] view]);
}

void tune_guest_window(Tab* tab)
{
    if (tab == nil || g_rt.fb.width == 0 || g_rt.fb.height == 0)
        return;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    auto* web_view = [tab web_view];
    auto* window = [web_view window];
    if (window == nil)
        return;

    [window setAlphaValue:0];
    [window setIgnoresMouseEvents:YES];

    // titlebarAccessoryViewControllers asserts on a borderless window.
    if ((window.styleMask & NSWindowStyleMaskTitled) != 0) {
        @try {
            while (window.titlebarAccessoryViewControllers.count > 0)
                [window removeTitlebarAccessoryViewControllerAtIndex:0];
            [window setTitlebarAppearsTransparent:YES];
            [window setTitleVisibility:NSWindowTitleHidden];
            [window setStyleMask:NSWindowStyleMaskBorderless];
            [window setHasShadow:NO];
            [window setIgnoresMouseEvents:YES];
            [window setLevel:NSNormalWindowLevel - 1];
            [window setExcludedFromWindowsMenu:YES];
            [window setAnimationBehavior:NSWindowAnimationBehaviorNone];
            [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces
                    | NSWindowCollectionBehaviorTransient
                    | NSWindowCollectionBehaviorIgnoresCycle
                    | NSWindowCollectionBehaviorStationary];
            [window setContentView:web_view];
        } @catch (NSException* e) {
            slog("strip chrome: %s", e.reason.UTF8String ?: "?");
        }
    }

    double dpr = g_rt.scale > 0.5 ? static_cast<double>(g_rt.scale) : 1.0;
    if (auto* screen = [window screen] ?: [NSScreen mainScreen]) {
        if (g_rt.scale < 0.5)
            dpr = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 1.0;
    }
    auto css_w = std::max(1, static_cast<int>(std::lround(g_rt.fb.width / dpr)));
    auto css_h = std::max(1, static_cast<int>(std::lround(g_rt.fb.height / dpr)));

    [window setContentSize:NSMakeSize(css_w, css_h)];
    hide_guest_window(window);
    force_page_visible(tab);

    if (auto* bridge = bridge_for(tab)) {
        bridge->set_viewport_rect(Gfx::IntRect { 0, 0, css_w, css_h });
        apply_display_metadata(bridge);
    }

    g_rt.window_tuned = true;
    g_rt.last_viewport = std::chrono::steady_clock::now();
    g_rt.viewport_pending = false;
    slog("tune window css=%dx%d fb=%ux%u dpr=%.2f", css_w, css_h, g_rt.fb.width, g_rt.fb.height, dpr);
}

void guest_css_size(int& css_w, int& css_h)
{
    double dpr = g_rt.scale > 0.5 ? static_cast<double>(g_rt.scale) : 1.0;
    css_w = std::max(1, static_cast<int>(std::lround(g_rt.fb.width / dpr)));
    css_h = std::max(1, static_cast<int>(std::lround(g_rt.fb.height / dpr)));
}

void cover_guest_window()
{
    auto* tab = active_tab();
    if (tab == nil || g_rt.fb.width == 0)
        return;
    int css_w = 1, css_h = 1;
    guest_css_size(css_w, css_h);
    pin_page_visible(tab);
}

void commit_guest_viewport()
{
    auto* tab = active_tab();
    auto* bridge = bridge_for(tab);
    if (!tab || !bridge || g_rt.fb.width == 0)
        return;
    int css_w = 1, css_h = 1;
    guest_css_size(css_w, css_h);
    if (auto* window = [tab.web_view window])
        [window setContentSize:NSMakeSize(css_w, css_h)];
    bridge->set_viewport_rect(Gfx::IntRect { 0, 0, css_w, css_h });
    pin_page_visible(tab);
    g_rt.last_viewport = std::chrono::steady_clock::now();
    g_rt.viewport_pending = false;
    // One quiet beat so the first paint at the new size is the one we send.
    g_rt.settling_until = g_rt.last_viewport + std::chrono::milliseconds(80);
}

void log_blit_skip(char const* why)
{
    auto now = std::chrono::steady_clock::now();
    if (g_rt.last_blit_skip.time_since_epoch().count() != 0
        && now - g_rt.last_blit_skip < std::chrono::seconds(1))
        return;
    g_rt.last_blit_skip = now;
    slog("blit skip %s", why);
}

bool blit_viewport(bool throttle = true)
{
    auto* tab = active_tab();
    auto* bridge = bridge_for(tab);
    if (!bridge) {
        log_blit_skip("no-bridge");
        return false;
    }
    if (g_rt.url.empty() || is_internal_url(g_rt.url) || !g_rt.load_issued) {
        log_blit_skip("no-url");
        return false;
    }
    if (!g_rt.session) {
        log_blit_skip("no-session");
        return false;
    }

    auto now = std::chrono::steady_clock::now();
    bool scrolling = now < g_rt.scrolling_until;
    if ((g_rt.viewport_pending || now < g_rt.resizing_until || now < g_rt.settling_until)
        && !g_rt.force_blit)
        return false;
    // Double-buffered presents flip the IOSurface id every vsync.
    // Cap chrome imports even from on_ready_to_paint (throttle=false).
    int gap_ms = 8;
    if (throttle && !scrolling && !g_rt.force_blit)
        gap_ms = 32;
    else if (!g_rt.force_blit && !scrolling)
        gap_ms = 16;
    if (g_rt.last_blit.time_since_epoch().count() != 0
        && now - g_rt.last_blit < std::chrono::milliseconds(gap_ms))
        return false;

    auto paintable = bridge->paintable();
    if (!paintable.has_value() || !paintable->shared_image_buffer) {
        log_blit_skip("no-paintable");
        return false;
    }

    auto* surf = static_cast<IOSurfaceRef>(
        paintable->shared_image_buffer->iosurface_handle().core_foundation_pointer());
    if (!surf) {
        log_blit_skip("no-iosurface");
        return false;
    }

    auto const id = static_cast<std::uint64_t>(IOSurfaceGetID(surf));
    auto const sw = static_cast<std::uint32_t>(IOSurfaceGetWidth(surf));
    auto const sh = static_cast<std::uint32_t>(IOSurfaceGetHeight(surf));
    // Backing stores are padded while resizing. Blit the painted
    // viewport, not the whole IOSurface, or the page sits in the
    // top-left of the well with empty/white around it.
    auto painted = paintable->bitmap_size;
    auto w = painted.width() > 0 ? static_cast<std::uint32_t>(painted.width()) : sw;
    auto h = painted.height() > 0 ? static_cast<std::uint32_t>(painted.height()) : sh;
    if (sw > 0)
        w = std::min(w, sw);
    if (sh > 0)
        h = std::min(h, sh);
    if (id == 0 || w < 8 || h < 8) {
        log_blit_skip("empty-iosurface");
        return false;
    }

    if (!scrolling && !g_rt.force_blit && id == g_rt.last_iosurface_id
        && g_rt.last_blit.time_since_epoch().count() != 0)
        return false;

    ++g_rt.surface_seq;
    g_rt.last_iosurface_id = id;
    g_rt.force_blit = false;
    g_rt.last_blit = now;
    g_rt.session->send_iosurface(id, w, h, g_rt.surface_seq);
    bool sent = send_surface_port(surf);
    if (!sent)
        copy_iosurface_to_fb(surf);
    slog("iosurface id=%llu %ux%u (surf %ux%u) seq=%u mach=%d",
        static_cast<unsigned long long>(id), w, h, sw, sh, g_rt.surface_seq, sent ? 1 : 0);
    return true;
}

void try_load();

void install_hooks(Tab* tab)
{
    if (tab == nil)
        return;
    auto* web_view = [tab web_view];
    if (web_view == nil || web_view == g_rt.hooked)
        return;

    auto& view = [web_view view];
    auto prev_paint = move(view.on_ready_to_paint);
    view.on_ready_to_paint = [prev_paint = move(prev_paint)]() {
        if (prev_paint)
            prev_paint();
        blit_viewport(false);
    };

    auto prev_title = move(view.on_title_change);
    view.on_title_change = [prev_title = move(prev_title)](auto const& title) {
        if (prev_title)
            prev_title(title);
        if (!g_rt.session)
            return;
        auto text = title.to_byte_string();
        std::string s { text.characters(), text.length() };
        if (is_internal_url(s))
            return;
        slog("title %s", s.c_str());
        g_rt.session->send_title(s);
    };

    auto prev_url = move(view.on_url_change);
    view.on_url_change = [prev_url = move(prev_url)](auto const& url) {
        if (prev_url)
            prev_url(url);
        if (!g_rt.session)
            return;
        auto text = url.to_byte_string();
        std::string s { text.characters(), text.length() };
        if (is_internal_url(s))
            return;
        slog("url %s", s.c_str());
        g_rt.session->send_url(s);
    };

    auto prev_start = move(view.on_load_start);
    view.on_load_start = [prev_start = move(prev_start)]() {
        if (prev_start)
            prev_start();
        slog("load_start");
        if (g_rt.session)
            g_rt.session->send_busy(true);
    };

    auto prev_finish = move(view.on_load_finish);
    view.on_load_finish = [prev_finish = move(prev_finish)](auto const& url) {
        if (prev_finish)
            prev_finish(url);
        auto text = url.to_byte_string();
        slog("load_finish %s", text.characters());
        if (g_rt.session)
            g_rt.session->send_busy(false);
        g_rt.last_blit = {};
        g_rt.force_blit = true;
        force_page_visible(active_tab());
        if (auto* b = bridge_for(active_tab()))
            apply_display_metadata(b);
        blit_viewport(false);
    };

    // Synthetic JSON keys have no NSEvent. Ladybird's default finish
    // handler VERIFY-crashes in key_event_to_ns_event (OwnPtr).
    view.on_finish_handling_key_event = [](Web::KeyEvent const&) {};

    g_rt.hooked = web_view;
    slog("hooks installed");
}

void ensure_view()
{
    auto* tab = active_tab();
    if (tab == nil)
        return;
    install_hooks(tab);
    if (!g_rt.window_tuned)
        tune_guest_window(tab);
    [tab.web_view handleVisibility:YES];
    try_load();
}

void try_load()
{
    if (g_rt.load_issued || g_rt.url.empty())
        return;
    auto* tab = active_tab();
    if (tab == nil)
        return;
    slog("load %s", g_rt.url.c_str());
    [[tab web_view] view].load_from_user_input(StringView { g_rt.url.data(), g_rt.url.size() });
    g_rt.load_issued = true;
}

void apply_fb(Suzuri::HostMessage const& msg)
{
    if (!msg.mach.empty())
        attach_chrome_mach(msg.mach);
    if (!msg.fb)
        return;
    bool const same = g_rt.fb.path == msg.fb->path && g_rt.fb.width == msg.fb->width
        && g_rt.fb.height == msg.fb->height;
    g_rt.fb = *msg.fb;
    if (msg.scale > 0)
        g_rt.scale = msg.scale;
    if (same) {
        blit_viewport();
        return;
    }
    g_rt.resizing_until = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
    if (g_rt.window_tuned) {
        // Split/sash: hold the last presented frame. Commit the viewport
        // after the sash is quiet so we do not realloc backing stores
        // on every jelly pixel.
        cover_guest_window();
        g_rt.viewport_pending = true;
        return;
    }
    slog("fb %s %ux%u scale=%.2f", g_rt.fb.path.c_str(), g_rt.fb.width, g_rt.fb.height, g_rt.scale);
    g_rt.window_tuned = false;
    ensure_view();
    blit_viewport(false);
}

void navigate(std::string url)
{
    g_rt.url = move(url);
    g_rt.load_issued = false;
    slog("navigate %s", g_rt.url.c_str());
    if (g_rt.session) {
        g_rt.session->send_busy(true);
        if (!is_internal_url(g_rt.url))
            g_rt.session->send_url(g_rt.url);
    }
    ensure_view();
    if (!g_rt.load_issued && g_rt.session)
        g_rt.session->send_busy(false);
}

void scroll_by(Suzuri::HostMessage const& msg)
{
    if (msg.dx == 0 && msg.dy == 0)
        return;
    auto* tab = active_tab();
    auto* bridge = bridge_for(tab);
    if (!bridge)
        return;

    // Native Ladybird sends device px; wheel delta stays CSS points.
    int x = static_cast<int>(std::lround(msg.rect.x));
    int y = static_cast<int>(std::lround(msg.rect.y));
    if (x == 0 && y == 0) {
        x = std::max(1, static_cast<int>(g_rt.fb.width / 2));
        y = std::max(1, static_cast<int>(g_rt.fb.height / 2));
    }
    Web::MouseEvent event;
    event.type = Web::MouseEvent::Type::MouseWheel;
    event.position = { x, y };
    event.screen_position = { x, y };
    event.button = Web::UIEvents::MouseButton::Middle;
    event.wheel_delta_x = msg.dx;
    event.wheel_delta_y = msg.dy;
    g_rt.scrolling_until = std::chrono::steady_clock::now() + std::chrono::milliseconds(280);
    g_rt.force_blit = true;
    bridge->enqueue_input_event(move(event));
}

Web::UIEvents::MouseButton mouse_button_from_code(int code)
{
    return Web::UIEvents::button_code_to_mouse_button(static_cast<i16>(code));
}

void pointer_at(Suzuri::HostMessage const& msg)
{
    if (!g_rt.hooked)
        ensure_view();
    auto* bridge = bridge_for(active_tab());
    if (!bridge)
        return;

    Web::MouseEvent::Type type = Web::MouseEvent::Type::MouseMove;
    if (msg.kind == "down")
        type = Web::MouseEvent::Type::MouseDown;
    else if (msg.kind == "up")
        type = Web::MouseEvent::Type::MouseUp;
    else if (msg.kind == "leave")
        type = Web::MouseEvent::Type::MouseLeave;

    auto button = mouse_button_from_code(msg.button);
    if (type == Web::MouseEvent::Type::MouseMove && msg.buttons == 0)
        button = Web::UIEvents::MouseButton::None;

    Web::MouseEvent event;
    event.type = type;
    // enqueue_input_event scales widget (CSS) points to device pixels.
    event.position = {
        static_cast<int>(std::lround(msg.rect.x)),
        static_cast<int>(std::lround(msg.rect.y)),
    };
    event.screen_position = event.position;
    event.button = button;
    event.buttons = static_cast<Web::UIEvents::MouseButton>(msg.buttons);
    event.modifiers = static_cast<Web::UIEvents::KeyModifier>(msg.modifiers);
    if (type == Web::MouseEvent::Type::MouseDown || type == Web::MouseEvent::Type::MouseUp)
        event.click_count = 1;
    if (type != Web::MouseEvent::Type::MouseMove)
        g_rt.scrolling_until = std::chrono::steady_clock::now() + std::chrono::milliseconds(180);
    bridge->enqueue_input_event(move(event));
}

Web::UIEvents::KeyCode key_from_name(std::string const& name, std::string const& text)
{
    if (name == "Enter" || name == "Return")
        return Web::UIEvents::KeyCode::Key_Return;
    if (name == "Backspace")
        return Web::UIEvents::KeyCode::Key_Backspace;
    if (name == "Tab")
        return Web::UIEvents::KeyCode::Key_Tab;
    if (name == "Escape")
        return Web::UIEvents::KeyCode::Key_Escape;
    if (name == "ArrowLeft" || name == "Left")
        return Web::UIEvents::KeyCode::Key_Left;
    if (name == "ArrowRight" || name == "Right")
        return Web::UIEvents::KeyCode::Key_Right;
    if (name == "ArrowUp" || name == "Up")
        return Web::UIEvents::KeyCode::Key_Up;
    if (name == "ArrowDown" || name == "Down")
        return Web::UIEvents::KeyCode::Key_Down;
    if (name == "Home")
        return Web::UIEvents::KeyCode::Key_Home;
    if (name == "End")
        return Web::UIEvents::KeyCode::Key_End;
    if (name == "PageUp")
        return Web::UIEvents::KeyCode::Key_PageUp;
    if (name == "PageDown")
        return Web::UIEvents::KeyCode::Key_PageDown;
    if (name == "Delete")
        return Web::UIEvents::KeyCode::Key_Delete;
    if (name == "Space" || text == " ")
        return Web::UIEvents::KeyCode::Key_Space;
    auto ch = text.empty() ? (name.empty() ? 0 : name[0]) : text[0];
    if (ch >= 'a' && ch <= 'z')
        return static_cast<Web::UIEvents::KeyCode>(static_cast<int>(Web::UIEvents::KeyCode::Key_A) + (ch - 'a'));
    if (ch >= 'A' && ch <= 'Z')
        return static_cast<Web::UIEvents::KeyCode>(static_cast<int>(Web::UIEvents::KeyCode::Key_A) + (ch - 'A'));
    if (ch >= '0' && ch <= '9')
        return static_cast<Web::UIEvents::KeyCode>(static_cast<int>(Web::UIEvents::KeyCode::Key_0) + (ch - '0'));
    return Web::UIEvents::KeyCode::Key_Invalid;
}

void send_key(Suzuri::HostMessage const& msg)
{
    ensure_view();
    auto* bridge = bridge_for(active_tab());
    if (!bridge)
        return;

    Web::KeyEvent event;
    event.type = msg.kind == "up" ? Web::KeyEvent::Type::KeyUp : Web::KeyEvent::Type::KeyDown;
    event.key = key_from_name(msg.key, msg.text);
    event.modifiers = static_cast<Web::UIEvents::KeyModifier>(msg.modifiers);
    if (!msg.text.empty()) {
        event.code_point = static_cast<u32>(static_cast<unsigned char>(msg.text[0]));
        event.should_insert_text = event.type == Web::KeyEvent::Type::KeyDown;
    }
    g_rt.scrolling_until = std::chrono::steady_clock::now() + std::chrono::milliseconds(180);
    bridge->enqueue_input_event(move(event));
}

void handle_host(Suzuri::HostMessage const& msg)
{
    switch (msg.type) {
    case Suzuri::HostMessage::Type::Spawn:
    case Suzuri::HostMessage::Type::Resize:
        apply_fb(msg);
        break;
    case Suzuri::HostMessage::Type::Navigate:
        navigate(msg.url);
        break;
    case Suzuri::HostMessage::Type::Scroll:
        scroll_by(msg);
        break;
    case Suzuri::HostMessage::Type::Pointer:
        pointer_at(msg);
        break;
    case Suzuri::HostMessage::Type::Key:
        send_key(msg);
        break;
    case Suzuri::HostMessage::Type::Focus:
    case Suzuri::HostMessage::Type::Draft:
    case Suzuri::HostMessage::Type::Stack:
    case Suzuri::HostMessage::Type::Kill:
    case Suzuri::HostMessage::Type::Unknown:
        break;
    }
}

void start_timer()
{
    if (g_rt.timer)
        return;
    g_rt.timer = true;
    // GCD timer — NSTimer scheduled from a dispatch block can miss the run loop.
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
        200 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        ensure_view();
        auto now = std::chrono::steady_clock::now();
        bool scrolling = now < g_rt.scrolling_until;
        bool resizing = now < g_rt.resizing_until;
        if (g_rt.viewport_pending && !resizing)
            commit_guest_viewport();
        if (!g_rt.visibility_forced)
            force_page_visible(active_tab());
        else
            pin_page_visible(active_tab());
        if (g_rt.load_issued)
            blit_viewport(!scrolling && !resizing);
    });
    dispatch_resume(timer);
}

void prepare_appkit()
{
    hide_all_guest_windows();
    if (!g_rt.observers) {
        g_rt.observers = true;
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:NSApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification*) {
                        slog("did_finish_launching");
                        hide_all_guest_windows();
                        ensure_view();
                    }];
        [nc addObserverForName:NSWindowDidChangeOcclusionStateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification*) {
                        pin_page_visible(active_tab());
                    }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* n) {
                        hide_guest_window(n.object);
                    }];
    }
    start_timer();
    ensure_view();
    blit_viewport();
}

} // namespace

static void suzuri_guest_thread(std::uint16_t port)
{
    Suzuri::Session session;
    if (!session.connect(port)) {
        slog("connect failed port=%u", static_cast<unsigned>(port));
        return;
    }
    session.send_hello("guest");
    slog("hello port=%u", static_cast<unsigned>(port));

    auto* session_ptr = &session;

    dispatch_async(dispatch_get_main_queue(), ^{
        g_rt.session = session_ptr;
        prepare_appkit();
    });

    Suzuri::HostMessage msg;
    while (session.poll(msg)) {
        if (msg.type == Suzuri::HostMessage::Type::Kill)
            break;
        bool const live = msg.type == Suzuri::HostMessage::Type::Scroll
            || msg.type == Suzuri::HostMessage::Type::Pointer
            || msg.type == Suzuri::HostMessage::Type::Key;
        if (live) {
            auto copy = msg;
            dispatch_async(dispatch_get_main_queue(), ^{
                handle_host(copy);
            });
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                handle_host(msg);
            });
        }
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        g_rt.session = nullptr;
        g_rt.hooked = nil;
    });
    slog("session end");
}

void suzuri_guest_prepare_app(void)
{
    if (!g_is_guest)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        hide_all_guest_windows();
    });
}

int suzuri_guest_try_start(int argc, char const* const* argv)
{
    auto port = Suzuri::port_from_args(argc, argv);
    if (!port)
        return 0;
    g_is_guest = true;
    // Occlusion / last-window patches key off this. Chrome sets it too;
    // set it here so a missing env still keeps WebContent Visible.
    char port_buf[16];
    std::snprintf(port_buf, sizeof(port_buf), "%u", static_cast<unsigned>(*port));
    setenv("SUZURI_GUEST_PORT", port_buf, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        hide_all_guest_windows();
    });
    std::thread(suzuri_guest_thread, *port).detach();
    return 1;
}
