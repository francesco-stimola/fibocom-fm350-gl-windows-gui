# Development setup, testing and releasing

## What you need

| Tool | Why | Install (per user, no admin) |
|---|---|---|
| **PowerShell 7.6+** | Runs the app, the linter and the tests. | `winget install Microsoft.PowerShell` |
| **Pester** | Test framework. | `Install-PSResource Pester -Scope CurrentUser` |
| **PSScriptAnalyzer** | Linter. | `Install-PSResource PSScriptAnalyzer -Scope CurrentUser` |
| Git | Version control. | — |
| VS Code + PowerShell extension | Optional editor. | — |

CI pins the exact Pester and PSScriptAnalyzer versions in `.github/workflows/ci.yml`; install the
same ones locally (`-Version <x.y.z>`) if a result differs between your machine and CI.

That is the whole list. The app needs **nothing beyond PowerShell 7** to develop and run: serial
port, WPF, WinForms and the Windows networking/PnP modules all ship with it (ARCHITECTURE →
*Runtime dependencies*). The one bundled tool, lpac for eSIM (`v1.1.0`), is added to the release
zip by the release workflow and never lives in the repository.

Windows PowerShell 5.1 ships an old Pester 3.x in `C:\Program Files\WindowsPowerShell\Modules`.
Run the commands below from `pwsh`, which picks the per-user Pester 5+.

## Lint and test

From the repository root, in `pwsh`:

```powershell
./tools/Invoke-Lint.ps1
Invoke-Pester -Path ./tests -ExcludeTagFilter Hardware
```

Both must be clean: zero diagnostics, zero failures. CI (`.github/workflows/ci.yml`) runs the
same two commands on every push to `main` and every pull request.

- **Lint goes through `tools/Invoke-Lint.ps1`**, not a bare `Invoke-ScriptAnalyzer`.
  PSScriptAnalyzer 1.24–1.25 on PowerShell 7.6 intermittently fails its own command lookups
  ("the term 'Get-Command' is not recognized") — an error of the analyzer, not a finding — and
  stays broken for the rest of the process. The script analyzes the files one at a time in a
  child process, moves whatever is left to a fresh process after such a failure, and exits with
  1 on any diagnostic or on a file it could not analyze at all.
- **This test command needs no modem and no admin rights.** Tests that talk to a real device are
  tagged `Hardware`, and every documented command excludes them: Pester itself runs every tag
  unless told otherwise. Run them on purpose on a machine where the modem is attached **and this
  app is not running** (it would hold the AT port), naming the modem's AT port:
  `$env:FM350_AT_PORT = 'COM5'; Invoke-Pester -Path ./tests -TagFilter Hardware`. Without the
  variable they are skipped.
- CI's `pwsh` shell sets `$ErrorActionPreference = 'Stop'`; a test that expects an error passes
  `-ErrorAction` explicitly so it behaves the same in CI and in an interactive session.
- Tests import the module **through its manifest**, the way the app does, so a function missing
  from `FunctionsToExport` fails the tests instead of passing them.

## Running the app from source

Until the installer (M7), the tray app starts from the repository, in `pwsh`:

```powershell
# Development mode: a simulated modem, no device, no administrator rights, no system change.
pwsh -NoProfile -File src/App/Start-Fm350App.ps1 -Simulated -Scenario PinRequired

# The real modem. Configuring its network adapter needs an elevated pwsh; without one, the app
# connects and stops before the adapter (it says so). -ObserveOnly reads and never writes.
pwsh -NoProfile -File src/App/Start-Fm350App.ps1 -ObserveOnly
```

