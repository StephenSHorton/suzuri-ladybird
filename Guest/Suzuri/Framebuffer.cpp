#include "Framebuffer.h"

#include <algorithm>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace Suzuri {

static constexpr char const magic[4] = { 'S', 'Z', 'F', 'B' };

struct Mapping {
    std::string path;
    int fd { -1 };
    std::uint8_t* p { nullptr };
    std::size_t len { 0 };
};

static Mapping g_map;

static void unmap()
{
    if (g_map.p && g_map.p != MAP_FAILED)
        munmap(g_map.p, g_map.len);
    if (g_map.fd >= 0)
        close(g_map.fd);
    g_map = {};
}

static std::size_t payload_bytes(Framebuffer const& fb)
{
    return static_cast<std::size_t>(fb.width) * fb.height * 4;
}

std::uint8_t* map_pixels(Framebuffer& fb)
{
    if (fb.width == 0 || fb.height == 0 || fb.path.empty())
        return nullptr;
    auto const n = payload_bytes(fb);
    auto const total = 16 + n;
    if (g_map.p && g_map.path == fb.path && g_map.len == total) {
        struct stat st {};
        if (fstat(g_map.fd, &st) == 0 && static_cast<std::size_t>(st.st_size) >= total)
            return g_map.p + 16;
    }

    unmap();
    int fd = open(fb.path.c_str(), O_RDWR | O_CREAT, 0644);
    if (fd < 0)
        return nullptr;
    if (ftruncate(fd, static_cast<off_t>(total)) != 0) {
        close(fd);
        return nullptr;
    }
    auto* p = static_cast<std::uint8_t*>(mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
    if (p == MAP_FAILED) {
        close(fd);
        return nullptr;
    }
    g_map = { fb.path, fd, p, total };
    return p + 16;
}

void publish_szfb(Framebuffer& fb)
{
    if (!g_map.p || g_map.path != fb.path)
        return;
    fb.seq += 1;
    char hdr[16] {};
    std::memcpy(hdr, magic, 4);
    auto put_u32 = [](char* p, std::uint32_t v) {
        p[0] = static_cast<char>(v & 0xff);
        p[1] = static_cast<char>((v >> 8) & 0xff);
        p[2] = static_cast<char>((v >> 16) & 0xff);
        p[3] = static_cast<char>((v >> 24) & 0xff);
    };
    put_u32(hdr + 4, fb.width);
    put_u32(hdr + 8, fb.height);
    put_u32(hdr + 12, fb.seq);
    std::memcpy(g_map.p, hdr, 16);
}

bool write_szfb(Framebuffer& fb, std::vector<std::uint8_t> const& bgra)
{
    auto const n = payload_bytes(fb);
    if (n == 0 || bgra.size() < n)
        return false;
    auto* dest = map_pixels(fb);
    if (!dest)
        return false;
    std::memcpy(dest, bgra.data(), n);
    publish_szfb(fb);
    return true;
}

void paint_placeholder(Framebuffer& fb, std::string const& url)
{
    auto const w = static_cast<std::size_t>(fb.width);
    auto const h = static_cast<std::size_t>(fb.height);
    if (w == 0 || h == 0)
        return;
    std::vector<std::uint8_t> px(w * h * 4);
    std::uint32_t hash = 2166136261u;
    for (unsigned char c : url) {
        hash ^= c;
        hash *= 16777619u;
    }
    std::uint8_t const rail[4] = { 36, 92, 232, 255 };
    std::uint8_t const fill[4] = { 18, 16, 12, 255 };
    std::uint8_t const bar[4] = { 32, 48, 72, 255 };
    std::uint8_t const stripe[4] = {
        static_cast<std::uint8_t>(20 + (hash & 0x3f)),
        static_cast<std::uint8_t>(60 + ((hash >> 8) & 0x3f)),
        static_cast<std::uint8_t>(160 + ((hash >> 16) & 0x3f)),
        255,
    };
    auto const rail_w = std::min<std::size_t>(8, w);
    auto const bar_h = std::min<std::size_t>(6, h);
    auto const band_y = std::min<std::size_t>(16, h ? h - 1 : 0);
    auto const band_h = std::min<std::size_t>(4, h > band_y ? h - band_y : 0);
    for (std::size_t y = 0; y < h; ++y) {
        for (std::size_t x = 0; x < w; ++x) {
            auto const* c = fill;
            if (x < rail_w)
                c = rail;
            else if (y < bar_h)
                c = bar;
            else if (y >= band_y && y < band_y + band_h)
                c = stripe;
            auto i = (y * w + x) * 4;
            std::memcpy(px.data() + i, c, 4);
        }
    }
    write_szfb(fb, px);
}

} // namespace Suzuri
