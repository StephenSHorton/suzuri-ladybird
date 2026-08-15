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
#include <LibWebView/ViewImplementation.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <thread>
#include <vector>

#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>

#if !__has_feature(objc_arc)
#    error "Suzuri guest requires ARC"
#endif

// One long-lived Ladybird. Socket thread owns TCP. AppKit work is on the
// main queue. Viewport pixels go into SZFB — no extra process, no full PNG.

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
};

GuestRuntime g_rt;

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

void send_surface()
{
    if (!g_rt.session || g_rt.fb.path.empty())
        return;
    g_rt.session->send_surface(g_rt.fb);
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

    // Keep a 1×1 on-screen sliver so AppKit does not treat the window as
    // occluded (that pauses WebContent paints). The well gets SZFB pixels.
    [window setFrame:NSMakeRect(0, 0, css_w, css_h) display:YES];
    [window setContentSize:NSMakeSize(css_w, css_h)];
    [window setAlphaValue:0.02];
    [window orderBack:nil];
    [web_view handleVisibility:YES];

    if (auto* bridge = bridge_for(tab))
        bridge->set_viewport_rect(Gfx::IntRect { 0, 0, css_w, css_h });

    g_rt.window_tuned = true;
    slog("tune window css=%dx%d fb=%ux%u dpr=%.2f", css_w, css_h, g_rt.fb.width, g_rt.fb.height, dpr);
}

bool blit_viewport()
{
    auto* tab = active_tab();
    auto* bridge = bridge_for(tab);
    if (!bridge || g_rt.fb.path.empty() || g_rt.fb.width == 0 || g_rt.fb.height == 0)
        return false;

    auto now = std::chrono::steady_clock::now();
    bool scrolling = now < g_rt.scrolling_until;
    auto min_gap = scrolling ? std::chrono::milliseconds(16) : std::chrono::milliseconds(33);
    if (!g_rt.force_blit && g_rt.last_blit.time_since_epoch().count() != 0
        && now - g_rt.last_blit < min_gap)
        return false;

    auto paintable = bridge->paintable();
    if (!paintable.has_value() || !paintable->shared_image_buffer)
        return false;
    auto bitmap = paintable->shared_image_buffer->bitmap_if_present();
    if (!bitmap)
        return false;

    auto* dest = Suzuri::map_pixels(g_rt.fb);
    if (!dest)
        return false;

    auto* surf = static_cast<IOSurfaceRef>(paintable->shared_image_buffer->iosurface_handle().core_foundation_pointer());
    if (surf)
        IOSurfaceLock(surf, kIOSurfaceLockReadOnly, nullptr);

    auto const dst_w = static_cast<int>(g_rt.fb.width);
    auto const dst_h = static_cast<int>(g_rt.fb.height);
    auto const src_w = bitmap->width();
    auto const src_h = bitmap->height();
    auto const copy_w = std::min(dst_w, src_w);
    auto const copy_h = std::min(dst_h, src_h);
    if (copy_w <= 0 || copy_h <= 0) {
        if (surf)
            IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, nullptr);
        return false;
    }

    auto const row_bytes = static_cast<std::size_t>(copy_w) * 4;
    std::uint32_t hash = 2166136261u;
    for (int y = 0; y < copy_h; ++y) {
        auto const* src = bitmap->scanline_u8(y);
        if (!src)
            continue;
        std::memcpy(dest + static_cast<std::size_t>(y) * dst_w * 4, src, row_bytes);
        if ((y & 15) == 0) {
            auto const* px32 = reinterpret_cast<std::uint32_t const*>(src);
            hash ^= px32[0] ^ px32[static_cast<unsigned>(copy_w / 2)]
                ^ px32[static_cast<unsigned>(copy_w - 1)];
        }
    }

    if (surf)
        IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, nullptr);

    if (!scrolling && !g_rt.force_blit && hash == g_rt.blit_hash)
        return false;

    Suzuri::publish_szfb(g_rt.fb);
    g_rt.blit_hash = hash;
    g_rt.force_blit = false;
    g_rt.last_blit = now;
    send_surface();
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
        blit_viewport();
    };

    auto prev_title = move(view.on_title_change);
    view.on_title_change = [prev_title = move(prev_title)](auto const& title) {
        if (prev_title)
            prev_title(title);
        if (!g_rt.session)
            return;
        auto text = title.to_byte_string();
        slog("title %s", text.characters());
        g_rt.session->send_title(std::string { text.characters(), text.length() });
    };

    auto prev_url = move(view.on_url_change);
    view.on_url_change = [prev_url = move(prev_url)](auto const& url) {
        if (prev_url)
            prev_url(url);
        if (!g_rt.session)
            return;
        auto text = url.to_byte_string();
        slog("url %s", text.characters());
        g_rt.session->send_url(std::string { text.characters(), text.length() });
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
        blit_viewport();
    };

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
    if (!msg.fb)
        return;
    g_rt.fb = *msg.fb;
    if (msg.scale > 0)
        g_rt.scale = msg.scale;
    slog("fb %s %ux%u scale=%.2f", g_rt.fb.path.c_str(), g_rt.fb.width, g_rt.fb.height, g_rt.scale);
    // Resize must not re-strip chrome (borderless windows abort on accessories).
    if (g_rt.window_tuned)
        g_rt.window_tuned = false;
    ensure_view();
    if (!blit_viewport() && !g_rt.fb.path.empty()) {
        Suzuri::paint_placeholder(g_rt.fb, g_rt.url);
        send_surface();
    }
}