- **Scenarios** of development mode: `Online`, `Connect`, `ApnNeeded` (the simulated network takes
  the APN `internet`), `PinRequired` (PIN `1234`; `0000` is refused), `FccLocked` (*Unlock* restarts
  it, unlocked), `AdapterDisabled`, `NoDevice`, `NoDriver`. Its settings, secrets and log live in
  `%LOCALAPPDATA%\fibocom-fm350-gl-windows-gui\simulated\`, apart from the real ones, and it runs
  beside the real app.
- **One instance**: a second launch brings the running app's window to the front and exits.
  *Exit* in the tray menu stops monitoring only: the connection stays as it is.
- **The real modem's AT port has one owner.** While the app runs it holds the port: close it
  (tray menu → *Exit*) before running `Hardware` tests or session scripts.
- `-Hidden` starts in the tray, without the window.

### Current tests

| File | What it proves |
|---|---|
| `tests/Bands.Tests.ps1` | `AT+GTACT` band codes: encoding matrix per RAT, rejected inputs, decoding matrix, unknown codes kept as-is, empty or malformed fields refused (never read as "all bands"), full encode→decode round trip; the supported and current band lists captured from the device (`AT+GTACT=?`, LTE-only, automatic, combined writes). |
| `tests/Module.Tests.ps1` | Both manifests — the core module and the tray app — are valid and export exactly their public functions, each with a synopsis. |
| `tests/AtText.Tests.ps1` | Framing the port's text into lines (split reads, CR-only echo, noise) and classifying each line: echo, answer, final result with its error code, unsolicited, stale. |
| `tests/AtChannel.Tests.ps1` | The AT channel over the simulated modem, and every fault scenario of ROADMAP M1: timeout, split answer, garbled bytes, a URC mid-answer, the port vanishing, the device back under another COM number, SIM busy after a band change, registration lost and regained, a slow `AT+COPS=0`, a late answer after a timeout, echo turned off. Also the bounded URC queue and closing. |
| `tests/SimulatedModem.Tests.ps1` | Fixture import and its format errors; the simulated modem answering from fixtures, and changing its answers once a scripted command has run. |
| `tests/Transport.Tests.ps1` | Serial port names refused, a missing port failing to open; the `Hardware` test on a real FM350. |
| `tests/Fixtures.Tests.ps1` | Every fixture follows the format, names its source and carries only the documented fake identifiers; the identifier check catches real-looking ones; the simulated modem of development mode answers with the documented fakes only. |
| `tests/Measurements.Tests.ps1` | Every measurement kind's index → dBm/dB mapping: range edges, the open-ended lowest and highest indexes, "not known" and out-of-range indexes. |
| `tests/Parsers.Tests.ps1` | Identity, SIM state, registration (read answers and URCs, every domain, reject causes), operator and technology, signal quality, temperature — on documented and captured fixtures played through the channel: without a SIM, registered on LTE, with the radio off; a `+C5GREG` read answer that carries `<n>` alone. |
| `tests/Cells.Tests.ps1` | `+GTCCINFO` serving and neighbour layouts on LTE, EN-DC and SA; `+GTCAINFO` primary and secondary carriers, older shorter lines, malformed fields; the device's cells idle and connected (band from the channel number, the "not known" location pattern), its ten-field primary carrier, LTE-A and EN-DC under traffic. |
| `tests/Arfcn.Tests.ps1` | EARFCN and NR-ARFCN against values worked out by hand from the 3GPP formulas, including the table rows that needed repair when transcribed. |
| `tests/Devices.Tests.ps1` | The modem's USB functions on captured PnP snapshots — before the serial driver (AT port without it, RNDIS working) and after (AT port working on its COM port) — the AT port of each composition, problem codes → driver state, leftover devices and other MediaTek devices skipped, two modems told apart. Reading the PnP records with PnP mocked: one property call per device, properties labelled with another device ignored; the `Hardware` test reads them on a real FM350 (read-only); which modem to open, from the captured snapshots and a matrix (no modem, no driver, another problem, no COM port, back under another COM number, two modems). |
| `tests/Timeouts.Tests.ps1` | Each command's documented worst case, the 3 s minimum, compound lines adding up; `Invoke-AtCommand` waiting that long when no timeout is given. |
| `tests/Contexts.Tests.ps1` | Data-context parsers on documented and captured fixtures: definitions, activation, address and mask in one field (IPv4, IPv6, odd masks), gateway, DNS over several lines, authentication without ever returning the password, `+GTDNS`, `+CGPADDR` (IPv4 or IPv6 by shape); the device's data context on the internet and the IMS APN. |
| `tests/Settings.Tests.ps1` | The decided defaults; every setting's validation (invalid → default and a problem, unknown → ignored); the file round trip, refusal to write an invalid value, a damaged file; the APN password encrypted and refused when it can't travel in an AT command. |
| `tests/Sim.Tests.ps1` | SIM states from `+CPIN?` and its CME errors, attempts left from `+CPINR` and from `+EPINC`, the PIN request, the ICCID (the device's lower-case filler); the PIN decision matrix (SIM state × stored PIN and its SIM × attempted × attempts left); the encrypted PIN store. |
| `tests/Fcc.Tests.ps1` | The three FCC reads, captured unlocked and documented locked; the diagnosis matrix (never locked when registered); the unlock on the simulated modem: the sequence once, the documented `ERROR` tolerated, a failing command stopping it before the restart, nothing written to an unlocked or unreadable module or without a confirmation. |
| `tests/Connection.Tests.ps1` | The state machine's matrix: from no device to online, every reason to stop and whether it is blocked, a drop from a further state, an active context differing from the settings, a context without an address or on the IMS APN, a context or a registration that couldn't be read (never written over), a disabled adapter, a port held by another program, an adapter to configure without administrator rights. |
| `tests/ConnectSequence.Tests.ps1` | Connect passes on the simulated modem: attaching to a connection that is up without a single write, a registered modem brought online step by step, the radio, the operator selection, the FCC lock, the SIM PIN rules (entered once, rejected and deleted, an answer that never came, last attempt — from `+CPINR` or `+EPINC` — another SIM, no ICCID, busy after the PIN, an attempt that can't be recorded, a pending attempt kept by another SIM), a failed address read taken for unknown, a modem error on `+CPIN?`, the APN asked for when the network gives the IMS APN, a context moved to the APN of the settings, the address from `+CGPADDR` as a /32, APN credentials, failing steps, a lost port, secrets kept out of the result and the log; "remove the PIN" (attempts from `+EPINC`, an unreadable PIN request, a malformed PIN refused without echoing it); without administrator rights the adapter left alone (`NotElevated`); the simulated adapter of development mode configured; the PIN attempts left read for the user while the SIM waits. |
| `tests/Network.Tests.ps1` | The adapter plan's matrix (fresh, configured, an earlier context, DHCP from the modem, DNS override, metric, missing address, a /32 with an on-link route when mask and gateway are missing, DNS compared per family); reading the adapter and applying a plan in the active store with the network cmdlets mocked; enabling the adapter the user disabled, found by its instance ID, and nothing under `-WhatIf`. |
| `tests/Log.Tests.ps1` | What redaction removes — secrets, identifiers, location, message content — and keeps; the daily files, the 14 kept, the daily limit noted once. |
| `tests/Radio.Tests.ps1` | The technology told from the serving cells — LTE, LTE-A, 5G NSA with an NR leg, 5G SA — never from `+COPS` nor from `+CESQ` alone (the idle anchor captured with NR measured: LTE, 5G available); the signal bars at their edges; cells without their location; the status reads, what fails to read left out, and a read without an answer ending them. |
| `tests/Simulation.Tests.ps1` | Development mode: every scenario builds, its names agree with the start script; the simulated adapter configured as a real one is; the modem away after a restart and back on the same port; reopened after a channel closed it; restarted unlocked after the FCC unlock. |
| `tests/Worker.Tests.ps1` | The worker's cadence (pure matrix); its cycles on the simulated modem: attaching without a write, connecting, a restarted worker attaching without a write, observe-only, every block; snapshots never changed once published and free of secrets and identifiers; every command (settings, APN password, PIN stored, rejected and never retried, forgotten, removed from the SIM, FCC unlock and restart, adapter enabled, refused while observing); a context code, or a status read without an answer, bringing the pass forward; a failed pass due again at once; the signal dropped below a ready SIM; the port lost and found again by PnP under another COM number, the network adapter a PnP read missed found without closing the port, a port another program holds, the scan interval; the heartbeat while the modem takes its time; the whole loop in a runspace, woken by a command, a failed cycle retried a second later, three in a row ending it. |
| `tests/AppView.Tests.ps1` | What the tray and the window show for each simulated scenario and made-up snapshots: tones, bars, 5G/4G labels, the tooltip within 127 characters, every reason and every command outcome in words, numbers in the invariant culture, what unblocks each block and when it can't be clicked, the SIM tab, observe-only and a restarting worker. |
| `tests/TrayIcon.Tests.ps1` | The icon drawn at every size, the label only where legible, redrawn only on a change, the previous handle destroyed once the new icon is set, and the GDI and USER object counts flat over hundreds of redraws. |
| `tests/MainWindow.Tests.ps1` | The window, never shown: it loads, takes every scenario's view, keeps what the user types, and turns its buttons into commands — the FCC unlock and removing the PIN from the SIM only after a confirmation; invalid settings refused at once. |
| `tests/Supervisor.Tests.ps1` | When to replace a worker and how long to wait, silence across a sleep not counted (pure matrix); real worker runspaces on the simulated modem: started, stopped with the port closed, restarted attaching without a write, ended after failing cycles with the reason told, working with an unwritable log, abandoned while stuck; the errors a worker writes taken; the single instance, the second launch's signal, a second launch without the running instance's rights exiting quietly, and a mutex taken over from an instance that died. |
| `tests/App.Tests.ps1` | The whole app in a process of its own, in development mode: it starts, connects, and exits cleanly when asked, its worker stopped and the port closed, with nothing logged as an error. |

## Fixtures

Raw captures go to `captures/` at the repository root, which git ignores. What is committed goes to
`tests/fixtures/`, one file per command and situation:

- `tests/fixtures/documented/` — answers written from the documentation: the layout is the cited
  source's, the values are invented. They let parsers be written before a device session, and are
  never mistaken for captures (status 📄 in `AT-COMMANDS.md`, not ✅).
- `tests/fixtures/device/` — answers captured from a real FM350, redacted.

A fixture is a text file:

```
# Source: [27.007] +CSQ, layout "+CSQ: <rssi>,<ber>"; values invented.
AT+CSQ
+CSQ: 20,99
OK
```

Lines starting with `#` are notes — the first says where the content comes from (a source key
such as `[FIBOCOM]`, or `captured` with the date and firmware). Then the command, then the answer
as the modem sends it, without echo, ending with its final result code. `Import-AtFixture` reads
it; `New-SimulatedModem -Fixture` answers with it.

