#pragma once

#include "Framebuffer.h"

#include <cstdint>
#include <functional>
#include <optional>
#include <string>

namespace Suzuri {

struct Rect {
    float x { 0 };
    float y { 0 };
    float w { 0 };
    float h { 0 };
};

struct HostMessage {
    enum class Type {
        Spawn,
        Resize,
        Focus,
        Navigate,
        Scroll,
        Pointer,
        Key,
        Draft,
        Stack,
        Kill,
        Unknown,
    };
    Type type { Type::Unknown };
    std::string pane_id;
    Rect rect {};
    float scale { 1 };
    std::string cwd;
    std::string url;
    bool focus_in { false };
    double dx { 0 };
    double dy { 0 };
    std::string kind;
    int button { 0 };
    int buttons { 0 };
    int modifiers { 0 };
    std::string key;
    std::string text;
    std::optional<Framebuffer> fb;
};

class Session {
public:
    using Handler = std::function<void(HostMessage const&)>;

    bool connect(std::uint16_t port);
    void send_hello(std::string const& title = "Ladybird");
    void send_title(std::string const& text);
    void send_url(std::string const& text);
    void send_busy(bool busy);
    void send_surface(Framebuffer const& fb);
    void send_crash(std::string const& message);

    // Blocking read of one JSON line. Returns false on EOF.
    bool poll(HostMessage& out);

    int fd() const { return m_fd; }

private:
    bool write_line(std::string const& line);
    int m_fd { -1 };
};

std::optional<std::uint16_t> port_from_args(int argc, char const* const* argv);
HostMessage parse_host_line(std::string const& line);

} // namespace Suzuri
