# Installation

Three supported paths: the `curl | sh` one-liner, `pip install` from the repository, and a manual
run straight from the checkout. All three land the same application.

- [One-liner install](#one-liner-install)
  - [What the script does](#what-the-script-does)
  - [Flags](#flags)
  - [Uninstall](#uninstall)
  - [Manual inspection](#manual-inspection)
- [Install from source](#install-from-source)
- [Manual run from a checkout](#manual-run-from-a-checkout)
- [Troubleshooting](#troubleshooting)

---

## One-liner install

```bash
curl -fsSL https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh | sh
```

Nothing has to be installed on your machine: the archive ships its own Python and Qt runtime
(bundled with PyInstaller), so this path works on a clean machine.

> **Release availability.** The archives come from the packaging stage, which has not shipped yet.
> If the script reports that no release exists for your platform, use
> [install from source](#install-from-source) — it is a first-class path, not a workaround.

### What the script does

1. Detects the operating system and architecture and maps them to an archive name:
   `macos-arm64`, `macos-x64`, `linux-x64`, `linux-arm64`.
2. Downloads the matching archive from GitHub Releases into a temporary directory.
3. Extracts it into `~/.binaural/`. An existing installation there is replaced.
4. Creates a symlink named `binaural` in `~/.local/bin` pointing at the executable. If
   `~/.local/bin` is not in your `PATH`, the script tells you the line to add and where.
5. Verifies the result by running `binaural --version`. A non-zero exit here means the install
   itself failed.

The script re-executes itself under `sh` when invoked under a shell that does not behave like a
POSIX shell, and it aborts on any unexpected platform rather than installing something broken.

### Flags

Pass flags after `sh`, for example:

```bash
curl -fsSL https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh | sh -s -- --dry-run
```

| Flag | Effect |
|---|---|
| `--help` | Usage summary, then exit without touching anything |
| `--version` | Print the installer version, then exit |
| `--dry-run` | Print every step and the resolved archive name, download and change nothing |
| `--prefix=DIR` | Install into `DIR` instead of `~/.binaural`. The symlink is created next to the executable |
| `--uninstall` | Remove the installation directory and the `binaural` symlink |

```bash
# see what would happen first
curl -fsSL https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh | sh -s -- --dry-run

# custom location
curl -fsSL https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh | sh -s -- --prefix="$HOME/opt/binaural"

# remove
curl -fsSL https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh | sh -s -- --uninstall
```

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh | sh -s -- --uninstall
```

That removes `~/.binaural/` and the `~/.local/bin/binaural` symlink. Settings live in the platform
settings store (`QSettings`), not in the install directory; remove them separately if you want a
clean slate.

### Manual inspection

Piping a remote script into a shell is not something to do blindly. Download it, read it, then run
it:

```bash
curl -fsSLO https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh
less install.sh
sh install.sh --dry-run
sh install.sh
```

---

## Install from source

You need Python 3.10 or newer (the project is developed against 3.12) and `pip`.

```bash
git clone https://github.com/zeroscrypt/binaural.git
cd binaural
python3 -m venv .venv
.venv/bin/python -m pip install -e ".[dev]"
.venv/bin/binaural
```

The `dev` extra adds `pytest` and `numpy`, which the test suite needs. For a plain install use
`pip install -e .`.

To have the command available outside the virtualenv, install into the user site:

```bash
python3 -m pip install --user -e .
```

Then check that `~/.local/bin` is on your `PATH`:

```bash
binaural --version
```

---

## Manual run from a checkout

If you do not want to install anything:

```bash
git clone https://github.com/zeroscrypt/binaural.git
cd binaural
python3 -m venv .venv
.venv/bin/python -m pip install "PySide6-Essentials>=6.5" "PySide6-Addons>=6.5"
PYTHONPATH=src .venv/bin/python -c "from binaural.app import main; main()"
```

`PYTHONPATH=src` is needed because the package lives under `src/` and is not installed in this mode.

---

## Troubleshooting

### `curl: command not found`

`curl` is not installed.

- **macOS:** it ships with the system, so this usually means a stripped environment. Install it with
  `brew install curl`, or download the release archive from
  [the releases page](https://github.com/zeroscrypt/binaural/releases) and extract it yourself.
- **Debian/Ubuntu:** `sudo apt-get install -y curl`
- **Fedora:** `sudo dnf install curl`
- **Arch:** `sudo pacman -S curl`
- **Alpine:** `sudo apk add curl`

Without `curl`, download the archive with your browser and follow
[uninstall](#uninstall) to see the layout the script would have produced, or just use
[install from source](#install-from-source).

### `python3: command not found` or Python older than 3.10

```bash
python3 --version
```

- **macOS:** the system Python is 3.9 on macOS 12. Install a newer one with `brew install python@3.12`
  and use `python3.12 -m venv .venv`.
- **Debian/Ubuntu** (older releases ship 3.8): `sudo apt-get install -y python3.10 python3.10-venv`
  or newer.
- **Fedora:** `sudo dnf install python3`
- **Arch:** `sudo pacman -S python`

If you only want the app and not the toolchain, use the one-liner — it bundles its own interpreter.

### `qt.qpa.plugin: Could not load the Qt platform plugin "xcb"`

Qt cannot open a window. On a desktop session this usually means missing system libraries for the
platform theme plugin. The xcb plugin needs a handful of X11 development packages:

```bash
# Debian/Ubuntu
sudo apt-get install -y libxcb-cursor0 libxkbcommon-x11-0 libxcb-xinerama0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 libxcb-xkb1 libegl1 libgl1 libglib2.0-0 libegl1-mesa

# Fedora
sudo dnf install -y xcb-util-cursor xcb-util-keysyms xcb-util-wm xcb-util-image \
    libxkbcommon-x11 mesa-libEGL mesa-libGL

# Arch
sudo pacman -S --needed xcb-util-cursor xcb-util-keysyms xcb-util-wm xcb-util-image \
    libxkbcommon-x11 mesa
```

### Qt does not start on a headless Linux machine

With no display there is no window to open. For tests, CI, or anything non-interactive:

```bash
QT_QPA_PLATFORM=offscreen .venv/bin/python -m pytest
```

`offscreen` keeps Qt fully functional minus the actual window. Use it for tests; it is not a
workaround for running the UI over a real remote session — for that use X11 forwarding or a
Wayland session.

### macOS: "binaural cannot be opened because the developer cannot be verified"

The release binary is not notarised. Two ways around it:

1. **Right-click → Open** in Finder, then confirm in the dialog. This works once per binary.
2. From a terminal, after the first launch attempt has been blocked:

   ```bash
   xattr -d com.apple.quarantine ~/.binaural/binaural
   ```

   On Apple Silicon, System Settings → Privacy & Security also offers "Open Anyway" after the first
   blocked attempt.

A source install has no such problem: the binary is built locally and never goes through Gatekeeper.

### `binaural: command not found` after install

The symlink is in `~/.local/bin` and that directory is not on your `PATH`. Add it:

```bash
# bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc

# zsh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Confirm with `ls -l ~/.local/bin/binaural` — if the symlink is missing, rerun the installer with
`--prefix=DIR` and put `binaural` on your `PATH` directly.

### No audio, or the error mentions `QAudioSink`

`QAudioSink` comes from PySide6-Addons. If you installed only PySide6-Essentials, the audio engine
cannot start.

```bash
.venv/bin/python -m pip install "PySide6-Addons>=6.5"
```

Also check that the platform can open the device at all:

```bash
# Linux
pactl list short sinks
pactl get-default-sink
```

If the sink exists and PulseAudio is running but audio is still silent, note that a session running
over SSH has no access to the local sound server.

### The beat is not audible on speakers

Expected, not a bug. On speakers the two frequencies mix in the air before reaching your ears and
the effect disappears. The app warns about this on startup. See
[Why headphones are mandatory](../README.md#why-headphones-are-mandatory).