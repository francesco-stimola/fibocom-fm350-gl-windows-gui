# Development log

Newest first. One entry per meaningful change — note *what* and *why*, not just *what*. This is
the running history, so context is never lost between sessions. Technical and design decisions
only.

## 2026-09-29 — M1: the AT channel, the simulated modem, fixture rules

The device-independent core of M1. Design decisions:
- **The echo is the anchor.** The FM350's echo is on by default and comes back on after a reset,
  so the channel keeps it on instead of sending `ATE0`. A command's answer starts after its echo;
  anything else before it is left over from an earlier command and is discarded. The failure this
  prevents is permanent: after one timeout, a late answer read as the next command's answer
  shifts every answer by one command, for as long as the process runs. The modem executes one
  command at a time, so a late answer always precedes the next echo — and the simulated modem
  behaves the same way. A timeout without echo (someone turned it off) is recovered by
  `Initialize-AtChannel`.
- **Transports are a shape, not a class hierarchy.** A transport is any object with `PortName`,
  `Lost`, `Write`, `Read` and `Close`. Port loss sets `Lost` instead of throwing: the channel checks
  a flag, no custom exception type crosses files or runspaces, and the static analyzer (which reads
  one file at a time) doesn't meet types defined elsewhere. Classes carry
  `[NoRunspaceAffinity()]`, because M3's worker runspace will own the port.
- **Numeric errors** (`AT+CMEE=1`): the app maps error numbers itself instead of depending on
  firmware wording.
- **7-bit text.** The port speaks IRA by default, with PDUs and UCS-2 in hex, so anything outside
  printable ASCII is line noise and is dropped: garbled bytes can't corrupt a final result code.
- **Bounded memory.** Unterminated text is capped at 4096 characters and the URC queue at 1000
  entries.
- **Fixtures** are plain text (notes, command, answer) in `tests/fixtures/documented/` (written from
  the documentation, values invented) or `tests/fixtures/device/` (captures). A test checks their
  format and source note, and fails on any identifier-like value other than the fakes in
  `tests/fixtures/fakes.psd1`.
- **Timeouts are the caller's.** `Invoke-AtCommand` requires one. **Decision:** each command's
  worst-case duration as documented by the vendor manual, never less than 3 s — the manufacturer's
  figures are maximums by design, and the floor covers USB latency and a busy modem. The cost is
  that a stuck modem is noticed only after that duration (3 min for `AT+COPS`, which is rare).
  M2 turns it into a lookup.

New device questions (`AT-COMMANDS.md` §7): whether DTR/RTS matter, which URCs arrive unprompted,
and whether `pwsh` survives the modem being unplugged while the port is open — a known weak spot
of `System.IO.Ports`.

## 2026-09-29 — M0 complete: CI green; review fixes

The first push ran CI on GitHub's Windows runner: lint and tests green. The end-of-milestone review
found two things, both fixed:
- **An empty band field decoded as "all bands".** Binding `''` or `' '` to an `[int]` parameter
  silently yields `0`, and code `0` means automatic band selection: once M5 splits a `+GTACT?`
  line, a doubled comma would have been written back as `0`, dropping the user's band lock.
  `ConvertFrom-GtactBandCode` now takes the code as text and accepts only a non-negative integer
  without leading zeros; tests cover empty, blank, malformed and pipeline input.
- **"Hardware tests are excluded by default" wasn't true.** Pester runs every tag unless told
  otherwise, so the first `Hardware` test of M1 would have failed CI on the modem-less runner.
  CI and every documented test command now pass `-ExcludeTagFilter Hardware`.

## 2026-09-29 — Vendor AT manual harvested; band codec extended to NR n512

The Fibocom *FM350 AT Commands User Manual* — V2.10 (2023), and V2.2 (2021), whose applicability
table names the FM350-GL — is now `[FIBOCOM]` in `AT-COMMANDS.md`. Every fact already recorded was
checked against it, and the facts M1–M9 need were added with section and page. The manual is
marked confidential, so only facts are taken from it, in our own words. What it changed:
- **NR band codes are `"50"` + N up to n512.** The codec now encodes and decodes NR n1–n512
  instead of refusing n100 and above. LTE stays at B1–B99: `100 + N` from B100 up would leave the
  documented range. An LTE band above 99 is now a non-terminating error, so a pipeline of bands
  carries on with the next one.
- **`+GTACT` keeps one band list per RAT**: a write changes only the RATs it names, so M5 writes
  every managed list each time. The setting is not persistent and triggers a new registration.
- **The manual's `+COPS` `<AcT>` table has no NR value** and gives `11` as eMTC. It stays ❓
  against 27.007 and `[3GINFO]` (`11` SA, `13` NSA), with `+ERAT?` as a second opinion.
