# ISS PISS-O-METER — macOS 🛰️🟡

The macOS menu-bar edition. A little tank icon + live percentage sit in your
**menu bar** (top-right, by the clock) showing how full the ISS urine tank is,
from NASA's public telemetry feed. Click it for status and last-update time.

Native AppKit, no third-party packages — the Mac twin of the Windows tray app.

## Requirements

- macOS **12 (Monterey) or newer** (uses URLSession async streaming)
- **Xcode Command Line Tools** — if you don't have them:
  ```bash
  xcode-select --install
  ```

## Run it (quickest)

```bash
swift IssPissOMeter.swift
```

…or double-click **`Run ISS PISS-O-METER.command`** in Finder. A tank icon with
the live percentage appears in your menu bar. (Running this way keeps a Terminal
window open; closing it quits the app. For a permanent install, build the app —
below.)

Running via the `swift` toolchain is deliberate: `swift` is Apple-signed, so
**Gatekeeper allows it** — the same trick the Windows version uses with the
signed `pwsh.exe` to stay out of Smart App Control's way.

## Install as a real app (persistent + Login Items)

```bash
chmod +x build-app.sh        # first time only
./build-app.sh
```

This compiles **`ISS PISS-O-METER.app`** (a proper `LSUIElement` menu-bar app,
ad-hoc signed). Drag it to `/Applications`, open it once (right-click → **Open**
the first time), then add it under **System Settings → General → Login Items**
to launch at startup.

## Menu

- **Header** — current tank percentage
- **Status line** — NOMINAL / FILLING UP / DUMP SOON / CRITICAL, plus last update
- **Refresh now** (⌘R) — force a fresh snapshot
- **Quit** (⌘Q)

## Status thresholds

| Reading | Status            |
|--------:|-------------------|
| < 60 %  | NOMINAL           |
| 60–80 % | FILLING UP        |
| 80–95 % | DUMP SOON         |
| ≥ 95 %  | CRITICAL – FLUSH! |

## How it works

Same data path as the Windows version: a Lightstreamer streaming session to
`push.lightstreamer.com` (adapter set `ISSLIVE`, item **`NODE3000005`** =
"Urine Tank Qty", percent), read via `URLSession.bytes` line-by-line. The tank
icon is drawn programmatically with AppKit/Core Graphics.

> **Note:** This port was written on a Windows machine and has **not yet been
> compiled/run on a Mac**. If `swift IssPissOMeter.swift` reports an error, paste
> it back and it'll get fixed quickly — the logic mirrors the working Windows app.
