# Development log

Newest first. One entry per meaningful change — note *what* and *why*, not just *what*. This is
the running history, so context is never lost between sessions. Technical and design decisions
only.

## 2026-10-01 — Decided: detect the FCC lock, and offer to unlock it

Modules taken from laptops are often locked by the laptop's maker and never search for networks;
our own module had to be unlocked before this project's device session (`AT-COMMANDS.md` §4,
source `[UNLOCK]`). The project had ruled the lock out of scope ("never touched by this app"); the
maintainer decided otherwise (options considered: detect and explain only; a README note only;
detect and offer the unlock): **the app detects the lock and offers to unlock it**. Design in
ARCHITECTURE → *FCC lock*; logic in M2, the window in M3, no escalation in M4.
- **The lock values explain, they don't gate.** Only the unlocked state of our firmware is known
  (`0`, `0`, `0,1`); treating every other answer as "locked" could stop a working modem on another
  firmware. So the diagnosis needs a registration that never starts as well.
- **No reset unlocks a modem**, so the recovery ladder doesn't escalate on a locked one — the same
  rule as for a SIM waiting for its PIN.
- **The unlock writes the modem's non-volatile memory** and lifts a restriction tied to the
  maker's radio certification: it runs only when the user asks, after a confirmation that says so,
  once. The scope line "no NV editing" now names this one exception.
- Our module being unlocked already, the unlock path is proven against the simulated modem; a
  locked module is needed to test it on hardware and to capture the locked values.

## 2026-10-01 — M2 defaults decided; the PnP reader moves to M2

Decided by the maintainer before M2 starts (ARCHITECTURE → *Network configuration*):
- **The modem is a backup**: a fixed interface metric of 500 keeps an existing wired or wireless
  connection in charge, so plugging the modem in never takes its traffic. Windows' automatic
  metric was the alternative to avoid: the RNDIS adapter reports 1 Gbps and would compete with
  Ethernet. A setting makes the modem preferred.
- **The operator's DNS**, from `+CGCONTRDP` or `+GTDNS`; the override is an empty setting.
- **An empty APN with `IPV4V6`**: the network assigns the subscription's own APN; a specific one
  goes in the settings.
- The worker needs the AT port's COM name and the adapter before anything else, so reading the
  PnP records — planned for M6 — is done in M2, next to the classification already there.

## 2026-10-01 — Decided: the app keeps the SIM PIN and can remove it from the SIM

The plan only detected a locked SIM, so a SIM with its PIN enabled would have kept the connection
down after every modem restart, against the app's purpose. Decided by the maintainer (options
considered: detection only; asking at every start; storing the PIN; storing it plus a way to turn
the PIN off): **store the PIN and enter it, and offer to remove it from the SIM.** Design in
ARCHITECTURE → *SIM PIN*; logic in M2, dialog in M3. The rules that keep it safe:
- **At most one attempt per stored PIN**, and none automatically with one attempt left: three
  wrong PINs lock the SIM behind its PUK, which the app never enters.
- The PIN is tied to the SIM it was given for, so a different SIM is never sent it.
- Encrypted at rest with DPAPI for the current user — the elevated task runs as the same user —
  and never logged or shown back; the same holds for an APN password (invariant 7 extended to
  secrets).
- Removing the PIN (`AT+CLCK="SC",0`) changes the SIM card, not the app, and says so before it
  runs.
The commands are standard (`[27.007]`) and wait for a device check with a PIN-enabled SIM (M2).

## 2026-10-01 — M1 complete: the protocol checked against a real FM350-GL

The device session ran on firmware `81600.0000.00.29.22.06`, without a SIM, then with one
registered on LTE; every answer was captured through the project's own channel, redacted into
`tests/fixtures/device/`, and played back through the parsers. The `Hardware` test passed: the
serial transport works on the real port. Facts are in `AT-COMMANDS.md` with their fixtures; what
changed the code or the design:
- **Parsers fixed where the device differs from the manual**, each with a test that fails
  without the fix: a format and an `<AcT>` without an operator mean nothing (`+COPS:0,255,"",0`
  read as GSM); a temperature sensor answering `0` is absent; TAC and cell identity filled with
  the modem's "not known" pattern (`FFFF`, `00FFFFFFF`, `000000`) are no location; a serving
  cell's band, left empty while idle, comes from its channel number (an NR channel shared by two
  bands stays without one); a primary carrier line has ten fields, the UL bandwidth after the DL
  one, while the manual lists nine.
