# Architecture

This document describes the design **as decided**, including the parts not built yet — each
section says which milestone implements it (see [`ROADMAP.md`](ROADMAP.md)). Thresholds marked
**TBD** are the human's decision (see `CLAUDE.md`); they are not to be filled in with a guess.

## Overview

Used over a USB adapter, the FM350-GL shows up on Windows as a set of serial ports and a network
adapter, but nothing brings the data connection up by itself: someone has to register on the
network and activate a data context over AT commands, then configure the adapter's IP address.
When the link drops, nothing brings it back. This app does both, from the system tray.

```
 ┌──────────────────── pwsh.exe · elevated · one instance ────────────────────┐
 │                                                                            │
 │   UI thread (STA)                        worker runspace                   │
 │  ┌──────────────────────┐   commands   ┌─────────────────────────────────┐ │
 │  │ tray icon + menu     │ ───────────► │ connection state machine        │ │
 │  │ main window (WPF)    │    queue     │ health checks · recovery ladder │ │
 │  │ supervisor           │ ◄─────────── │ AT channel ──────► COMx (MD AT) │ │
 │  └──────────────────────┘   snapshots  │ network config ──► modem NIC    │ │
 │                                        └─────────────────────────────────┘ │
 └────────────────────────────────────────────────────────────────────────────┘
```

## Scope and non-goals

- **Windows 10/11 x64, PowerShell 7.6+.** No other platform: on Linux the modem is served by
  ModemManager/NetworkManager, and almost everything here (drivers, PnP, adapter configuration,
  autostart) is Windows-specific.
- **FM350-GL over USB.** Laptops with an OEM-integrated FM350 (PCIe) that already work through
  Windows' mobile broadband stack are out of scope.
- **No redistribution of the modem driver**, nor of any binary whose license doesn't allow it.
  Open-source tools ship only under their own license (lpac, from `v1.1.0` — see *eSIM*).
- Not a firmware tool: no flashing, no IMEI changes, no NV editing — with one exception the user
  asks for explicitly, the FCC unlock (see *FCC lock*).

## Process model (M3)

One process, living in the system tray. There is no Windows service: if the app is closed, the
user reopens it and monitoring resumes.

### Threads
- **UI thread** (STA): the tray icon (WinForms `NotifyIcon`), the main window (WPF), and a
  **supervisor**. It only reads snapshots and enqueues commands — it never does I/O.
- **Worker runspace**: owns the COM port, the state machine, health checks, recovery, network
  configuration. It publishes an **immutable snapshot** of its state after every change (the UI
  reads the latest reference; no locks shared with the UI) and consumes commands from a
  `ConcurrentQueue` (connect, disconnect, apply bands, …).
- **Supervisor**: the worker writes a heartbeat timestamp; if it stops (crash, hang), the UI
  thread disposes the runspace and starts a new one. A new worker **attaches** to whatever state
  the modem is in (see *Startup reconciliation*) — a worker restart is not a re-dial.

### Startup, elevation, single instance
- The app needs admin rights (adapter configuration, device restart, drivers). To avoid a UAC
  prompt at every start, the installer (M7) registers a **scheduled task** — *at logon, run with
  highest privileges* — that starts the app hidden, and a **Start-menu shortcut** that runs that
  task. One UAC prompt at install time, none afterwards.
- **The app's files live where only administrators can write.** The logon task runs them elevated
  without a prompt, so a copy in a user-writable folder (the extracted zip, a per-user module path)
  would let any program running as the user edit them and gain administrator rights silently. The
  installer copies the app under `%ProgramFiles%` and the task starts it from there, with
  `pwsh -NoProfile` and a module path limited to admin-only folders: the user's profile script and
  per-user modules are user-writable too. For the same reason no setting names an executable or a
  script to run: lpac is found next to the app.
- A named **mutex** enforces one instance. A second launch signals the first to show its window
  and exits: two instances would fight over the COM port.

### Closing and reopening
Closing the app stops **monitoring and recovery only**. The modem stays registered, the data
context stays active, the adapter keeps its address. On reopen, the app reads that state and
carries on.

