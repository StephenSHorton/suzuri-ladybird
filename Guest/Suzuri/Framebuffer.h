#pragma once

#include <cstdint>
#include <string>
#include <vector>

// SZFB: 16-byte header (magic SZFB, le u32 w/h/seq) + BGRA rows.
namespace Suzuri {

struct Framebuffer {
    std::string path;
    std::uint32_t width { 0 };
    std::uint32_t height { 0 };
    std::uint32_t seq { 0 };
};

bool write_szfb(Framebuffer& fb, std::vector<std::uint8_t> const& bgra);
// Shared mapping of the SZFB file. Pixel payload starts at offset 16.
std::uint8_t* map_pixels(Framebuffer& fb);
void publish_szfb(Framebuffer& fb);
void paint_placeholder(Framebuffer& fb, std::string const& url);

} // namespace Suzuri