- **`<AcT>` 13 is not 5G.** The device reports `13` (EN-DC) in `+COPS` and every registration
  report on an LTE cell with NR switched off: the cell can anchor EN-DC, nothing more. Whether NR
  is in use must come from an NR measurement. Likewise `+C5GREG` mirrors the EPS registration.
- **The modem doesn't send every report it is asked for**: no `+CSCON`, `+CGREG` or `+C5GREG`
  code arrived while the state changed, and MediaTek's own codes (`+CIREPI`, `+CTZV`…) can land
  inside an answer. So health checks read the state, and parsers pick lines by prefix or shape,
  never by position (ARCHITECTURE).
- **The port**: a pulled cable makes the next write fail at once and the transport reports the
  port lost — never a write timeout — and `pwsh` survives it, finalizers included; this also
  confirms the write-timeout fix of the M1 review. `GetPortNames()` keeps listing a port that was
  open when its device left, so presence comes from PnP. Once, the first open after the driver
  install stayed silent for about 45 s; it never happened again, and the worker keeps
  initializing a silent port rather than closing it.
- **`+GTACT` is persistent on this firmware**, against the manual: it survives `+CFUN=15` and a
  power cycle. LTE and NR codes go in one write, the lists are per RAT, and n77 drops out of the
  list by itself after a registration attempt (cause unknown, carried by M5).
- **APN credentials go through `+CGAUTH`**, though the manual doesn't list it and its test form
  answers `+CME ERROR: 100`: the read form works. `+EIAAPN`, the documented alternative that
  writes persistent state, is absent from this firmware. Probing a command by its test form alone
  is not enough: the read form decides.
- Carried forward on purpose: the app's own data context, DHCP and context persistence go to M2,
  which builds that sequence; NSA, SA and LTE-A observations to M5; `+CFUN=1,1` to M4; the eSIM
  questions to a module with an eUICC (this one has none).

## 2026-10-01 — The AT-port driver installed the way M6 will install it

The guided path of ARCHITECTURE → *Drivers*, walked by hand once: the package (the commit-pinned
zip) matched its known fingerprints — zip, `.cat`, `.inf` and both `.sys` — the catalog carried a
valid *Microsoft Windows Hardware Compatibility Publisher* signature, the INF listed the modem's
hardware IDs, and nothing in the package was executed. `pnputil /add-driver <inf> /install`, the
only elevated step, bound `usb2ser_tm` to all seven serial functions.
- **The driver loads with Memory Integrity on**, which closes the last open point of the driver
  design.
- **MD AT is `MI_06` on `7127`**, as the INF says, and Windows numbered the ports at install time:
  the app reads the AT port's COM name from the device (`Device Parameters\PortName`, the same in
  every Windows language, unlike the friendly name). `Resolve-ModemUsbDevice` now returns it.
- **Reading PnP properties is slow**: each `Get-PnpDeviceProperty` call costs about a second
  whatever it reads, so the reader fetches every key of a device in one call.
- The INF also covers product IDs `7128` and `7129`, which no FM350 document names; they stay
  outside the detection.

## 2026-10-01 — First device capture: the modem's USB functions on Windows; detection as a pure function

The first look at a real FM350-GL, before any driver is installed, answers most of the open rows
of `AT-COMMANDS.md` §1:
- **Composition `7127`** (mode 41, the documented default): nine functions under the composite
  device — RNDIS on `MI_00`, seven vendor-class serial ports, ADB on `MI_05`.
