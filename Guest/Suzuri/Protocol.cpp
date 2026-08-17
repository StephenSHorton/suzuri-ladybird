#include "Protocol.h"

#include <cstdlib>
#include <arpa/inet.h>
#include <cstring>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sstream>
#include <sys/socket.h>
#include <unistd.h>

namespace Suzuri {
namespace {

std::string json_escape(std::string const& s)
{
    std::string o;
    o.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
        case '"':
            o += "\\\"";
            break;
        case '\\':
            o += "\\\\";
            break;
        case '\n':
            o += "\\n";
            break;
        case '\r':
            o += "\\r";
            break;
        case '\t':
            o += "\\t";
            break;
        default:
            o += static_cast<char>(c);
            break;
        }
    }
    return o;
}

std::optional<std::string> json_string(std::string const& line, char const* key)
{
    std::string pat = std::string("\"") + key + "\"";
    auto pos = line.find(pat);
    if (pos == std::string::npos)
        return std::nullopt;
    pos = line.find(':', pos + pat.size());
    if (pos == std::string::npos)
        return std::nullopt;
    pos = line.find('"', pos + 1);
    if (pos == std::string::npos)
        return std::nullopt;
    std::string out;
    for (std::size_t i = pos + 1; i < line.size(); ++i) {
        if (line[i] == '\\' && i + 1 < line.size()) {
            out += line[i + 1];
            ++i;
            continue;
        }
        if (line[i] == '"')
            return out;
        out += line[i];
    }
    return std::nullopt;
}

std::optional<double> json_number(std::string const& line, char const* key)
{
    std::string pat = std::string("\"") + key + "\"";
    auto pos = line.find(pat);
    if (pos == std::string::npos)
        return std::nullopt;
    pos = line.find(':', pos + pat.size());
    if (pos == std::string::npos)
        return std::nullopt;
    ++pos;
    while (pos < line.size() && (line[pos] == ' '))
        ++pos;
    char* end = nullptr;
    auto v = std::strtod(line.c_str() + pos, &end);
    if (end == line.c_str() + pos)
        return std::nullopt;
    return v;
}

std::optional<int> parse_int(char const* s)
{
    if (!s || !*s)
        return std::nullopt;
    char* end = nullptr;
    auto v = std::strtol(s, &end, 10);
    if (end == s)
        return std::nullopt;
    return static_cast<int>(v);
}

} // namespace

bool Session::connect(std::uint16_t port)
{
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return false;
    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        return false;
    }
    int one = 1;
    ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    m_fd = fd;
    return true;
}

bool Session::write_line(std::string const& line)
{
    if (m_fd < 0)
        return false;
    auto msg = line + "\n";
    auto* p = msg.data();
    auto n = msg.size();
    while (n) {
        auto w = ::write(m_fd, p, n);
        if (w <= 0)
            return false;
        p += w;
        n -= static_cast<std::size_t>(w);
    }
    return true;
}

void Session::send_hello(std::string const& title)
{
    write_line("{\"type\":\"hello\",\"protocol\":1,\"title\":\"" + json_escape(title) + "\"}");
}

void Session::send_title(std::string const& text)
{
    write_line("{\"type\":\"title\",\"string\":\"" + json_escape(text) + "\"}");
}

void Session::send_url(std::string const& text)
{
    write_line("{\"type\":\"url\",\"string\":\"" + json_escape(text) + "\"}");
}

void Session::send_busy(bool busy)
{
    write_line(std::string("{\"type\":\"busy\",\"bool\":") + (busy ? "true" : "false") + "}");
}

void Session::send_surface(Framebuffer const& fb)
{
    std::ostringstream o;
    o << "{\"type\":\"surface\",\"kind\":\"file\",\"path\":\"" << json_escape(fb.path)
      << "\",\"width\":" << fb.width << ",\"height\":" << fb.height << "}";
    write_line(o.str());
}

void Session::send_iosurface(std::uint64_t id, std::uint32_t width, std::uint32_t height, std::uint32_t seq)
{
    std::ostringstream o;
    o << "{\"type\":\"surface\",\"kind\":\"iosurface\",\"id\":" << id
      << ",\"width\":" << width << ",\"height\":" << height << ",\"seq\":" << seq << "}";
    write_line(o.str());
}

