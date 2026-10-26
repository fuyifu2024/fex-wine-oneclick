# fex-wine-oneclick

**English** | [中文](README.md)

One-click installer for **FEX-Emu + x86-64 Wine** on ARM64 Ubuntu (Raspberry Pi 5 and friends), so Windows `.exe` files **open with a double-click**.

> Tested on Raspberry Pi 5 (4 GB) + Ubuntu 26.04 LTS (resolute, aarch64).

## What it does

1. Installs **FEX-Emu** (the x86/x86-64 → ARM64 userspace emulator) from the official PPA and registers its binfmt handlers
2. Downloads the **Ubuntu 24.04 x86-64 RootFS** that FEX needs to run x86-64 programs
3. Installs **x86-64 Wine 9.x** plus its full dependency closure into that RootFS — amd64 `.deb` packages are fetched from the Ubuntu archive and extracted directly (no root, no dpkg database changes)
4. Sets up the wine prefix, the **Z: drive union root**, and the **system32 links** (see “Why the hacks” below)
5. Installs the `fex-wine` command and a desktop entry that associates `.exe` files with it

## Requirements

- ARM64 (aarch64) Ubuntu **24.04+**; 26.04 recommended
- **4K page size kernel** — `getconf PAGESIZE` must print `4096`. Kernels with 16K or 64K pages cannot run FEX.
- **ARMv8.2+ CPU** (the Pi 5's Cortex-A76 qualifies). The installer detects ARMv8.0 / 8.2 / 8.4 and picks the matching `fex-emu-armv8.x` package.
- About **7 GB free disk** (the extracted RootFS is roughly 2.5 GB)
- **sudo** (for installing the apt packages)

## Install

```bash
git clone https://github.com/fuyifu2024/fex-wine-oneclick.git
cd fex-wine-oneclick
./install.sh
```

You will be asked for your sudo password once. The RootFS download is about 500 MB and expands to roughly 2.5 GB.

## Usage

- **Double-click any `.exe`** in your file manager → it opens through FEX + Wine
- From a terminal: `~/.local/bin/fex-wine program.exe [arguments...]`
- Console applications automatically open a terminal window for their output; GUI applications just open their window
- For scripting: `FEX_WINE_NO_TERMINAL=1 fex-wine program.exe` runs console apps inline in the current terminal
- Logs: `~/.fex-wine.log`

## Limitations

- **64-bit Windows programs only** — the packaged noble `wine64` has no 32-bit support
- Performance is “usable, not fast”: older apps, simple GUIs and 2D games are fine; modern 3D games are out of reach
- **Games with anti-cheat won't run** (EAC, BattlEye, Ricochet, …) — a general limitation of Wine and emulation layers
- The first launch of any given program is slower (FEX has to JIT-compile; later runs hit the code cache)

## Why the hacks

FEX's RootFS is a **path-redirection overlay**, not a chroot. That creates two traps, both handled automatically by the installer:

1. **FEX does not redirect paths whose symlink resolution enters the rootfs's `/` subtree at the kernel level.** Wine maps `Z:` to `/` by default, so every `Z:\usr\lib\...\wine\...dll` lookup lands on the *host* `/usr` (where there is no Wine) → `could not load kernel32.dll`.
   Fix: a **union root** at `~/.fex-zroot`, which stitches the rootfs's `/usr`, `/lib`, `/etc`, … together with the host's `/home`, `/media`, … and is what the prefix's `dosdevices/z:` points at.
2. Wine resolves PE modules from the **prefix's system32** first. The installer symlinks every `x86_64-windows/*` module from the rootfs into `system32`, plus `zlib1.dll`, which Wine cannot find on its own (it lives in the mingw tool directory).
3. Programs must be launched with a **`Z:\...` Windows-style path**. With a bare Unix path, engines such as Unity see `unix/...` as the application folder and fail with “there should be a `*_Data` folder next to the executable”.

## Check / uninstall

```bash
./install.sh --check        # report status, change nothing
./install.sh --uninstall    # remove what this installer created (keeps the FEX apt packages)
./install.sh --purge        # also remove the FEX apt packages and the PPA
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `could not load kernel32.dll` | Re-run `./install.sh` — it re-creates the system32 links in the prefix |
| Double-click does nothing / the app exits immediately | Check the last lines of `~/.fex-wine.log` |
| Dozens of duplicate icons appear in the app grid | There is a self-referential symlink in `~/.local/share/applications/`; move it away (the installer warns about this) |
| `FEX requires a 4K page-size kernel` | This machine runs a 16K/64K page kernel and cannot use FEX |
| A game reports a missing `*_Data` folder | Handled by the `Z:\` path in the wrapper; if it still happens, attach the log to an issue |

## Credits

- [FEX-Emu](https://github.com/FEX-Emu/FEX) — fast x86/x86-64 userspace emulator for ARM64
- [Wine](https://www.winehq.org/) — Windows API implementation
- Ubuntu archive and the FEX RootFS mirror

## License

MIT