void navigate(std::string url)
{
    g_rt.url = move(url);
    g_rt.load_issued = false;
    slog("navigate %s", g_rt.url.c_str());
    if (g_rt.session) {
        g_rt.session->send_busy(true);
        g_rt.session->send_title(g_rt.url.empty() ? "Ladybird" : g_rt.url);
        g_rt.session->send_url(g_rt.url);
    }
    if (!g_rt.fb.path.empty()) {
        Suzuri::paint_placeholder(g_rt.fb, g_rt.url);
        send_surface();
    }
    ensure_view();
    if (!g_rt.load_issued && g_rt.session)
        g_rt.session->send_busy(false);
}

void scroll_by(Suzuri::HostMessage const& msg)
{
    if (msg.dx == 0 && msg.dy == 0)
        return;
    auto* bridge = bridge_for(active_tab());
    if (!bridge)
        return;

    double dpr = g_rt.scale > 0.5 ? static_cast<double>(g_rt.scale) : 1.0;
    int x = static_cast<int>(msg.rect.x);
    int y = static_cast<int>(msg.rect.y);
    if (x == 0 && y == 0) {
        x = std::max(1, static_cast<int>(g_rt.fb.width / dpr / 2));
        y = std::max(1, static_cast<int>(g_rt.fb.height / dpr / 2));
    }
    Web::MouseEvent event;
    event.type = Web::MouseEvent::Type::MouseWheel;
    event.position = { x, y };
    event.screen_position = { x, y };
    event.button = Web::UIEvents::MouseButton::Middle;
    event.wheel_delta_x = msg.dx;
    event.wheel_delta_y = msg.dy;
    g_rt.scrolling_until = std::chrono::steady_clock::now() + std::chrono::milliseconds(180);
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
    event.position = { static_cast<int>(msg.rect.x), static_cast<int>(msg.rect.y) };
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
        if (!g_rt.load_issued) {
            g_rt.last_blit = {};
            blit_viewport();
        }
    });
    dispatch_resume(timer);
}

void prepare_appkit()
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    if (!g_rt.observers) {
        g_rt.observers = true;
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification*) {
                        slog("did_finish_launching");
                        ensure_view();
                    }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidChangeOcclusionStateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification*) {
                        if (auto* tab = active_tab())
                            [tab.web_view handleVisibility:YES];
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
    session.send_hello("Ladybird");
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

int suzuri_guest_try_start(int argc, char const* const* argv)
{
    auto port = Suzuri::port_from_args(argc, argv);
    if (!port)
        return 0;
    std::thread(suzuri_guest_thread, *port).detach();
    return 1;
}
