//! Suzuri guest for Ladybird. Chrome never links this crate.
//!
//! Speaks line-delimited JSON on 127.0.0.1. Paints SZFB. If a Ladybird
//! binary is on `LADYBIRD` (or a default path), navigate shells out to
//! `--headless screenshot` and copies the PNG into the well.

use std::env;
use std::io::{self, BufRead, BufReader, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{self, Command};

const HELLO: &[u8] = b"{\"type\":\"hello\",\"protocol\":1,\"title\":\"Ladybird\"}\n";

/// Distinct from the example guest's jade rail.
const RAIL: [u8; 4] = [36, 92, 232, 255];
const FILL: [u8; 4] = [18, 16, 12, 255];
const BAR: [u8; 4] = [32, 48, 72, 255];

struct FbSlot {
    path: String,
    w: u32,
    h: u32,
}

fn main() {
    let port = match resolve_port(env::args().skip(1), env::var("SUZURI_GUEST_PORT").ok()) {
        Ok(port) => port,
        Err(msg) => {
            eprintln!("suzuri-ladybird: {msg}");
            process::exit(1);
        }
    };

    let mut stream = match TcpStream::connect(("127.0.0.1", port)) {
        Ok(stream) => stream,
        Err(err) => {
            eprintln!("suzuri-ladybird: connect 127.0.0.1:{port} failed: {err}");
            process::exit(1);
        }
    };

    if let Err(err) = stream.write_all(HELLO).and_then(|_| stream.flush()) {
        eprintln!("suzuri-ladybird: write hello failed: {err}");
        process::exit(1);
    }

    let _ = serve(stream);
}

fn serve(stream: TcpStream) -> io::Result<()> {
    let mut writer = stream.try_clone()?;
    let mut fb: Option<FbSlot> = None;
    let mut url = String::new();
    for line in BufReader::new(stream).lines() {
        let line = line?;
        if line.is_empty() {
            continue;
        }
        match message_type(&line).as_deref() {
            Some("spawn") | Some("resize") => {
                if let Some(next) = parse_fb(&line) {
                    fb = Some(next);
                }
                if let Some(slot) = &fb {
                    paint_current(slot, &url);
                    write_line(&mut writer, &surface_msg(slot))?;
                }
            }
            Some("stack") | Some("focus") | Some("draft") => {}
            Some("navigate") => {
                url = extract_url(&line);
                write_line(&mut writer, &field_msg("busy", "true"))?;
                write_line(&mut writer, &field_msg("title", title_for(&url)))?;
                write_line(&mut writer, &field_msg("url", &url))?;
                if let Some(slot) = &fb {
                    let _ = paint_placeholder(slot, &url);
                    write_line(&mut writer, &surface_msg(slot))?;
                    if paint_ladybird(slot, &url).is_ok() {
                        write_line(&mut writer, &surface_msg(slot))?;
                    }
                }
                write_line(&mut writer, r#"{"type":"busy","bool":false}"#)?;
            }
            Some("kill") => return Ok(()),
            _ => {}
        }
    }
    Ok(())
}

fn title_for(url: &str) -> &str {
    if url.is_empty() {
        "Ladybird"
    } else {
        url
    }
}

fn paint_current(fb: &FbSlot, url: &str) {
    if paint_ladybird(fb, url).is_ok() {
        return;
    }
    let _ = paint_placeholder(fb, url);
}

fn paint_ladybird(fb: &FbSlot, url: &str) -> io::Result<()> {
    if url.is_empty() {
        return Err(io::Error::other("no url"));
    }
    let bin = find_ladybird().ok_or_else(|| io::Error::other("no ladybird binary"))?;
    headless_into_fb(&bin, fb, url)
}

fn find_ladybird() -> Option<PathBuf> {
    if let Ok(p) = env::var("LADYBIRD") {
        let path = PathBuf::from(p);
        if path.is_file() {
            return Some(path);
        }
    }
    let home = env::var("HOME").ok()?;
    let candidates = [
        format!("{home}/projects/ladybird/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird"),
        format!("{home}/projects/ladybird/Build/release/bin/Ladybird"),
        format!("{home}/ladybird/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird"),
        "/Applications/Ladybird.app/Contents/MacOS/Ladybird".into(),
    ];
    candidates.into_iter().map(PathBuf::from).find(|p| p.is_file())
}

fn headless_into_fb(bin: &Path, fb: &FbSlot, url: &str) -> io::Result<()> {
    let png = std::env::temp_dir().join(format!(
        "suzuri-ladybird-{}-{}.png",
        process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0)
    ));
    let mut cmd = Command::new(bin);
    if let Some(dir) = bin.parent() {
        cmd.current_dir(dir);
    }
    if let Ok(src) = env::var("LADYBIRD_SOURCE_DIR") {
        cmd.env("LADYBIRD_SOURCE_DIR", src);
    }
    let status = cmd
        .args([
            "--headless",
            "screenshot",
            "--screenshot-path",
        ])
        .arg(&png)
        .arg("--window-width")
        .arg(fb.w.to_string())
        .arg("--window-height")
        .arg(fb.h.to_string())
        .arg("--force-new-process")
        .arg(url)
        .status()?;
    if !status.success() || !png.is_file() {
        let _ = std::fs::remove_file(&png);
        return Err(io::Error::other("ladybird headless screenshot failed"));
    }
    let result = png_file_to_szfb(&png, fb);
    let _ = std::fs::remove_file(&png);
    result
}

fn png_file_to_szfb(png: &Path, fb: &FbSlot) -> io::Result<()> {
    let bgra = decode_png_bgra(png, fb.w, fb.h)?;
    let seq = read_seq(&fb.path).unwrap_or(0).wrapping_add(1);
    write_szfb(&fb.path, fb.w, fb.h, seq, &bgra)
}

/// Decode a PNG and nearest-neighbor scale into `dst_w`×`dst_h` BGRA.
fn decode_png_bgra(path: &Path, dst_w: u32, dst_h: u32) -> io::Result<Vec<u8>> {
    let file = std::fs::File::open(path)?;
    let decoder = png::Decoder::new(file);
    let mut reader = decoder
        .read_info()
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    let mut raw = vec![0u8; reader.output_buffer_size()];
    let info = reader
        .next_frame(&mut raw)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    let src_w = info.width.max(1);
    let src_h = info.height.max(1);
    let src = match info.color_type {
        png::ColorType::Rgba => rgba_to_bgra(&raw[..info.buffer_size()]),
        png::ColorType::Rgb => rgb_to_bgra(&raw[..info.buffer_size()]),
        png::ColorType::Grayscale => gray_to_bgra(&raw[..info.buffer_size()]),
        png::ColorType::GrayscaleAlpha => gray_alpha_to_bgra(&raw[..info.buffer_size()]),
        other => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported png color {other:?}"),
            ));
        }
    };
    Ok(scale_bgra(&src, src_w, src_h, dst_w.max(1), dst_h.max(1)))
}