A **PnP snapshot** — how Windows sees the modem's USB functions — is a JSON file instead:
`{ "Source": "captured <date>: <situation>", "Devices": [ <one record per device> ] }`, each record
holding the device properties as `Get-PnpDeviceProperty` names them, without the `DEVPKEY_Device_`
prefix (`InstanceId`, `Present`, `ProblemCode`, `Service`, `Parent`, `HardwareIds`...).

**Before a capture is committed**, identifiers are replaced with the fakes listed in
`tests/fixtures/fakes.psd1` — IMEI, IMSI, ICCID and EID digit runs, phone numbers, the module
serial number (`+CFSN`), the TAC and cell identity of registration reports and `+GTCCINFO`
lines, and in PnP snapshots the instance part of every instance ID (a USB serial number, or a
Windows-generated hash) and the container ID. Message text and USSD replies are
rewritten by hand. Location fakes keep the length the modem pads to (TAC 4 or 6 digits, cell
identity 8, 9 or 10); the modem's own "not known" pattern (`FFFF`, `00FFFFFFF`, `000000`) stays as
captured. Captured fixtures also take the 3GPP test network `001`/`01` for the operator, invented
PCIs (with the channel numbers, a set of neighbour cells fingerprints a place) and documentation
addresses (RFC 5737 for IPv4, RFC 3849 for IPv6). `tests/Fixtures.Tests.ps1` fails on any fixture that still carries an
identifier-like value other than those fakes.