### Updates (M7)
The zip on GitHub Releases is the only distribution channel. Once per app start, when the
connection first comes online (at logon it usually isn't yet), the worker reads the latest release
from GitHub's public API: one attempt, no retry until the next start, no timer. If that release is
newer than the running version, the tray menu says so and links to it. The app never downloads or
installs an update: updating stays *extract the zip, run `install.cmd`*, with its one UAC prompt.
A setting turns the check off. Since the app can run for weeks, a release is noticed at the next
start, not the day it is published.

## AT channel (M1)

Everything the worker says to the modem goes through one **AT channel** per port (facts:
`AT-COMMANDS.md` §2).

- **Transport.** The channel talks to a *transport*: any object with `PortName`, `Lost`,
  `Write`, `Read` and `Close`. There are two: the serial port (`System.IO.Ports`) and the
  **simulated modem**, which answers from fixtures and plays scripted faults — the tests use it,
  and so does the app's development mode (M3). A transport that loses its port sets `Lost`
  instead of throwing, and never touches the port again; the channel then reports `PortLost` to
  every command, and the worker opens a new channel once the device is back — found again by PnP,
  because it can come back as a new device instance under another COM number (`AT-COMMANDS.md`
  §1).
- **Echo as anchor.** The modem's echo stays on (its power-on default). A command's answer starts
  after its echo: anything else that arrives before it is left over from an earlier command,
  typically a late answer after a timeout, and is discarded. Without the anchor, one late answer
  would shift every later answer by one command — for as long as the process runs.
  `Initialize-AtChannel` turns the echo back on (`ATE1`) and sets numeric error codes
  (`AT+CMEE=1`); the worker runs it after opening a channel and after a timeout, and keeps
  running it while it times out: the port has been seen silent for up to almost three minutes
  after it appeared (`AT-COMMANDS.md` §2), which is no reason to close it.
- **Late answers stay answers.** After a timeout the channel remembers the command (up to the
  last 10 of them) until its late answer ends — a stale final result closes the oldest — or the
  next echo arrives; meanwhile those answers' lines are discarded, not passed on as unsolicited
  codes: a late `+CSCON: 1,0` would otherwise read as "connected", and a late bare IMSI would look
  like an unknown code worth logging. Registration reports are the exception — they say which form
  they are in, so a real one is never held back and a late one still reads correctly. The price:
  a real `+CSCON` code arriving while a late `AT+CSCON?` answer is due is dropped, until that
  answer ends or the next command. `ATE1` can't be anchored, so it counts no line as its answer
  while a late answer is due, and `Initialize-AtChannel` doesn't trust it anyway: the anchored
  `AT+CMEE=1` decides.
- **Unsolicited codes** are recognized by prefix and queued, including those arriving in the
  middle of an answer; the worker drains the queue between commands. A read or test command
  (`AT+CEREG?`) claims lines with its own prefix as its answer; a set command (`AT+CEREG=2`)
  doesn't, so a registration code arriving during it still reaches the queue. The modem's own
  MediaTek codes (`+CIREPI`, `+EDSBP`, `+CTZV`…) are not on the list: one arriving between a
  command's echo and its result lands among the answer's lines. So **parsers pick their lines by
  prefix or by shape, never by position** (`AT-COMMANDS.md` §2).
- **Command text is printable ASCII.** A CR would make the modem run two commands; a character
  the port can't carry would make the echo unrecognizable, and a command that ran would be
  reported as a timeout and retried.
- **A write that times out is not a lost port**: the port is there, the modem isn't draining it.
  The command then times out without an echo — the symptom of a hung modem, not of a missing one.
- **Pure core.** Framing (`Split-AtText`) and classification (`Resolve-AtLine`) are pure
  functions; the I/O loop around them is thin.
- **Bounded.** Unterminated text is capped at 4096 characters and the unsolicited-code queue at
  1000 entries (oldest dropped): nothing grows without limit over weeks.
- **Timeouts** come from a lookup (`Get-AtCommandTimeout`), unless the caller gives one: each
  command's worst-case duration as documented by the vendor manual, never less than 3 s (margin
  for USB latency and a busy modem); a compound line gets the sum of its commands'. A stuck modem
  is noticed at most that long after the command — 3 min only for `AT+COPS`, which the connect
  sequence reads only while the modem is not registered.

## Connection state machine (M2)

```
 NoDevice ─► PortOpen ─► Identified ─► SimReady ─► Registered ─► DataActive ─► Online
     ▲                                                                           │
     └────────────── device removed / port lost (from any state) ◄───────────────┘
```

