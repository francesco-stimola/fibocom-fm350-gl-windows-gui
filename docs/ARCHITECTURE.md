# Architecture

This document describes the design **as decided**, including the parts not built yet — each
section says which milestone implements it (see [`ROADMAP.md`](ROADMAP.md)). Thresholds marked
**TBD** are the human's decision (see `CLAUDE.md`); they are not to be filled in with a guess.

## Overview

Used over a USB adapter, the FM350-GL shows up on Windows as a set of vendor USB functions — the AT
port among them — and a network adapter, but nothing brings the data connection up by itself: someone has to register on the
network and activate a data context over AT commands, then configure the adapter's IP address.
When the link drops, nothing brings it back. This app does both, from the system tray.

```
 ┌──────────────────── pwsh.exe · elevated · one instance ────────────────────┐
 │                                                                            │
 │   UI thread (STA)                        worker runspace                   │
 │  ┌──────────────────────┐   commands   ┌─────────────────────────────────┐ │
 │  │ tray icon + menu     │ ───────────► │ connection state machine        │ │
 │  │ main window (WPF)    │    queue     │ health checks · recovery ladder │ │
 │  │ supervisor           │ ◄─────────── │ AT channel ────► MD AT (WinUSB) │ │
 │  └──────────────────────┘   snapshots  │ network config ──► modem NIC    │ │
 │                                        └─────────────────────────────────┘ │
 └────────────────────────────────────────────────────────────────────────────┘
```

## Scope and non-goals

- **Windows 10/11 on x64 or Arm64, PowerShell 7.6+** — Arm64 compatible in software, not verified on
  hardware (M10). No other platform: on Linux the modem is served by
  ModemManager/NetworkManager, and almost everything here (drivers, PnP, adapter configuration,
  autostart) is Windows-specific. Windows PowerShell 5.1, part of Windows, only starts it
  (*Startup, elevation, single instance*). Encrypted DNS needs Windows 11 (*Network
  configuration*).
- **FM350-GL over USB.** Laptops with an OEM-integrated FM350 (PCIe) that already work through
  Windows' mobile broadband stack are out of scope.
- **No driver to bring, install or redistribute** (M10): the modem's vendor functions run on
  Windows' own WinUSB driver (*USB functions and WinUSB*). No binary ships whose license doesn't
  allow it.
  Open-source tools ship only under their own license (lpac and ZXing.Net, from `v1.2.0` — see
  *eSIM*).
- Not a firmware tool: no flashing, no IMEI changes, no NV editing — with one exception the user
  asks for explicitly, the FCC unlock (see *FCC lock*).

## Process model (M3)

One process, living in the system tray. There is no Windows service: if the app is closed, the
user reopens it and monitoring resumes.

### Threads
- **UI thread** (STA): the tray icon (WinForms `NotifyIcon`), the main window (WPF), and a
  **supervisor**. It only reads snapshots and enqueues commands — it never does I/O on the modem,
  the network or PnP. A dispatcher timer ticks every 500 ms: it takes the worker's latest
  snapshot, supervises the worker, and redraws the tray icon, its tooltip and the window only when
  the snapshot or the worker's state changed (`Update-App`).
- **Worker runspace**: owns the AT port, the state machine, health checks, recovery, network
  configuration (`Invoke-ModemWorker`). It publishes an **immutable snapshot** of its state after
  every change and consumes the UI's commands from a queue.
- **Supervisor**: the worker writes a heartbeat; if it ends (an error) or stops beating (a hang),
  the UI thread replaces it (`Resolve-SupervisorAction`). A new worker **attaches** to whatever
  state the modem is in (see *Startup reconciliation*) — a worker restart is not a re-dial.

### The worker (M3)
- **One link per worker** (`New-ModemWorkerLink`): a synchronized hashtable, the only object both
  threads touch — the command queue (`ConcurrentQueue`), an event that wakes the worker at once,
  the latest snapshot, the heartbeat, the stop request. No lock is held across I/O. A worker that
  hung and comes back to life later writes only to its own link, never to its successor's.
- **Snapshots are immutable by construction** (`New-ModemSnapshot`): a new object every time,
  which nobody changes afterwards; the UI reads whichever is the latest. They carry no secret —
  the stored PIN and APN password only as "stored or not" — and no identifier: no ICCID, and
  cells without MCC, MNC, TAC or cell identity. Their version grows across worker restarts.
- **Commands** (`Send-ModemCommand`): check now (a connect pass, which never breaks a connection
  that works), save settings and the APN password, set the network mode (tried, *Modes and*
  *bands*), store or forget the SIM PIN, remove the PIN from the SIM, lift the FCC lock, enable
  the adapter, the messages' (*SMS*), the eSIM's (*eSIM*). Secrets travel as `SecureString`s and stay
  in the process. Each command's outcome comes back in the next snapshots (the last ten).
- **Cadence** (`Resolve-WorkerSchedule`, pure; decided 2026-10-01): a connect pass every 30 s
  online, every 10 s while the connection is on its way, every 30 s while it waits for the user
  (whose command runs one at once); the radio for display every 5 s once the SIM is ready; a look
  for the modem by PnP every 5 s while no port is open; a data-path round every 60 s while the
  adapter carries the context's address (M4, *The data-path probe*). A registration or context
  code from the modem brings the next pass forward — a hint, never the only source.
- **Recovery is decided on every cycle** — a pure function, cheap — on the state the last pass or
  probe left (*Health checks and the recovery ladder*), and its step taken in the same cycle.
- **The port is found again at every look**: by PnP (`Resolve-ModemPresence`), never remembered —
  after a re-enumeration the modem can come back as a new device instance, on its old driver
  (`AT-COMMANDS.md` §1), which the worker puts on WinUSB again (*USB functions and WinUSB*). A lost port is closed at once; the next look finds the device again. While
  a pass finds no network adapter, PnP is read again for it at the scan cadence, the port left
  open: one PnP read that missed it must not leave the connection blocked.
- **What is shown is what was read**: below a ready SIM the radio is not read, and the last
  reading is dropped with it — no old bars over a SIM that waits for its PIN.
- **The heartbeat never waits on the modem**: the worker's transport wraps the real one and reads
  at most a second at a time (`WorkerTransport`), the channel reading again until the command's
  own timeout. A command that legitimately takes minutes (`AT+COPS`) never looks like a hang;
  only a call that never returns (PnP, the network stack) stops the heartbeat.
- **Errors stop the cycle, not the worker.** The worker runs with `$ErrorActionPreference = 'Stop'`:
  any error stops the cycle where it happened — never half a cycle carried on — and is logged; the
  cycle is tried again a second later. A look, a pass or a status read is marked done only once it
  has run, so the part that failed is the part tried again. Three failed cycles in a row end the
  worker with that error, and the supervisor starts a new one. A log that can't be written never
  stops anything.
- **Supervisor timings** (decided 2026-10-01): a worker silent for 60 s is hung — abandoned (its
  pipeline asked to stop, released whenever its stuck call returns) and replaced; a new worker
  starts 5 s after a failure, the wait doubling at every failure in a row up to 5 min, and a worker
  that ran 10 min before failing starts the count over. **Only silence the UI has watched counts**:
  a computer that sleeps stops the worker's waits and the UI's timer alike while the clock runs on,
  so after a gap of more than 5 s between two ticks the silence is counted from the resume. Errors
  and warnings the worker writes are taken and logged at every tick, so they never pile up.