- **The network adapter needs nothing**: Windows' own RNDIS driver claims it through the
  compatible ID `USB\Class_e0&SubClass_01&Prot_03` (the interface association's class, not
  interface 0's own). ADB is claimed by Windows' WinUSB. Only the serial ports wait for a driver,
  each with problem code 28 and no COM port at all.
- **The instance ID is Windows-generated** from the USB port, not a serial number: plugging the
  modem into another port gives it new instance IDs, so nothing may remember them.
- **Functions are linked through their composite device, not their container ID.** They do share
  a container ID here, but a device on a port the firmware calls non-removable inherits the
  computer's, which every built-in device shares; the network adapter will be found by its own
  instance ID.

M6's detection step is brought forward as `Resolve-ModemUsbDevice`: PnP records in, one object per
modem out — AT port, network adapter, every function with role and driver state (`Working`,
`NoDriver` for problem codes 1 and 28, `Problem` for any other). Tested on the redacted capture
and a matrix (the 7126 layout, problem codes, leftover devices, other MediaTek devices, two
modems). PnP snapshots are the first JSON fixtures; the identifier check now covers them too —
instance IDs keep their shape with a zeroed hash, container IDs are fakes.

## 2026-09-29 — M1 code-complete: parsers, measurements, 3GPP band tables; a robust linter

Everything in M1 that doesn't need the device is done; the device session remains.
- **Parsers are pure and tolerant.** Each takes the answer lines, picks the lines with the prefix
  it knows and ignores the rest, and returns `$null` for what isn't there, so an unexpected line
  never breaks a parse. `+CEREG`-style reports tell the read answer from the URC by the second
  argument (an unquoted number). `+GTCCINFO` lines are read by their first field, because serving
  and neighbour lines have different layouts; `+GTCAINFO` lines from their start, because the
  tail changed between firmware versions, and each carrier's technology comes from its band code.
- **Parsers are tested through the channel**: each documented fixture is played by the simulated
  modem and read back by `Invoke-AtCommand`, so the tests see what a parser will see.
- **Measurements** map an index to the edge the specification names for it, plus whether that
  edge is a bin, a ceiling (lowest index) or a floor (highest index).
- **3GPP band tables** (36.101 Table 5.7.3-1, 38.101-1 Tables 5.4.2.1-1 and 5.4.2.3-1, V20.1.0) are
  transcribed into data files rather than typed into code. They were extracted from the
  specification documents and checked — every E-UTRA range starts at its offset, no two overlap —
  and the extraction needed repairs, now covered by tests: footnote marks glued to band numbers
  (`292` was band 29), and range dashes lost or varying. NR bands overlap, so an NR-ARFCN gives
  every candidate band; the band the modem reports stays preferred.
- **Numbers are culture-invariant** (new rule in `CLAUDE.md`): the first transcription wrote
  `1844,9` for 1844.9 MHz under a comma-decimal culture — an array in PowerShell source. The
  analyzer caught it; the decimal-frequency bands now have tests.
- **Lint goes through `tools/Invoke-Lint.ps1`.** PSScriptAnalyzer 1.24/1.25 on PowerShell 7.6
  intermittently fails its own command lookups ("'Get-Command' is not recognized"), in parallel or
  sequential analysis alike, and then stays broken for the rest of the process — seen in about
  half of the runs. The script analyzes files one at a time in a child process and hands whatever
  is left to a fresh process after such a failure; diagnostics are never retried away.
- **Timing-based tests** use generous timeouts except where a timeout is the point: a cold start
  on a busy machine once made a 1 s initialization miss.

**End-of-milestone review: 7 findings in the product, all fixed**, each with a test that fails
without the fix:
- `Initialize-AtChannel` trusted ATE1's unanchored answer, which after a timeout — exactly when it
  runs — can be the late error of the command that timed out. Now only the anchored `AT+CMEE=1`
  decides.
- `Invoke-AtCommand` accepted a CR (two commands run, e.g. `AT` + `AT+CFUN=0`) and non-ASCII
  characters (echo unrecognizable, a command that ran reported as a timeout). Now printable ASCII
  only — what the port carries.
- A late answer came out as unsolicited codes: a late `+CSCON: 1,0` read as "connected", a late
  IMSI as an unknown code. The channel now remembers timed-out commands until their answers end
  or the next echo, and discards those answers' lines. This fix touched the classification of
  every answer, so it got a targeted re-check, which found three gaps, all fixed with tests:
  `ATE1` (unanchored) still took a late answer during `Initialize-AtChannel`; a second timeout
  overwrote the first (now a queue of up to 10, which a modem that stopped answering reaches);
  and a real registration report was held back while a late one was due (registration reports
  are now exempt: they say which form they are in). What remains by design: a real `+CSCON` code
  arriving while a late `AT+CSCON?` answer is due is dropped until that answer ends.
- A write timeout marked the port lost, which would have sent a present-but-hung modem into a
  reopen loop instead of the hung-modem recovery path.
- Parsers threw on ten-digit band codes and on empty lines; they now return nothing for them.
- `ConvertFrom-Earfcn -Earfcn $null` answered band 1 (an `[int]` binds `$null` as 0); a missing
  channel number now gives nothing.
- A set command (`AT+CEREG=2`) claimed its prefix, swallowing a registration code that arrived
  during it; only read, test and execute forms claim theirs now.
Minor, also fixed: the simulated modem's command log is bounded; the linter no longer reports
success when its child process dies silently; the fixture check covers the module serial number.

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
