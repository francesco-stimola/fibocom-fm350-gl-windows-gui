<div align="center">

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/logo-light.png">
    <img alt="fibocom-fm350-gl-windows-gui" src="assets/logo-light.png" width="80%">
  </picture>

### Keep your FM350-GL online on Windows

**Connects the modem, shows the signal, locks 4G/5G bands — and brings the link back when it drops.**

System tray app · PowerShell 7 · recovery ladder · band lock · no driver to install

[![CI](https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/actions/workflows/ci.yml/badge.svg)](https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.6%2B-5391FE.svg)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6.svg)](#requirements)

[The problem](#the-problem) · [Features](#features) · [Install](#install) · [How it works](#how-it-works) · [Requirements](#requirements) · [Roadmap](docs/ROADMAP.md) · [Architecture](docs/ARCHITECTURE.md)

</div>

---

## The problem

The Fibocom FM350-GL is a capable 5G module, and M.2-to-USB adapters make it a cheap external
modem. On Windows, though, plugging it in is not enough: it shows up as a handful of serial ports
and a network adapter, and nothing brings the data connection up by itself. Someone has to
register on the network and activate a data context with AT commands, then configure the
adapter's IP address by hand. And when the link drops — it does — nothing brings it back.

## Features

- **Connect** — registers, activates the data context, configures the modem's network adapter.
  If the modem is already online when the app starts, it attaches instead of re-dialing.
- **Tray icon** — signal bars and technology (4G/5G) at a glance; details in the tooltip and the
  main window: operator, signal quality, serving and neighbour cells, carrier aggregation.
- **Recovery** — health checks from "is the device there?" down to "do packets actually flow?",
  and a ladder of recovery steps that starts from the gentlest one the symptom allows and
  escalates only while the link stays down.
- **Modes and bands** — 4G + 5G, 4G only or 5G only (SA), and per-band locking for LTE and NR.
  A new mode is tried first: if the modem finds no network with it, it goes back to what it had.
- **No driver to install** (since 2.0) — the app puts the modem's AT port, and its other vendor
  ports, on WinUSB, the generic USB driver that comes with Windows: nothing to find, download or
  install. The *USB* tab shows each port and its driver.
- **Encrypted DNS** — DNS over HTTPS to the DNS servers you choose, or to the one your DoH
  template names — by name too, looked up again every hour —, on the modem's adapter alone, never
  falling back to plain DNS (Windows 11).
- **Update notice** — the tray menu says when a newer release is out. Nothing is ever downloaded
  or installed by the app.
- **Languages** — English, Italian, German, French, Spanish, Portuguese, Dutch and Polish, as
  Windows' display language asks. Translations other than Italian have had no native speaker's
  review yet: corrections are welcome (`src/App/Strings`, `src/Installer/Strings`).
- **SMS and data usage** (since 1.1) — read and send text messages, and see how much data this
  billing cycle has used, with an optional quota warning. Balance codes like `*123#` (USSD) get no
  reply from the FM350-GL on LTE, so they are not offered.
- **eSIM** (since 1.2) — on modules with an embedded SIM: switch between the physical SIM and the
  eSIM, each SIM — each eSIM profile — connecting with its own APN settings and listing the
  messages that came in on it; list, enable, disable, rename and delete eSIM profiles; download
  one from its activation code, typed or read from the image of its QR code; the EID at hand, to
  copy. Through
  [lpac](https://github.com/estkme-group/lpac). lpac takes the activation code — and, to rename a
  profile, its ICCID — on its command line: the app never logs them, but on a computer that
  records processes' command lines, as an IT department's may, they are recorded too.

## Install

1. **PowerShell 7.6 or later**: `winget install Microsoft.PowerShell`, or *PowerShell* from the
   Microsoft Store. Windows PowerShell 5.1, which Windows already has, only starts it.
2. **Download** `fibocom-fm350-gl-windows-gui-<version>.zip` from the
   [latest release](https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/latest)
   and extract it (*Extract All*). Windows may ask whether to run a file that came from the
   internet: that is the installer itself.
3. **Run `install.cmd`** and accept the one UAC prompt. A window shows what it does: it copies the
   app to `C:\Program Files\fibocom-fm350-gl-windows-gui`, registers the tasks that start it with
   administrator rights, adds **Fibocom FM350-GL Windows GUI** to the Start menu, and starts the app. Your account must
   be an administrator: the app runs as the account that installs it. The extracted folder can be
   deleted afterwards.
4. **Nothing else.** At its first start the app puts the modem's ports on Windows' own WinUSB driver,
   and connects. If MediaTek's serial driver gave you COM ports for the modem, they go away while the
   app is installed (see *Requirements*).

From then on the Start-menu entry opens its window — no more UAC prompts. To have it start in
the tray when you sign in to Windows, tick *Start the app in the tray when you sign in to Windows*
in its *Connection* tab: it is off until you do.

**Updating**: extract the new release's zip and run its `install.cmd`. The running app exits —
the connection stays up — and the new version starts. Once per start, when the connection first
comes online, the app asks GitHub for the latest release, and the tray menu says when a newer one
is out; the request names the app and nothing about you or your computer, though GitHub sees your
IP address. *Connection* → *Updates* turns it off.

**Uninstalling**: *Uninstall* in Settings → Apps → Installed apps, or run `uninstall.cmd` — from
the zip, or from the install folder — and accept the UAC prompt. It removes the app, its tasks,
its Start-menu entry and its place in the list of installed apps, and asks whether to delete your
settings, the stored SIM PIN and APN password, and the logs too. The connection is left as it is.
The modem's ports go back to the driver Windows ranks best — MediaTek's serial driver, where it is
installed —: plug the modem in before uninstalling, or they stay on WinUSB.

## How it works

One PowerShell 7 process lives in the system tray. The UI thread only draws; a worker runspace
owns the modem's AT port, runs the connection state machine and the recovery ladder, and publishes
state snapshots for the UI. A supervisor restarts the worker if it ever stops, and the new worker
picks up the connection where it is.

```
 tray icon · window ──commands──►  worker: state machine · health · recovery
                    ◄─snapshots──        │                  │
                                 AT port (WinUSB)     modem network adapter
```

The app starts through scheduled tasks with elevated rights — from the Start menu, and at sign-in
once you turn that on — with one UAC prompt at install time, none afterwards. Details:
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Requirements

- Windows 10 or 11, 64-bit, on an x64 (Intel or AMD) or an Arm64 processor — the installer refuses
  others: PowerShell 7 has no 32-bit version. **Windows on Arm64 is supported in software only: it
  has not been tested on Arm64 hardware.** Encrypted DNS needs Windows 11.
- [PowerShell 7.6+](https://github.com/PowerShell/PowerShell): `winget install Microsoft.PowerShell`.
- A Fibocom FM350-GL on a USB adapter, with a SIM.
- No driver: the modem's AT port runs on WinUSB and its network adapter on RNDIS, both part of
  Windows. From 2.0 MediaTek's serial driver is not used: while the app is installed the modem has
  no COM ports, so another program that needs them can't run beside it.

Nothing else to install: the app runs on PowerShell alone, and from `v1.2.0` its release carries
the two programs eSIM needs: lpac — for x64 and, from `v2.0.0`, Arm64 —, and ZXing.Net to read a
QR code.

## Development

Setup, lint and test commands, running the app from source, fixture rules and the release
process: [`docs/SETUP.md`](docs/SETUP.md). Protocol facts and their sources:
[`docs/AT-COMMANDS.md`](docs/AT-COMMANDS.md). Contributions: [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Credits

- [prusa-dev/luci-app-modemband](https://github.com/prusa-dev/luci-app-modemband) (MIT) — the
  `AT+GTACT` band-code convention and band lists for the FM350-GL.
- [prusa-dev/luci-app-3ginfo-lite](https://github.com/prusa-dev/luci-app-3ginfo-lite) (GPL-3.0) —
  the FM350-GL cell and carrier-aggregation report layouts.
- [prusa-dev/lpac-fibocom-wrapper](https://github.com/prusa-dev/lpac-fibocom-wrapper) (MIT) —
  eSIM management on the FM350 over AT commands.
- [estkme-group/lpac](https://github.com/estkme-group/lpac) (AGPL-3.0) — the eSIM engine, shipped
  with releases from `v1.2.0` under its own license.
- [micjahn/ZXing.Net](https://github.com/micjahn/ZXing.Net) (Apache-2.0) — reads an eSIM's QR code
  from an image, shipped with releases from `v1.2.0` under its own license.
- [obsy/sms_tool](https://github.com/obsy/sms_tool) (Apache-2.0) and
  [wargio/fm350-util](https://github.com/wargio/fm350-util) (MIT) — how modems deliver SMS and
  USSD replies, and SMS on the FM350-GL.

## Disclaimer

Not affiliated with, endorsed by, or supported by Fibocom or MediaTek. Product names are
trademarks of their owners and are used only to say which hardware this software works with.

The app changes system state — the modem's configuration, the network adapter's IP settings, the
driver of the modem's USB ports — and needs administrator rights to do it. Use it at your own risk.

## License

[GNU Affero General Public License v3.0 or later](LICENSE).