- `Online` means: data context active with an address, the adapter configured with that address,
  and the last data-path probe passed (the probe is M4's H7; until it runs, it counts as passed).
- Each transition is decided by a **pure function** of (current state, observed facts) → next
  state + actions (`Resolve-ConnectionState`). The state is the furthest one the facts support;
  the action is the first missing step: open the port, initialize the channel, enter the SIM PIN,
  turn the radio on, select the operator automatically, define the app's context, activate it,
  configure the adapter. With no step to take, a **reason** says why — searching, SIM busy, a PIN
  the user must give, an FCC lock — and **blocked** says whether it is out of the app's reach: no
  device or driver, a SIM waiting for the user, an FCC lock, an APN the user must give, no network
  adapter. No recovery step changes those, so none is escalated (M4).
- **A context that carries no internet** — active without an IPv4 address, or on the IMS APN,
  told by the network identifier `ims` in `+CGCONTRDP` (`AT-COMMANDS.md` §3) — doesn't count as
  data active. With an empty APN in the settings that is the network's choice, on some networks
  the IMS APN: the reason is `ApnNeeded` (blocked) and the window asks for an APN; the default
  stays empty, since it works where the network assigns its internet APN (decided 2026-10-01).
  When such a context differs from the settings — the user has just given an APN — it is
  **deactivated**, then defined and activated as they say: it carries nothing, so nothing that
  works is broken. Without an address on the APN of the settings, the reason is `NoAddress`.
- **A pass** (`Invoke-ModemConnect`) observes, takes the missing step, observes again, until no
  step is left — and never runs the same step twice in one pass: a step that didn't take waits for
  the next pass, on the worker's cadence. The observation reads only as far as the state allows
  (no context reads before registration, no lock reads after it). The worker loop only gathers
  facts and executes actions.
- **The app's data context is context 1.** Context 0 is the modem's own attach context
  (`AT-COMMANDS.md` §3).

### Startup reconciliation
Before running any connect sequence, the worker **observes**: is the device present, is the SIM
ready, is the modem registered, is a data context active, does the adapter already carry that
address? It enters the state machine at the furthest state the facts support. Only the missing
steps are executed.

The data context definition (`+CGDCONT`) is documented as **persistent** on the FM350, though our
device lost it at a reset (`AT-COMMANDS.md` §3): the connect sequence reads it and writes it only
when it is missing or its APN or PDP type differ from the settings — not at every connect. A context that
is **active** but not as the settings say is left alone (the pass says `SettingsPending`): new
settings apply at the next connect, never by breaking a connection that works.

### SIM PIN (M2; dialog in M3)
A SIM whose PIN is enabled asks for it at every power-on, so a modem that restarts would stay
offline until someone typed it. The app keeps the PIN and enters it itself, under rules that never
let it lock the SIM (facts: `AT-COMMANDS.md` §3):
- **States** read from `+CPIN?`: `READY` continues; `SIM PIN` leads to the PIN step; `SIM PUK` (and
  any other code) stops and says so — **the app never enters a PUK**, the user does it with a
  phone; `+CME ERROR: 10` is "no SIM"; SIM busy (`14`) is waited out.
- **Storage.** The user types the PIN once in the main window. It is kept encrypted with DPAPI for
  the current user (`ConvertFrom-SecureString`, no extra dependency) in its own file next to the
  settings — the elevated task runs as the same user, so it can read it — together with the
  identity of the SIM it belongs to, so another SIM is never sent it: a SHA-256 of its ICCID (read
  with the SIM still locked, `AT+ICCID`), itself encrypted — the ICCID is kept nowhere. A SIM that
  can't be identified is sent nothing. Never logged, never in a snapshot: the UI only learns
  whether a PIN is stored.
- **One attempt per stored PIN.** The worker sends `AT+CPIN="<pin>"` at most once for a given
  stored PIN. Rejected, the PIN is deleted and the app asks for it again — never a second try:
  three wrong PINs lock the SIM behind its PUK. When the remaining attempts can be read —
  `+CPINR`, or on the FM350, which lacks it, the first value of `+EPINC` — and only one is left,
  nothing is sent automatically. The attempt is **recorded before** `AT+CPIN` goes
  out, and cleared once the SIM is seen ready: an answer that never arrives — a timeout, a crash —
  is never followed by a second attempt; the user is asked instead.
- **"Remove the PIN from the SIM"** (logic M2, dialog M3): `AT+CLCK="SC",0,"<pin>"` turns the
  SIM's PIN request off for good, after a confirmation that says it changes the SIM, not the app.
  It spends an attempt like any PIN entry and follows the same rules: only on a ready SIM whose PIN
  request is on, never with one attempt left (`Disable-SimPin`).
- The decision — SIM state, stored PIN and its SIM, attempts left, already tried → send, ask the
  user, report, continue — is a **pure function** with a matrix of tests. A locked SIM is not a
  fault the recovery ladder can fix: H3 failing for a PIN or PUK escalates nothing; the tray
  shows it.

### FCC lock (M2; unlock offered in M3)
FM350 modules taken from laptops are often locked by the laptop's maker: a locked module answers
AT commands but never searches for networks (`AT-COMMANDS.md` §4). Left alone, the app would read
that as a fault and climb the recovery ladder for nothing.
- **Read, never assumed.** While the modem is not registered, the connect sequence reads
  `+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?`. The vendor documents the second value of
  `+GTFCCEFFSTATUS` as the unlock status, `0` meaning locked; the one locked module on record
  answered `2`, `0`, `2,0` and refused to turn its radio on, so it could never search (ours, unlocked:
  `0`, `0`, `0,1`). The values **explain a registration that never starts; they never stop a modem
  that registers.** The diagnosis (`Resolve-FccLock`) is a pure function: locked when not
  registered and the unlock status says locked; unknown when the values can't be read; not locked
  otherwise. A documented value, not a time limit, decides: no threshold to wait out.
- **No escalation.** A modem diagnosed as locked is not reset by the recovery ladder: no reset
  unlocks it. The connect sequence doesn't even try to turn its radio on. The tray and the window
  say what it is.
- **Unlock, only when asked.** For a modem diagnosed as locked the window offers *Unlock*, behind
  a confirmation that says it writes the modem's non-volatile memory and lifts a restriction the
  laptop's maker set for its radio certification, at the user's responsibility. The app then runs
  the known sequence once — `AT+GTFCCLOCKMODE=0`, `AT+GTFCCLOCKSTATE=0`, `AT+GTFCCEFFSTATUS=0,0`,
  `AT&W`, `AT+CFUN=1,1` — waits for the modem to come back on USB, reads the three values again
  and reports. Never automatic, never repeated by itself (`Invoke-FccUnlock`). It reads the lock
  first and writes nothing unless the modem says it is locked; it stops at the first command that
  fails, before the restart — except `AT+GTFCCEFFSTATUS=0,0`, which the vendor documents as
  read-only (its set form answers `ERROR`): it is kept as the sequence was done on our module, and
  its error doesn't stop the sequence (decided 2026-10-01). The vendor's own unlock is a
  challenge-response with a secret of the laptop's maker, which the app never implements; our
  module took the mode write without it, but the other sources pass the challenge first, so on
  some modules the unlock may be refused.
- **Tested where it can be.** Our module is already unlocked, so the unlock path is proven against
  the simulated modem; on hardware it waits for a locked module, which is also how the locked
  values get captured.

## Health checks and the recovery ladder (M4)

**Health checks**, from cheapest to most expensive:

| # | Check | Fails when |
|---|---|---|
| H1 | Device present (PnP) | The modem is gone from USB. |
| H2 | AT port answers | `AT` gets no `OK` in time. |
| H3 | SIM ready | `+CPIN?` is not `READY`. |
| H4 | Registered | Registration status is not home/roaming. |
| H5 | Data context up | No active context, or no address. |
| H6 | Adapter configured | The adapter's address differs from the context's. |
| H7 | Data path | Probes bound to the modem's address get no answer. |

**Recovery ladder** — the **symptom picks the entry step**, and the ladder escalates only while
the checks keep failing after each step's settle time:

| Step | Action | Entry symptom | Impact |
|---|---|---|---|
| R1 | Re-apply adapter configuration | H6 | None on the radio. |
| R2 | Deactivate + reactivate the data context | H5, H7 | Short data gap. |
| R3 | Deregister + automatic re-registration | H4 | Registration gap. |
| R4 | Radio off → on (`+CFUN`) | R3 failed | Radio gap. |
| R5 | Modem reset (`+CFUN=15`) | R4 failed | Device re-enumerates on USB. |
| R6 | Restart the USB device (`pnputil /restart-device`) | H2 with H1 passing | Device re-enumerates. |

- **What no reset fixes is not escalated**: a SIM waiting for its PIN or PUK (*SIM PIN*), a modem
  locked by its maker (*FCC lock*). The tray says what it is instead.
- The checks **read** the state; they don't wait for unsolicited codes. The FM350 doesn't send
  every report it is asked for — no `+CSCON`, `+CGREG` or `+C5GREG` code was seen while the state
  changed (`AT-COMMANDS.md` §2) — so a code is a hint to read sooner, never the only source.
- Settle times, backoff between cycles, and when counters reset after sustained health: **TBD**.
  Measured on the device, as input: after `+CFUN=1` (R4) the modem was registered again within
  about a second; after `+CFUN=15` (R5) it dropped off USB about 49 s after the `OK` and was back
  about 28 s later.
- After repeated full cycles the app keeps trying at a slow cadence (**TBD**) and shows the
  failure in the tray instead of hammering the network.
- The choice "symptoms + history → next step" is a **pure function**, proven by a matrix.

### Maintenance windows
An intentional operation that disrupts the link — applying a new mode or band set — opens a
**maintenance window**: checks keep running for display, but **nothing escalates** until the
modem is back online or the window times out (**TBD**).

## Modes and bands (M5)

Everything goes through `AT+GTACT` (spec: [`AT-COMMANDS.md` §5](AT-COMMANDS.md#5-gtact--mode-and-bands)).
- **Mode**: at least *4G + 5G* and *4G only*; the full list follows from `AT+GTACT=?` on the
  device.
- **Band lock**: per-RAT band lists; empty means "all bands". The modem keeps one list per RAT
  and a write changes only the RATs it names, so applying always writes **every** managed RAT's
  list: nothing from an earlier setting survives by accident.
- Applying: open a maintenance window → set → wait for re-registration → close the window.
- The chosen mode and bands are saved in the settings and **re-applied on every connect**, so the
  app never depends on what the modem remembers across a reset.
- The band-code codec (`src/FibocomFm350/Bands.ps1`, M0) keeps codes it doesn't recognize, so
  writing a list back never drops something the modem reported.

## Network configuration (M2)

- The modem's adapter is found through the device it belongs to: its `PnPDeviceID` is the
  instance ID of the modem's RNDIS function (`MI_00`, ARCHITECTURE → *Drivers*), never a name or
  an index.
- **Configured from the context.** The FM350 serves no DHCP (`AT-COMMANDS.md` §1), so the app
  configures the adapter from the context: the IPv4 address — from `+CGCONTRDP`, or from
  `+CGPADDR` when, as on the FM350, `+CGCONTRDP` leaves it out — with its mask, a default route
  through its gateway, its DNS servers. **Without a mask the address is a /32, and without a
  gateway the default route is on the link** (next hop `0.0.0.0`): the modem answers ARP for
  every destination. Should a modem's DHCP give a usable address, it is kept, with its gateway
  and DNS.
- **A plan, then the changes.** `Resolve-AdapterConfiguration` (pure) compares the adapter as read
  with what the context and the settings ask, and lists only the changes needed — an adapter
  already configured gives an empty plan — or says why it can't: no address reported. Leftovers of an earlier context (manual addresses, default routes) are removed.
  `Set-ModemAdapterConfiguration` applies a plan (administrator rights) and stops at the first
  change that fails; the next pass plans again.
- The configuration is written to the **active store only** (`-PolicyStore ActiveStore`) —
  addresses, routes, DHCP, metric: it vanishes at reboot instead of lingering as stale persistent
  configuration. **DNS servers have no active store**: they are set on the adapter, and rewritten
  at every connect.
- **IPv4 only.** The app configures the context's IPv4 address; IPv6 on the adapter is left to the
  network's router advertisements, if the modem relays them. A context of type `IPV6` alone is
  therefore not offered in the settings.
- **The modem is a backup by default** (decided 2026-10-01): its adapter gets a fixed interface
  metric of 500, far above the automatic metrics Windows gives wired and wireless adapters, so
  plugging it in never takes the traffic of a connection that is already up; alone, it carries
  everything. The RNDIS adapter reports 1 Gbps, so the automatic metric would put it level with
  Ethernet. A setting makes the modem preferred instead (a low metric). The metric is set for
  IPv4 and IPv6 alike.
- **DNS: the operator's by default** — from `+CGCONTRDP`, else `+GTDNS`. The DNS override is a
  setting, empty by default.
- Every change is **scoped to the modem's adapter** and idempotent.

## Tray icon (M3)

- Drawn at runtime with `System.Drawing` at the size the current DPI asks for: signal bars, a
  color for the state (connected / recovering / offline), and the technology (4G/5G) if legible
  at that size.
- **Redrawn only when what it shows changes**, and the previous icon's handle is released with
  `DestroyIcon` once the new one is set. Without that, a GDI handle leaks at every refresh and the
  process dies after days.
- Tooltip: operator, technology, key quality values, band. Menu: open, reconnect, quick mode
  switch (4G + 5G / 4G only), exit.

## Drivers (M6)

Only the modem's AT ports need a driver — the MediaTek serial driver `usb2ser_tm`; the network
function is RNDIS, which Windows serves itself ([`AT-COMMANDS.md` §1](AT-COMMANDS.md#1-usb-identity)).
No official public download exists for that driver, and redistributing it is not licensed, so the
app follows **"bring your own driver", guided**: it never downloads or bundles a driver, it tells
the user where a known copy is published and by whom, the user downloads it, and the app decides
whether it is safe to install.

1. **Detect** the modem's USB functions by hardware ID and classify them: absent, present without
   a driver (problem code 28 or 1), present with another problem (disabled, failed to start),
   working. A modem is the composite device its functions hang from — not their container ID,
   which a device on a port the firmware calls non-removable inherits from the computer and shares
   with everything built in. For the same reason the network adapter is found by its own instance
   ID (the adapter's `PnPDeviceID`). Instance IDs are not remembered across runs: the FM350's is
   generated from the USB port it sits in. The classification is a pure function
   (`Resolve-ModemUsbDevice`) over the PnP records; reading them is the thin part around it, in
   the worker (`Get-ModemPnpRecord`, M2): one `Get-PnpDeviceProperty` call per device with every
   key, given the device object — about 50 ms; given an instance ID, about a second — plus the COM
   port name from the device's registry parameters. Never several devices in one call: the cmdlet
   then sometimes labels one device's properties with another's instance ID.
2. **Guide.** A dialog explains that the project does not distribute the driver, shows where a
   known copy is published — a page pinned to a fixed commit, taken from the known-fingerprints
   manifest — and says plainly that it is a third party's copy of MediaTek's driver. Two actions:
   *open that page* in the browser, and *choose the downloaded package*. The app itself never
   fetches it: if the page disappears, any identical copy from anywhere still passes step 4 as the
   verified version.
3. **Take the package** the user points to — a zip or a folder — and locate the INFs in it. An
   executable in the package is **never run**: installers found in the wild are often unsigned.
4. **Verify**, as a pure decision function:
   - the catalog (`.cat`) carries a valid signature from *Microsoft Windows Hardware Compatibility
     Publisher* (WHQL) — **required**. A catalog signature covers the hashes of the files it lists,
     so authenticity comes from the signature, not from where the package was downloaded;
   - the INF lists the modem's hardware IDs — **required**;
   - the files match a known fingerprint from the manifest committed in the repo (SHA-256 of
     `.cat`, `.inf`, `.sys`, plus the page where a copy is published; hashes and links only, no
     binaries) — reported as a **verified version**, otherwise as an unknown but signed version.
5. **Install** with `pnputil /add-driver <inf> /install`, which re-validates the catalog and refuses
   a tampered package; uninstall by locating the published `oemNN.inf`.

`usb2ser_tm` 3.22.43.1 loads with Memory Integrity (core isolation) on (`AT-COMMANDS.md` §1).

## eSIM (M8)

Profile management on modules with an embedded SIM. The eUICC protocol (GSMA SGP.22, including
TLS to the operator's SM-DP+ server) is **not** reimplemented: [lpac](https://github.com/estkme-group/lpac)
runs as an external process, one invocation per operation (facts: `AT-COMMANDS.md` §8).

```
  UI ──command──► worker ──spawns──► lpac (LPAC_APDU=stdio)
                    ▲  │                 │ stdout: {"type":"apdu", func, param}
                    │  └──── stdin ◄─────┘ stdin:  {"type":"apdu", ecode, data}
                    │
                 AT port: AT+CCHO / AT+CGLA / AT+CCHC ──► eUICC
```

- **lpac never touches the AT port.** Its `stdio` backend hands every APDU to the worker, which
  carries it with `AT+CCHO`/`AT+CGLA`/`AT+CCHC` on the port it already owns (invariant 1). lpac
  talks to the SM-DP+ over HTTPS on its own (`winhttp`).
- **The bridge is a translation** — lpac request → AT command, AT response → lpac answer — written
  as pure functions and tested with a matrix; the lpac side is simulated in the tests.
- **Operations:** chip info; profile list, enable, disable, nickname; download from an activation
  code or QR code; delete behind a strong confirmation; notifications processed automatically after
  each operation. `chip purge` is never exposed.
- **Switching** the SIM slot (`AT+GTDUALSIM`) or the enabled profile disrupts the link, so it runs
  inside a **maintenance window** (see *Maintenance windows*). The slot setting is **persistent**
  modem state (`AT-COMMANDS.md` §4): the app writes it only after a confirmation saying that the
  choice stays in the modem across restarts, and always shows the active slot.
- **Identifiers:** EID and ICCIDs are redacted like IMEI and IMSI; activation codes are secrets and
  are never logged.
- **lpac ships with the app.** lpac is AGPL-3.0, so unlike the modem driver it may be
  redistributed. The release workflow downloads the pinned version from lpac's official GitHub
  releases, checks its SHA-256, and puts `lpac.exe` and its license in the release zip; lpac's
  source archive for the same tag is attached to the GitHub Release as the corresponding source.
  The binary is never committed to git.

## SMS, USSD and data usage (M9)

What a prepaid or capped SIM needs day to day (facts: `AT-COMMANDS.md` §9).

### SMS
- **PDU mode only.** Text mode depends on the modem's character-set setting and hides the header
  that ties the parts of a long message together; a PDU carries everything, and its format is a
  public standard (3GPP TS 23.040, alphabets in TS 23.038). Decoding and encoding are **pure
  functions** with a matrix of tests: GSM 7-bit with its extension table, UCS-2, long messages
  reassembled from their parts, long messages split for sending.
- **The modem stores, then announces.** On every connect the worker sets `+CNMI` so that a new
  message is saved on the modem and announced with `+CMTI: <storage>,<index>`. Direct delivery
  (`+CMT`) is never used: it hands the message to the port without storing it, so one arriving
  while the app is closed or its worker is restarting would be lost, and it must be acknowledged
  within 15 s or the modem sends it again.
- **The AT channel routes the notices.** `+CMTI` and `+CUSD` are unsolicited result codes: they can
  arrive at any time, in the middle of another command's response too (M1 separates them). The
  worker reads the new message and publishes it in the next snapshot; the UI shows a tray
  notification.
- **Messages stay on the modem.** The inbox is read from the modem's storage at start and on each
  notice; delete acts there. The app keeps no copy on disk. A full storage is shown in the UI,
  since new messages can't be stored.

### USSD
One session at a time. The request is `AT+CUSD`; the reply arrives later as a `+CUSD` code, often
after the command's `OK`, and may ask for an answer (a menu). The worker waits for it up to a
timeout (**TBD**), decodes it by its data coding scheme (pure function), and the UI shows it with
an answer box when the network expects one. **Best effort:** whether USSD works over LTE/NR
depends on the operator's network; if the FM350 can't do it, the feature is dropped, not
emulated.

### Data usage
- **Counted on the Windows side.** The modem has no traffic counter (`AT-COMMANDS.md` §9); the
  worker samples the byte counters of the modem's network adapter on its regular loop.
- **Accumulated across resets, as a pure function.** The counters restart from zero whenever the
  adapter is re-created (modem reset, device restart, replug). For each sample: if the new value
  is below the previous one, the counter restarted and the new value is the delta; otherwise the
  delta is the difference.
- **Persisted** under `%LOCALAPPDATA%\fibocom-fm350-gl-windows-gui\`, periodically and on exit.
  Traffic while the app is closed is still counted at the next start, unless the counters were
  reset in between: the totals are approximate, and the UI says so.
- **Today and the billing cycle**, whose start day is a setting (a day the month doesn't have
  means its last day). An optional quota raises tray warnings at thresholds (**TBD**). **The quota
  never disconnects** — the app does not break a working connection.

### Identifiers
Phone numbers, message text and USSD replies are personal data: never logged, and replaced by fake
values of the same shape in fixtures.

## Settings and logs (M2/M3)

- Settings: a JSON file under `%APPDATA%\fibocom-fm350-gl-windows-gui\`. The elevated scheduled
  task runs as the same user, so the path is the same elevated or not. `Apn` (empty: the
  subscription's own), `PdpType` (`IP` or `IPV4V6`), `ApnAuthentication` (`None`, `PAP`, `CHAP`)
  with `ApnUser`, `DnsServers` (the override; empty keeps the operator's), `InterfaceMetric` (500:
  the modem as a backup). Read leniently — an invalid value falls back to its default and is
  reported, an unknown one is ignored: a bad file never stops the app — and written strictly: an
  invalid value is refused. The file is replaced whole (a temporary file, then a move).
- Secrets — the SIM PIN, an APN password — never go in the settings file: each is kept
  DPAPI-encrypted for the current user in a file of its own in the same folder (see *SIM PIN*).
- Logs: rolling files under `%LOCALAPPDATA%\fibocom-fm350-gl-windows-gui\logs\`, one per day,
  the 14 newest kept, at most 10 MB a day (then one line says so). **Every line is redacted on its
  way in** (`ConvertTo-RedactedText`): no IMEI, IMSI, ICCID, EID, MSISDN or other phone numbers,
  serials, cell identity + TAC, message text, USSD replies — and no secret: the PIN of `AT+CPIN=`
  and `AT+CLCK=`, the credentials of `+CGAUTH`. The file is opened for each line: the log holds no
  handle.
- Data usage totals (M9): a JSON file under `%LOCALAPPDATA%\fibocom-fm350-gl-windows-gui\`.

## Module layout

```
src/
  FibocomFm350/          core module: no UI; imported by the app and by the tests
    FibocomFm350.psd1
    FibocomFm350.psm1
    Bands.ps1            AT+GTACT band codes (M0)
    AtText.ps1           framing and classifying the lines on the AT port (M1, pure)
    Timeouts.ps1         each command's documented worst case (M2, pure)
    Transport.ps1        the serial transport, and the shape every transport has (M1)
    SimulatedModem.ps1   the simulated modem: fixtures + scripted faults; fixture import (M1)
    AtChannel.ps1        the AT channel: commands, answers, unsolicited codes (M1)
    Measurements.ps1     measurement index -> dBm/dB (M1, pure)
    Parsers.ps1          identity, SIM, registration, operator, signal, temperature (M1, pure)
    Cells.ps1            +GTCCINFO cells and +GTCAINFO carrier aggregation (M1, pure)
    Arfcn.ps1            channel number -> frequency and band (M1, pure)
    Contexts.ps1         data context: definition, activation, address, DNS, authentication (M2, pure)
    Settings.ps1         settings file, APN password (M2)
    Sim.ps1              SIM PIN: states, the decision, the encrypted store, removing it (M2)
    Fcc.ps1              FCC lock: reads, diagnosis, unlock (M2)
    Connection.ps1       state machine (pure), observation and connect pass (M2)
    Network.ps1          modem adapter: configuration plan (pure), read and apply (M2)
    Log.ps1              redaction (pure), rolling log (M2)
    Devices.ps1          the modem's USB functions: classification (M6, pure), PnP reader (M2)
    Data/                3GPP band tables, transcribed (EutraBands.psd1, NrBands.psd1)
    …                    recovery, drivers (M4–M6)
  App/                   tray app: UI thread, worker runspace, supervisor (M3)
tests/
  *.Tests.ps1            Pester
  fixtures/
    documented/          answers written from the documentation, values invented (M1)
    device/              answers and PnP snapshots captured from a real FM350, redacted (device session)
    fakes.psd1           the only identifier-like values a fixture may carry
tools/
  Invoke-Lint.ps1        the linter, as CI runs it (docs/SETUP.md)
assets/                  logo (source: logo.html)
```

## Runtime dependencies

None beyond **PowerShell 7.6+ on Windows**. Everything the app uses ships with it: `System.IO.Ports`
(serial), WPF and WinForms (UI), `System.Drawing` (icon), and the Windows modules `PnpDevice`,
`NetAdapter`, `NetTCPIP`, `DnsClient`, `ScheduledTasks`. From `v1.1.0` the release zip also
carries `lpac.exe` for eSIM (see *eSIM*); nothing has to be installed separately.

## Invariants

1. **One owner per resource.** Only the worker opens the COM port; the mutex keeps a second
   instance away from it, and external tools such as lpac reach the modem only through the worker. Every handle, subscription, runspace and timer is released by its owner,
   on the error path too.
2. **The UI thread never blocks.**
3. **Attach before dial.** Startup and worker restarts observe first and only run missing steps.
4. **Escalate only on a failed health check.** Maintenance windows suspend escalation.
5. **Every icon handle is destroyed.**
6. **Parsers and decisions are pure.** Text or state in, value out; nothing in them touches the
   port, the network or the clock.
7. **No identifier leaves the process unredacted**, and no secret (SIM PIN, APN password) leaves
   it at all — encrypted at rest, never logged, never shown back.
8. **System changes are scoped to the modem's adapter**, idempotent, and volatile where possible.
9. **Band codes round-trip.** A code read from the modem survives being written back, even when
   the app does not understand it.
10. **Elevated code comes only from an admin-only location.** The app and the tools it runs are
    loaded from under `%ProgramFiles%`; nothing user-writable (profile scripts, per-user modules,
    paths from settings) is executed by the elevated process.

## Independent implementation

The protocol knowledge comes from `docs/AT-COMMANDS.md`, where every fact has a source and a
status. The upstream project that inspired this one has no license, so its code is neither
copied nor paraphrased; the architecture above (tray process, worker runspace, state machine,
recovery ladder) is this project's own.