- **Development mode** (`Start-Fm350App -Simulated -Scenario …`): the worker drives a simulated
  modem and adapter (`New-SimulatedDevice`, scenarios in `Data/Simulation.psd1`: online, connect,
  an APN needed, a PIN required, an FCC lock and its unlock, a disabled adapter, no modem, its
  functions not on WinUSB yet; and M4's faults — a path that settles, a data path down, a network that drops ICMP, a
  registration lost, a modem that doesn't answer, a network that refuses it for good; and M5's
  modem in LTE-only mode, in NR-only mode where there is no 5G SA, and a network with 5G SA; and
  M9's eUICC in use, with no profile enabled and with one) — no device, no administrator rights,
  nothing changed on the system. The recovery steps act on the simulated modem as on a real one,
  every time they run, and so does putting its functions on WinUSB. Its settings,
  secrets and log live in a folder of their own, and it runs beside the real app.
- **Observe only** (`-ObserveOnly`): the worker reads and never writes — no step, no command that
  changes the modem or the system. The window says which step it withholds.

### Startup, elevation, single instance
- The app needs admin rights (adapter configuration, device restart, the USB functions' driver). To avoid a UAC
  prompt at every start, the installer (M7) registers two **scheduled tasks** that run with the
  highest privileges as the user who installed it — *Start at logon*, which starts the app hidden
  in the tray, and *Open*, which starts it with its window — and a **Start-menu shortcut** that
  runs *Open*. One UAC prompt at install time, none afterwards (*Installing and updating*).
- **Starting at sign-in is the user's choice, off by default** (decided 2026-10-03): *Start at
  logon* is registered disabled on a first installation, and an update keeps it as the user left
  it. The *Connection* tab's checkbox turns it on or off — the elevated app enables or disables
  the task (`Set-AppLogonTask`), never creates or deletes it; the checkbox shows the task's own
  state, read by the worker, not a copy in the settings file, and is greyed out where there is no
  such task (development mode). Like every system call, it runs on the worker, never on the UI
  thread.
- **The app's files live where only administrators can write.** The tasks run them elevated
  without a prompt, so a copy in a user-writable folder (the extracted zip, a per-user module path)
  would let any program running as the user edit them and gain administrator rights silently. The
  installer copies the app under `%ProgramFiles%` and checks that nobody else can change any of
  it. For the same reason no setting names an executable or a script to run: lpac is found next to
  the app.
- **PowerShell 7 is found, never named.** Its MSIX package — what winget installs from 7.6, and
  the only package from 7.7 — lives in a folder named after its version, which every update
  replaces, and its one stable name, the app execution alias, is in the user's profile
  (`AT-COMMANDS.md` §11.2). So the tasks start **Windows PowerShell 5.1**, which every supported
  Windows has in its system folder, with the launcher `Start-Fm350.ps1` from the install folder; at
  every start the launcher looks for PowerShell 7 — the MSI's folder, the current user's MSIX
  package — and takes the newest at 7.6 or later that is under Program Files and signed by
  Microsoft. It starts it with `-NoProfile` and **no console window**: a console program started by
  a task gets one, which `-WindowStyle Hidden` doesn't hide under Windows Terminal, the default
  terminal of Windows 11. The launcher's own console shows for a moment. Without a usable
  PowerShell 7, the launcher says so in a message box and what to install.
- **Paths are literal, modules admin-only.** The tasks name Windows PowerShell and the launcher by
  their full paths, resolved by the installer from Windows' known folders — never through `PATH`
  or an environment variable, which the user can set. The launcher, the installer and the app set
  their module path to Windows' own modules and PowerShell's (`$PSHOME`) before any command could
  load one: the user's module folder is theirs to write, and PowerShell puts it back in the
  process's module path whenever a runspace opens (`AT-COMMANDS.md` §11.2), so the app takes it
  out again as each worker runspace opens.
- **What invariant 10 doesn't cover.** User Account Control is not a security boundary
  (`AT-COMMANDS.md` §11.2): a program running as the user can reach an elevated process of the same
  user in ways no app closes — the user's environment, for one, reaches every process the user
  starts. The app closes the paths made of files: its own, PowerShell's, the modules and profiles,
  the settings.
- A named **mutex** enforces one instance (`Enter-AppInstance`): machine-wide, since the AT port
  is. A second launch signals the first to show its window — through an event of its Windows
  session — and exits: two instances would fight over the AT port. A mutex left by an instance
  that died is taken over. A launch without the running instance's administrator rights can't
  signal it, and exits quietly. Development mode has a mutex of its own.
- **Without administrator rights** the app runs, reads and connects, and stops before configuring
  the adapter (`NotElevated`, blocked): it says so instead of failing at every pass.

### Closing and reopening
Closing the app stops **monitoring and recovery only**. The modem stays registered, the data
context stays active, the adapter keeps its address. On reopen, the app reads that state and
carries on. *Exit* asks the worker to close the AT port and waits for it up to 5 s; then the
process ends whatever is left — a worker stuck in a call that never returns would otherwise keep
the process, and the port, alive.

### Installing and updating (M7)
- **The package.** The release zip holds what `src/` holds — `install.cmd`, `uninstall.cmd`, the
  launcher `Start-Fm350.ps1`, the folders `App`, `FibocomFm350`, `Installer` — with `LICENSE`,
  `README.md` and `CHANGELOG.md`, and no folder at its top: Explorer's *Extract All* names one
  after the zip. The installer copies those entries and nothing else, so an *extract here* into a
  busy folder never takes the folder along.
- **`install.cmd`** runs the launcher in Windows PowerShell. It first refuses a Windows the app
  can't run on — anything but 64-bit Windows on an x64 or an Arm64 processor, read from
  `Win32_Processor` (`Test-LauncherPlatform`): PowerShell 7.6 has no 32-bit build. Windows on
  Arm was refused up to 1.x, for the modem's driver package had no Arm64 driver; from 2.0 the
  app's driver is Windows' own WinUSB (M10; `AT-COMMANDS.md` §11.2). Then it finds PowerShell 7 and starts the installer (`Installer\Invoke-Fm350Setup.ps1`) with the one UAC prompt, in a window
  that waits for Enter at the end. The installer runs as the account that ran the `.cmd`: when the
  prompt is answered with another account's credentials, that other account is not the one the
  app must run as, and nothing is done.
- **Install** (`Install-Fm350App`): the running app, if any, is asked to exit — an event of its
  session, which only an elevated process can signal — and its mutex held until the end, so none
  starts meanwhile; *Exit* stops monitoring only, the connection stays up. An app that doesn't exit
  within 30 s (another Windows session) stops the installation before anything changes. The
  package's entries are copied beside the install folder, their mark of the web removed, and the
  copy checked: owned and writable by SYSTEM, Administrators and TrustedInstaller alone, every file
  of it (`Test-AdminOnlyAccess`). Then the old folder moves aside, the copy takes its place, and the
  old one is deleted; a failure halfway puts the old one back, and leftovers are deleted at the next
  installation. The two tasks are registered — Task Scheduler's defaults would stop the app after
  72 hours, keep it from starting on batteries, stop it when the computer goes on batteries, and
  run it at below-normal priority (`AT-COMMANDS.md` §11.2): none of that applies —, the
  Start-menu shortcut made with an icon the installed app draws, the app listed in Windows'
  installed apps (`Register-AppUninstallEntry`: its key under `Uninstall`, written whole at every
  installation — name, version, icon, folder, size, page, `uninstall.cmd` through `cmd /c`, no
  *Modify* nor *Repair*), the mutex released, and the app started with its window through *Open*.
  When a step fails after the running app exited, that app is started again from the folder in
  place — the old one put back, or the new one — before the failure is said: an update that fails
  never leaves monitoring off.
- **Updating** is the same: extract the new zip, run its `install.cmd`. Running it again from the
  install folder makes the tasks and the shortcut again without copying.
- **Uninstall** (`uninstall.cmd`, in the zip and in the install folder, or *Uninstall* in
  Windows' installed apps, which runs it — from the folder it deletes: it moves its current
  folder away first, its last line is read whole, and `(goto)` leaves the batch file before it
  exits, or `cmd` would look for the file once gone and exit 1): the running app exits as above,
  then the tasks and their folder, the shortcut and the install folder are removed, and the app's
  entry in the list last — until the folder is gone, an uninstallation that failed can run again from there. First,
  while the app's code is still there, the modem's functions on WinUSB — on Windows' own
  `winusb.inf`, as the app puts them: one another tool put there with an INF of its own is left —
  go back to the driver Windows ranks best (`Restore-ModemUsbFunction`, M10; *USB functions and
  WinUSB*): MediaTek's COM ports come back where its driver is in the driver store. A function
  another program holds stays on WinUSB. The functions of a modem not plugged in, which Windows
  remembers on WinUSB — `DiInstallDevice` reaches present devices only —, are removed from Windows
  instead (`DiUninstallDevice`; decided 2026-10-05), which chooses their driver afresh when the
  modem comes back. The uninstaller says each. A failure there, PnP that couldn't be read
  included, is said and stops nothing. Nothing else on the modem or its adapter is undone: the connection stays as it is, as
  *Exit* leaves it. The uninstaller asks whether to delete the settings, the stored SIM PIN and
  APN password, and the logs too.

### Updates (M7)
The zip on GitHub Releases is the only distribution channel. Once per app start, when the
connection first comes online (at logon it usually isn't yet), the worker reads the latest release
from GitHub's public API: one attempt, no retry until the next start, no timer. When the API
refuses (`403`, `429` — its limit is 60 requests an hour per public address, shared with every
other client behind it: a home router, an office, an operator's address translation;
`AT-COMMANDS.md` §11.3), that same attempt asks the latest release's page once instead, and reads
the release's tag from where it redirects. If that release is
newer than the running version, the tray menu says so and links to it. The app never downloads or
installs an update: updating stays *extract the zip, run `install.cmd`*, with its one UAC prompt.
A setting turns the check off. Since the app can run for weeks, a release is noticed at the next
start, not the day it is published.
- **The request** (`Start-UpdateCheck`) names the app as its user agent and nothing else — no
  version, no Windows build, no language, which .NET's and PowerShell's own user agents would add
  —, and gives up after 10 s. It runs **asynchronously**: the worker sends it and looks for the
  answer once a second, its heartbeat never waiting on the network. A worker replaced while the
  request was under way passes it on as done: no second attempt.
- **The page** (`Start-UpdateCheck -Page`) is one `HEAD` with the same user agent and nothing
  else, its redirect read and never followed; the log says the API refused, and whether its rate
  limit was used up.
- **The decision** (`Resolve-UpdateNotice`, pure) reads the answer's tag (`v<major>.<minor>.<patch>`)
  and compares it with the running version; a draft or a prerelease is never newer. For the page,
  `Resolve-UpdateRedirect` (pure) takes the tag from a redirect to this repository's release page
  only, reads one to the list of releases as none published, and fails on anything else — never
  asking again. The tray menu
  links the release's page, **built from the tag** — no address from the answer is ever opened —,
  through Explorer: the elevated app never starts a browser itself. Development mode never sends
  the request.

## AT channel (M1)

Everything the worker says to the modem goes through one **AT channel** per port (facts:
`AT-COMMANDS.md` §2).

- **Transport.** The channel talks to a *transport*: any object with `PortName`, `Lost`,
  `Write`, `Read` and `Close`. There are two: the **WinUSB transport** (M10, `Transport.ps1`)
  and the **simulated modem**, which answers from fixtures and plays scripted faults — the tests
  use it, and so does the app's development mode (M3). A transport that loses its port sets
  `Lost` instead of throwing, and never touches the port again; the channel then reports
  `PortLost` to every command, and the worker opens a new channel once the device is back — found
  again by PnP, because it can come back as a new device instance (`AT-COMMANDS.md` §1).
- **The WinUSB transport** opens the AT function's interface (*USB functions and WinUSB*) and
  talks through its bulk pipes, the pair read from the interface — one IN, one OUT (`AT-COMMANDS.md`
  §1.2). No modem-control request is sent: the modem needs none. It reads **one packet at a time**:
  a full packet completes a read as a short one does, so an answer whose length is a multiple of
  the packet size never waits for a zero-length packet. Each read waits at most the time asked,
  the pipe's own timeout; `ERROR_SEM_TIMEOUT` is nothing yet, **any other error means the port is
  gone** — `Lost`. A write gets 2 s: one that times out is a modem not draining it, not a lost
  port. Text travels as Latin-1 bytes, as on the COM port. The interface and its handles are
  released once, by `Close`, on the error path too.
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
  sequence reads only while the modem is not registered, and the worker's status read only after
  two quicker reads were answered: a read without an answer ends the status read there and brings
  the next pass forward.

## Connection state machine (M2)

```
 NoDevice ─► PortOpen ─► Identified ─► SimReady ─► Registered ─► DataActive ─► Online
     ▲                                                                           │
     └────────────── device removed / port lost (from any state) ◄───────────────┘
```

- `Online` means: data context active with an address, the adapter configured with that address,
  and the data-path probe not failing (H7: until its rounds prove the path, it counts as passed).
- Each transition is decided by a **pure function** of (current state, observed facts) → next
  state + actions (`Resolve-ConnectionState`). The state is the furthest one the facts support;
  the action is the first missing step: open the port, initialize the channel, enter the SIM PIN,
  turn the radio on, select the operator automatically, define the app's context, activate it,
  configure the adapter. With no step to take, a **reason** says why — searching, SIM busy, a PIN
  the user must give, an FCC lock, a port another program holds — and **blocked** says whether it
  is out of the app's reach: no device, an AT port the app can't put on WinUSB, a SIM waiting for the user, an FCC lock, an APN
  the user must give, a network adapter missing or disabled by the user, no administrator rights
  to configure it. No recovery step changes those, so none is escalated (M4).
- **What couldn't be read is unknown, never "no".** A read that fails leaves its fact `$null`, and
  the state machine takes no step on it: a context whose activation or parameters couldn't be read
  is neither activated nor deactivated (`ContextUnknown`, not blocked — the next pass reads it
  again); a definition is written only over a context known to be inactive; a modem error on
  `+CPIN?` other than the SIM codes is no SIM state (`SimUnknown`, not blocked). One failed read
  must never break a working connection or send the user after a problem that isn't there.
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
  (no context parameters before registration, no lock reads after it). The worker loop only gathers
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
  out, and read back — a PIN whose attempt can't be recorded is not sent — and cleared once the
  stored PIN's SIM is seen ready, identified by its ICCID: an answer that never arrives — a
  timeout, a crash — is never followed by a second attempt, not even after another SIM was in
  the modem meanwhile; the user is asked instead.
- **"Remove the PIN from the SIM"** (logic M2, dialog M3): `AT+CLCK="SC",0,"<pin>"` turns the
  SIM's PIN request off for good, after a confirmation that says it changes the SIM, not the app.
  It spends an attempt like any PIN entry and follows the same rules: only a PIN of 4 to 8 digits,
  only on a ready SIM whose PIN request is known to be on, never with one attempt left
  (`Disable-SimPin`).
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
  the simulated modem. Proving it on a module that is really locked — and capturing the locked
  values — is optional: taken up only if one turns up or a user needs it (decided 2026-10-01).

## Health checks and the recovery ladder (M4)

**Health checks**, from cheapest to most expensive. The connect pass already reads what H1–H6
need, in this order, and stops at the first that fails, so the state it reaches says which check
fails (`Resolve-HealthCheck`, pure). Only H7 has a read of its own: the data-path probe.

| # | Check | Fails when | The pass's state |
|---|---|---|---|
| H1 | Device present (PnP) | The modem is gone from USB, its AT port is not on WinUSB (yet), or has a problem. | `NoDevice` |
| H2 | AT port answers | The port can't be opened, or the modem doesn't answer on it. | `NoDevice` (`PortFailed`), `PortOpen` |
| H3 | SIM ready | `+CPIN?` is not `READY`. | `Identified` |
| H4 | Registered | Registration status is not home/roaming. | `SimReady` |
| H5 | Data context up | No context defined, none active, or no address. | `Registered`; `SimReady` while the definition is missing (it is written while the modem registers) |
| H6 | Adapter configured | The adapter's address differs from the context's. | `DataActive` |
| H7 | Data path | Probes bound to the modem's address get no answer. | `DataActive` (`DataPathFailed`) |

- The checks **read** the state; they don't wait for unsolicited codes. The FM350 doesn't send
  every report it is asked for — no `+CSCON`, `+CGREG` or `+C5GREG` code was seen while the state
  changed (`AT-COMMANDS.md` §2) — so a code is a hint to read sooner, never the only source.
- A failing check whose cause the state machine calls **blocked** is out of the app's reach — no
  device, an AT port that can't be put on WinUSB, a SIM waiting for its PIN or PUK, an FCC lock, an APN or an APN password to
  give, an adapter missing or disabled by the user, no administrator rights — and so is a port
  another program holds: recovery never acts under them. The tray says what it is instead.

### The data-path probe (H7)
- **ICMP echo requests sent from the modem's address** (`Test-ModemDataPath`, through the IP
  Helper API: .NET's `Ping` can't choose the address it sends from). Windows sends a packet from
  an address out of the interface that has it, so the probe tests the path through the modem even
  while the modem is a backup and other adapters carry the traffic. Addresses are never logged.
- **A round** is up to 3 requests, each waiting 1 s for its reply, to `1.1.1.1` and `8.8.8.8` in
  turn; the first reply passes it. **H7 fails after 2 rounds failed in a row**
  (`Resolve-DataPathHealth`, pure): one lost round is never a failure. Rounds count for one
  address: a new address, the same one set again, or a recovery step starts them over.
- **Only a path that has answered once can fail.** Until a round has passed since the app
  started, failed rounds prove nothing — a private APN or an operator may drop ICMP while the
  user's traffic flows — so they are logged once and shown, never escalated (decided
  2026-10-02). The flag travels in the snapshot to a worker that replaces this one. The price:
  a path dead from the very first connect is not mended by H7 until it has worked once.
- **A path that settles is no failure.** An address just set is `Tentative` while Windows checks
  that no other host has it — 3.1 to 3.5 s on the device — and a request sent from it fails at
  once: that was M3's one reply in four right after the adapter was configured
  (`AT-COMMANDS.md` §1). No round is sent from an address Windows has not made `Preferred`, and
  the first round waits 5 s after the address was set or a recovery step was taken. An address Windows refused (`Duplicate`, `Invalid`) counts as
  not configured: H6, and the pass sets it again.
- **Cadence**: a round every 60 s, 10 s after one that failed or couldn't be sent; only while the
  adapter carries the context's address. About 72 bytes a round, some 3 MB a month; a dead path is
  noticed within about 15 to 76 s. The state follows the verdict at once, without waiting for the
  next pass. Decided 2026-10-02.

### The recovery ladder
Each step does the least that can mend what fails, and leaves the rest to the connect pass the
worker runs right after it (`Invoke-RecoveryStep`):

| Step | Action | The pass then | Impact |
|---|---|---|---|
| R1 | Remove the adapter's addresses and default routes (`Resolve-AdapterClearing`) | Configures it from scratch | None on the radio. |
| R2 | Deactivate the data context (`AT+CGACT=0,1`) | Activates it, configures the adapter | Short data gap. |
| R3 | Deregister (`AT+COPS=2`) | Selects the operator automatically | Registration gap. |
| R4 | Radio off (`AT+CFUN=4`) | Turns it on | Radio gap. |
| R5 | Modem reset (`AT+CFUN=15`) | — the modem leaves USB and comes back | About a minute and a half off USB. |
| R6 | Restart the USB device (`pnputil /restart-device`) | — the device re-enumerates | Device re-enumerates. |

**The symptom picks the entry step, and the ladder climbs only while a check keeps failing after
each step's settle time.** The decision is a pure function — failing check, history, clock in;
step out (`Resolve-RecoveryAction`), proven by a matrix:
- **Ladders.** Each check has the steps that can mend it, from the least disruptive: H6
  R1–R5; H5 and H7 R2–R5; H4 R3–R5; H3 R5 alone — only a reset reads the SIM again; H2 R6 alone —
  a silent port takes no AT command, and the modem is still on USB. H1 has none: nothing reaches a
  device that is gone. The next step is the first of the failing check's ladder above the last one
  taken, so a check that changes on the way — the registration lost after the context was
  restarted — carries on upward; past the top of its ladder the cycle is over.
- **Grace.** A failing check is first left to the connect pass, which takes the missing steps
  itself: 3 min for H2 (the port has been seen silent for almost three minutes after it appeared,
  `AT-COMMANDS.md` §2), 2 min for H3 and H4, 1 min for H5 and H6; H7 at once, its own 2 failed
  rounds being its grace. Counted from when *that* check started failing: a port that falls
  silent after a step taken for the registration gets its 3 min, not the registration's leftover.
- **What couldn't be read is not escalated** (`SimUnknown`, `ContextUnknown`): one failed read
  must never break a connection that may well work (*Connection state machine*); a modem that
  stops answering altogether is H2.
- **Settle.** A step taken is given its time, whatever fails meanwhile — a reset takes the modem
  off USB: R1 30 s, R2 1 min, R3 and R4 2 min, R5 and R6 5 min. Measured on the device, with the
  worker taking each step (`AT-COMMANDS.md` §3): online again about 1.5 s after R2, 2 s after R3,
  11 s after R4, 87 s after R5 (off USB from about 51 s to 76 s); after R6 the port answered at
  once and only the adapter had to be configured again — and once the modem left USB by itself
  about 73 s later, inside R6's settle time.
- **Cycles.** After a cycle that didn't mend it, the next one starts at the entry step 5 min
  later, then 15 min later, then **once an hour: the slow cadence**, at which the tray shows the
  failure instead of hammering the network.
- **Starting over.** Health that holds 10 min starts the ladder and the cycle count over. A
  failure that comes back before that carries on up the ladder: the last step mended the symptom,
  not its cause.
- **Skipped steps.** Without administrator rights the steps that need them (R1, R6) are skipped;
  so is the reset (R5) when the SIM's PIN request is on and no PIN is stored — after a reset the
  SIM would wait for a PIN the app doesn't have, an outage turned into one only the user can end.
  A network mode the user narrowed leaves H4 without a step (*Modes and bands*). A check left
  with no step is shown, not escalated.
- **A step with nothing to act on is not counted**: when the port went with the modem between
  the reading and the step, the next cycle decides again on what the next look finds.
- **Observe only.** The step is named in the window and the log, never taken.
- **Continuity.** The history travels in the snapshot, published before a step runs: a worker
  that replaces another — one stuck in a step that never returned, too — carries on where it was,
  and a restart never starts the ladder over nor repeats a step without its settle time.
- **Sleep.** After the computer slept — a wait that ends far past its deadline — the data path is
  proven again and a failing check gets its grace time again: what the pause broke is the pass's
  to mend first.
- **R6 safely.** The worker closes the AT port first (Windows postpones restarting a device whose
  port is held), finds the modem again by PnP — H1 must pass — and restarts its composite USB
  device, checked by its hardware ID, with `pnputil` from the system folder, never through `PATH`
  (invariant 10).
- **On WinUSB (M10)** the ladder is the same. The AT port's handle is closed before R6 as the COM
  port was; a lost transport is found again by the next look. A USB restart (R6) brings the
  functions back as the same device instances, still on WinUSB; a reset (R5) may bring the modem
  back as another instance, on another driver or none, with another network adapter
  (`AT-COMMANDS.md` §1.2). A function that comes back as a new instance is put on WinUSB again
  before its port opens — an intended operation, under H1, whose ladder is empty (*USB functions
  and WinUSB*) —, and the adapter is configured from scratch.
- Timings decided 2026-10-02.

### Maintenance windows
An intentional operation that disrupts the link opens a **maintenance window**
(`Open-MaintenanceWindow`): checks keep running for display, but **nothing escalates** until the
window ends, or until the modem is healthy again after the operation broke the link — a healthy
reading taken before it did doesn't close it; then a failing check gets its grace time from the
window's end. A window lasts 3 min; the FCC unlock, which restarts the modem as a reset does,
opens one of 5 min (decided 2026-10-02). A network mode written — by the pass, by the user's
choice, by its undoing — opens one of 3 min (*Modes and bands*), and so does a SIM slot or an
eSIM profile switched (*eSIM*).

## Modes and bands (M5)

Everything goes through `AT+GTACT` (spec: [`AT-COMMANDS.md` §5](AT-COMMANDS.md#5-gtact--mode-and-bands));
the decisions are pure functions (`Resolve-NetworkMode`, `Resolve-NetworkModeTrial`).
- **Modes** (decided 2026-10-03): *4G + 5G* (`20,6,3`: NR preferred, then LTE — UMTS too, as the
  modem's automatic mode), *4G only* (`2,3,3`) and *5G only (SA)* (`14,6,6`), of those
  `AT+GTACT=?` lists. 5G NSA needs an LTE anchor: *5G only* registers only where the SIM's
  operator offers 5G SA.
- **Not managed by default** (decided 2026-10-03): the app writes no mode until the user chooses
  one; *As the modem has it* stops managing it again. A managed mode comes with its band lists:
  per RAT the mode uses, the bands chosen, or every band the modem supports.
- **Read at every pass** once the SIM is ready (`AT+GTACT?`, cheap), what the modem supports once
  per channel (`AT+GTACT=?`); the window shows both.
- **Written only when the modem's differs from the settings.** The modem keeps its setting across
  resets and power cycles, and every write registers it again and ends the data context
  (`AT-COMMANDS.md` §5), so a mode that works is never written again for nothing. The mode is
  compared on its RAT and the preferences that count for it; a band list counts as kept when the
  modem uses no band the settings leave out. A band asked that the modem leaves out is no reason
  to write: the FM350 drops n77 by itself whenever n78 is listed, and writing it back would
  register the modem again at every pass. The price: a list an outside tool narrowed is not
  widened again by the pass; the window shows the modem's lists, and *Apply* writes them all.
- **Every managed RAT's list is written** — the bands chosen, or every band `AT+GTACT=?` lists —
  so nothing from an earlier setting survives by accident: the modem keeps one list per RAT, and
  a write changes only the RATs it names. UMTS lists are not managed: never written, kept as the
  modem has them.
- **A write that didn't hold is not repeated**: the same command over the setting as read before
  it — taken and not kept, or refused — is not written again (`NotKept`, shown in the window),
  until the port is opened anew: after a restart the modem may take it.
- **In the pass**: once the SIM is ready and the radio on, ahead of the context's steps — on a
  connection that is up too, whose state stays the one the facts support — and never over an
  FCC lock; the reason the connection waits for, if any, stays what health and recovery go by. A
  write the modem took, or that got no answer, opens a maintenance window: nothing escalates while
  the modem registers again; the pass activates the context again.
- **The user's choice is tried** (decided 2026-10-03). *Apply* in the window, or the tray's quick
  switch, writes it at once, without asking — the window says that the modem keeps it, after the
  app exits too — inside a maintenance window. It is saved in the settings once the modem has
  registered with it in force, as read 10 s after the write or later: a reading sooner can still
  be the registration the write ends (`AT-COMMANDS.md` §5), and a modem that didn't keep the
  write stays registered with its old mode. A write that got no answer is tried as one that
  landed. Without that registration by the window's end (3 min) the setting before the first
  change on trial is written back, each code as read (invariant 9), and the settings stay as they
  were — a choice made over a remote session through this modem never leaves the user cut off; the
  trial ends only once the modem has taken it back, tried again a pass later, and once the modem is
  back on USB. Meanwhile the pass keeps the modem as chosen; the trial and its window are published
  at once, and a worker that replaces another carries them on. A choice the modem has already is
  saved without a write — n77 left out beside n78 counts as had — unless a trial is on, which it
  joins; *As the modem has it* during a trial writes the setting before back first.
- **A narrowed mode that loses the network is shown, not escalated** (decided 2026-10-03): NR
  alone, or LTE bands chosen, can keep the modem off a network a wider choice would find, and no
  reset changes that. In force on the modem — or not known to be otherwise, a read that failed —
  it leaves H4 without a recovery step: past H4's grace time the tray turns red, *No network*, and
  the window offers *Use 4G + 5G, every band*.
  The price: a laptop that leaves 5G SA coverage stays offline until the user acts.
- The band-code codec (`src/FibocomFm350/Bands.ps1`, M0) keeps codes it doesn't recognize, so
  writing a list back never drops something the modem reported.
- **Development mode**: the simulated modem keeps a mode and band lists as the device does — one
  list per RAT, n77 dropped with n78, the setting kept across a reset — and registers again
  after a write in a network with LTE on B1, B3, B7 and B20, NR on n78 under EN-DC, and 5G SA in
  the *Standalone* scenario only.

## Network configuration (M2)

- The modem's adapter is found through the device it belongs to: its `PnPDeviceID` is the
  instance ID of the modem's RNDIS function (`MI_00`, *USB functions and WinUSB*), never a name
  or an index.
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
  addresses, routes, metric: they vanish at reboot instead of lingering as stale persistent
  configuration. DHCP's setting is the exception: Windows stores it in the active store alone and
  keeps it across reboots, so the adapter stays without DHCP — the modem serves none anyway.
  **DNS servers and their encryption have no active store**: they are set on the adapter, kept
  across reboots — the encrypted servers a DoH template's name was last looked up to count again
  at the next start (*Encrypted DNS*) — and compared at every connect.
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
  setting, empty by default. Servers are compared per family, and a family only when servers of
  it are wanted: Windows reads IPv4 servers before IPv6 ones and lists IPv6 servers nobody set
  (`fec0:0:0:ffff::1`–`3`, or router advertisements'), so a list compared whole could fail to match
  for good — an IPv6-first override, IPv6 servers left by an earlier context — and the adapter would
  never count as configured.
- **Encrypted DNS (DoH), M7** (decided 2026-10-03): a setting turns DNS over HTTPS on for the
  servers of the DNS override, or for the server the DoH template names — the operator's servers
  speak no DoH. Each server uses the template Windows knows for it, or the template the settings
  give, which then applies to every server of the override; a server with neither is a settings
  problem. It is set **per
  interface** (`SetInterfaceDnsSettings` with `DNS_INTERFACE_SETTINGS3` and
  `DnsServerDohProperty`), never per server address system-wide
  (`Set-DnsClientDohServerAddress -AutoUpgrade`), which would change every adapter using that
  address. The pass re-applies it like the servers — on the new adapter a re-enumerated modem
  brings, too — and removes it when the setting is turned off. **No fallback to plain DNS**: who
  turns encryption on wants no query in the clear; the health checks don't notice a DoH failure,
  since H7 probes by address, not by name. The window shows whether it is on. No DoT.
  - **How** (`Resolve-AdapterConfiguration`, `Set-InterfaceDoh`; `AT-COMMANDS.md` §11.1): each
    family's servers are set together with their DoH properties in one `SetInterfaceDnsSettings`
    call — never first in the clear —, each with `DNS_DOH_SERVER_SETTINGS_ENABLE` and its template,
    the one Windows knows read from its list (`Get-DohKnownServer`); never Windows' automatic
    template, never `FALLBACK_TO_UDP`. What the interface carries is read back with
    `GetInterfaceDnsSettings` and compared at every pass: a server without encryption, with another
    template or allowed to fall back is set again. The comparison is with the interface's
    **static** servers, which that read gives — never the IPv6 ones Windows lists on its own, nor a
    DHCP server's. **A family the servers leave out keeps no static server**: the operator's IPv6
    server beside an IPv4 override would answer in the clear; every server goes, encrypted or not
    (`Set-DnsClientServerAddress -ResetServerAddresses`) — never first stripped of its encryption,
    which a failed reset would leave in the clear — and the wanted ones are set again, encrypted,
    at once. Turned off, the DoH properties come off first, then the servers change as usual. A
    read Windows refuses for one family is **not read**, never "no DoH": encryption is left as it
    is at that pass and nothing is blocked; turned off, the servers are still set, compared with
    the ones Windows lists. Only a missing function means a Windows without it. Its list of known
    templates failing to read doesn't stop the pass either: a server with no template given keeps
    the one the adapter already encrypts it with; with none, encryption is left as it is until the
    list reads. Either way the log says so once. **IPv6 servers the network gives** — from router
    advertisements or DHCPv6: listed by Windows, neither static nor its own `fec0` ones — are out
    of a reset's reach, and Windows may query them in the clear: the window's DNS line names them
    and the log says how many, once (decided 2026-10-03). Nothing is blocked for them: a network
    that gives IPv6 DNS servers usually gives IPv6 too, which works without the app.
  - **A server named by its template** (decided 2026-10-03): without the override, the template's
    host is the server — Windows binds encryption to an address, never to a name
    (`AT-COMMANDS.md` §11.1). A host that is an address is that server. A name is looked up by
    the worker (`Resolve-DohServer`, `Update-WorkerDohName`): when it starts, then every
    `DohRefreshMinutes` (60 by default, 5 to 1440), and at the pass cadence (30 s) while a lookup
    fails, the last addresses kept meanwhile; the pass sets new addresses at once. A lookup is
    never waited on for more than 2 s at a time, and gives up after 15 s; while it runs, the worker
    looks for its answer once a second, as for the update check. Until the name has
    addresses, the servers the adapter already encrypts with that template count as the last ones
    — Windows keeps them across restarts —, and with none the adapter is configured with **no DNS
    server at all** (the operator's, in the clear, are taken off), so the connection is up and
    only names wait; an adapter the modem's DHCP configured is left alone and waits
    (`DohServerUnresolved`, blocked).
  - **The one query in the clear, declared.** The name is looked up through Windows, as any name
    — on every interface, over the encrypted server itself while it answers. When Windows can't —
    the server moved and the modem alone carries traffic, or nothing is set yet —, the app asks
    the operator's DNS servers for the context (the `+CGCONTRDP` ones) for that **one name**, over
    UDP **in the clear**, from a socket bound to the modem's address, so it leaves through the
    modem (Windows' strong host model). It reveals which resolver the user has, never what they
    look up. The query has a random ID and source port, and an answer counts only from a server
    asked, with that ID and that question (RFC 5452). The window and the log say when a lookup
    went that way.
  - **What it can't set, it doesn't configure.** Encrypted DNS without any server, on a Windows
    without the per-interface API, or with a server that has no template known or given: the plan
    holds no change at all — the adapter isn't configured, so no query goes through it in the clear
    — and the connection waits for the user (`DohNeedsServers`, `DohUnavailable`,
    `DohTemplateMissing`, blocked: no recovery step mends a setting). The window says why and opens
    the settings; its own check refuses to save such settings in the first place.
  - **Windows 10 has no per-interface DoH** (`AT-COMMANDS.md` §11.1, from Microsoft's
    documentation; not tried on a Windows 10 computer). Whether a Windows has it is read, not
    assumed from a build number: the DnsClient module's DoH cmdlets and the version-3 read of the
    adapter's settings. Where it is missing, the window greys the setting out and says why; a
    settings file that turns it on anyway blocks the adapter's configuration as above.
- **A disabled adapter is the user's choice**: the pass stops there (`AdapterDisabled`, blocked)
  and changes nothing on it; the window offers to enable it again (administrator rights), never
  the app by itself (decided 2026-10-01).
- Every change is **scoped to the modem's adapter** and idempotent.

## Tray icon (M3)

What it shows is decided by pure functions of the snapshot (`Resolve-TrayIcon`,
`ConvertTo-TrayText`); icon states and texts decided 2026-10-01. The tray's icon is the signal;
the **app's own icon** — the window's title bar, the taskbar, the Start-menu shortcut — is the
logo's glyph (`assets/logo.html`, its `?icon` variant: the circular arrow around four bars), drawn
from the logo's geometry at every size an icon file needs, no image file in the repository
(`AppIcon.ps1`; decided 2026-10-03).
- Drawn at runtime with `System.Drawing` at the size Windows asks for: four signal bars, a color
  for the state, and the technology label (`5G`, `4G`) where it is legible — 24 pixels and up; at
  16 pixels (100 % scaling) the bars alone.
- **Tones**: green online; amber on its way; red when the user must act (a PIN, an APN, an FCC
  lock, a disabled adapter, a function Windows wouldn't put on WinUSB…); grey with no modem, or
  while the worker restarts or doesn't answer (a restart touches no connection).
- **Recovering** (M4, decided 2026-10-02): amber, headline *Recovering*, while a recovery step
  settles or the next cycle is awaited — the text says the step (*Restarting the data
  connection.*) or what fails and when the steps start again; a modem off USB during its reset is
  recovering, not missing. Once the cycles have run out, at the slow cadence: red, *Connection
  lost*, with the time of the next try. Back online, the window notes the step that brought it
  back (*Recovered at 14:02: …*) until health has held. Observing only, the window names the step
  it withholds.
- **Bars** from the serving RSRP (the LTE anchor's; the NR cell's on 5G SA): from −115, −105, −95
  and −85 dBm up, one to four; all empty when nothing is measured.
- **5G is the NR leg in use**: an NR serving cell in `+GTCCINFO`. Idle on an LTE anchor the modem
  measures NR all the same (`AT-COMMANDS.md` §3): that is "LTE, 5G available" in the window and
  4G in the tray. No technology at all while the operator read says the modem is not registered:
  in NR-only mode without a 5G SA network of its own, the FM350 lists another operator's NR cell
  as serving (`AT-COMMANDS.md` §4.1).
- **Redrawn only when what it shows changes**, and the previous icon's handle is released with
  `DestroyIcon` once the new one is set. Without that, a GDI handle leaks at every refresh and the
  process dies after days; a test counts the process's GDI and USER objects over hundreds of
  redraws.
- Tooltip, 127 characters at most: online, the technology, the operator, the RSRP; otherwise why
  not, in a few words; on a second line the data used today and in the cycle, against the quota
  when there is one (M8) — the first line is cut to make room. **Notifications** (M8,
  `Get-TrayNotice`): new messages — how many, the newest one's sender, never the text; a click
  opens the *Messages* tab — and a quota threshold, each once, **with the app's icon in them**
  (`Show-TrayNotice`): Windows heads them with the PowerShell that hosts the app, whatever
  identity the process or a shortcut carries (`AT-COMMANDS.md` §11.2), so the icon goes in the
  notification itself; where Windows takes none, the standard one. Each is shown once: the snapshot's announcement Ids
  carry over to the next worker, so a restart repeats nothing, and a notice the tray can't show
  yet waits for the next change. Menu: a newer release, only when there is one (M7, *Updates*) — its page —,
  *Open*, *Check now* (a connect pass now), *Network mode* — the modes the modem supports, its own
  checked, a click tries another one, the bands as the settings have them (M5) —, *Exit*. The menu
  is filled from the latest snapshot as it opens. A left click opens the window.
- **No network** (M5, decided 2026-10-03): red, while a network mode the user narrowed finds no
  network past H4's grace time (*Modes and bands*).

## Main window (M3)

A WPF window (`MainWindow.xaml`), filled from a pure view of the snapshot (`ConvertTo-WindowView`);
closing it hides it — the app stays in the tray. Its buttons only queue commands: the outcome
comes back in a later snapshot, so the window never waits on the modem or the system.
- **The connection**, always in view: the state in words, the technology and the operator, the SIM
  in use (M9: its slot, and the eSIM's profile enabled), and what is unusual — development mode,
  observe-only, settings that apply at the next connection.
- **What blocks it, with the action that unblocks it**: an APN to give (`ApnNeeded`), the APN
  password to give again (`ApnPasswordUnreadable`), the PIN (`NoPin` and the like), *Enable
  adapter* for an adapter the user disabled (administrator rights; never done by the app on its
  own), *Unlock…* for an FCC-locked modem, *Open the settings* for encrypted DNS that can't be set (M7), *Open
  eSIM* for an eSIM with no profile enabled (M9). What
  the app can't act on — a PUK, no SIM, the last PIN attempt — is said, with nothing to click.
- **What changes something outside the app asks first**: the FCC unlock (it writes the modem's
  non-volatile memory and lifts the laptop maker's restriction), removing the PIN from the SIM (it
  changes the SIM, in any phone too). The eSIM's own (M9) are in *eSIM*. Putting the modem's
  functions on WinUSB asks nothing: it is the app's way of working (*USB functions and WinUSB*).
- **Tabs**: *Signal* — LTE and NR quality, serving and neighbour cells, carrier aggregation
  (uplink values only for a carrier that carries uplink); *SIM* — *Use the physical SIM (slot 1)…*
  (M9, *eSIM*), its state and attempts left, the stored PIN (store, forget), removing the PIN from
  the SIM; *Network* (M5) — the modem's mode and bands as read, the mode to keep (or *As the modem
  has it*), a checkbox per band the modem supports with *every band* per RAT, *Apply*, and how the
  last choice went (on trial until when, kept, undone, bands the modem leaves out); *Connection* —
  the settings — the APN ones the SIM in use's, which the tab says above them and keeps closed
  while no SIM is identified (*Settings and logs*) —, checked as typed with
  the same validation the worker applies, and encrypted DNS against what the snapshot says Windows
  can do — the servers it knows a template for, whether it has the per-interface API —; whether
  the adapter's DNS is encrypted now, and for which servers; saving them never changes the network
  mode; *USB* (M10) — the modem's vendor functions, the driver of each, the last time they were
  put on WinUSB (*USB functions and WinUSB*); *eSIM* (M9, *eSIM*).
  The footer says the app's version. Tabs whose content may outgrow the window — *SIM*,
  *Connection*, *USB*, *eSIM* — scroll; the outcome and the footer wrap beside *Check now*, never
  under it.
- **Its own on the taskbar** (decided 2026-10-03): the window and the Start-menu shortcut carry
  one AppUserModelID, `FibocomFm350Gl.WindowsGui` (`AppIdentity.ps1`; development mode its own).
  Without it the window takes the identity of the PowerShell that hosts it — an MSIX package's,
  icon included —; with it, the taskbar shows the shortcut's icon and name, and pinning the
  window pins the shortcut, which starts the app through its *Open* task, without a UAC prompt
  (`AT-COMMANDS.md` §11.2). The window's ID is removed before it closes, as Windows requires; a
  failure to set or remove it leaves the window working, with PowerShell's identity.

### Languages (M7)

Decided 2026-10-03: the app speaks English, Italian, German, French, Spanish, Portuguese, Dutch
and Polish — **everything the user reads**: the window and its dialogs, the tray, the blockers,
the installer and the launcher. The **log stays in English**: it serves reports and diagnosis.
- **Windows' display language decides**, with no setting: `CurrentUICulture`, or its parent
  (`it-CH` → Italian, `pt-BR` → Portuguese), when the app has it; English otherwise
  (`Resolve-AppLanguage`). Chosen when the app starts (`Set-AppLanguage`); a language changed in
  Windows applies at the next start. Until then, and in the tests, English.
- **One table per language** — `App\Strings\<language>.psd1`, `Installer\Strings\<language>.psd1`
  —, English the complete one and the fallback of a key a language lacks; a table that can't be
  read is English, never a failure. Texts are templates with placeholders `{0}`, `{1}`… filled in
  the invariant culture, like every number the app writes. A sentence that follows a colon has a
  form of its own (`ActionInline.*`, `StepInline.*`): lower-casing a first letter is right in
  English, wrong for a German noun. The app's tables hold more than the 500 keys PowerShell
  takes from a data file by default: they are read with `-SkipLimitCheck` — the app's own files,
  where only administrators write.
- **Codes travel, texts don't.** The worker publishes codes — reasons, results, checks, steps, a
  setting's broken rule with its values (`ConvertTo-AppSetting`'s `Issues`) —, and the window
  turns them into words; the English sentences the log writes are made apart, in the core module.
  A combo box's value is its `Tag`, never the text it shows.
- The window's XAML holds `[[Key]]` tokens, replaced before it is read (`ConvertTo-LocalizedXaml`).
  The launcher, in Windows PowerShell 5.1, reads the installer's tables: every table is UTF-8 with
  a byte order mark, without which 5.1 reads the ANSI code page.
- Tests prove every table has English's keys and placeholders, that every key the code and the
  XAML name exists and every English key is used, and show each language on every simulated
  scenario and in the window with no key missing.

## USB functions and WinUSB (M10)

The modem's AT port is one of its USB functions, of vendor class `ff/00/00`, which Windows' own
serial driver doesn't claim ([`AT-COMMANDS.md` §1](AT-COMMANDS.md#1-usb-identity)). Up to 1.x the
app needed MediaTek's serial driver for it, which has no license to be redistributed: the user
brought it, and the app checked and installed it (M6, *bring your own driver*). From 2.0 the app
puts the modem's vendor functions on **WinUSB**, the generic USB driver that comes with Windows,
and talks to the AT function through its two bulk pipes (§1.2): nothing for the user to find,
download or install, no package added to the driver store, nothing to sign — and no driver in the
way of Windows on Arm64. Decided 2026-10-04 (`DEVLOG.md`): **WinUSB only**, also where MediaTek's
driver is installed; **every vendor function**, never the network one; **by the worker**, by
itself. The network function stays on Windows' RNDIS driver, as before.

1. **Read** the modem's USB functions by hardware ID and classify them. A modem is the composite
   device its functions hang from — not their container ID, which a device on a port the firmware
   calls non-removable inherits from the computer and shares with everything built in. For the
   same reason the network adapter is found by its own instance ID (the adapter's `PnPDeviceID`).
   Instance IDs are not remembered across runs: the FM350's is generated from the USB port it sits
   in. Reading is the thin part (`Get-ModemPnpRecord`, in the worker): one `Get-PnpDeviceProperty`
   call per device with every key, given the device object — about 50 ms; given an instance ID,
   about a second; never several devices in one call, which then sometimes labels one device's
   properties with another's instance ID —, plus the device's registry parameters: its COM port
   (`PortName`) and its device interface classes (`DeviceInterfaceGUIDs`). The classification is
   a pure function (`Resolve-ModemUsbDevice`): each function's role (the AT port, the network
   function, another), what it is (MediaTek's INF names them: AP log, GNSS, AP META, MD AT, MD
   META, NPT, debug), whether it is a **vendor function** — the AT port, and every function whose
   compatible IDs name class `ff/00/00` —, whether its driver is WinUSB, and its state: working;
   without a driver (problem code 28 or 1, or none and a service read as none); another problem.
2. **Choose the modem** (`Resolve-ModemPresence`, pure, at every look): the first by instance ID
   whose AT port works on WinUSB with the app's interface class — *Present*; one whose PnP read
   failed counts too, the opening of its interface tells, as a COM port's opening did —, else the
   first with an AT port: *Unbound* when its AT port is on another driver, on none, or on WinUSB without the
   app's class; *Problem* when the user disabled it (problem code 22) or it has a problem on
   WinUSB, which another installation wouldn't mend.
3. **Decide** which functions go on WinUSB now (`Resolve-ModemBinding`, pure): the chosen modem's
   vendor functions on another driver or none — so that none stands as an unknown device in
   Device Manager —, and the AT port also on WinUSB without the app's interface class; the AT
   port first. Never the network function, nor a function that is not a vendor one (ADB, which
   Windows puts on WinUSB itself). Left as they are: a function that couldn't be read — its service
   or its registry parameters, which a PnP read now and then misses: never taken for one on another
   driver, it is looked at again next time —; a function the user disabled; one with a
   problem on WinUSB; one whose installation failed already — **tried once per instance**, again
   at the app's next start, at a new instance, or when the user asks to check now (decided
   2026-10-04), and when the modem comes back after it left USB — unplugged, reset, its SIM taken
   out —, whichever of its instances it comes back as (decided 2026-10-05: it alternates between
   two) — not again by a worker that replaces another: the snapshot carries the failed
   instances to it as hashes (SHA-256), never their IDs.
4. **Put them on WinUSB** (`Install-WinUsbDriver`, in the worker, with administrator rights):
   - **Never under another program.** A function whose COM port or device interface another
     program holds is left on its driver: each is opened for an instant, exclusively, nothing read
     or written (`Test-UsbFunctionFree`) — its COM port, and the interfaces of every class its
     `DeviceInterfaceGUIDs` name (WinUSB's, or another program's: a function another tool put on
     WinUSB) —; Windows answers a port held with `ERROR_BUSY` on MediaTek's driver, with
     `ERROR_ACCESS_DENIED` on WinUSB (`AT-COMMANDS.md` §2, §1.2). A port held is said — for the AT port, *another program is using
     the modem's AT port*, as before — and looked at again at the next look (decided 2026-10-04).
   - **As Device Manager does when a driver is picked by hand** (`AT-COMMANDS.md` §1.2): for the
     AT function, the app's device interface class `{4FDE9624-2286-4DC0-9D07-601A3922581A}`
     added to its `DeviceInterfaceGUIDs` first, keeping any other there, so that its interface is
     there at once; the function's class set to `USBDevice`; Windows' own `winusb.inf`, from the
     Windows folder, its generic model chosen by its hardware ID `USB\MS_COMP_WINUSB` — never by
     its name, which is localized —; `DiInstallDevice` with no window. Nothing is staged in the
     driver store. A failure after the class changed gives the function back to its best driver,
     and takes the interface class back out.
   - On a thread of the pool, the worker waiting for it a second at a time, its heartbeat beating;
     given up after 5 minutes, as pnputil was. An installation that hangs holds Windows' others:
     after one that timed out, the rest of that look's aren't started — failed as it did, each
     tried again as one —, so the worker waits 5 minutes at most, not 5 for each function. The
     uninstallation's way back does the same.
   - **Never the network function** — refused by the decision, by the command's parameter check
     and by the C# that calls Windows —, and never a modem reset.
   - **Never an open port taken away**: the AT port is put on WinUSB only when it isn't usable
     there, so the app holds no port on it — and the function whose port the worker holds is left
     out of every decision, whatever a PnP read says of it. A network mode on trial isn't cut by it; its port comes
     back by it.
   - Once the AT port is on WinUSB, a **maintenance window** as long as R6's settle time: a port
     just started may stay silent for minutes (`AT-COMMANDS.md` §2).
   - A function that comes back as a **new device instance** — another USB port, a re-enumeration
     — has its old driver again (MediaTek's, when it is in the driver store, or none) and is put
     on WinUSB again: an intended operation, never a failed health check. Until then the check
     failing is H1, whose ladder is empty: nothing escalates.
   - **What stops it is said**, never escalated (*Connection state machine*): the installation
     failed (`BindFailed`), Windows finishes it at the next restart (`BindRestartNeeded`), no
     administrator rights (`BindNotElevated`), another program holds the port (`PortInUse`). In
     observe-only mode the step is named and withheld.
5. **Open the AT port** (`Get-WinUsbInterfacePath`, `Open-WinUsbAtTransport`): its interface in
   the app's class, found for its instance ID by `CM_Get_Device_Interface_List` — a path never
   shown nor logged —, then its bulk pair (*AT channel*). The window, the tooltip and the log say
   WinUSB where they named a COM port.
6. **The way back** (`Restore-UsbFunctionDriver`): the app's interface class taken out of the
   function's `DeviceInterfaceGUIDs`, then `DiInstallDevice` with no driver named — the best match
   in the driver store, MediaTek's serial driver when it is there —; with none — Windows answering
   *no compatible driver* or *no driver selected*, and only then —, a null driver: the function as
   Windows leaves one it found no driver for. Any other failure is said, the function left on its
   driver. The uninstallation does it for every vendor function on `winusb.inf` of every FM350
   plugged in, reading PnP again once when a read missed one — each device as the read that had it
   whole (`Join-ModemPnpRecord`), the first read alone when the second fails —, and saying one
   still missed, left as it is, plugged in or not: its driver is unknown. Those of an FM350 not plugged in,
   which Windows remembers on WinUSB, it removes from Windows (`Select-AbsentWinUsbFunction`,
   `Remove-AbsentUsbFunction`: `DiUninstallDevice`), so that their driver is chosen afresh when
   the modem comes back — never the network function, never ADB, never a device plugged in, which
   the C# checks with `CM_Locate_DevNode` (*Installing and updating*, M10).
7. **The USB tab** (decided 2026-10-04): the state, with nothing to click — the app puts the
   functions on WinUSB by itself, and *Check now* tries again what failed: each vendor function
   with its driver (WinUSB, another, none) and its problem code, and the last time the app put
   functions on WinUSB, when and how it went for each.

The facts of MediaTek's serial driver — what M6 checked before installing it — stay in
`AT-COMMANDS.md` §1.1, for the record: they say why a COM port needed a driver the user had to
bring.

## eSIM (M9)

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

- **lpac never touches the AT port, nor the network.** Its `stdio` APDU backend hands every APDU to
  the worker, which carries it with `AT+CCHO`/`AT+CGLA`/`AT+CCHC` on the port it already owns
  (invariant 1); its `stdio` HTTP backend hands every request for the SM-DP+ to the worker, which
  makes it over HTTPS with .NET (decided 2026-10-04). lpac's own `curl` backend checks no
  certificate, and would have the elevated app ship and run an old `libcurl.dll` with its TLS
  library (`AT-COMMANDS.md` §8).
- **The SM-DP+'s certificate is checked** (`FibocomFm350.EsimHttp`, C# compiled at run time: a TLS
  callback runs on a thread with no runspace). Taken when Windows trusts it; otherwise only when
  it names the host and its chain ends at the GSMA's root CI, the one that issues SM-DP+
  certificates and that our eUICC trusts (`Data/GsmaRsp2RootCi1.pem`, from two sources,
  `AT-COMMANDS.md` §8) — as ChromeOS's LPA does. Revocation is not checked against that root:
  its list is an offline CA's. A request is checked first (`Resolve-LpacHttpRequest`): a `POST` to
  `https://<host>/gsma/rsp2/es9plus/<function>` — a host name, no port, one of the five ES9+
  functions lpac calls — with lpac's three headers, or it is never sent. No cookie, no redirect
  followed, the answer at most 8 MB, the run's time limit for each request.
- **The bridge is a translation** — lpac request → AT command, AT answer → lpac answer — written
  as pure functions with a matrix of tests (`Resolve-LpacApduRequest`, `Resolve-LpacApduAnswer`,
  `ConvertFrom-LpacLine`, `ConvertTo-LpacAnswerLine`), and a thin loop around them
  (`Invoke-LpacOperation`) that takes any AT channel, whatever transport is under it:
  - `connect` and `disconnect` are answered at once: the port is the worker's, open already.
  - `logic_channel_open` is `AT+CCHO`; the modem's session ID gets a channel number of the
    bridge's — the lowest free from 1 —, which lpac writes into each request's class byte. The
    modem routes by the session ID whatever the class byte says (`AT-COMMANDS.md` §8), so
    `transmit` goes as `AT+CGLA` on the channel the class byte names, or on the only one open.
  - `logic_channel_close` is `AT+CCHC` for a channel the bridge opened. An error in answer is a
    channel the SIM closed already: **a profile switch resets the SIM**, and the logical channels
    with it. Channels left open — lpac stopped, a close unanswered — are closed at the end of the
    run.
  - Every request gets one answer line: lpac reads one per request. A request for the network
    that fails its check, or on the way, is answered with no status — lpac reads it as the
    server's error —, and the run says why, with the host.
  - A run ends with lpac's output, at its time limit (lpac stopped), on a lost port, or when the
    worker is ending — asked at every beat; a request for the network under way is given up —:
    the app waits 5 s for its worker, and a channel left open would stay so until the SIM resets.
    No run starts once the worker is ending. The loop owns the process from its start and
    disposes it, its redirected streams with it, whatever happens.
- **lpac runs with the app's settings, nothing else of its own**: `LPAC_APDU=stdio` and
  `LPAC_HTTP=stdio` are named, and lpac's and its library's other variables are taken out of the
  environment it inherits — the user's environment reaches the elevated
  app's children, and a variable could name another backend (one opens a COM port itself),
  another ISD-R, or debug output carrying the APDUs. Its arguments are passed one by one, never
  joined into a command line; no window. **Its path is named in one place** (`Get-LpacPath`):
  the `lpac` folder beside the app's modules, under Program Files (invariant 10), the build of
  the Windows it runs on — `x64` or `arm64` (M10) —, native whatever PowerShell runs the app. No
  setting names it.
- **lpac's command lines** (`Get-LpacArgument`, pure): `chip info`; `profile list`; `profile
  enable|disable <AID> 1` — the refresh flag always given: lpac's code defaults to none, and the
  modem resets the SIM only on the refresh —; `profile nickname <ICCID>`; `profile delete <AID>`;
  `profile download -a <activation code> [-c <confirmation code>]`, never `-p` (a preview read
  from standard input, which the APDUs use) nor `-i` (the IMEI); `notification list`;
  `notification process -a -r`. `chip purge` has no operation.
- **The SIM slot in use** (`AT+GTDUALSIM?`) and the kind of SIM in it (`AT+SIMTYPE?`) are read
  once per port, after a switch, and when the user asks to read the eSIM again; a read the modem
  leaves unanswered is tried again at the next pass. lpac reaches the eUICC only while its slot
  is the one in use.
- **The eUICC is read** — `chip info`, `profile list`, `notification list` — when it is the SIM in
  use, its SIM ready or with no profile enabled (never while it resets), and a read is due: on the
  first port, after an eSIM command, at the user's request, and when the connection comes back
  online with notifications waiting.
- **Notifications are processed automatically**: each read sends what the eUICC holds, each to
  its server, then removes it from the eUICC — never in observe-only mode. What can't be sent (no
  internet yet, through a profile just enabled) stays for the next read.
- **Commands** (`Send-ModemCommand`): read the eSIM again, select the slot, enable, disable,
  nickname, delete — a profile by its ISD-P AID —, download. Refused in observe-only mode
  (reading excepted), while the eUICC's slot is not the one in use (`NotEuicc`), without lpac
  (`NoLpac`), and for a switch while a network mode is on trial (`TrialOn`): its undoing needs the
  registration the switch drops. A profile enabled is never deleted (`ProfileEnabled`). The
  activation and confirmation codes travel as `SecureString`s, are checked first
  (`ConvertFrom-EsimActivationCode`), and are never logged nor shown back.
- **Switching** the SIM slot (`AT+GTDUALSIM`) or the enabled profile disrupts the link, so it runs
  inside a **maintenance window** (see *Maintenance windows*) — also when the switch's answer is
  lost or lpac's run fails: a slot write left unanswered, like a network mode's, may have landed,
  and an APDU answered too late fails lpac's run, not the eUICC's switch; the slot is then read
  again. The slot setting is **persistent**
  modem state (`AT-COMMANDS.md` §4): the app writes it only after a confirmation saying that the
  choice stays in the modem across restarts, and always shows the active slot.
- **An eUICC with no profile enabled** (`+CPIN: EMPTY_EUICC`) is a SIM state of its own,
  `NoProfile`: blocked, never escalated — no reset enables a profile; the user does.
- **Identifiers:** the ICCIDs stay in the worker; a snapshot carries the profiles' ISD-P AIDs,
  providers, names, nicknames, classes and states, and the EID, which the window shows with
  *Copy* (decided 2026-10-04: providers ask for it to sell a plan) — never the log nor the tooltip.
  The log redacts `AT+CGLA`'s APDUs, in a command and in its answer, and activation codes; an eSIM
  command's failure is logged by the step that failed and lpac's reason.
- **What lpac's command line carries** (decided 2026-10-04): the activation code, its confirmation
  code and, to set a nickname, the profile's ICCID — lpac `2.2.1` takes them nowhere else
  (`AT-COMMANDS.md` §8). The app's log never has them; but for the seconds lpac runs, whatever
  records processes' command lines sees them — an administrator's tools, Windows' process-creation
  auditing where a policy turns it on with command lines, Sysmon, an EDR agent: on a computer an IT
  department manages, its IT department. Said in the README and the release notes. A later lpac
  that reads them from its standard input would take them off the command line.
- **Development mode** (`-Scenario EsimEmpty`, `Esim`): the simulated modem has two slots, as our
  module has them — the physical SIM, and an eUICC holding a test profile (`SimulatedEuicc`): its
  logical channels, the STORE DATA requests that change it told by their tag, the SIM reset after
  a switch. A simulated lpac (`SimulatedLpac`) speaks lpac's `stdio` protocol for one operation
  and gives lpac's result from what the eUICC holds. Nothing of the eSIM ships proven on it alone
  (decided 2026-10-03). **The programs the zip bundles run in the tests**: CI builds the zip before
  them, and `Bundled.Tests.ps1` runs its lpac through the bridge against the simulated eUICC —
  enable, disable, nickname, delete; the test that would have caught `2.3.0` — and reads QR codes
  with its ZXing.Net.
- **lpac ships with the app.** lpac is AGPL-3.0, so unlike the modem driver it may be
  redistributed. **Version `2.2.1`** (decided 2026-10-04): `2.3.0`'s `stdio` backend doesn't work
  (`AT-COMMANDS.md` §8). The release workflow downloads the pinned version from lpac's official
  GitHub release (`tools/Lpac.psd1`), checks the SHA-256 of each file — the one computed at the
  first download, GitHub listing none for that release —, and puts the files the pin lists of each
  of its Windows builds, x64 and Arm64 (M10), in the zip's `lpac\x64` and `lpac\arm64` folders —
  `lpac.exe`, its README and licenses; not `libcurl.dll`, which the app doesn't use — with
  `SOURCE.txt`, which says where the source is; lpac's source archive for the
  same tag is attached to the GitHub Release as the corresponding source. The binaries are never
  committed to git; a `lpac` folder in `src/` is never packaged.
- **The window's *eSIM* tab** (decided 2026-10-04): the SIM in use — also in the top panel — and
  *Use the eSIM (slot 2)…*, whose twin *Use the physical SIM (slot 1)…* is on the *SIM* tab: the
  two exclude each other — the one whose SIM is in use says *In use* and is off —, and both tabs
  say, in the same words, that the modem uses one SIM at a time and that a switch drops the
  connection for a moment. The physical SIM in slot 1 and the eUICC in slot 2, as on the FM350-GL
  (`AT-COMMANDS.md` §8); the EID with *Copy*; the chip's facts and the notifications waiting; the profiles,
  the enabled one in bold, with *Enable…*, *Disable…*, *Delete…* and a nickname to *Rename*; *Read
  again*; *Download a profile* from an activation code typed or read from the image of its QR code,
  with a confirmation code. Slots are counted from 1, as the modem names them (`SUB1`, `SUB2`).
  What changes the modem asks first: a slot switch — *No* preselected — says that the modem keeps
  it, that the connection drops, and that an eSIM with no profile enabled has no network; enabling
  or disabling a profile says that the SIM restarts; deleting one names it, says it can't be undone
  and that the provider must give a new code, and **takes its name typed** (case and blanks aside).
  A download asks nothing: the tab says the EID reaches the provider's server. The codes are typed
  in password boxes and travel as `SecureString`s. **One command at a time**: the tab's buttons
  wait for the outcome of the one sent, or for another worker. No Windows notification: the outcomes
  are in the window, where the user started them.
- **A QR code read from an image** (decided 2026-10-04): the window passes the image's path, and the
  worker reads it when the download starts (`Read-QrCode`) — the code never passes through the
  window nor a snapshot, and no decoding runs on the UI thread. A file of at most 20 MB and 50
  megapixels, drawn at most 2000 pixels on its longer side, QR codes only, trying hard. The reader
  is **ZXing.Net** (Apache-2.0), bundled like lpac: `tools/ZXing.psd1` pins its nuget.org package
  by SHA-256 — its library for .NET 9 goes in the zip's `zxing` folder, with the license at the
  release's tag, which the package doesn't carry (`AT-COMMANDS.md` §8). Its path is named in one
  place (`Get-ZxingPath`), under Program Files; it is loaded the first time a code is read.

## SMS, USSD and data usage (M8)

What a prepaid or capped SIM needs day to day (facts: `AT-COMMANDS.md` §9).

### SMS
- **PDU mode only.** Text mode depends on the modem's character-set setting and hides the header
  that ties the parts of a long message together; a PDU carries everything, and its format is a
  public standard (3GPP TS 23.040, alphabets in TS 23.038). Decoding and encoding are **pure
  functions** with a matrix of tests (`Sms.ps1`): GSM 7-bit with its extension table, UCS-2, long
  messages reassembled from their parts, long messages split for sending.
- **What the codec does with the edges.** A PDU that can't be read is still listed, as malformed,
  so it can be deleted. 8-bit data and compressed text have no text to show, and say so. A silent
  message (*short message type 0*: never to be shown) is listed by its sender and time alone —
  marked, never new, never announced —, since a modem that stores it gives it a place only deleting
  frees (decided 2026-10-04). A message
  that names a national language table is read with the default tables and flagged: the tables
  of 23.038 annex A are not carried. UCS2 is read and written as UTF-16, so the emoji that phones
  send in surrogate pairs come out whole, and a pair is never split between two parts. Sending:
  GSM 7-bit when the alphabet holds every character, else UCS2; the SIM's service centre; no
  validity period (the centre's own); parts joined by a one-octet reference.
- **Which SIM** (decided 2026-10-04): the modem uses one SIM at a time, so a message goes out from
  the SIM in use, and the list is what the modem stores for the slot in use — each slot has a
  storage of its own, and on the eUICC's slot the profiles share part of it (`AT-COMMANDS.md` §9).
  The *Messages* tab names the SIM in use above the list, and says by *Send* that the message goes
  out from it and where to put the other one in use.
- **Each message by the SIM it came in on** (decided 2026-10-04). A stored message carries no trace
  of the SIM that received it, so the app remembers it: a part listed unread came in since the
  storage was last read, on the SIM in use — the only one registered —, and is noted with that SIM
  (told as for its APN settings: the SHA-256 of its ICCID), the kind of SIM and an eSIM profile's
  name, in one file encrypted with DPAPI for the user — fingerprints and a name, no text, no
  number; the newest 1000 parts. Before the app changes the SIM in use — a slot switched, a profile
  enabled or disabled — the storage is checked, so what came in on it is not told as the next one's.
  Whenever a pass finds another SIM in use — the app's switch, a SIM swapped, a profile switched by
  another program —, the list is emptied and read again whole. On a profile, the
  messages that came in on **another profile still on the eUICC are not listed**: the tab says how
  many, and they show — and can be deleted — when that profile is in use. A message that came in on
  a SIM not there now (a deleted profile, another physical SIM), or not known to be there (the
  eUICC's profiles not read), is listed with a note naming that SIM: a deleted profile by its name
  as it was last. A part already read when the app first saw it, or one that came in while the SIM
  in use couldn't be identified, has no SIM known and shows with every SIM. A new message hidden is
  not counted as new.
- **The modem stores, then announces.** Once the SIM is ready on a newly opened port, the worker
  sets `AT+CNMI=2,1,0,0,0`, so that a new message is saved on the modem and announced with
  `+CMTI: <storage>,<index>` — on the MD AT port, data up or not (`AT-COMMANDS.md` §9). Notices start
  off (`0,0,0,0,0`), and a message that comes while they are off is stored silently, so the inbox
  is read whole when the worker sets them, not only on a notice. The app selects no storage: the
  FM350 offers `"SM"` alone to `+CPMS=`, which its notices name already. Direct delivery
  (`+CMT`) is never used: it hands the message to the port without storing it, so one arriving
  while the app is closed or its worker is restarting would be lost, and it must be acknowledged
  within 15 s or the modem sends it again.
- **The AT channel routes the notices.** `+CMTI` is an unsolicited result code: it can arrive at
  any time, in the middle of another command's response too (M1 separates them). The worker reads
  the new message and publishes it in the next snapshot; the UI shows a tray notification.
- **Messages stay on the modem.** The inbox is read from the modem's storage when the notices are
  set and on each notice; delete acts there. The app keeps no copy on disk. A full storage is
  shown in the UI, since new messages can't be stored.
- **Sending, part by part.** Each part is one `AT+CMGS`: its length, the modem's `> ` prompt, the
  PDU and Ctrl-Z (`Send-AtMessagePdu`). The modem picks each part's message reference itself, so
  the app sends `0`. A part refused or unanswered ends the message there, and the UI says how many
  parts went out; the app never sends a part again by itself — an unanswered part may have gone
  out, and each part costs. Sent messages are not stored on the modem.
- **The worker owns them, as it owns the port** (`Update-WorkerInbox`). It sets the notices once
  the SIM is ready on a newly opened port, and lists the storage whole (`AT+CMGL=4`) then, on a
  `+CMTI`, after a command, and when a pass finds the storage's count changed — a message stored
  without a notice is found that way. A step the modem refuses, or one that fails, is logged
  once — by the modem's answer or the error's type — and tried again after the next pass: it
  never stops the cycle. A listing cut short has marked what it listed read, so its unread parts
  are kept new. A lost port forgets the messages; the next one sets the notices again.
  **Observe-only mode reads none**: listing marks messages read on the modem.
- **Commands**: open a message (new no more), delete one — the storage is read again first, so
  every part is deleted where it is now —, send one. The number and the text never reach the
  log; a failure's detail gives the error's type only, as its text may hold either.
- **The snapshot** carries the messages without their storage indexes, how full the storage is,
  whether a message is going out, and the last announcement — how many new messages, the newest
  one's sender — with an Id that grows across worker restarts, so a restarted worker never
  announces them again.
- **The window** (decided 2026-10-04): one *Messages* tab — the list, newest first and new ones
  marked, the selected message's text below it, and a box to write one at the bottom, with its
  count of characters and parts — 255 parts at most. Selecting a message opens it: it is new no
  more. Deleting asks for a confirmation every time, *No* preselected. *Send* waits for the
  worker's answer to the message queued, or for another worker: a second click, or a double one,
  sends nothing.
- **What is new is remembered by the message, not its place** (decided 2026-10-04). The modem marks
  a message read as soon as it is listed (`AT-COMMANDS.md` §9), so a message that comes in unread
  is noted at once and stays new until the user opens it, across app restarts and a modem that
  comes back under another storage index: each of its parts by a fingerprint (SHA-256 of the part's PDU
  as stored, which holds the sender, the time stamp and the text), kept in one file encrypted with DPAPI for
  the user — no text, no number. A fingerprint leaves when its message is opened or deleted, or is
  no longer in the storage — unless the message came in on another SIM than the one in use, whose
  storage is not the one read (*Each message by the SIM it came in on*, above): the file holds at
  most what the storages can and the parts whose SIM is remembered, and is rewritten whole.
- **The tray says who wrote** (decided 2026-10-04): a notification with the sender alone; the text
  only in the window. Windows keeps the sender in its notification history, for the same Windows
  account that can open the window anyway.

### USSD
**Not built.** USSD was planned as best effort — dropped, not emulated, if the FM350 couldn't do
it — and on the device it can't: on LTE the modem accepts `AT+CUSD` and no reply ever comes, with
two SIMs and either way of writing the code (`AT-COMMANDS.md` §9). The facts about `+CUSD` and
USSD's coding stay in §9 for a network or a firmware that answers.

### Data usage
- **Counted on the Windows side.** The modem has no traffic counter (`AT-COMMANDS.md` §10); the
  worker reads the byte counters of the modem's network adapter every 30 s (decided 2026-10-04),
  port open or not (`Update-WorkerUsage`). Reading them never stops the worker's cycle: a failure
  is logged once and the next reading tries again — data usage is no reason to touch the
  connection.
- **Accumulated across resets, as a pure function** (`Update-DataUsage`). The counters restart
  from zero whenever the adapter is re-created (modem reset, device restart, replug). For each
  sample: if the new value is below the previous one, the counter restarted and the new value is
  the delta; otherwise the delta is the difference. Another adapter counts its whole value; the
  very first sample, with nothing before it, only sets where counting starts. What a sample adds
  goes to its local calendar day; the last 100 days are kept.
- **Persisted** under `%LOCALAPPDATA%\fibocom-fm350-gl-windows-gui\usage.json`: at most every
  5 minutes, at once when a quota threshold is said, and when the worker ends (decided
  2026-10-04). A save missed — a crash — loses nothing: the next sample counts from the counters
  last saved. Traffic while the app is closed is still counted at the next start, unless the
  counters were reset in between; at a reset, what came since the last reading (30 s at most) is
  lost: the totals are approximate, and the UI says so.
- **Today and the billing cycle**, whose start day is a setting — day 1 by default, a day the
  month doesn't have meaning its last day (decided 2026-10-04) — (`Measure-DataUsage`). An
  optional quota, in gigabytes, off by default, is said in the tray at **80% and 100%**, each once
  per cycle: a new cycle or another quota starts over, and what was said is kept in the same file,
  so a restart never says it again (`Resolve-UsageWarning`; decided 2026-10-04). **The quota never
  disconnects** — the app does not break a working connection.
- **Shown in a *Data* tab** — today, the cycle with its dates, the quota with its share used, and
  the two settings — and in the tray icon's tooltip (decided 2026-10-04).

### Identifiers
Phone numbers, message text and USSD replies are personal data: never logged, and replaced by fake
values of the same shape in fixtures.

## Settings and logs (M2/M3)

- Settings: a JSON file under `%APPDATA%\fibocom-fm350-gl-windows-gui\`. The elevated scheduled
  task runs as the same user, so the path is the same elevated or not. `Apn` (empty: the
  subscription's own), `PdpType` (`IP` or `IPV4V6`), `ApnAuthentication` (`None`, `PAP`, `CHAP`)
  with `ApnUser` — from 1.2.0 each SIM's own, kept apart (below) —, `DnsServers` (the override;
  empty keeps the operator's) with, from M7,
  `DnsOverHttps` (off by default; on needs the override, or a template that names its server),
  `DohTemplate` (empty: the template Windows knows for each server — *Network configuration*) and
  `DohRefreshMinutes` (60: how often a server the template names by a name is looked up again;
  5 to 1440), `CheckForUpdates` (on: the update
  notice, *Updates*), `InterfaceMetric` (500:
  the modem as a backup), `NetworkMode` (empty: not managed; `Automatic`, `LteOnly`,
  `NrOnly`) with `LteBands` and `NrBands` (empty: every band), and from M8 `UsageCycleDay` (1: the
  day of the month the billing cycle starts on, 1 to 31) and `UsageQuotaGB` (0: none; gigabytes,
  decimals allowed, up to 10000). Read leniently — an invalid value falls back to its default and is
  reported, an unknown one is ignored: a bad file never stops the app — and written strictly: an
  invalid value is refused. The file is replaced whole (a temporary file, then a move).
- Secrets — the SIM PIN, an APN password — never go in the settings file: each is kept
  DPAPI-encrypted for the current user in a file of its own in the same folder (see *SIM PIN*).
  With PAP or CHAP set, **no stored password means an empty one**, which some operators expect;
  a stored password that can't be read (another Windows user, a damaged file) is never replaced by
  an empty one: the pass stops before activating (`ApnPasswordUnreadable`, blocked) and the
  window asks for it again (decided 2026-10-01).
- **Each SIM keeps its own APN settings** (decided 2026-10-04): `Apn`, `PdpType`,
  `ApnAuthentication`, `ApnUser` and the APN password are the SIM in use's — an operator gives
  them together, and a slot switch or an eSIM profile changes the operator. They are kept in
  `sim-settings.json`, an entry per SIM, the SIM told by a SHA-256 of its ICCID — without the
  filler `F`, which the modem's `+ICCID` carries and lpac's list of profiles doesn't —, encrypted
  with DPAPI as the PIN file's is: the file holds no identifier. A SIM's password is in
  `apn-password-<Id>.dat`, named by its entry's random Id. Every pass reads the ICCID once the SIM
  is ready — a SIM can change while the port stays open: a slot switch, a profile, a SIM swapped
  — and connects with that SIM's settings; an ICCID that can't be read leaves the context unknown
  (`ContextUnknown`), no step is taken on it, and the log says so once. A SIM seen for the first
  time connects with the subscription's own APN until the user gives one; the APN settings saved
  before 1.2.0, in `settings.json`, go to the first SIM identified, once — the password file
  copied as it is, so one that can't be read stays so; a `settings.json` that can't be read is
  tried again at the next pass, never taken for one without APN settings —, and `settings.json`
  keeps the defaults from then on. The window shows and saves the SIM in use's: the snapshot
  carries a random token for it — never its fingerprint —, which a save carries back; none is
  saved for a SIM that changed since (`SimChanged`) or with none identified (`NoSim`), and the
  form takes the APN settings again when another SIM is in use. A save that doesn't touch them —
  the *Data* tab's, the *Connection* tab's with no SIM identified — leaves them out. Everything
  is checked before the first write, and the worker reads its settings again after a save, even
  one that failed halfway. A deleted eSIM profile's are forgotten. DNS, the metric, the network
  mode and the rest stay every SIM's.
- Logs: rolling files under `%LOCALAPPDATA%\fibocom-fm350-gl-windows-gui\logs\`, one per day,
  the 14 newest kept, at most 10 MB a day (then one line says so). **Every line is redacted on its
  way in** (`ConvertTo-RedactedText`): no IMEI, IMSI, ICCID, EID, MSISDN or other phone numbers,
  serials, cell identity + TAC, message text, USSD replies — and no secret: the PIN of `AT+CPIN=`
  and `AT+CLCK=`, the credentials of `+CGAUTH`. The file is opened for each line: the log holds no
  handle. The worker writes it; the UI thread only for rare events (start, a worker replaced,
  exit). A log that can't be written (a full disk) never stops the worker or a pass.
- Data usage totals (M8): `usage.json` under `%LOCALAPPDATA%\fibocom-fm350-gl-windows-gui\` —
  the counters last read, bytes per day, the quota thresholds said this cycle (*Data usage*).

## Module layout

```
src/
  FibocomFm350/          core module: no UI; imported by the app and by the tests
    FibocomFm350.psd1
    FibocomFm350.psm1
    Bands.ps1            AT+GTACT band codes (M0)
    AtText.ps1           framing and classifying the lines on the AT port (M1, pure)
    Timeouts.ps1         each command's documented worst case (M2, pure)
    WinUsb.ps1           the Windows calls of WinUSB, CfgMgr32 and SetupAPI, compiled at run time;
                         the AT function's interface, a COM port tried, a function put on WinUSB
                         and given back to its best driver (M10)
    Transport.ps1        the WinUSB transport, and the shape every transport has (M1, M10); the
                         bulk pipes picked (pure)
    SimulatedModem.ps1   the simulated modem: fixtures + scripted faults; fixture import (M1); its network mode (M5);
                         its message storage, notices and sending (M8); its SIM slots and eUICC (M9)
    AtChannel.ps1        the AT channel: commands, answers, unsolicited codes (M1); sending a PDU (M8)
    Measurements.ps1     measurement index -> dBm/dB (M1, pure)
    Parsers.ps1          identity, SIM, registration, operator, signal, temperature (M1, pure)
    Cells.ps1            +GTCCINFO cells and +GTCAINFO carrier aggregation (M1, pure)
    Arfcn.ps1            channel number -> frequency and band (M1, pure)
    Contexts.ps1         data context: definition, activation, address, DNS, authentication (M2, pure)
    Settings.ps1         settings file, APN password (M2)
    Usage.ps1            data usage: the adapter's counters accumulated, the cycle, the quota (M8,
                         pure), their reading and file
    Sms.ps1              SMS: the PDU codec, long messages joined and split, the storage's
                         answers, what is new and the SIM each part came in on (M8, M9, pure);
                         their files
    Sim.ps1              SIM PIN: states, the decision, the encrypted store, removing it (M2)
    Esim.ps1             eSIM: lpac's lines and command lines, the bridge to AT+CCHO/+CGLA/+CCHC
                         (pure), the SIM slot's reads; lpac run to its end; the SM-DP+'s HTTPS (M9)
    QrCode.ps1           a QR code read from an image, with ZXing.Net (M9)
    Fcc.ps1              FCC lock: reads, diagnosis, unlock (M2)
    Modes.ps1            network mode and bands: reads, what to write (pure), a choice on trial (M5)
    Connection.ps1       state machine (pure), observation and connect pass (M2)
    Network.ps1          modem adapter: configuration plan (pure), read and apply (M2); its
                         encrypted DNS (M7)
    Dns.ps1              encrypted DNS on one interface: read and set through the IP Helper API,
                         the templates Windows knows; the template's server by name, looked up
                         through Windows or with a DNS query of its own (M7)
    Log.ps1              redaction (pure), rolling log (M2)
    Devices.ps1          the modem's USB functions: classification (M6, M10, pure), PnP reader (M2),
                         which modem to open (M3, pure), which functions to put on WinUSB (M10,
                         pure), its USB restart (M4); pnputil
    Radio.ps1            technology, bars, cells for display (M3, pure), and their reads
    Health.ps1           which check fails, the data path's verdict (M4, pure); the probe
    Recovery.ps1         the recovery decision (M4, pure), maintenance windows, the steps
    Simulation.ps1       development mode: the simulated device and adapter (M3); lpac (M9)
    Updates.ps1          the update notice: what GitHub's answer means (pure), the request (M7)
    Startup.ps1          the start at sign-in: the installer's logon task, read and turned on or off (M7)
    Worker.ps1           the worker: link, cadence (pure), snapshots (pure), commands, loop (M3)
    Data/                3GPP band tables, transcribed (EutraBands.psd1, NrBands.psd1); the
                         simulated modem's answers (Simulation.psd1); the GSM 7 bit default alphabet
                         (GsmAlphabet.psd1); the GSMA's root CI (GsmaRsp2RootCi1.pem)
  install.cmd            installs or updates the app (M7): runs Start-Fm350.ps1 -Mode Install
  uninstall.cmd          removes it (M7)
  Start-Fm350.ps1        the launcher, in Windows PowerShell 5.1: finds PowerShell 7, starts the
                         app or the installer (M7)
  Installer/             the installer (M7): its own module, FibocomFm350.Installer, and
                         Invoke-Fm350Setup.ps1, which the launcher runs elevated; Texts.ps1 and
                         Strings/, its texts and the launcher's in each language
  App/                   tray app (M3): its own module, FibocomFm350.App
    Texts.ps1            the app's texts in Windows' display language (M7); Strings/ holds
                         one table per language
    View.ps1             what the tray and the window show, from a snapshot (pure)
    TrayIcon.ps1         the icon: drawn, swapped, every handle destroyed
    AppIcon.ps1          the app's own icon, the logo's glyph: window, taskbar, shortcut (M7)
    AppIdentity.ps1      the app's AppUserModelID, on its window and its Start-menu shortcut (M7)
    MainWindow.xaml/.ps1 the main window and its buttons
    Supervisor.ps1       worker runspaces, when to replace one (pure), the single instance
    App.ps1              the UI thread's loop, start and exit
    Start-Fm350App.ps1   the script that starts the app
tests/
  *.Tests.ps1            Pester
  fixtures/
    documented/          answers written from the documentation, values invented (M1)
    device/              answers and PnP snapshots captured from a real FM350, redacted (device session)
    fakes.psd1           the only identifier-like values a fixture may carry
tools/
  Invoke-Lint.ps1        the linter, as CI runs it (docs/SETUP.md)
  LintRetry.ps1          when the linter starts another analyzer process, and gives a file up (pure)
  New-ReleasePackage.ps1 the release zip and its notes (M7): CI builds them at every push, the
                         release workflow publishes them; lpac and ZXing.Net in the zip, lpac's
                         source beside (M9)
  Lpac.psd1              lpac's pinned release: addresses and SHA-256 (M9)
  ZXing.psd1             ZXing.Net's pinned package and license: addresses and SHA-256 (M9)
assets/                  logo (source: logo.html)
```

## Runtime dependencies

None beyond **PowerShell 7.6+ on Windows**. Everything the app uses ships with them: WinUSB and
SetupAPI, part of Windows (the AT port, M10), WPF and WinForms (UI), `System.Drawing` (icon), `System.Net.Http` (the update notice),
and the Windows modules `PnpDevice`, `NetAdapter`, `NetTCPIP`, `DnsClient`, `ScheduledTasks`.
Windows PowerShell 5.1 and its `Appx` module, part of Windows, run the launcher. From `v1.2.0`
the release zip also carries lpac for eSIM — `lpac.exe`, in the `lpac` folder, for x64 and, from
`v2.0.0`, Arm64 — and ZXing.Net to
read a QR code from an image — `zxing.dll`, in the `zxing` folder (see *eSIM*); nothing has to be
installed separately.

## Invariants

1. **One owner per resource.** Only the worker opens the AT port; the mutex keeps a second
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
8. **System changes are scoped to the modem**: its network adapter — idempotent, volatile where
   possible — and its own vendor USB functions, put on WinUSB: a persistent change by nature, never
   the network function, never under a port another program holds, given back to their best driver
   by the uninstallation (M10).
9. **Band codes round-trip.** A code read from the modem survives being written back, even when
   the app does not understand it.
10. **Elevated code comes only from an admin-only location.** The app and the tools it runs are
    loaded from under `%ProgramFiles%` or the system folder, by literal paths; nothing
    user-writable (profile scripts, per-user modules, paths from settings or the environment) is
    executed by the elevated process — its module path is held to admin-only folders, also after
    a runspace opens —, and the WinUSB driver comes from Windows' own `winusb.inf`, in the
    Windows folder. User Account Control is no security boundary: this closes the paths made of files
    (*Startup, elevation, single instance*).

## Independent implementation

The protocol knowledge comes from `docs/AT-COMMANDS.md`, where every fact has a source and a
status. The upstream project that inspired this one has no license, so its code is neither
copied nor paraphrased; the architecture above (tray process, worker runspace, state machine,
recovery ladder) is this project's own.