- **Persistent modem state identified**: `+CGDCONT` (the connect sequence writes it only when it
  differs from the settings), `+GTDUALSIM`, and `+GTUSBMODE`, `+E5GOPT`, `+EIAAPN`, which the app
  only reads. **Decision for M8:** the app may write `+GTDUALSIM` — switching between the physical
  SIM and the eSIM is what M8 is for — but only after a confirmation saying that the choice stays
  in the modem across restarts, and with the active slot always shown.
- **Not in the manual**: `+CGAUTH` and the logical-channel commands `+CCHO`/`+CGLA`/`+CCHC` —
  questions for the device session; `+CSIM` is the documented fallback for eSIM.
- **Layouts completed**: `+GTCCINFO` serving and neighbour lines (they differ), `+GTCAINFO` MIMO
  and modulation, `+CGCONTRDP`'s combined address-and-mask string, the measurement range edges with
  their 3GPP clauses, and `AT+CFUN=15` as the modem reset for recovery step R5.

## 2026-09-29 — The unscheduled ideas decided: M9 (`v1.2.0`), zip-only distribution, update notice; elevated code only from Program Files

**M9 — SMS, USSD and data usage, in `v1.2.0`.** The three serve one need, a prepaid or capped SIM:
the operator's messages, balance codes, how much data is left.
- SMS in **PDU mode**, with the codec written as pure functions from 3GPP TS 23.040 and 23.038:
  text mode depends on the character-set setting and hides the header that joins the parts of a
  long message. New messages are **stored, then announced** (`+CMTI`), never delivered directly
  (`+CMT`): direct delivery doesn't store the message, so one arriving while the app is closed
  would be lost, and it needs an acknowledgement within 15 s.
- USSD is **best effort**. The vendor manual documents `+CUSD`, but no source confirms it works on
  the FM350 over LTE/NR, where it depends on the operator's network. If the device session shows it
  doesn't, it is dropped, not emulated.
- Data usage is counted **on the Windows side**: neither the vendor manual nor 3GPP TS 27.007 has a
  byte counter. The adapter's counters restart whenever the adapter is re-created, so totals are
  accumulated across resets by a pure function and persisted. A quota only warns; it never
  disconnects.
- Other projects were read for facts: `sms_tool` (Apache-2.0) and `luci-app-sms-tool-js`
  (GPL-3.0). Neither has anything specific to the FM350.

**Distribution: the release zip only.** The PowerShell Gallery was weighed: `Update-PSResource`
would make updating one command, and both channels could share one installer. Declined for a
single channel: no publishing account or API key in the release pipeline, and a version published
to the Gallery can only be hidden, never deleted.

**Update notice, checked at start.** Once per app start, when the connection first comes online,
the worker reads the latest GitHub release and the tray menu reports a newer one. No timer in a
process that runs for weeks; the cost is that a release is noticed at the next start. The app never
installs an update itself: a self-updating elevated process is attack surface.

**Elevated code only from Program Files** (new invariant 10). The logon task runs the app elevated
without a prompt, so any file it executes from a user-writable place — the extracted zip, the
user's PowerShell profile, per-user modules, a path from settings — would let any program running
as the user gain administrator rights silently. The installer copies the app under
`%ProgramFiles%`; the task runs `pwsh -NoProfile` with a module path limited to admin-only folders;
no setting names code to run.

**Redaction list** extended with EID, phone numbers, message text and USSD replies (`CLAUDE.md`,
SETUP, CONTRIBUTING, reviewer).

## 2026-09-29 — Facts harvested from external sources; eSIM planned (M8, `v1.1.0`)

**Harvest.** Every fact the later milestones need from other projects is now in
`AT-COMMANDS.md`, with its source and commit, so development doesn't have to reopen them:
- `luci-app-3ginfo-lite` — its FM350-GL support is **GPL-3.0**, compatible with this project's
  AGPL-3.0, so it is a licensed source for what was otherwise only known from unlicensed code: the
  `+GTCCINFO`/`+GTCAINFO` layouts, the index → dBm/dB conversions (they match the 3GPP reporting
  ranges), the bandwidth codes, `AT+ICCID`, `AT+GTSENRDTEMP=1`, and `AT+GTUSBMODE` 40 = the
  `7126` composition. Its `<AcT>` reading (7 LTE, 11 SA, 13 NSA) follows 27.007.
- `luci-app-modemband` (MIT) — the FM350's supported LTE and 5G SA band lists, and how to change
  bands without changing the mode (keep the first three values of `AT+GTACT?`).
- `lpac` (AGPL-3.0) and `lpac-fibocom-wrapper` (MIT) — the eSIM path below.

