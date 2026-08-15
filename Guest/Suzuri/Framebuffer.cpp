#include "Framebuffer.h"

#include <algorithm>
#include <cstring>
#include <fstream>

namespace Suzuri {

static constexpr char const magic[4] = { 'S', 'Z', 'F', 'B' };

bool write_szfb(Framebuffer& fb, std::vector<std::uint8_t> const& bgra)
{
    if (fb.width == 0 || fb.height == 0 || fb.path.empty())
        return false;
    auto const n = static_cast<std::size_t>(fb.width) * fb.height * 4;
    if (bgra.size() < n)
        return false;
    fb.seq += 1;
    std::fstream out(fb.path, std::ios::in | std::ios::out | std::ios::binary);
    if (!out) {
        out.open(fb.path, std::ios::out | std::ios::binary | std::ios::trunc);
        if (!out)
            return false;
    }
    out.seekp(16);
    out.write(reinterpret_cast<char const*>(bgra.data()), static_cast<std::streamsize>(n));
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
    out.seekp(0);
    out.write(hdr, 16);
    out.flush();
    return static_cast<bool>(out);
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
