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
*Runtime dependencies*). The two bundled programs (`v1.2.0`) — lpac for eSIM, ZXing.Net to read a
QR code — are added to the release zip by the release workflow and never live in the repository.

Windows PowerShell 5.1 ships an old Pester 3.x in `C:\Program Files\WindowsPowerShell\Modules`.
Run the commands below from `pwsh`, which picks the per-user Pester 5+.

## Lint and test

From the repository root, in `pwsh`:

```powershell
./tools/Invoke-Lint.ps1
Invoke-Pester -Path ./tests -ExcludeTagFilter Hardware
```

Both must be clean: zero diagnostics, zero failures. CI (`.github/workflows/ci.yml`) runs the
same two commands on every push to `main` and every pull request, and writes every diagnostic and
every failed test as an annotation of the run: what failed can be read on the run's page, or from
GitHub's public API, without its log. Before the tests it builds the release zip and its notes,
as a release would (`tools/New-ReleasePackage.ps1`), publishes nothing, says what it built in a
notice, and names the zip in `FM350_PACKAGE` for the tests that run what it bundles.

- **Lint goes through `tools/Invoke-Lint.ps1`**, not a bare `Invoke-ScriptAnalyzer`.
  PSScriptAnalyzer 1.24–1.25 on PowerShell 7.6 intermittently fails its own command lookups
  ("the term 'Get-Command' is not recognized") — an error of the analyzer, not a finding — and
  stays broken for the rest of the process. The script analyzes the files one at a time in a
  child process and moves whatever is left to a fresh process after such a failure, the file it
  broke on first. It exits with 1 on any diagnostic, or for a file the analyzer failed on in 20
  processes (`-MaxFileAttempts`); no process starts after 80 in all (`-MaxProcesses`), so a run
  that can't succeed still ends. Diagnostics are never retried. The list of files reaches the
  child in a temporary file, so a clone in a deep folder doesn't outgrow Windows' command-line
  limit.
- **This test command needs no modem and no admin rights.** Tests that talk to a real device are
  tagged `Hardware`, and every documented command excludes them: Pester itself runs every tag
  unless told otherwise. Run them on purpose on a machine where the modem is attached, its AT
  function already on WinUSB as the app puts it, **and this app is not running** (it would hold
  the AT port): `$env:FM350_HARDWARE = '1'; Invoke-Pester -Path ./tests -TagFilter Hardware`. The
  AT port is found by PnP, as the app finds it. Without the variable they are skipped.
- **The programs the zip bundles are tested from a zip**: `tests/Bundled.Tests.ps1` takes lpac and
  ZXing.Net out of the zip `FM350_PACKAGE` names, and runs them — lpac through the bridge against
  the simulated eUICC, ZXing.Net on QR codes it writes. Without the variable they are skipped. To
  run them locally (network access, or the cache below):
  `$package = ./tools/New-ReleasePackage.ps1; $env:FM350_PACKAGE = $package.Zip`, then the test
  command.
- CI's `pwsh` shell sets `$ErrorActionPreference = 'Stop'`; a test that expects an error passes
  `-ErrorAction` explicitly so it behaves the same in CI and in an interactive session.
- Tests import the module **through its manifest**, the way the app does, so a function missing
  from `FunctionsToExport` fails the tests instead of passing them.

## Running the app from source

The tray app also starts from the repository, in `pwsh`:

```powershell
# Development mode: a simulated modem, no device, no administrator rights, no system change.
pwsh -NoProfile -File src/App/Start-Fm350App.ps1 -Simulated -Scenario PinRequired

# The real modem. Configuring its network adapter needs an elevated pwsh; without one, the app
# connects and stops before the adapter (it says so). -ObserveOnly reads and never writes.
pwsh -NoProfile -File src/App/Start-Fm350App.ps1 -ObserveOnly
```