**eSIM, after the first release.** `v1.0.0` stays focused on connection and stability; eSIM comes
in `v1.1.0` on that base. Scope: everything but erasing the chip — chip info, list, enable,
disable, nickname, download (activation code or QR), delete behind a strong confirmation,
automatic notification processing; `chip purge` is never exposed.

Design choice: lpac runs in its **`stdio` APDU mode** and the worker bridges each APDU to the eUICC
with `AT+CCHO`/`AT+CGLA`/`AT+CCHC`. The existing wrapper takes the other route — lpac's `at`
backend opens the COM port itself — which would break the one-owner invariant of the AT port
while the app is running. With `stdio`, lpac never sees the port, and the bridge is a pure
translation that can be tested without hardware.

**lpac ships in the release zip.** Unlike the modem driver, lpac's license (AGPL-3.0) allows
redistribution, so the simplest path for the user wins over guiding them to download it or having
the app download it. The release workflow fetches the pinned version from lpac's official GitHub
releases, checks its SHA-256, adds `lpac.exe` and its license to the zip, and attaches lpac's
source archive for the same tag to the GitHub Release — the corresponding source the AGPL
requires, kept next to the binary instead of relying on a third-party link staying up. The binary
is never committed to git. `CLAUDE.md`'s third-party-binaries rule now separates the two cases.

## 2026-09-29 — Roadmap decisions: driver before the first release, which is `v1.0.0`; where the upstream is named

- **Driver installation (now M6) comes before packaging and the first release (now M7).** With
  the guided design the driver milestone is small — detection, a dialog, a pure verification
  function, `pnputil` — and it makes the first release self-contained: install the app, and it
  walks the user through the driver. The installer and the driver install both need admin rights,
  so they are tested together. Cost: the first release comes one milestone later.
- **The first release is `v1.0.0`.** It comes only after every planned milestone, so it is the
  complete product, not a preview — SemVer's `0.x` ("anything may change") would undersell it.
  Until then `ModuleVersion` stays at `0.1.0` as the in-development marker; the release step sets
  it to `1.0.0`, and the release workflow checks that tag and module version agree.
- **The upstream project is named only in the technical docs**: `CLAUDE.md` (the rule needs a
  name to be enforceable), `docs/AT-COMMANDS.md` (it is the cited source of the `AT+GTACT`
  examples — the record of what was taken: facts from its README, never code) and this log.
  `README.md` and `CONTRIBUTING.md`, the public face, state the rule without the name.

## 2026-09-29 — Decision: "bring your own driver", guided (M6)

The app will never download or bundle the MediaTek serial driver. It **points** the user to where
a known copy is published — a third party's copy, pinned to a fixed commit, and said to be one —
the user downloads it, and the app decides whether it is safe to install.

Three options were weighed: the app downloading that copy itself (with consent), guiding the user
to it, or naming no source at all. Guiding won:
- **Downloading** would make the project part of the distribution chain of a proprietary binary
  republished without a license, write a hard dependency on a third party's repository into the
  code, and break the feature (until a new release) the day that repository disappears. It saves
  the user one click.
- **Naming no source** sends users hunting on driver mirror sites, where modified or unsigned
  packages are common.
- **Guiding** keeps the convenience, leaves the download with the user, and degrades gracefully:
  if the page goes away, any identical copy from anywhere is still recognized.

Authenticity never depends on the source: a WHQL catalog signature covers the hashes of every file
it lists, and `pnputil` re-validates it on install. So the check is a pure decision function:
Microsoft-signed catalog and matching hardware IDs are required; a match with a known fingerprint
(manifest of hashes and links, starting with the 3.22.43.1 package) upgrades the result to
"verified version". Executables inside a package are never run. Design: `ARCHITECTURE.md` →
*Drivers*; scope: ROADMAP M6.

## 2026-09-28 — Where the AT-port driver can come from (research for M6)

Where the app will get the driver at install time. Findings, recorded as facts in
`AT-COMMANDS.md` §1:

- **Only the AT ports need a driver.** The Linux `option` patch for the FM350-GL lists the USB
  interfaces: the network function is RNDIS, which Windows has built in; the AT ports are vendor
  class, which Windows' `usbser.sys` doesn't claim.
- **Not on Windows Update.** The Microsoft Update Catalog has no MediaTek serial package for these
  IDs, so plugging the modem in never installs it by itself: the app has to, and installing a
  driver always needs administrator rights.