fn rgba_to_bgra(src: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(src.len());
    for px in src.chunks_exact(4) {
        out.extend_from_slice(&[px[2], px[1], px[0], px[3]]);
    }
    out
}

fn rgb_to_bgra(src: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(src.len() / 3 * 4);
    for px in src.chunks_exact(3) {
        out.extend_from_slice(&[px[2], px[1], px[0], 255]);
    }
    out
}

fn gray_to_bgra(src: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(src.len() * 4);
    for &g in src {
        out.extend_from_slice(&[g, g, g, 255]);
    }
    out
}

fn gray_alpha_to_bgra(src: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(src.len() / 2 * 4);
    for px in src.chunks_exact(2) {
        out.extend_from_slice(&[px[0], px[0], px[0], px[1]]);
    }
    out
}

fn scale_bgra(src: &[u8], src_w: u32, src_h: u32, dst_w: u32, dst_h: u32) -> Vec<u8> {
    let mut out = vec![0u8; dst_w as usize * dst_h as usize * 4];
    if src_w == dst_w && src_h == dst_h {
        let n = out.len().min(src.len());
        out[..n].copy_from_slice(&src[..n]);
        return out;
    }
    for y in 0..dst_h as usize {
        let sy = y * src_h as usize / dst_h as usize;
        for x in 0..dst_w as usize {
            let sx = x * src_w as usize / dst_w as usize;
            let si = (sy * src_w as usize + sx) * 4;
            let di = (y * dst_w as usize + x) * 4;
            if si + 4 <= src.len() {
                out[di..di + 4].copy_from_slice(&src[si..si + 4]);
            }
        }
    }
    out
}

fn paint_placeholder(fb: &FbSlot, url: &str) -> io::Result<()> {
    let w = fb.w as usize;
    let h = fb.h as usize;
    let mut px = vec![0u8; w * h * 4];
    let stripe = url_stripe(url);
    let rail_w = 8.min(w);
    let bar_h = 6.min(h);
    let band_y = 16.min(h.saturating_sub(1));
    let band_h = 4.min(h.saturating_sub(band_y));
    for y in 0..h {
        for x in 0..w {
            let c = if x < rail_w {
                RAIL
            } else if y < bar_h {
                BAR
            } else if y >= band_y && y < band_y + band_h {
                stripe
            } else {
                FILL
            };
            let i = (y * w + x) * 4;
            px[i..i + 4].copy_from_slice(&c);
        }
    }
    let seq = read_seq(&fb.path).unwrap_or(0).wrapping_add(1);
    write_szfb(&fb.path, fb.w, fb.h, seq, &px)
}

