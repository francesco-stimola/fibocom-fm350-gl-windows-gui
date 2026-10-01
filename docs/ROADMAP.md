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
| [M2 — Connection](#m2) | 🔨 code-complete |
| [M3 — Tray app](#m3) | 📋 planned |
| [M4 — Health & recovery](#m4) | 📋 planned |
| [M5 — Modes & bands](#m5) | 📋 planned |
| [M6 — Driver installation](#m6) | 📋 planned |
| [M7 — Packaging & first release](#m7) — tag `v1.0.0` (planned) | 📋 planned |
| [M8 — eSIM](#m8) — tag `v1.1.0` (planned) | 📋 planned |
| [M9 — SMS, USSD & data usage](#m9) — tag `v1.2.0` (planned) | 📋 planned |

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
- [x] Connect sequence: SIM check, data context definition (persistent on the FM350: written only when it differs from the settings), registration, attach, context activation.
- [x] SIM PIN (design: ARCHITECTURE → *SIM PIN*): the decision as a pure function with a matrix of tests (SIM state × stored PIN and its SIM × attempts left × already tried → send, ask the user, report, continue); the PIN stored DPAPI-encrypted with the SIM it belongs to; at most one attempt per stored PIN; a PUK never entered by the app.
- [x] FCC lock (design: ARCHITECTURE → *FCC lock*): read the three lock values in the connect sequence; the diagnosis as a pure function with a matrix of tests (lock values × registration state → locked or not; the vendor's unlock-status value decides, not a time limit) — it explains a registration that never starts and never stops a modem that registers; the unlock sequence, proven against the simulated modem.
- [x] Network configuration of the modem's adapter (address, mask, gateway, DNS) in the active store.
- [x] Startup reconciliation: attach to an existing connection without re-dialing.
- [x] Redacted rolling log.
- [ ] On the device: `AT-COMMANDS.md` §7 questions 5, 6 and 12 — the app's own data context, DHCP on the adapter, whether a written context survives a power cycle, the `+CGAUTH` set form for APN credentials on that context — and the NR leg of an EN-DC cell under traffic (questions 3, 4). With a SIM whose PIN is enabled: the `+CPIN` states, `AT+CPIN=`, `+CPINR`, `AT+CLCK="SC"` (`AT-COMMANDS.md` §3). The modem stays a backup (high metric) during the session, so the machine's own traffic keeps its usual route.

<a id="m3"></a>
## M3 — Tray app

- [ ] Worker runspace + immutable state snapshots + command queue.
- [ ] Supervisor: heartbeat, worker restart that attaches instead of re-dialing.
- [ ] Single instance (mutex; a second launch shows the first window).
- [ ] Tray icon rendering with handle disposal; tooltip; menu.
- [ ] Main window: connection status, signal, cells, carrier aggregation.
- [ ] FCC lock in the window and the tray: the diagnosis, and *Unlock* for a modem diagnosed as locked, behind a confirmation that says it writes the modem's non-volatile memory and lifts the maker's restriction; never automatic. On hardware with a locked module when one is available — capturing the locked values too.
- [ ] SIM PIN in the main window: enter or replace the stored PIN; the SIM's state (PIN or PUK required, PIN rejected, attempts left); "remove the PIN from the SIM" (`AT+CLCK="SC",0`) behind a confirmation that says it changes the SIM.
- [ ] Development mode: the app runs against the simulated modem, without a device and without admin rights (no system changes).

<a id="m4"></a>
## M4 — Health & recovery

- [ ] Health checks H1–H7, including a data-path probe bound to the modem's address.
- [ ] Recovery decision as a pure function (symptoms + history → step), with a matrix of tests. No escalation for what no reset fixes: a SIM waiting for its PIN or PUK, a modem diagnosed as FCC-locked.
- [ ] Recovery steps R1–R6 with settle times and backoff (**values: human decision**).
- [ ] Maintenance windows.
- [ ] On the device: `AT-COMMANDS.md` §7 question 8 for `+CFUN=1,1` (`+CFUN=15` and `+CFUN=4`/`1` are measured).
- [ ] Soak run on the real device (duration: human decision), with handle and memory counts before/after.

<a id="m5"></a>
## M5 — Modes & bands

- [ ] Read current mode and bands from the modem; supported values from `AT+GTACT=?`.
- [ ] UI: mode selector (at least 4G + 5G / 4G only) and per-RAT band checkboxes.
- [ ] Apply inside a maintenance window, writing every managed RAT's band list (the modem keeps one list per RAT); persist in settings; re-apply on every connect.
- [ ] On the device: `AT-COMMANDS.md` §7 questions 7 (do NR codes restrict NSA?) and 10 (`+GTCAINFO` with LTE-A, NSA, SA), and why n77 drops out of the band list (§5).

<a id="m6"></a>
## M6 — Driver installation

"Bring your own driver", guided: the app never downloads or bundles a driver. It tells the user
where a known copy is published and by whom; the user downloads it and hands it over; the app
verifies it and installs it (design: ARCHITECTURE → *Drivers*).

- [x] Classify the modem's USB functions and their driver state (AT ports present without a driver) as a pure function, tested on a device capture: `Resolve-ModemUsbDevice`.
- [x] Read the PnP records it classifies: done in M2 (`Get-ModemPnpRecord`), which needs it to find the AT port.
- [ ] Driver dialog: the project does not distribute the driver; where a known copy is published (commit-pinned page from the manifest) and that it is a third party's copy of MediaTek's driver; actions *open that page* and *choose the downloaded package*.
- [ ] Package intake: a zip or a folder chosen by the user; locate the INFs in it. Never run an executable from the package.
- [ ] Verification as a pure decision function with a matrix of tests: catalog signed by Microsoft (WHQL) → required; INF covers the modem's hardware IDs → required; files match a known fingerprint → reported as a verified version.
- [ ] Known-fingerprints manifest in the repo (SHA-256 of `.cat`, `.inf`, `.sys`, and the commit-pinned page where a copy is published — hashes and links only, no binaries), starting with MediaTek `usb2ser_tm` 3.22.43.1.
- [ ] Install/uninstall via `pnputil`; surfaced in the UI.

<a id="m7"></a>
## M7 — Packaging & first release

- [ ] Installer script: copies the app under `%ProgramFiles%` (the elevated task never runs files from a user-writable folder), unblocks them, registers the logon scheduled task (highest privileges) and the Start-menu shortcut; uninstaller removes all three.
- [ ] Release workflow on `v*` tags: lint + tests, check the tag matches the module version, build the zip, publish a GitHub Release with the `CHANGELOG.md` section as notes.
- [ ] Update notice: once per app start, when the connection first comes online, read the latest GitHub release; if it is newer, the tray menu says so and links to it. Never installs anything; can be turned off in settings.
- [ ] README install instructions: PowerShell 7, the app, and the guided driver step.
- [ ] Set `ModuleVersion` to `1.0.0` and tag `v1.0.0`.

<a id="m8"></a>
## M8 — eSIM

Profile management on modules with an embedded SIM, through lpac as an external process (design:
ARCHITECTURE → *eSIM*; facts: `AT-COMMANDS.md` §8). Everything but erasing the chip.

- [ ] Device session on a module with an eUICC: answer the open questions in `AT-COMMANDS.md` §8.
- [ ] APDU bridge in the worker: lpac's `stdio` protocol ↔ `AT+CCHO` / `AT+CGLA` / `AT+CCHC` on the AT port the worker owns; the protocol translation as pure functions with a matrix of tests; lpac simulated in the tests.
- [ ] Slot selection (`AT+GTDUALSIM`) and profile switches inside a maintenance window. The slot is persistent modem state: it is switched only after a confirmation that says so, and the active slot is always shown.
- [ ] Operations: chip info; profile list, enable, disable, nickname; download from an activation code or a QR code; delete behind a strong confirmation. Notifications processed automatically. `chip purge` never exposed.
- [ ] EID, ICCIDs and activation codes redacted in logs and fixtures.
- [ ] UI: an eSIM page in the main window.
- [ ] lpac bundled in the release: the release workflow downloads the pinned lpac version from its official GitHub releases, verifies its SHA-256, and puts `lpac.exe` with its license in the zip; lpac's source archive for the same tag is attached to the GitHub Release (AGPL-3.0 corresponding source). Never committed to git.

<a id="m9"></a>
## M9 — SMS, USSD & data usage

What a prepaid or capped SIM needs day to day: the operator's messages, balance codes, and how much
data is left (design: ARCHITECTURE → *SMS, USSD and data usage*; facts: `AT-COMMANDS.md` §9).

- [ ] Device session: answer the open questions in `AT-COMMANDS.md` §9 — storages, which port gets new-message notices, USSD on LTE / NSA / SA with a real operator.
- [ ] SMS codec as pure functions written from 3GPP TS 23.040 and 23.038, with a matrix of tests: PDU decoding, GSM 7-bit (with the extension table) and UCS-2, long messages reassembled from their parts; PDU encoding for sending, splitting long messages.
- [ ] Receive: new-message notices from the modem, a tray notification, an inbox in the main window; read and delete on the modem's storage. No copy of the messages on disk.
- [ ] Send a message.
- [ ] USSD: send a code, show the reply, answer a menu, cancel. **Best effort**: if the device session shows that USSD does not work on the FM350 over LTE/NR, it leaves this milestone and the finding is recorded in `AT-COMMANDS.md`.
- [ ] Data usage: the modem adapter's byte counters, sampled by the worker, accumulated across counter resets (pure function) and persisted; today and the current billing cycle (start day in settings); an optional quota with a tray warning (thresholds: **human decision**). Never disconnects.
- [ ] Phone numbers, message text and USSD replies never logged.
- [ ] UI: messages and USSD in the main window; usage in the window and the tooltip.

---

## Open decisions (the maintainer's)

Decisions that change what happens next and are the maintainer's to take. Remove a line when it is
decided, and record the decision in `DEVLOG.md`.

- **FCC unlock sequence** (ARCHITECTURE → *FCC lock*). The sequence that unlocked our module
  includes `AT+GTFCCEFFSTATUS=0,0`, which the vendor manual documents as read-only, its set form
  answering `ERROR` (`AT-COMMANDS.md` §4). Implemented for now: the sequence as it was done, that
  one command's error tolerated. The alternatives: leave the command out; or stop at its error as at
  any other (then, if the manual is right, the unlock never reaches the restart).

---

## Ideas (not scheduled)

*None at the moment.* Considered and declined: distribution through the PowerShell Gallery
(DEVLOG, 2026-09-29).
