# suzuri-ladybird

Suzuri guest plugin for [Ladybird](https://github.com/LadybirdBrowser/ladybird).

This repo is the **tracker + overlay**. It does **not** vendor LibWeb.
`StephenSHorton/suzuri` never contains the engine. Install is optional:
a manifest points at a binary you built.

Pinned upstream: see [`UPSTREAM`](UPSTREAM) (`LadybirdBrowser/ladybird` @ `accee62a12e4`).

## What chrome talks to

Suzuri chrome spawns a guest with `--suzuri-guest --port N`. The process
speaks line-delimited JSON on `127.0.0.1` and paints a `SZFB` file that
chrome blits into the mosaic well.

Until Ladybird is built and the overlay is applied, the **Rust guest**
in `sidecar/` is that process. It is titled `Ladybird`, owns the well
pixels, and on `navigate` will shell out to a Ladybird binary if
`LADYBIRD` (or a default path) exists:

```
Ladybird --headless screenshot --screenshot-path <png> \
  --window-width W --window-height H --force-new-process URL
```

Ladybird already ships that headless path. The overlay
(`Guest/Suzuri/`) is the in-process hook: same ABI, no extra process.

MCP (eval / screenshot / click) stays later, inside this process.

## Build the guest (today)

```bash
cd sidecar
cargo test
cargo build --release
```

Binary: `sidecar/target/release/suzuri-ladybird`.

Drop a manifest (see `manifest/ladybird.json`) in:

| OS | Path |
| --- | --- |
| macOS | `~/Library/Application Support/suzuri/guests/ladybird.json` |
| Windows | `%LOCALAPPDATA%\suzuri\guests\ladybird.json` |
| Linux | `~/.config/suzuri/guests/ladybird.json` |

Set `command` to the binary you built. Palette → **New guest pane**.
If more than one guest is installed, name this one `ladybird` or pick it.

## Apply the overlay onto a Ladybird tree

```bash
git clone https://github.com/LadybirdBrowser/ladybird.git
git -C ladybird checkout "$(awk -F= '/^sha=/{print $2}' UPSTREAM)"
./scripts/apply.sh /path/to/ladybird
# then build Ladybird as upstream documents:
#   ./Meta/ladybird.py build
```

`apply.sh` copies `Guest/Suzuri/` to `UI/AppKit/Suzuri/` and patches
`UI/AppKit/CMakeLists.txt` + `UI/AppKit/main.mm` so Ladybird itself
accepts `--suzuri-guest --port N`.

## Layout

| Path | Role |
| --- | --- |
| `sidecar/` | Rust sidecar — works as the suzuri guest now |
| `Guest/Suzuri/` | C++ overlay compiled into Ladybird (no AK in the protocol files) |
| `manifest/ladybird.json` | Example suzuri manifest |
| `scripts/apply.sh` | Copy overlay + patch AppKit |
| `scripts/sync-upstream.sh` | Fetch and record a new Ladybird SHA |

## Rules

- Do not copy this into `StephenSHorton/suzuri`.
- Do not open a Ladybird window over the mosaic. Pixels go through `SZFB`.
- Rebase the overlay when `scripts/sync-upstream.sh` moves `UPSTREAM`.