- **OEM packages checked:** Dell F34XK 6.0.3.54 (official package, SHA-256 matching Dell's page)
  contains **only PCIe drivers** (`PCI\VEN_14C3&DEV_4D75` and Intel companions) — no USB serial
  INF. So do the FM350 "Ports" drivers published on the Microsoft Update Catalog by Fibocom and
  HP (0.6.200.352) and Palcom (5933.0.6.1). Laptops with the Intel 5G Solution 5000 all use the
  module over PCIe, so no laptop driver package is expected to carry the USB serial driver: that
  one comes from the module channel (Fibocom and its distributors), not from OEMs.
- **The driver in the upstream repository**: its installer is an unsigned NSIS "MediaTek
  COM_Driver Installer" 3.22.43.1 — nothing ties it to Acer despite the file name — but the driver
  inside is genuine: the catalog is signed by *Microsoft Windows Hardware Compatibility Publisher*
  and the `.sys` by MediaTek, and a catalog signature breaks if any covered file changes. So
  authenticity is established by the signature, not by the download location. Fingerprints, to
  recognize the same package from any source:

  ```
  39b8eaa7bcc86e8b9ab19f00755852f04a31a79992b95ae06606dc6383352197  usb2ser_tm.cat
  86254f45d729fd787650ede591412d64d61da1fbc80f7a03ec44a876e2401509  usb2ser_tm.inf
  2292b04b4d0c0659257078e2480d0a49fb5672ce9c4ff8461ade1504ebecdeaa  x64/usb2ser_tm.sys
  7dbb1edd585c5e49a8e7db05a2100b165436e3bd9cceb4d82c7dcf473624e5ca  x86/usb2ser_tm.sys
  ```

- **Still open:** an official public URL. Techship, Fibocom's distributor, publishes an *FM350 USB
  Driver Install User Guide v1.02*, so a Fibocom-distributed package exists; whether it matches the
  fingerprints above is unknown. Also unknown: whether 3.22.43.1 loads with Memory Integrity (core
  isolation) on — older MediaTek `usb2ser` drivers are reported incompatible.

## 2026-09-28 — Project setup (M0)

**Why this project.** [prusa-dev/fibocom-connect-fm350](https://github.com/prusa-dev/fibocom-connect-fm350)
proved that a USB-attached FM350-GL can be brought online on Windows with AT commands and a static
adapter configuration. It is a console script, its only recovery is a full restart when the device
or the link disappears, and it has no GUI, no band management and no driver handling. This
project aims at an app that runs for weeks without attention.

**Decisions taken before the first line of code:**
- **New repository, independent implementation.** The upstream repository has no license, so its
  code is all-rights-reserved: a fork would be tolerated by GitHub's terms, but modifying and
  redistributing it would not be licensed. Facts are not copyrightable, so the protocol knowledge
  is rebuilt from primary sources in `docs/AT-COMMANDS.md`, each fact with its source and status.
  Two MIT-licensed repositories by the same author (`luci-app-modemband`, `lpac-fibocom-wrapper`)
  are usable references.
- **PowerShell 7.6+, Windows only.** Chosen over Windows PowerShell 5.1 for a stable, installable
  runtime that also works on Windows 10, and over a compiled language to keep the project easy to
  read and change. Everything the app needs ships with PowerShell 7 on Windows — verified with
  pwsh 7.6.6 / .NET 10: `System.IO.Ports`, WPF, WinForms, `System.Drawing`, and the `PnpDevice`,
  `NetAdapter`, `NetTCPIP`, `DnsClient`, `ScheduledTasks` modules. Multi-platform was ruled out:
  on Linux ModemManager already does this job, and most of the work here is Windows-specific.
- **One process in the tray, no Windows service.** If the app is closed the user reopens it and
  monitoring resumes; closing it does not drop the connection, and reopening attaches to it.
- **Drivers are never committed.** The upstream repository ships a MediaTek serial-port driver
  (`usb2ser_tm` 3.22.43.1, WHQL-signed) without a license to redistribute it; here no driver is
  ever committed or shipped (M6 decides how the user gets it — see the 2026-09-29 entry).

**What landed.** Docs skeleton, CI (lint + tests on a Windows runner, tool versions pinned), logo
rendered from `assets/logo.html`, and the core module with its first pure function: the
`AT+GTACT` band-code codec. The codec refuses what it can't encode reliably (NR bands from n100
up, UMTS) and decodes an unrecognized code as `Unknown` with its raw value, so a band list read
from the modem can be written back unchanged. 36 tests; three mutations (wrong NR prefix, widened
LTE range, module file not loaded) each turned the suite red. The third exposed refusal tests that
passed for the wrong reason — "command not found" is also an exception — so they now assert the
parameter-binding exception specifically.

**Not verified:** anything that needs the modem, and CI on GitHub (the module requires pwsh 7.6+
on the runner).
