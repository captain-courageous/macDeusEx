# Deus Ex — Native Apple Silicon (Metal)

A native `arm64` macOS build of **Deus Ex (GOTY 1.112fm)** powered by **DXEngine** with a native Apple **Metal** renderer, Cocoa AppKit integration, macOS Game Mode, and controller support.

> **Requires your own legally owned copy of Deus Ex GOTY (1.112fm)** — Steam, GOG, retail disc, CrossOver/Whisky bottle, or standalone folder. No copyrighted game assets or icons are hosted or bundled in this repository.

---

## Quick Install (Terminal)

1. Open **Terminal** (`Cmd + Space`, type `Terminal`, press `Enter`).
2. Paste this command and press `Enter`:

```bash
curl -fsSL https://raw.githubusercontent.com/captain-courageous/macDeusEx/main/quick-install.sh | bash
```

The script automatically searches common **Steam** (including external Steam libraries), **GOG**, **Heroic**, **CrossOver**, **Whisky**, `~/Games`, `~/Downloads`, and existing `Deus Ex.app` installs.

If your game folder is somewhere else, pass `--game <path>` (or the path directly):

```bash
curl -fsSL https://raw.githubusercontent.com/captain-courageous/macDeusEx/main/quick-install.sh | bash -s -- --game ~/path/to/"Deus Ex GOTY"
```

Add `--dmg` if you also want a drag-to-Applications disk image (`~/Downloads/Deus Ex.dmg`):

```bash
curl -fsSL https://raw.githubusercontent.com/captain-courageous/macDeusEx/main/quick-install.sh | bash -s -- --dmg
```

When finished, a single ad-hoc signed, self-contained **`Deus Ex.app`** (with your game files baked inside and the original game icon extracted directly from your local GOG, Steam, or `DeusEx.exe` files) is placed in `~/Downloads`. Drag it into **Applications** or double-click to play.

---

## Where Saves & Settings Live

User saves, screenshots, and `.ini` configuration files are stored in:

```text
~/Library/Application Support/Deus Ex Native/
```

Your saves stay intact across upgrades or when moving `Deus Ex.app`. Hold **Option (⌥)** while launching to manually select a different game installation.

---

## Credits & Upstream Projects

This distribution combines and extends the work of the following upstream open-source projects:

- **[DXEngine (`JuggyMcNutty/port-ex-machina`)](https://github.com/JuggyMcNutty/port-ex-machina)** — Core C++20 Deus Ex / Unreal Engine 1 reimplementation, UnrealScript VM, physics, AI, and accuracy work (zlib license; *this distribution is an altered version*).
- **[DeusEX-MacOS-Metal (`Alyx-ML/DeusEX-MacOS-Metal`)](https://github.com/Alyx-ML/DeusEX-MacOS-Metal)** — Native Apple **Metal** rendering backend (`MetalRenderDevice`), Cocoa AppKit display/dialog integration, and initial macOS packaging & verification harnesses.
- **[SurrealEngine](https://github.com/dpjudas/SurrealEngine)** (Magnus Norddahl, Lupert Everett, and contributors) — Upstream Unreal Engine 1 foundation upon which `DXEngine` is built (zlib license).
- **Third-Party Libraries** — OpenAL Soft (LGPL v2), OpenMPT (BSD-3-Clause), glslang (BSD-3-Clause), Vulkan/Khronos headers, VMA, miniz, r8brain-free-src (Aleksey Vaneev of Voxengo), kissfft, stb_vorbis, dr_wav, dr_flac, minimp3, nanosvg, picoPNG, and TinySHA1. Full license texts are included in [LICENSE.md](LICENSE.md) and inside `Deus Ex.app/Contents/Resources/Licenses/`.

### Source Code, CI Builds & License Compliance

Prebuilt `DeusEx-macos-arm64.tar.gz` binaries in [Releases](https://github.com/captain-courageous/macDeusEx/releases) are built directly from source on Apple Silicon macOS via GitHub Actions ([`.github/workflows/release.yml`](.github/workflows/release.yml)), and `quick-install.sh` automatically verifies the downloaded archive against `SHA256SUMS.txt` before extracting.

All upstream projects permit binary redistribution when original notices, modified-version markings, and OpenAL Soft's corresponding source are preserved:
- Browsable modified engine source code: **[captain-courageous/DXEngine (`macos-arm64-metal`)](https://github.com/captain-courageous/DXEngine/tree/macos-arm64-metal)** (forked from [`JuggyMcNutty/DXEngine`](https://github.com/JuggyMcNutty/DXEngine))
- Complete licenses: [LICENSE.md](LICENSE.md)
- Exact release source archive (`Deus-Ex-Mac-Source.tar.gz`): attached in [Releases](https://github.com/captain-courageous/macDeusEx/releases) (starting at `v0.1.0`).
