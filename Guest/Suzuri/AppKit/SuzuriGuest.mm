#include "SuzuriGuest.h"
#include "../Framebuffer.h"
#include "../Protocol.h"

#include <thread>

#if !__has_feature(objc_arc)
#    error "Suzuri guest requires ARC"
#endif

// In-process guest loop. Ladybird's own event loop still runs so WebContent
// can paint. This thread owns the suzuri socket.
static void suzuri_guest_thread(std::uint16_t port)
{
    Suzuri::Session session;
    if (!session.connect(port))
        return;
    session.send_hello("Ladybird");

    Suzuri::Framebuffer fb;
    std::string url;
    Suzuri::HostMessage msg;
    while (session.poll(msg)) {
        switch (msg.type) {
        case Suzuri::HostMessage::Type::Spawn:
        case Suzuri::HostMessage::Type::Resize:
            if (msg.fb)
                fb = *msg.fb;
            Suzuri::paint_placeholder(fb, url);
            if (!fb.path.empty())
                session.send_surface(fb);
            break;
        case Suzuri::HostMessage::Type::Navigate:
            url = msg.url;
            session.send_busy(true);
            session.send_title(url.empty() ? "Ladybird" : url);
            session.send_url(url);
            Suzuri::paint_placeholder(fb, url);
            if (!fb.path.empty())
                session.send_surface(fb);
            session.send_busy(false);
            // Next: loadURL on the active LadybirdWebView and copy its
            // bitmap into SZFB (see LibWebView HeadlessMode::Screenshot).
            break;
        case Suzuri::HostMessage::Type::Kill:
            return;
        default:
            break;
        }
    }
}

int suzuri_guest_try_start(int argc, char const* const* argv)
{
    auto port = Suzuri::port_from_args(argc, argv);
    if (!port)
        return 0;
    std::thread(suzuri_guest_thread, *port).detach();
    return 1;
}