## Releasing (from M7)

Releases are cut from **git tags**. Nothing is released by merging. The zip attached to the
GitHub Release is the only distribution channel.

**The first release is `v1.0.0`**, cut at the end of M7 when the whole planned scope is in. Until
then `ModuleVersion` stays at `0.1.0`, which means "in development"; there are no `0.x` releases.

1. Update `ModuleVersion` in `src/FibocomFm350/FibocomFm350.psd1` and move the `Unreleased`
   section of `CHANGELOG.md` under the new version.
2. Commit, then tag: `git tag v1.0.0` and `git push origin v1.0.0`.
3. The release workflow runs lint and tests, checks that the tag equals the module version, builds
   `fibocom-fm350-gl-windows-gui-1.0.0.zip`, and publishes a GitHub Release with that zip and the
   `CHANGELOG.md` section as release notes.

What a user does with the zip:

1. Install PowerShell 7.6+ (`winget install Microsoft.PowerShell`).
2. Download the zip from the Releases page and extract it.
3. Run `install.cmd` and accept the **single** UAC prompt. The installer copies the app under
   `%ProgramFiles%`, registers a logon task that starts it elevated from there, and adds a
   Start-menu shortcut. The extracted folder is not used afterwards and can be deleted.
4. If the modem's AT ports have no driver, the app says so and guides the user: it opens the page
   where a known copy is published, the user downloads the package and picks it, and the app
   verifies and installs it (ARCHITECTURE → *Drivers*).
5. From then on the app starts at logon, lives in the tray, and reopens from the Start menu without
   UAC prompts.

Updating means extracting the new zip and running `install.cmd` again; the tray menu says when a
newer release exists. Unsigned scripts are
expected: the installer and the logon task invoke `pwsh` with `-ExecutionPolicy Bypass` for this
app's files only; the machine's execution policy is not changed.
