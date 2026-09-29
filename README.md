<div align="center">

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/logo-light.png">
    <img alt="fibocom-fm350-gl-windows-gui" src="assets/logo-light.png" width="80%">
  </picture>

### Keep your FM350-GL online on Windows

**Connects the modem, shows the signal, locks 4G/5G bands — and brings the link back when it drops.**

System tray app · PowerShell 7 · recovery ladder · band lock · driver install

[![CI](https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/actions/workflows/ci.yml/badge.svg)](https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.6%2B-5391FE.svg)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6.svg)](#requirements)

[The problem](#the-problem) · [Features](#features) · [How it works](#how-it-works) · [Requirements](#requirements) · [Roadmap](docs/ROADMAP.md) · [Architecture](docs/ARCHITECTURE.md)

</div>

---

> **Status: early development.** There is nothing to install yet. Progress is tracked in
> [`docs/ROADMAP.md`](docs/ROADMAP.md); the first release will be `v1.0.0`.

## The problem

The Fibocom FM350-GL is a capable 5G module, and M.2-to-USB adapters make it a cheap external
modem. On Windows, though, plugging it in is not enough: it shows up as a handful of serial ports
and a network adapter, and nothing brings the data connection up by itself. Someone has to
register on the network and activate a data context with AT commands, then configure the
adapter's IP address by hand. And when the link drops — it does — nothing brings it back.

## Features

Planned, in roadmap order:

- **Connect** — registers, activates the data context, configures the modem's network adapter.
  If the modem is already online when the app starts, it attaches instead of re-dialing.
- **Tray icon** — signal bars and technology (4G/5G) at a glance; details in the tooltip and the
  main window: operator, signal quality, serving and neighbour cells, carrier aggregation.
- **Recovery** — health checks from "is the device there?" down to "do packets actually flow?",
  and a ladder of recovery steps that starts from the gentlest one the symptom allows and
  escalates only while the link stays down.
- **Modes and bands** — 4G + 5G or 4G only, and per-band locking for LTE and NR.
- **Drivers** — detects when the modem's AT ports have no driver and installs the driver package
  you provide, after checking its Microsoft signature and that it matches your modem.
- **eSIM** (after 1.0) — on modules with an embedded SIM: list, switch, rename, download and delete
  eSIM profiles, through [lpac](https://github.com/estkme-group/lpac).
- **SMS, USSD and data usage** (after 1.0) — read and send text messages, run balance codes like
  `*123#`, and see how much data this billing cycle has used, with an optional quota warning.

## How it works

One PowerShell 7 process lives in the system tray. The UI thread only draws; a worker runspace
owns the modem's AT port, runs the connection state machine and the recovery ladder, and publishes
state snapshots for the UI. A supervisor restarts the worker if it ever stops, and the new worker
picks up the connection where it is.

```
 tray icon · window ──commands──►  worker: state machine · health · recovery
                    ◄─snapshots──        │                  │
                                    AT port (COMx)    modem network adapter
```

The app starts at logon through a scheduled task with elevated rights — one UAC prompt at install
time, none afterwards. Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Requirements

- Windows 10 or 11, x64.
- [PowerShell 7.6+](https://github.com/PowerShell/PowerShell): `winget install Microsoft.PowerShell`.
- A Fibocom FM350-GL on a USB adapter, with a SIM.
- The **MediaTek USB serial driver** (`usb2ser_tm`, WHQL-signed) for the modem's AT ports. The
  network adapter needs no driver: Windows provides it. This project does not distribute the
  driver: the app tells you where a verified copy is published, and installs the package you
  download once it has checked it.

Nothing else to install: the app runs on PowerShell alone, and from `v1.1.0` its release carries
the one tool eSIM needs.

## Development

Setup, lint and test commands, fixture rules and the release process:
[`docs/SETUP.md`](docs/SETUP.md). Protocol facts and their sources:
[`docs/AT-COMMANDS.md`](docs/AT-COMMANDS.md). Contributions: [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Credits

- [prusa-dev/luci-app-modemband](https://github.com/prusa-dev/luci-app-modemband) (MIT) — the
  `AT+GTACT` band-code convention and band lists for the FM350-GL.
- [prusa-dev/luci-app-3ginfo-lite](https://github.com/prusa-dev/luci-app-3ginfo-lite) (GPL-3.0) —
  the FM350-GL cell and carrier-aggregation report layouts.
- [prusa-dev/lpac-fibocom-wrapper](https://github.com/prusa-dev/lpac-fibocom-wrapper) (MIT) —
  eSIM management on the FM350 over AT commands.
- [estkme-group/lpac](https://github.com/estkme-group/lpac) (AGPL-3.0) — the eSIM engine, shipped
  with releases from `v1.1.0` under its own license.
- [obsy/sms_tool](https://github.com/obsy/sms_tool) (Apache-2.0) and
  [wargio/fm350-util](https://github.com/wargio/fm350-util) (MIT) — how modems deliver SMS and
  USSD replies, and SMS on the FM350-GL.

## Disclaimer

Not affiliated with, endorsed by, or supported by Fibocom or MediaTek. Product names are
trademarks of their owners and are used only to say which hardware this software works with.

The app changes system state — the modem's configuration, the network adapter's IP settings,
drivers — and needs administrator rights to do it. Use it at your own risk.

## License

[GNU Affero General Public License v3.0 or later](LICENSE).