fn url_stripe(url: &str) -> [u8; 4] {
    let mut h: u32 = 2166136261;
    for b in url.as_bytes() {
        h ^= u32::from(*b);
        h = h.wrapping_mul(16777619);
    }
    [
        20 + (h & 0x3f) as u8,
        60 + ((h >> 8) & 0x3f) as u8,
        160 + ((h >> 16) & 0x3f) as u8,
        255,
    ]
}

fn parse_fb(line: &str) -> Option<FbSlot> {
    let path = json_string_field(line, "path")?;
    if path.is_empty() {
        return None;
    }
    let w = json_i64_field(line, "width")? as u32;
    let h = json_i64_field(line, "height")? as u32;
    if w == 0 || h == 0 || w > 4096 || h > 4096 {
        return None;
    }
    Some(FbSlot { path, w, h })
}

fn surface_msg(fb: &FbSlot) -> String {
    let mut out = String::from("{\"type\":\"surface\",\"path\":");
    push_json_string(&mut out, &fb.path);
    out.push_str(&format!(",\"width\":{},\"height\":{}}}", fb.w, fb.h));
    out
}

fn write_line(w: &mut impl Write, line: &str) -> io::Result<()> {
    writeln!(w, "{line}")?;
    w.flush()
}

fn field_msg(kind: &str, value: &str) -> String {
    if kind == "busy" {
        return format!(
            "{{\"type\":\"busy\",\"bool\":{}}}",
            value == "true"
        );
    }
    let mut out = String::from("{\"type\":\"");
    out.push_str(kind);
    out.push_str("\",\"string\":");
    push_json_string(&mut out, value);
    out.push('}');
    out
}

fn resolve_port(
    args: impl IntoIterator<Item = impl AsRef<str>>,
    env_port: Option<String>,
) -> Result<u16, String> {
    let mut port = None;
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let arg = arg.as_ref();
        if arg == "--suzuri-guest" {
            continue;
        }
        if arg == "--port" {
            let value = args
                .next()
                .ok_or_else(|| "missing value for --port".to_string())?;
            port = Some(parse_port(value.as_ref())?);
            continue;
        }
        if let Some(value) = arg.strip_prefix("--port=") {
            port = Some(parse_port(value)?);
        }
    }
    if let Some(port) = port {
        return Ok(port);
    }
    match env_port {
        Some(value) => parse_port(&value),
        None => Err("need --port N or SUZURI_GUEST_PORT".into()),
    }
}

fn parse_port(s: &str) -> Result<u16, String> {
    match s.parse::<u16>() {
        Ok(0) | Err(_) => Err(format!("invalid port {s:?}")),
        Ok(port) => Ok(port),
    }
}

fn message_type(line: &str) -> Option<String> {
    json_string_field(line, "type")
}

fn extract_url(line: &str) -> String {
    json_string_field(line, "url").unwrap_or_default()
}

fn json_i64_field(line: &str, key: &str) -> Option<i64> {
    let after = after_key(line, key)?.trim_start();
    let mut end = 0;
    let bytes = after.as_bytes();
    if bytes.first() == Some(&b'-') {
        end = 1;
    }
    while end < bytes.len() && (bytes[end].is_ascii_digit() || bytes[end] == b'.') {
        end += 1;
    }
    if end == 0 || after[..end] == *"-" {
        return None;
    }
    after[..end].parse::<f64>().ok().map(|n| n as i64)
}

fn after_key<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let mut search = line;
    while let Some(idx) = search.find('"') {
        search = &search[idx + 1..];
        let Some(after_key) = search.strip_prefix(key).and_then(|s| s.strip_prefix('"')) else {
            continue;
        };
        return after_key.trim_start().strip_prefix(':');
    }
    None
}

fn json_string_field(line: &str, key: &str) -> Option<String> {
    let mut search = line;
    while let Some(idx) = search.find('"') {
        search = &search[idx + 1..];
        let Some(after_key) = search.strip_prefix(key).and_then(|s| s.strip_prefix('"')) else {
            continue;
        };
        let Some(after_colon) = after_key.trim_start().strip_prefix(':') else {
            continue;
        };
        let after_quote = after_colon.trim_start().strip_prefix('"')?;
        return parse_json_string(after_quote);
    }
    None
}

