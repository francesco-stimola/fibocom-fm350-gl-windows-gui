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

### Current tests

| File | What it proves |
|---|---|
| `tests/Bands.Tests.ps1` | `AT+GTACT` band codes: encoding matrix per RAT, rejected inputs, decoding matrix, unknown codes kept as-is, empty or malformed fields refused (never read as "all bands"), full encode→decode round trip. |
| `tests/Module.Tests.ps1` | The manifest is valid and exports exactly the public functions. |
| `tests/AtText.Tests.ps1` | Framing the port's text into lines (split reads, CR-only echo, noise) and classifying each line: echo, answer, final result with its error code, unsolicited, stale. |
| `tests/AtChannel.Tests.ps1` | The AT channel over the simulated modem, and every fault scenario of ROADMAP M1: timeout, split answer, garbled bytes, a URC mid-answer, the port vanishing, the device back under another COM number, SIM busy after a band change, registration lost and regained, a slow `AT+COPS=0`, a late answer after a timeout, echo turned off. Also the bounded URC queue and closing. |
| `tests/SimulatedModem.Tests.ps1` | Fixture import and its format errors; the simulated modem answering from fixtures. |
| `tests/Transport.Tests.ps1` | Serial port names refused, a missing port failing to open; the `Hardware` test on a real FM350. |
| `tests/Fixtures.Tests.ps1` | Every fixture follows the format, names its source and carries only the documented fake identifiers; the identifier check catches real-looking ones. |
| `tests/Measurements.Tests.ps1` | Every measurement kind's index → dBm/dB mapping: range edges, the open-ended lowest and highest indexes, "not known" and out-of-range indexes. |
| `tests/Parsers.Tests.ps1` | Identity, SIM state, registration (read answers and URCs, every domain, reject causes), operator and technology, signal quality, temperature — on documented fixtures played through the channel. |
| `tests/Cells.Tests.ps1` | `+GTCCINFO` serving and neighbour layouts on LTE, EN-DC and SA; `+GTCAINFO` primary and secondary carriers, older shorter lines, malformed fields. |
| `tests/Arfcn.Tests.ps1` | EARFCN and NR-ARFCN against values worked out by hand from the 3GPP formulas, including the table rows that needed repair when transcribed. |
| `tests/Devices.Tests.ps1` | The modem's USB functions on a captured PnP snapshot (AT port without its driver, RNDIS working), the AT port of each composition, problem codes → driver state, leftover devices and other MediaTek devices skipped, two modems told apart. |

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
rewritten by hand. `tests/Fixtures.Tests.ps1` fails on any fixture that still carries an
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
