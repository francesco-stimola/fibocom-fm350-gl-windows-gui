# Roadmap

**The single source of truth for "what's next".** Each milestone lists its scope as checkboxes;
keep them current as work lands. The design each milestone implements is in
[`ARCHITECTURE.md`](ARCHITECTURE.md); the protocol facts in [`AT-COMMANDS.md`](AT-COMMANDS.md);
the history in [`DEVLOG.md`](DEVLOG.md).

## Status

One row per milestone. The Status cell is a single label — ✅ complete · 🔨 code-complete ·
📋 planned. A release tag is noted next to the milestone it is cut from; a tag not cut yet is
written `(planned)`.

| Milestone | Status |
|---|---|
| [M0 — Project setup](#m0) | ✅ complete |
| [M1 — Modem protocol](#m1) | ✅ complete |
| [M2 — Connection](#m2) | ✅ complete |
| [M3 — Tray app](#m3) | ✅ complete |
| [M4 — Health & recovery](#m4) | ✅ complete |
| [M5 — Modes & bands](#m5) | ✅ complete |
| [M6 — Driver installation](#m6) | ✅ complete |
| [M7 — Packaging & first release](#m7) — tag `v1.0.0` | ✅ complete |
| [M8 — SMS, USSD & data usage](#m8) — tag `v1.1.0` (planned) | 📋 planned |
| [M9 — eSIM](#m9) — tag `v1.2.0` (planned) | 📋 planned |

---

<a id="m0"></a>
## M0 — Project setup

- [x] Repository layout, `CLAUDE.md`, docs skeleton (ARCHITECTURE, AT-COMMANDS, ROADMAP, DEVLOG, SETUP).
- [x] Lint (`PSScriptAnalyzer`) and test (`Pester`) setup, runnable locally without admin or modem.
- [x] CI workflow: lint + tests on every push and pull request.
- [x] Core module skeleton `src/FibocomFm350` with its first pure function: the `AT+GTACT` band-code codec, with a matrix of tests.
- [x] Logo (light/dark) from `assets/logo.html`.
- [x] First push; CI green on GitHub.

<a id="m1"></a>
## M1 — Modem protocol

Everything needed to talk to the modem and understand its answers — no connection logic yet.

- [x] **Device session**: answer the open questions in [`AT-COMMANDS.md` §7](AT-COMMANDS.md#7-open-questions-for-the-first-device-session), capture the responses into `tests/fixtures/device/`, and run the `Hardware` tests — the first time the serial transport meets the real port. The questions that need a data context, an NR leg or another network are carried by M2, M4 and M5 below.
- [x] Fixture rules in place: capture format, redaction of identifiers, and a test that fails if a fixture contains an unredacted IMEI/IMSI/ICCID pattern.
- [x] AT channel over a **transport** interface, with `System.IO.Ports` as the real transport: send a command, collect lines until the final result code, per-command timeout, URCs separated from responses.
- [x] **Simulated modem**: a transport that answers from fixtures and runs **scripted fault scenarios**, each an automated test in the default run:
  - no final result code (timeout); a response split across reads; garbled bytes;
  - an unsolicited result code arriving in the middle of a response;
  - the port vanishing mid-command, and the device coming back under a different COM number;
  - `+CME ERROR` / SIM busy right after a mode or band change;
  - registration lost and regained; a slow `AT+COPS=0`.
- [x] Pure parsers, each tested on fixtures: identity, SIM state, registration, operator + access technology, signal quality, serving/neighbour cells, carrier aggregation, temperature. (On documented fixtures; the device session adds captured ones.)
- [x] Measurement index → dBm/dB and ARFCN → band tables transcribed from the 3GPP specs, with clause/table numbers recorded in `AT-COMMANDS.md`.

<a id="m2"></a>
## M2 — Connection

- [x] Settings file (APN, optional APN credentials, DNS override, route metric) with defaults and validation. Defaults (decided 2026-10-01): empty APN — the subscription's own — with PDP type `IPV4V6`; DNS from the operator, no override; the modem as a backup (interface metric 500).
- [x] Read the PnP records `Resolve-ModemUsbDevice` classifies (`Get-PnpDevice`, one `Get-PnpDeviceProperty` call per device, the COM port name from the registry), in the worker: the AT port and the adapter are found with it. Brought forward from M6.
- [x] Connection state machine as a pure transition function, with a matrix of tests.
- [x] Per-command timeouts as a pure lookup: each command's worst-case duration from the vendor manual (`AT-COMMANDS.md` §2), never less than 3 s.
- [x] Connect sequence: SIM check, data context definition (written only when missing or different from the settings), registration, attach, context activation. A context that carries no internet — no IPv4 address, or the IMS APN the network gives an empty APN on some networks — asks for an APN (`ApnNeeded`) or, when it differs from the settings, is deactivated and set up again as they say.
- [x] SIM PIN (design: ARCHITECTURE → *SIM PIN*): the decision as a pure function with a matrix of tests (SIM state × stored PIN and its SIM × attempts left × already tried → send, ask the user, report, continue); the PIN stored DPAPI-encrypted with the SIM it belongs to; at most one attempt per stored PIN; a PUK never entered by the app.
- [x] FCC lock (design: ARCHITECTURE → *FCC lock*): read the three lock values in the connect sequence; the diagnosis as a pure function with a matrix of tests (lock values × registration state → locked or not; the vendor's unlock-status value decides, not a time limit) — it explains a registration that never starts and never stops a modem that registers; the unlock sequence, proven against the simulated modem.
- [x] Network configuration of the modem's adapter (address, mask, gateway, DNS) in the active store; the address from `+CGPADDR` when `+CGCONTRDP` leaves it out, as a /32 with a default route on the link when no mask or gateway is reported (the FM350 serves no DHCP).
- [x] Startup reconciliation: attach to an existing connection without re-dialing.
- [x] Redacted rolling log.
- [x] On the device: `AT-COMMANDS.md` §7 questions 5, 6 and 12 — the app's own data context (no address in `+CGCONTRDP`; `+CGPADDR` has it), no DHCP on the adapter (a /32 with an on-link route carries traffic), a written context lost at a reset, the `+CGAUTH` set form on that context — and the NR leg of an EN-DC cell under traffic (questions 3, 4, 10). With SIMs of two operators: an empty APN put on the IMS APN; the connect pass from nothing to a data context, attach without re-dialing, moving a context to the APN of the settings. With a SIM whose PIN is enabled: the `+CPIN` states, a wrong and a right PIN, `+CPINR` absent and `+EPINC` instead, `AT+CLCK="SC"` on and off (`AT-COMMANDS.md` §3).

<a id="m3"></a>
## M3 — Tray app

- [x] Worker runspace + immutable state snapshots + command queue. After a lost port the worker finds the AT port and the adapter again by PnP: after a re-enumeration the modem can come back as a new device instance under other COM numbers (`AT-COMMANDS.md` §1). Cadence decided 2026-10-01.
- [x] Supervisor: heartbeat, worker restart that attaches instead of re-dialing. Timings decided 2026-10-01.
- [x] Single instance (mutex; a second launch shows the first window).
- [x] Tray icon rendering with handle disposal; tooltip; menu. Icon states and texts decided 2026-10-01.
- [x] Main window: connection status, signal, cells, carrier aggregation.
- [x] What blocks the connection, in the window, with the action that unblocks it: an APN to give (`ApnNeeded`), the APN password to give again (`ApnPasswordUnreadable`), and for a network adapter the user disabled (`AdapterDisabled`) an *Enable* button (administrator rights) — never enabled by the app on its own.
- [x] FCC lock in the window and the tray: the diagnosis, and *Unlock* for a modem diagnosed as locked, behind a confirmation that says it writes the modem's non-volatile memory and lifts the maker's restriction; never automatic. Proven on the simulated modem; a module that is really locked is optional (below).
- [x] SIM PIN in the main window: enter or replace the stored PIN; the SIM's state (PIN or PUK required, PIN rejected, attempts left); "remove the PIN from the SIM" (`AT+CLCK="SC",0`) behind a confirmation that says it changes the SIM.
- [x] Development mode: the app runs against the simulated modem, without a device and without admin rights (no system changes).
- [x] On the device: the worker and the tray on the real modem — observing only, then elevated: online from nothing, still online after *Exit*, attached again at the next start without a step. 5G told from the NR leg in use (`AT-COMMANDS.md` §3).

Optional, not scheduled (decided 2026-10-01): the FCC unlock on a module that is really locked, capturing its locked values (`AT-COMMANDS.md` §4) — taken up only if one turns up or a user needs it; nothing in M4–M9 depends on it.

<a id="m4"></a>
## M4 — Health & recovery

- [x] Health checks H1–H7, told from the state the connect pass reaches, and H7 a data-path probe bound to the modem's address: ICMP rounds that a path still settling — an address Windows is still checking, a lost round — never fail, nor a path that has never answered since the app started (a network that drops ICMP). Target and interval decided 2026-10-02.
- [x] Recovery decision as a pure function (failing check + history → step), with a matrix of tests. No escalation for what no reset fixes: whatever the state machine calls blocked — a SIM waiting for its PIN or PUK, an FCC lock, an APN or its password to give, an adapter missing or disabled, no administrator rights — nor under a port another program holds.
- [x] Recovery steps R1–R6 with grace and settle times, cycles, backoff and the slow cadence, counters reset after sustained health (values decided 2026-10-02); the state carried across worker restarts and sleep; "Recovering" in the tray and the window.
- [x] Maintenance windows; the FCC unlock opens one.
- [x] On the simulated modem: new fault scenarios — a path that settles, a data path down, a registration lost, a modem that doesn't answer, a network that refuses it for good — each driven through the ladder by the worker in the default test run.
- [x] On the device: the data path right after the adapter is configured — M3's one reply in four was the address still `Tentative` for about 3.5 s; the worker's ladder R2 → R3 → R4 → R5 on the real modem, each step started by blocking the probes, and R6; `AT-COMMANDS.md` §7 question 8 for `+CFUN=1,1`.
- [x] Soak run on the real device, 24 h (decided 2026-10-02), with handle and memory counts before/after: online throughout, one worker, no recovery step, no warning; handles, GDI and USER objects, threads and private memory flat once warmed up (DEVLOG 2026-10-03).

<a id="m5"></a>
## M5 — Modes & bands

- [x] Read current mode and bands from the modem at every pass (`AT+GTACT?`); supported values from `AT+GTACT=?`, once per channel. Pure parsers on device fixtures; band codes kept as read (invariant 9).
- [x] UI: mode selector — *4G + 5G*, *4G only*, *5G only (SA)*, or *As the modem has it* (decided 2026-10-03) — and per-RAT band checkboxes, in a *Network* tab; the quick mode switch in the tray menu.
- [x] Apply inside a maintenance window, writing every managed RAT's band list (the modem keeps one list per RAT); persist in settings; re-apply on every connect — written only when the modem's differs from the settings, a band the modem drops by itself (n77) no reason to write again, a write that didn't hold never repeated. The user's choice is tried: saved once the modem registers with it, written back as it was when it finds no network; a narrowed mode that loses the network takes no recovery step and says so (decided 2026-10-03).
- [x] On the simulated modem: a network mode kept as the device keeps it, one list per RAT, n77 dropped with n78, a write that registers it again; new scenarios — the modem in LTE-only mode, in NR-only mode without 5G SA, a network with 5G SA.
- [x] On the device: `AT-COMMANDS.md` §7 question 7 — NR codes restrict NSA too (§5); question 10 — no 5G SA network for our SIM, the modem camping on another operator's SA cell (§4.1); n77 drops out when n78 is listed too, and stays alone (§5); every write ends the data context. The app's own pass and trials on the real modem: re-applied, kept, undone after 3 min.

Optional, not scheduled: `+GTCAINFO` on 5G SA (question 10), where a SIM's operator offers it; the LTE neighbour lines with a six-digit channel seen once (`AT-COMMANDS.md` §4.1).

<a id="m6"></a>
## M6 — Driver installation

"Bring your own driver", guided: the app never downloads or bundles a driver. It tells the user
where a known copy is published and by whom; the user downloads it and hands it over; the app
verifies it and installs it (design: ARCHITECTURE → *Drivers*).

- [x] Classify the modem's USB functions and their driver state (AT ports present without a driver) as a pure function, tested on a device capture: `Resolve-ModemUsbDevice`.
- [x] Read the PnP records it classifies: done in M2 (`Get-ModemPnpRecord`), which needs it to find the AT port.
- [x] Known-fingerprints manifest in the repo (SHA-256 of `.cat`, `.inf`, `.sys`, and the commit-pinned page where a copy is published — hashes and links only, no binaries), starting with MediaTek `usb2ser_tm` 3.22.43.1: `Data/Drivers.psd1`.
- [x] Package intake: a zip or a folder chosen by the user, copied into a new folder only SYSTEM and administrators can open, where it is checked and installed from (invariant 10); the INFs located in it. Never run an executable from the package.
- [x] Verification as a pure decision function with a matrix of tests: catalog signed by Microsoft (WHQL) → required; that catalog, and no other, vouches for the INF → required; INF covers the modem's hardware IDs → required; files match a known fingerprint → reported as a verified version. Facts and sources in `AT-COMMANDS.md` §1.1.
- [x] Install/uninstall via `pnputil` from the system folder, in the worker, with administrator rights; surfaced in the UI. Proven on the simulated modem (scenario `NoDriver`) and with PnP and pnputil mocked.
- [x] Driver dialog — the window's *Driver* tab, opened from the blocker: the project does not distribute the driver; where a known copy is published (commit-pinned page from the manifest) and that it is a third party's copy of MediaTek's driver; actions *open that page* and *choose the downloaded package*.
- [x] On the device: the published package checked (hashes, signature, the verdict) without installing it; the installed driver uninstalled and installed again by the app's commands, the modem back on its AT port as before — under new COM numbers and a new published name. The page opened from the elevated app in a browser that is not.

<a id="m7"></a>
## M7 — Packaging & first release

- [x] Installer (design: ARCHITECTURE → *Installing and updating*): `install.cmd` copies the app under `%ProgramFiles%` — the package's own entries, the mark of the web removed, the copy checked admin-only —, registers the two tasks (*Start at logon*, *Open*: highest privileges, no time limit, on batteries, normal priority) and the Start-menu shortcut, and lists the app in Windows' installed apps (decided 2026-10-03), whose *Uninstall* runs `uninstall.cmd`; `uninstall.cmd` removes all of it. Run again over a running app, it asks the app to exit — the connection stays up —, replaces the folder whole and starts it again; an update that fails after the app exited starts that app again. The tasks start Windows PowerShell 5.1 with the launcher `Start-Fm350.ps1`, which finds PowerShell 7 — the MSI's or the user's MSIX package, under Program Files and signed by Microsoft — at every start: winget installs the MSIX, whose folder changes at every update (invariant 10, `AT-COMMANDS.md` §11.2). Proven in TestDrive with Task Scheduler's cmdlets mocked.
- [x] The module path held to admin-only folders in the launcher, the installer and the app — also after a worker's runspace opens, which puts the user's module folder back in it (`AT-COMMANDS.md` §11.2).
- [x] Starting at sign-in off by default (decided 2026-10-03): the logon task is registered disabled, an update keeps the user's choice, and a checkbox in the *Connection* tab turns it on or off.
- [x] The installer refuses a Windows the app can't run on — anything but 64-bit Windows on x64 (decided 2026-10-03): PowerShell 7.6 has no 32-bit build, Windows on Arm loads only Arm64 kernel drivers (`AT-COMMANDS.md` §11.2).
- [x] Release workflow on `v*` tags (`release.yml`): CI's lint, tests and package, the tag checked against the three modules' version, the zip built, a GitHub Release published with the version's `CHANGELOG.md` section as notes; actions pinned to commits. CI builds the zip and the notes at every push, publishing nothing.
- [x] Update notice: once per app start, when the connection first comes online, the latest GitHub release read — asynchronously, the app's name as user agent and nothing else, 10 s at most, one attempt; when the API refuses (rate limit), the latest release's page once instead, its redirect read —; if it is newer, the tray menu says so and links its page, built from its tag. Never installs anything; a setting turns it off; never in development mode.
- [x] Encrypted DNS (DoH) on the modem's adapter (decided 2026-10-03): a setting turns DoH on for the servers of the DNS override, which it needs; an optional DoH template applies to every server of the override; a server with no template, known or given, is a settings problem. Applied per interface (`SetInterfaceDnsSettings`, `DNS_INTERFACE_SETTINGS3`, `DnsServerDohProperty`), each family's servers set with their encryption in one call, re-applied by the pass, removed when turned off; no fallback to plain DNS: what can't be set leaves the adapter unconfigured and waits for the user. The window shows whether it is on, and IPv6 DNS servers the network gives besides, which Windows may query in the clear (decided 2026-10-03: said, never acted on). No DoT. Windows 10 has no per-interface DoH (`AT-COMMANDS.md` §11.1, from Microsoft's documentation): the setting is greyed out where the API is missing, read rather than assumed.
- [x] A DoH server named by its template (decided 2026-10-03): without the override, the template's host is the server — its address, or its name looked up at the start, every `DohRefreshMinutes` (60) and every 30 s while it fails; through Windows, and when Windows can't, the operator's DNS asked for that one name in the clear from the modem's address (the declared exception). Until the name has addresses, the servers already encrypted with that template, else no DNS server at all.
- [x] The app's own icon (decided 2026-10-03): the logo's glyph (`assets/logo.html`, `?icon`), drawn in code at every size, for the window, the taskbar and the Start-menu shortcut; the tray keeps its icon of the signal. On the taskbar the window and the shortcut share one AppUserModelID: the app's icon, not its PowerShell's, and pinning the window pins the shortcut.
- [x] Languages (decided 2026-10-03): English, Italian, German, French, Spanish, Portuguese, Dutch and Polish, from Windows' display language; everything the user reads, the installer and the launcher included; the log in English. One table per language, each proven complete against English.
- [x] The window at its smallest size: the tabs that can outgrow it scroll, the footer wraps beside *Check now*.
- [x] README install instructions: PowerShell 7, the app, and the guided driver step.
- [x] `CHANGELOG.md`: the Unreleased section completed with M4–M7, the release's notes.
- [x] On the device: a real installation with `install.cmd` from the zip as downloaded (one UAC prompt); the app started by the logon task after a restart, and by the Start-menu shortcut and the pinned window; the start at sign-in turned on and off from the *Connection* tab; encrypted DNS on the modem's adapter with the connection up, by address and by name, and taken off; the update notice against GitHub's real answers (`404`, and `403` with the address's quota used up); `install.cmd` again over the running app; the uninstallation, by `uninstall.cmd` and from Windows' installed apps; the system put back after each step (`AT-COMMANDS.md` §11).
- [x] Set `ModuleVersion` to `1.0.0` and tag `v1.0.0`.

<a id="m8"></a>
## M8 — SMS, USSD & data usage

What a prepaid or capped SIM needs day to day: the operator's messages, balance codes, and how much
data is left (design: ARCHITECTURE → *SMS, USSD and data usage*; facts: `AT-COMMANDS.md` §9–§10).

- [ ] Device session: answer the open questions in `AT-COMMANDS.md` §9 — storages, which port gets new-message notices, USSD on LTE / NSA / SA with a real operator.
- [ ] SMS codec as pure functions written from 3GPP TS 23.040 and 23.038, with a matrix of tests: PDU decoding, GSM 7-bit (with the extension table) and UCS-2, long messages reassembled from their parts; PDU encoding for sending, splitting long messages.
- [ ] Receive: new-message notices from the modem, a tray notification, an inbox in the main window; read and delete on the modem's storage. No copy of the messages on disk.
- [ ] Send a message.
- [ ] USSD: send a code, show the reply, answer a menu, cancel. **Best effort**: if the device session shows that USSD does not work on the FM350 over LTE/NR, it leaves this milestone and the finding is recorded in `AT-COMMANDS.md`.
- [ ] Data usage: the modem adapter's byte counters, sampled by the worker, accumulated across counter resets (pure function) and persisted; today and the current billing cycle (start day in settings); an optional quota with a tray warning (thresholds: **human decision**). Never disconnects.
- [ ] Phone numbers, message text and USSD replies never logged.
- [ ] UI: messages and USSD in the main window; usage in the window and the tooltip.

<a id="m9"></a>
## M9 — eSIM

Profile management on modules with an embedded SIM, through lpac as an external process (design:
ARCHITECTURE → *eSIM*; facts: `AT-COMMANDS.md` §8). Everything but erasing the chip. Released only
as far as it is verified on a module with an eUICC: nothing of it ships proven on the simulated
modem alone (decided 2026-10-03).

- [x] Device session, first part: our module's eUICC found on slot 1 and reached (`AT-COMMANDS.md` §8) — the slot switched there and back with `AT+GTDUALSIM`, the ISD-R through `+CCHO` / `+CGLA`; one profile on it, of class test.
- [ ] Device session, the rest of §8's open questions: the longest APDU through `+CGLA`, how the class byte routes, what enabling a profile needs.
- [ ] `+CPIN: EMPTY_EUICC` — an eUICC with no profile enabled — told apart from the other SIM states (today it reads as *Other*).
- [ ] APDU bridge in the worker: lpac's `stdio` protocol ↔ `AT+CCHO` / `AT+CGLA` / `AT+CCHC` on the AT port the worker owns; the protocol translation as pure functions with a matrix of tests; lpac simulated in the tests.
- [ ] Slot selection (`AT+GTDUALSIM`) and profile switches inside a maintenance window. The slot is persistent modem state: it is switched only after a confirmation that says so, and the active slot is always shown.
- [ ] Operations: chip info; profile list, enable, disable, nickname; download from an activation code or a QR code; delete behind a strong confirmation. Notifications processed automatically. `chip purge` never exposed.
- [ ] EID, ICCIDs and activation codes redacted in logs and fixtures.
- [ ] UI: an eSIM page in the main window.
- [ ] lpac bundled in the release: the release workflow downloads the pinned lpac version from its official GitHub releases, verifies its SHA-256, and puts `lpac.exe` with its license in the zip; lpac's source archive for the same tag is attached to the GitHub Release (AGPL-3.0 corresponding source). Never committed to git.

---

## Open decisions (the maintainer's)

Decisions that change what happens next and are the maintainer's to take. Remove a line when it is
decided, and record the decision in `DEVLOG.md`.

*None at the moment.*

---

## Ideas (not scheduled)

*None at the moment.* Considered and declined: distribution through the PowerShell Gallery
(DEVLOG, 2026-09-29).