void Session::send_crash(std::string const& message)
{
    write_line("{\"type\":\"crash\",\"message\":\"" + json_escape(message) + "\"}");
}

bool Session::poll(HostMessage& out)
{
    if (m_fd < 0)
        return false;
    std::string line;
    char c;
    while (true) {
        auto n = ::read(m_fd, &c, 1);
        if (n == 0)
            return false;
        if (n < 0)
            return false;
        if (c == '\n')
            break;
        if (c != '\r')
            line += c;
    }
    out = parse_host_line(line);
    return true;
}

std::optional<std::uint16_t> port_from_args(int argc, char const* const* argv)
{
    std::optional<std::uint16_t> port;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--suzuri-guest")
            continue;
        if (a == "--port" && i + 1 < argc) {
            if (auto v = parse_int(argv[++i]); v && *v > 0 && *v < 65536)
                port = static_cast<std::uint16_t>(*v);
            continue;
        }
        if (a.rfind("--port=", 0) == 0) {
            if (auto v = parse_int(a.c_str() + 7); v && *v > 0 && *v < 65536)
                port = static_cast<std::uint16_t>(*v);
        }
    }
    if (port)
        return port;
    if (auto* env = std::getenv("SUZURI_GUEST_PORT")) {
        if (auto v = parse_int(env); v && *v > 0 && *v < 65536)
            return static_cast<std::uint16_t>(*v);
    }
    return std::nullopt;
}

HostMessage parse_host_line(std::string const& line)
{
    HostMessage m;
    auto type = json_string(line, "type").value_or("");
    if (type == "spawn")
        m.type = HostMessage::Type::Spawn;
    else if (type == "resize")
        m.type = HostMessage::Type::Resize;
    else if (type == "focus")
        m.type = HostMessage::Type::Focus;
    else if (type == "navigate")
        m.type = HostMessage::Type::Navigate;
    else if (type == "scroll")
        m.type = HostMessage::Type::Scroll;
    else if (type == "pointer")
        m.type = HostMessage::Type::Pointer;
    else if (type == "key")
        m.type = HostMessage::Type::Key;
    else if (type == "draft")
        m.type = HostMessage::Type::Draft;
    else if (type == "stack")
        m.type = HostMessage::Type::Stack;
    else if (type == "kill")
        m.type = HostMessage::Type::Kill;
    m.pane_id = json_string(line, "pane_id").value_or("");
    m.cwd = json_string(line, "cwd").value_or("");
    m.url = json_string(line, "url").value_or("");
    if (auto s = json_number(line, "scale"))
        m.scale = static_cast<float>(*s);
    if (auto x = json_number(line, "x"))
        m.rect.x = static_cast<float>(*x);
    if (auto y = json_number(line, "y"))
        m.rect.y = static_cast<float>(*y);
    if (auto w = json_number(line, "w"))
        m.rect.w = static_cast<float>(*w);
    if (auto h = json_number(line, "h"))
        m.rect.h = static_cast<float>(*h);
    if (auto dx = json_number(line, "dx"))
        m.dx = *dx;
    if (auto dy = json_number(line, "dy"))
        m.dy = *dy;
    m.kind = json_string(line, "kind").value_or("");
    m.key = json_string(line, "key").value_or("");
    m.text = json_string(line, "text").value_or("");
    if (auto b = json_number(line, "button"))
        m.button = static_cast<int>(*b);
    if (auto b = json_number(line, "buttons"))
        m.buttons = static_cast<int>(*b);
    if (auto mods = json_number(line, "modifiers"))
        m.modifiers = static_cast<int>(*mods);
    m.mach = json_string(line, "mach").value_or("");
    if (auto path = json_string(line, "path")) {
        Framebuffer fb;
        fb.path = *path;
        if (auto w = json_number(line, "width"))
            fb.width = static_cast<std::uint32_t>(*w);
        if (auto h = json_number(line, "height"))
            fb.height = static_cast<std::uint32_t>(*h);
        if (!fb.path.empty() && fb.width && fb.height)
            m.fb = fb;
    }
    return m;
}

} // namespace Suzuri