- **Scenarios** of development mode: `Online`, `Connect`, `ApnNeeded` (the simulated network takes
  the APN `internet`), `PinRequired` (PIN `1234`; `0000` is refused), `FccLocked` (*Unlock* restarts
  it, unlocked), `AdapterDisabled`, `NoDevice`, `NoDriver`; M4's faults `Settling`, `DataPathDown`,
  `IcmpDropped`, `RegistrationLost`, `ModemHung`, `Unrecoverable`; M5's `LteOnlyMode`, `NrOnlyMode` (no
  5G SA: *5G only* finds no network) and `Standalone` (5G SA on n78). Its settings, secrets and log live in
  `%LOCALAPPDATA%\fibocom-fm350-gl-windows-gui\simulated\`, apart from the real ones, and it runs
  beside the real app.
- **One instance**: a second launch brings the running app's window to the front and exits.
  *Exit* in the tray menu stops monitoring only: the connection stays as it is.
- **The real modem's AT port has one owner.** While the app runs it holds the port: close it
  (tray menu → *Exit*) before running `Hardware` tests or session scripts.
- `-Hidden` starts in the tray, without the window.
- Modules load only from PowerShell's own folder and Windows': the start script sets the module
  path so, as the installed app does (ARCHITECTURE → *Startup, elevation, single instance*).
- `src/install.cmd` installs the repository's working copy as a release would install its zip:
  under Program Files, with its tasks and shortcut — one UAC prompt; `uninstall.cmd` removes it.

### Current tests

| File | What it proves |
|---|---|
| `tests/Bands.Tests.ps1` | `AT+GTACT` band codes: encoding matrix per RAT, rejected inputs, decoding matrix, unknown codes kept as-is, empty or malformed fields refused (never read as "all bands"), full encode→decode round trip; the supported and current band lists captured from the device (`AT+GTACT=?`, LTE-only, automatic, combined writes). |
| `tests/Modes.Tests.ps1` | The network mode: `AT+GTACT?` and `AT+GTACT=?` parsed from the device's captures (automatic, LTE-only, NR-only, combined writes, n77 with n78 and alone), unknown codes kept and written back; the command written; the decision matrix — not managed, not known, the mode and the preferences that count, bands restricted or every one, a band the modem leaves out no reason to write, a band it uses that the settings leave out, unsupported bands and modes, a write the modem didn't keep, what counts as narrowed; the trial's confirm and revert, a registration read too soon after the write ignored. |
| `tests/Lint.Tests.ps1` | The linter's retry decision (`tools/LintRetry.ps1`): the file a process broke on — one that died without a word included — counts one attempt and goes first in the next process; failures counted per file, never added up across files; a file given up at its last attempt while the others go on; no process past the limit; a run driven end to end against a made-up analyzer — a file failing nineteen times in a row, several in turn, one that always fails, an analyzer that fails on everything. |
| `tests/Module.Tests.ps1` | Both manifests — the core module and the tray app — are valid and export exactly their public functions, each with a synopsis. |
| `tests/AtText.Tests.ps1` | Framing the port's text into lines (split reads, CR-only echo, noise) and classifying each line: echo, answer, final result with its error code, unsolicited, stale. |
| `tests/AtChannel.Tests.ps1` | The AT channel over the simulated modem, and every fault scenario of ROADMAP M1: timeout, split answer, garbled bytes, a URC mid-answer, the port vanishing, the device back under another COM number, SIM busy after a band change, registration lost and regained, a slow `AT+COPS=0`, a late answer after a timeout, echo turned off. Also the bounded URC queue and closing. Sending a PDU (`Send-AtMessagePdu`): the prompt, the parts of a long message in turn, a refusal before the prompt and after the PDU, no prompt and no answer (ESC written, and the next command still in step), codes arriving before the prompt, with the answer and after it, a lost port not written to again, bad arguments, a closed channel. |
| `tests/SimulatedModem.Tests.ps1` | Fixture import and its format errors; the simulated modem answering from fixtures, and changing its answers once a scripted command has run. Its messages: the device's starting state, a message stored and announced once `+CNMI` asks, marked read once listed or read, deleted by place or flag, the lowest free place and a full storage, arrivals on a schedule, messages already stored, a PDU taken after `AT+CMGS`'s prompt and nothing after ESC. |
| `tests/Transport.Tests.ps1` | Serial port names refused, a missing port failing to open; the `Hardware` test on a real FM350. |
| `tests/Fixtures.Tests.ps1` | Every fixture follows the format, names its source and carries only the documented fake identifiers — a message PDU decoded, its service centre and sender among the fakes; the identifier check catches real-looking ones; the simulated modem of development mode answers with the documented fakes only, its messages too. |
| `tests/Measurements.Tests.ps1` | Every measurement kind's index → dBm/dB mapping: range edges, the open-ended lowest and highest indexes, "not known" and out-of-range indexes. |
| `tests/Parsers.Tests.ps1` | Identity, SIM state, registration (read answers and URCs, every domain, reject causes), operator and technology, signal quality, temperature — on documented and captured fixtures played through the channel: without a SIM, registered on LTE, with the radio off; a `+C5GREG` read answer that carries `<n>` alone. |
| `tests/Cells.Tests.ps1` | `+GTCCINFO` serving and neighbour layouts on LTE, EN-DC and SA; `+GTCAINFO` primary and secondary carriers, older shorter lines, malformed fields; the device's cells idle and connected (band from the channel number, the "not known" location pattern), its ten-field primary carrier, LTE-A and EN-DC under traffic. |
| `tests/Arfcn.Tests.ps1` | EARFCN and NR-ARFCN against values worked out by hand from the 3GPP formulas, including the table rows that needed repair when transcribed. |
| `tests/Devices.Tests.ps1` | The modem's USB functions on captured PnP snapshots — before the serial driver (AT port without it, RNDIS working) and after (AT port working on its COM port) — the AT port of each composition, problem codes → driver state, leftover devices and other MediaTek devices skipped, two modems told apart. Reading the PnP records with PnP mocked: one property call per device, properties labelled with another device ignored; the `Hardware` test reads them on a real FM350 (read-only); which modem to open, from the captured snapshots and a matrix (no modem, no driver, another problem, no COM port, back under another COM number, two modems); each function's driver package (the AT port's published as an `oem` INF), and the composition that needs one; the snapshot right after the driver was uninstalled (no problem code, a service read as none: no driver), keys PnP has no value for, and a service that couldn't be read (not taken for none). |
| `tests/Drivers.Tests.ps1` | The AT port's driver: the INF read as Windows reads it (comments, continued lines, `[Strings]`, sections merged, the catalog and the models section for x64, the package's files under their disks' paths); the verdict's matrix (the known package verified, a signed one the app doesn't know, a package for another port, no INF, no catalog, another signer, an attestation signature, an INF its catalog doesn't vouch for, a signature that doesn't verify, several INFs); the manifest's shape (hashes, a page pinned to a commit); copying a zip or a folder, an INF's package alone out of a shared folder, nothing outside the folder, nothing too big, a beat at every file; the folder only SYSTEM and administrators can open, and the leftovers deleted at the start — only the app's; the facts read from a package, each file hashed once; pnputil mocked: its arguments, exit codes, only an `oem` INF deleted; the `Hardware` test on the driver store's copy (read-only). |
| `tests/Timeouts.Tests.ps1` | Each command's documented worst case, the 3 s minimum, compound lines adding up; `Invoke-AtCommand` waiting that long when no timeout is given. |
| `tests/Contexts.Tests.ps1` | Data-context parsers on documented and captured fixtures: definitions, activation, address and mask in one field (IPv4, IPv6, odd masks), gateway, DNS over several lines, authentication without ever returning the password, `+GTDNS`, `+CGPADDR` (IPv4 or IPv6 by shape); the device's data context on the internet and the IMS APN. |
| `tests/Settings.Tests.ps1` | The decided defaults; every setting's validation (invalid → default and a problem, unknown → ignored); the network mode and its bands; the billing cycle's day and a quota in gigabytes with decimals, in the invariant culture; encrypted DNS - kept without servers, and said, unless the template names its server; a template naming an IP address for that server alone; how often its name is looked up - and the update notice; the file round trip, refusal to write an invalid value, a damaged file; the APN password encrypted and refused when it can't travel in an AT command. |
| `tests/Sim.Tests.ps1` | SIM states from `+CPIN?` and its CME errors, attempts left from `+CPINR` and from `+EPINC`, the PIN request, the ICCID (the device's lower-case filler); the PIN decision matrix (SIM state × stored PIN and its SIM × attempted × attempts left); the encrypted PIN store. |
| `tests/Fcc.Tests.ps1` | The three FCC reads, captured unlocked and documented locked; the diagnosis matrix (never locked when registered); the unlock on the simulated modem: the sequence once, the documented `ERROR` tolerated, a failing command stopping it before the restart, nothing written to an unlocked or unreadable module or without a confirmation. |
| `tests/Connection.Tests.ps1` | The state machine's matrix: from no device to online, every reason to stop and whether it is blocked, a drop from a further state, an active context differing from the settings, a context without an address or on the IMS APN, a context or a registration that couldn't be read (never written over), a disabled adapter, a port held by another program, an adapter to configure without administrator rights; the network mode written ahead of the context's steps, on a connection that is up too, after the radio and the operator selection, never over an FCC lock or before the SIM. |
| `tests/ConnectSequence.Tests.ps1` | Connect passes on the simulated modem: attaching to a connection that is up without a single write, a registered modem brought online step by step, the radio, the operator selection, the FCC lock, the SIM PIN rules (entered once, rejected and deleted, an answer that never came, last attempt — from `+CPINR` or `+EPINC` — another SIM, no ICCID, busy after the PIN, an attempt that can't be recorded, a pending attempt kept by another SIM), a failed address read taken for unknown, a modem error on `+CPIN?`, the APN asked for when the network gives the IMS APN, a context moved to the APN of the settings, the address from `+CGPADDR` as a /32, APN credentials, failing steps, a lost port, secrets kept out of the result and the log; "remove the PIN" (attempts from `+EPINC`, an unreadable PIN request, a malformed PIN refused without echoing it); without administrator rights the adapter left alone (`NotElevated`); the simulated adapter of development mode configured; the PIN attempts left read for the user while the SIM waits. |
| `tests/Network.Tests.ps1` | The adapter plan's matrix (fresh, configured, an earlier context, DHCP from the modem, DNS override, metric, missing address, a /32 with an on-link route when mask and gateway are missing, DNS compared per family); reading the adapter and applying a plan in the active store with the network cmdlets mocked; enabling the adapter the user disabled, found by its instance ID, and nothing under `-WhatIf`. |
| `tests/Sms.Tests.ps1` | The SMS codec on PDUs built by hand from 3GPP's layouts, GSM 7-bit packed by a reference drawn as a string of bits: a message received from a number of each type and a name, `*` and `#`, a fill semi-octet; UCS2, a surrogate pair, an odd octet; extension characters, an escape the table lacks, two escapes, a lone one; the time stamp's time zone, a digit that is not one, a date that doesn't exist; a long message's part, one-octet and two-octet references, fill bits; a national language table; 8-bit data and compressed text; class 0, silent, a voicemail waiting; a message stored to send with each validity-period format; a status report and every range of its status; malformed PDUs; the data coding scheme's matrix; the user data header's (ignored elements, the last of two, one that runs past). Encoding: exact PDUs, numbers refused, split at 160/153 and 70/67, an escape and a surrogate pair never split, a part packed after its header's fill bit, round trips, more than 255 parts refused; `Measure-SmsText`; joining parts in order, never across references, senders, counts or reference sizes, a part stored twice, parts missing, unread when a part is, the time of the first part; `+CMGL` through the channel, a header without its index and status left out, `+CMGR`, `+CPMS` (the device's capture), `+CMTI` (the device's line too); the device's `+CMGL` and `+CMGR` answers, decoded back to the texts sent. What is new: a fingerprint per PDU, the unread kept, opened and no longer stored left out; the encrypted file read back, missing, or unreadable. |
| `tests/Esim.Tests.ps1` | eSIM: lpac's lines read, its APDU requests carried as `AT+CCHO`/`AT+CGLA`/`AT+CCHC` and answered (matrices), its command lines and activation codes, its results read; the SIM slot's reads on device fixtures; the bridge run end to end with a scripted lpac (a lost port, a run that hangs, channels left open); the simulated eUICC and lpac; the worker's eSIM - `NoProfile`, the reads, every command and refusal, an eUICC with no profile published as read, the EID in its snapshot and no ICCID, no activation code in a snapshot or the log, a download from an image with no code refused unsent; the real process plumbing with a stand-in for lpac (`tests/Lpac/FakeLpac.ps1`). |
| `tests/Usage.Tests.ps1` | Data usage: a sample's bytes added, a counter that restarted, another adapter, nothing moved, the local day, 100 days kept, the input never changed; the cycle's first day (day 1, mid-month, a day the month lacks, a leap year, a year boundary); today and the cycle summed, the quota's percent and threshold; each threshold said once per cycle, only the highest of two reached at once, a new cycle or another quota starting over; the file read back, the thresholds said included, a damaged one giving nothing with a warning that names no folder; the adapter's counters read by its instance ID, with the network cmdlets mocked. |
| `tests/Log.Tests.ps1` | What redaction removes — secrets, identifiers, location, message content — and keeps; the daily files, the 14 kept, the daily limit noted once. |
| `tests/Radio.Tests.ps1` | The technology told from the serving cells — LTE, LTE-A, 5G NSA with an NR leg, 5G SA — never from `+COPS` nor from `+CESQ` alone (the idle anchor captured with NR measured: LTE, 5G available); no technology while the modem is not registered (another operator's NR cell camped on in NR-only mode); the signal bars at their edges; cells without their location; the status reads, what fails to read left out, and a read without an answer ending them. |
| `tests/Simulation.Tests.ps1` | Development mode: every scenario builds, its names agree with the start script; the simulated adapter configured as a real one is; the modem away after a restart and back on the same port; reopened after a channel closed it; restarted unlocked after the FCC unlock; its AT port's driver installed and uninstalled as pnputil would; its network mode answering as the device's captures do, one list per RAT, n77 dropped with n78, a write registering it again in the network around it (LTE, NR-only, 5G SA), refused values, the mode kept across a reset; the messages on its SIM, read, unread and in two parts, one more coming in later, kept across a restart that turns its notices off. |
| `tests/Worker.Tests.ps1` | The worker's cadence (pure matrix); its cycles on the simulated modem: attaching without a write, connecting, a restarted worker attaching without a write, observe-only, every block; snapshots never changed once published and free of secrets and identifiers; every command (settings, APN password, PIN stored, rejected and never retried, forgotten, removed from the SIM, FCC unlock and restart, adapter enabled, refused while observing); the AT port's driver — a package copied and checked, published as under way first, installed only once checked, a version the app doesn't know only once accepted, never over a port that works, a refused or unreadable package deleted at once, the copy deleted when the worker ends, uninstalled with the port closed and nothing escalated after, never while a network mode is on trial, refused while observing or without administrator rights, a copy that can't be deleted tried again and logged once, no folder of the user's in a failure's text; with PnP and pnputil mocked, installed from the copy with the heartbeat beating, pnputil's exit code told, only an `oem` INF uninstalled; a context code, or a status read without an answer, bringing the pass forward; a failed pass due again at once; the signal dropped below a ready SIM; the port lost and found again by PnP under another COM number, the network adapter a PnP read missed found without closing the port, a port another program holds, the scan interval; the heartbeat while the modem takes its time; the whole loop in a runspace, woken by a command, a failed cycle retried a second later, three in a row ending it; health and recovery scenario by scenario (M4); the network mode — left alone unless managed, never written again when kept, re-applied once in a maintenance window, a write not kept never repeated, nothing written while observing, no step for a narrowed mode without a network; the user's choice written, tried, saved or undone code by code, carried to a new worker, against a saved mode, after two changes, bands, the saved mode kept when other settings are saved. Data usage on the simulated modem: counted from the first reading, each quota threshold said once with the connection untouched, the totals and thresholds carried to the next worker, a USB restart, the settings measured again at once, counters that can't be read never stopping the cycle, the totals saved at the end; the schedule's readings of the counters, port open or not. Messages: the notices set once the SIM is ready, the storage read newest first with what is new, announced once with the newest sender and never again by the next worker, a notice read at once, a message stored without one found by the next pass and no listing when the storage is as it was, a long message announced once as its parts come, a silent message listed but never new nor announced, and deleted, a full storage; opened for good - by the next worker before its first listing too -, deleted part by part where they are now, nothing for one gone; the unread parts of a listing cut short kept new; the cycle going on when reading messages fails, said once by the error's type; sent part by part, said to be going out first, stopped at a refused part and never sent again, a number or a text refused; no number and no text in the log, an error given by its type; nothing in observe-only mode or without a ready SIM; a refused step said once and tried after the next pass; the notices set again after a lost port. |
| `tests/AppView.Tests.ps1` | What the tray and the window show for each simulated scenario and made-up snapshots: tones, bars, 5G/4G labels, the tooltip within 127 characters, every reason and every command outcome in words, numbers in the invariant culture, what unblocks each block and when it can't be clicked, the SIM tab, observe-only and a restarting worker; the network tab (the modem's mode and bands, the choices, a trial and how it ended, bands left out) and the tray's mode menu; the Driver tab (the AT port's driver, where the known copy is published and by whom, a package's verdict and why one is refused, what is under way, what can't be done and why, no uninstall during a network-mode trial); *No network* for a narrowed mode once its grace time is over; the app's version in the footer. The Messages tab (the list newest first, new ones marked and counted, the time where the user is, a text cut for the list and on one line, what a message without text shows, parts missing, a national table, why there are none, a full and an empty SIM, a message going out, the newest sent), the count of a message being written (GSM 7-bit, an escape, two parts, UCS2, too long), the Data tab (today, the cycle's first and last day, the quota and its share, at most a full bar, a threshold, nothing counted yet, sizes whatever the culture), the tooltip's usage line and its room, the tray's notices (once each, messages first, singular and plural, by sender only), message outcomes (parts sent, an error's type, an opened message saying nothing). The eSIM tab and the SIM in use (slots counted from 1, the eSIM's profile enabled, a physical SIM), *Open eSIM* for an eSIM with no profile enabled, the EID, the chip and the notifications, a profile's name by nickname, name or provider, what can't be done and why (a command under way, no lpac, a failed read, not read yet, no profile, no slot, no modem, observe-only), a QR code read only with ZXing.Net, nothing without a snapshot or from before M9; every eSIM outcome in words, an activation code's problem and an image's by name. |
| `tests/TrayIcon.Tests.ps1` | The icon drawn at every size, the label only where legible, redrawn only on a change, the previous handle destroyed once the new icon is set, and the GDI and USER object counts flat over hundreds of redraws. Notifications: the tray icon's window and id reached once it shows, nothing on what is not one, the standard notification where the app's icon can't go in, nothing under -WhatIf. |
| `tests/AppIcon.Tests.ps1` | The app's own icon: the logo's glyph drawn where `logo.html` puts it (the bars, the lighter last one, the arrow, its opening, a transparent background), the icon file with every size as PNG images, and the window's icon holding them all; the taskbar identity set on a window and taken off again, and set on a shortcut without changing what it runs; the notifications' icon, large, its handles released. |
| `tests/MainWindow.Tests.ps1` | The window, never shown: it loads, takes every scenario's view, keeps what the user types, and turns its buttons into commands — the FCC unlock, removing the PIN from the SIM, uninstalling the driver and installing a version the app doesn't know only after a confirmation; the Driver tab opened from the blocker, its page opened, the package chosen sent to be checked; invalid settings refused at once; encrypted DNS and the update notice filled and saved, to a server the template names with how often its name is looked up, encrypted DNS refused for a server without a template, without servers or where Windows can't, an interval out of range refused, the Connection tab opened from its blocker; the network tab filled from the view, a mode and its bands applied, a band asked for at least, *Use 4G + 5G* from the blocker; the app's icon; the tabs that scroll, the footer that wraps beside *Check now*. The Messages tab: its header and list, a new message opened when selected, and again when selected again, a selection kept when the list is filled again, deleting only once confirmed, sending the number and text as typed, once however many clicks until the worker answers or another worker takes over, the text kept until sent and a new one kept, 255 parts at most, nothing sent without both, the count as one types, a message going out, nothing without a modem. The Data tab: what it shows, the quota's bar red from a threshold, its form left alone while the user types, its two settings saved with the others as saved and a decimal comma, a day refused; the connection's save keeping them. The eSIM tab: the SIM in use in the top panel, the profiles, the EID, the other slot; the tab opened from its blocker; a physical SIM in use keeping the eSIM out of reach; the slot switched, a profile enabled or disabled only after a Yes, deleted only once its name was typed - in a dialog whose button works once the name matches, blanks and case aside -, renamed with the blanks around taken off, a nickname over 64 bytes refused; the buttons that fit the profile selected, the selection kept; a download from the code typed and its confirmation code, as secure strings, or from the image of a QR code, which a code typed replaces, the form emptied once done, nothing sent without a code; one command at a time until the worker answers or another takes over; the EID copied, or a hint. |
| `tests/Startup.Tests.ps1` | The start at sign-in: the logon task read (on, off, missing) and turned on or off with Task Scheduler's cmdlets mocked; the worker's command on the simulated device, installed and not, refused while observing; a failed read; what the window shows, greyed out and why, and its Save turning it on only when changed. |
| `tests/Texts.Tests.ps1` | The languages: the one chosen for each Windows display language, English where a table can't be read, placeholders in the invariant culture; every table of the app and of the installer UTF-8 with a byte order mark, with English's keys and placeholders and no stray brace, a sentence after a colon in lower case; every key the code and the XAML name exists, every English key used - a family of keys completed with a code, of one part or more (`Esim.State.<state>`); each language on every simulated scenario, in the tray, the menu and the window, with no key missing; every rule a setting can break in words, and in English as the log says it; the installer's texts and yes in each language; the launcher's Italian read right by Windows PowerShell 5.1. |
| `tests/Supervisor.Tests.ps1` | When to replace a worker and how long to wait, silence across a sleep not counted (pure matrix); real worker runspaces on the simulated modem: started, stopped with the port closed, restarted attaching without a write, ended after failing cycles with the reason told, working with an unwritable log, abandoned while stuck; the errors a worker writes taken; the single instance, the second launch's signal, a second launch without the running instance's rights exiting quietly, and a mutex taken over from an instance that died; the exit event the installer signals; the module path the app started with, kept as a worker's runspace opens. |
| `tests/App.Tests.ps1` | The whole app in a process of its own, in development mode: it starts, connects, and exits cleanly when asked, its worker stopped and the port closed, with nothing logged as an error; the tray's network mode menu filled as it opens and a click sending the mode; a notification shown once the tray icon shows, and once, the standard one where the app's icon can't go in. |
| `tests/Installer.Tests.ps1` | The launcher's choice of PowerShell 7 (a matrix: MSI, MSIX, too old, outside Program Files, not Microsoft's) and of the Windows it installs on (x64 only: Arm, 32-bit, a processor that can't be read), also run in Windows PowerShell 5.1, and the PowerShell running the tests found; command lines quoted as Windows splits them; the install layout from the known folders, not the environment; the two tasks' definitions (no time limit, on batteries, normal priority, highest privileges) and their registration with Task Scheduler's cmdlets mocked; the `lpac` and `zxing` folders copied when the package has them; the admin-only check's matrix, a user's folder refused and the system folder taken; the package copied without what lies beside it, its mark of the web removed; installing, updating over a running app, leftovers, a copy not admin-only, a swap that fails, an app that won't exit, run from the install folder, the shortcut and its icon, the app started again when an update fails after it exited; the entry in Windows' installed apps (in Pester's test registry key: its values, written whole again, taken off last, kept after a failed uninstallation only while what it runs is whole); uninstalling, with the user's data or not; the running app asked to exit through its event - a real app in development mode included; the setup script refusing an account that isn't the one that ran it. No task is registered, nothing written under Program Files. |
| `tests/Release.Tests.ps1` | The release's version (the three modules, the tag) and the CHANGELOG section that becomes the notes, as matrices; lpac's and ZXing.Net's pins (their official addresses, no `libcurl.dll`, the library for .NET 9, the license at its tag) and a pin missing a part refused; the notes beside lpac and ZXing.Net; the zip built from this repository with stand-ins for lpac's release and ZXing.Net's package, offline: the package at its top, lpac and ZXing.Net in their folders, nothing else, a `lpac` or `zxing` folder in `src/` never packaged, a package the installer takes; a SHA-256 that doesn't match builds nothing. |
| `tests/Updates.Tests.ps1` | What GitHub's answer about the latest release means (a matrix: newer, the same, older, draft, prerelease, none, a refusal and whether it is the rate limit, errors), the release's page built from its tag; where the latest release's page leads (a matrix: a release's page, the list of releases, another site or page, no redirect, a refusal never asked about again); the request - the app's name as its user agent and nothing else, read once ended, failing on a refused connection and a timeout, sent to the loopback address only; the page's request - a `HEAD`, its redirect not followed, to a loopback listener; the worker's one attempt per app start, once online, the page asked once after a refusal, not in development mode or when turned off, carried to a new worker; the tray menu's item. |
| `tests/Dns.Tests.ps1` | Encrypted DNS: the plan's matrix (each server with the template Windows knows or the settings give, per family, set again when it differs or may fall back, nothing at all planned without servers, the API or a template, taken off first when turned off, no static server left in the clear in a family the servers leave out, Windows' own IPv6 servers never changed, encryption left as it is when Windows refused part of the read or its list of templates — the servers still set with encryption off, the template the adapter carries kept, nothing blocked, said once; the IPv6 servers the network gives told from static and Windows' own ones, in one written form, said and never acted on); the changes applied with the Windows call mocked; an interface of this computer read (read only), a refused read, the function missing, Windows' list of templates unreadable; the blocked state; the whole pass on the simulated modem, on and off; what the window shows. A server named by its template: which servers the settings and the lookups give; the plan without addresses yet (no DNS server at all, the ones already encrypted with the template kept, an adapter the modem's DHCP configured left alone); the app's own DNS query and the reading of answers (RFC 1035 matrix: aliases, compression, errors, another ID, name or type, malformed); a real query over loopback, a source address this computer doesn't have, an answer from elsewhere, Windows' answers faked; the worker on the simulated modem — the first lookup, the interval, the operator's DNS only when Windows can't, no DNS server while it fails with one log line, a new name, a worker restart, a lookup timed out and closed, the cycle waiting while a lookup is under way; the window and the log on the network's IPv6 servers. |
| `tests/Health.Tests.ps1` | Which check fails, from the connection's state; the data path's verdict from its rounds, a path never answered since the start taken for nothing; the probe sent from a source address. |
| `tests/Recovery.Tests.ps1` | The recovery decision's matrix: entry steps, grace, settle, the ladder climbed, cycles, backoff and the slow cadence, health that holds, maintenance windows, blocked and unknown states, skipped steps, a narrowed network mode leaving H4 without a step; the steps on the simulated modem and on the system, mocked. |

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

## Releasing

Releases are cut from **git tags**. Nothing is released by merging. The zip attached to the
GitHub Release is the only distribution channel.

**The first release is `v1.0.0`**, cut at the end of M7; before it `ModuleVersion` was `0.1.0`,
"in development", and there are no `0.x` releases.

1. Set `ModuleVersion` in the three manifests - `src/FibocomFm350/FibocomFm350.psd1`,
   `src/App/FibocomFm350.App.psd1`, `src/Installer/FibocomFm350.Installer.psd1` - and move the
   `Unreleased` section of `CHANGELOG.md` under the new version, with the date.
2. Commit and push; CI builds the zip and the notes from that commit (a notice says what).
3. Tag and push the tag: `git tag v1.0.0` and `git push origin v1.0.0`.
4. The release workflow (`.github/workflows/release.yml`) runs CI's lint, tests and package, then
   checks that the tag names the modules' version, builds
   `fibocom-fm350-gl-windows-gui-1.0.0.zip`, and publishes a GitHub Release with that zip and the
   version's `CHANGELOG.md` section as its notes (`gh release create`, the job's own token), and
   lpac's source archive beside the zip (from `v1.2.0`). Its actions are pinned to commits.
5. **lpac and ZXing.Net** (from `v1.2.0`): the package takes their pins - `tools/Lpac.psd1`:
   lpac's Windows build into the zip's `lpac` folder, its source archive beside the zip;
   `tools/ZXing.psd1`: ZXing.Net's library for .NET 9 from its nuget.org package, and its license,
   into the zip's `zxing` folder -, each file used only when its SHA-256 matches the pin. It
   downloads them into `dist/download/` (`download` in the output folder), or takes them from
   `-Cache`; locally too, the zip is built only with that network access or cache. A new version
   is a new pin: its files' SHA-256; for lpac, the facts of `AT-COMMANDS.md` §8 read again at its
   tag and a device session. Neither is committed, `src/lpac/` and `src/zxing/` included.

What a user does with the zip is in `README.md` → *Install*: PowerShell 7.6+, the zip extracted,
`install.cmd` with its one UAC prompt, the driver step guided by the app. Unsigned scripts are
expected: the tasks and the installer start PowerShell with `-ExecutionPolicy Bypass` for this
app's files only; the computer's execution policy is not changed.