fn parse_json_string(after_open_quote: &str) -> Option<String> {
    let mut out = String::new();
    let mut chars = after_open_quote.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                '"' => out.push('"'),
                '\\' => out.push('\\'),
                '/' => out.push('/'),
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                'u' => {
                    let hex: String = chars.by_ref().take(4).collect();
                    if hex.len() != 4 {
                        return None;
                    }
                    let code = u32::from_str_radix(&hex, 16).ok()?;
                    out.push(char::from_u32(code)?);
                }
                other => out.push(other),
            },
            c => out.push(c),
        }
    }
    None
}

fn push_json_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => {
                let n = c as u32;
                out.push_str(&format!("\\u{n:04x}"));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn read_seq(path: &str) -> Option<u32> {
    let mut f = std::fs::File::open(path).ok()?;
    let mut hdr = [0u8; 16];
    use std::io::Read;
    f.read_exact(&mut hdr).ok()?;
    if &hdr[0..4] != b"SZFB" {
        return None;
    }
    Some(u32::from_le_bytes(hdr[12..16].try_into().ok()?))
}

fn write_szfb(path: &str, w: u32, h: u32, seq: u32, bgra: &[u8]) -> io::Result<()> {
    use std::io::{Seek, SeekFrom};
    let n = (w as usize) * (h as usize) * 4;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .read(true)
        .open(path)?;
    f.set_len((16 + n) as u64)?;
    f.seek(SeekFrom::Start(16))?;
    f.write_all(&bgra[..n])?;
    let mut hdr = [0u8; 16];
    hdr[0..4].copy_from_slice(b"SZFB");
    hdr[4..8].copy_from_slice(&w.to_le_bytes());
    hdr[8..12].copy_from_slice(&h.to_le_bytes());
    hdr[12..16].copy_from_slice(&seq.to_le_bytes());
    f.seek(SeekFrom::Start(0))?;
    f.write_all(&hdr)?;
    f.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_type_and_url() {
        assert_eq!(
            message_type(r#"{"type":"navigate","url":"https://ladybird.org"}"#).as_deref(),
            Some("navigate")
        );
        assert_eq!(
            extract_url(r#"{"type":"navigate","url":"https://ladybird.org"}"#),
            "https://ladybird.org"
        );
    }

    #[test]
    fn paints_orange_rail() {
        let p = std::env::temp_dir().join(format!("suzuri-lb-fb-{}", std::process::id()));
        let slot = FbSlot {
            path: p.to_string_lossy().into(),
            w: 16,
            h: 8,
        };
        paint_placeholder(&slot, "https://ladybird.org").unwrap();
        let mut hdr = [0u8; 16];
        let mut f = std::fs::File::open(&p).unwrap();
        use std::io::Read;
        f.read_exact(&mut hdr).unwrap();
        assert_eq!(&hdr[0..4], b"SZFB");
        let mut px = vec![0u8; 16 * 8 * 4];
        f.read_exact(&mut px).unwrap();
        assert_eq!(&px[0..4], &RAIL);
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn busy_msg_is_bool() {
        assert_eq!(field_msg("busy", "true"), r#"{"type":"busy","bool":true}"#);
    }

    #[test]
    fn png_rgba_scales_into_szfb() {
        let dir = std::env::temp_dir();
        let png = dir.join(format!("suzuri-lb-src-{}.png", std::process::id()));
        let fb_path = dir.join(format!("suzuri-lb-dst-{}.szfb", std::process::id()));
        {
            let f = std::fs::File::create(&png).unwrap();
            let mut enc = png::Encoder::new(f, 2, 2);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            let mut w = enc.write_header().unwrap();
            // R, G / B, white
            w.write_image_data(&[
                255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255,
            ])
            .unwrap();
        }
        let slot = FbSlot {
            path: fb_path.to_string_lossy().into(),
            w: 4,
            h: 4,
        };
        png_file_to_szfb(&png, &slot).unwrap();
        let mut hdr = [0u8; 16];
        let mut f = std::fs::File::open(&fb_path).unwrap();
        use std::io::Read;
        f.read_exact(&mut hdr).unwrap();
        assert_eq!(&hdr[0..4], b"SZFB");
        let mut px = vec![0u8; 4 * 4 * 4];
        f.read_exact(&mut px).unwrap();
        // top-left of a 2x2 red pixel, scaled 2x, is BGRA red
        assert_eq!(&px[0..4], &[0, 0, 255, 255]);
        let _ = std::fs::remove_file(&png);
        let _ = std::fs::remove_file(&fb_path);
    }
}
