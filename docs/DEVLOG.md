# Development log

Newest first. One entry per meaningful change — note *what* and *why*, not just *what*. This is
the running history, so context is never lost between sessions. Technical and design decisions
only.

## 2026-10-04 — M8: the milestone's review, and its fixes

The milestone's one review pass found five defects, each fixed with a test:
- **A double click on *Send* sent the message twice**: the button stayed enabled until the worker
  published that a message was going out. The window now waits for the worker's answer to the
  command it queued (its Id, which `Send-AppCommand` now returns), or for another worker.
- **A listing the parser couldn't read stopped every cycle**: a `+CMGL` header with an index
  alone threw, before the recovery decision and the snapshot, and the worker ended after three
  cycles, again and again while the message stayed stored. The parser leaves such a header out,
  and the messages' step, like data usage, never stops the cycle.
- **A message opened while the worker was replaced stayed new**: the window opened each message
  once, and the command could go with the worker that ended; a new worker took it before reading
  its record of what is new. Selecting a message again now opens it again, and the record is read
  before a message is taken off it.
- **A listing cut short lost its unread parts**: the modem had marked them read. They are kept
  new from the lines that came.
- **A long paste froze the window**: the text is measured on every keystroke. The box takes 255
  parts at most, and a longer text is too long without being measured.

## 2026-10-04 — M8: the Messages and Data tabs, the tooltip, the notifications

The window and the tray show what the worker reads (ARCHITECTURE → *Tray icon*, *SMS*):
- **Pure views**, each with its matrix of tests: `Get-MessagesView` (the list, newest first, a
  message's text or why it has none, the parts missing, why there are no messages),
  `Get-UsageView`, `Get-TrayNotice`, and the tooltip's second line; sizes in decimal units — a
  gigabyte is 10^9 bytes, as the quota counts it — in the invariant culture.
- **Selecting a message opens it**, once: a selection the window restores after a refresh opens
  nothing. The list is filled again only when it changed, so the selection stays.
- **The text being written stays until its message is sent**, and a new text typed meanwhile is
  kept: a failed message is the user's to send again.
- **Each tab saves its own settings, the others' as saved**: saving the connection used to send
  the form's fields alone, which would have put the data usage settings back to their defaults.
  The quota takes a decimal comma as a point.
- **A notification waits until the tray icon shows**, and each is shown once, by the Ids the
  worker carries over; a click on one about messages opens their tab.
- The *Connect* scenario's SIM holds no message: the app's own end-to-end test starts it, and
  should not leave a notification behind in Windows.

## 2026-10-04 — M8: messages in the worker

The worker reads, opens, deletes and sends messages (ARCHITECTURE → *SMS*):
- **The storage is listed when it may have changed**: once the notices are set, on a `+CMTI`,
  after a command, and when a pass finds its count changed — one `AT+CPMS?` per pass, rather than
  a new interval to decide. A refused step waits for the next pass, logged once by the command
  and the modem's answer.
- **Announced once**: a message is announced when a part of it is new and none of it was new
  before, so a long message's later parts don't announce it again; the announcement's Id carries
  over to the next worker, like the quota's, so a restart never repeats it.
- **Deleting reads the storage again first** and deletes every part where it is now: the indexes
  the window saw may have moved.
- **No number or text in the log**, on the error path too: a failed message command's detail is
  the error's type.
- **Observe-only mode reads no message**: listing marks them read on the modem, a change of state.
- The simulated SIM holds four parts — read, unread, a long message — and a message comes in a
  minute after the start; a restart turns its notices off, as the device's power-on does.

## 2026-10-04 — Decided: the inbox and the data usage in the window

Taken by the maintainer:
- **One *Messages* tab**: the list, the selected message below, a box to write one at the bottom.
  Rejected: a separate *Send* tab; a window of its own to write.
- **A message is opened by selecting it** in the list, as in a mail client. Rejected: a *Mark as
  read* button.
- **Deleting asks every time**, *No* preselected, as the app's other actions that can't be undone.
- **Data usage in a *Data* tab** with its two settings, and in the tooltip. Rejected: a line in
  the window's top panel, alone or beside the tab.

## 2026-10-04 — M8: messages on the device, and USSD left out

M8's device session, on LTE, with the app's codec and sending code (`AT-COMMANDS.md` §9):
- **Notices come on the MD AT port**, data up or not: with `AT+CNMI=2,1,0,0,0` each part is stored
  and announced as `+CMTI: "SM", <index>`. Notices start off, and a message that comes then is
  stored silently, so the worker reads the whole inbox when it sets them, not only on a notice.
- **The app selects no storage**: `+CPMS=` takes `"SM"` alone while `+CPMS?` reports `"MT"`, and
  the notices name `"SM"` already. Nothing to set, nothing to put back.
- **The modem picks each message reference itself**, one per attempt, whatever the PDU says; the
  app sends `0` and never counts references. Sent messages are not stored.
- **A part can be refused for a while** (`+CME ERROR: 226` after 12.8 s; the same parts went through
  two minutes later). A part refused or unanswered ends the message, and the app never resends by
  itself: an unanswered part may have gone out, and each part costs.
- **USSD is left out**, as the best-effort rule said: `AT+CUSD` answers `OK` and no reply ever comes,
  with two SIMs and the code written either way. Registered for SMS only on the circuit-switched
  side, the modem most likely has no fallback for it, and no USSD over IMS was offered. The `+CUSD`
  facts stay in §9; the 30 s wait decided for a reply is moot.

Built for the inbox and the sending, ahead of the worker:
- `Send-AtMessagePdu` — `AT+CMGS`, the `> ` prompt (no line end after it), the PDU and Ctrl-Z; on a
  missing prompt or a timeout it cancels with ESC and clears what the modem echoed, so the next
  command's answer is not mixed with the PDU.
- **What is new**: a part's fingerprint is the SHA-256 of its PDU as stored, which holds the sender,
  the time stamp and the text; `Update-SmsUnread` (pure) keeps the unread ones still stored and not
  opened, in a DPAPI file that holds no text and no number.
- **The simulated modem stores messages**: `+CPMS`, `+CMGL`, `+CMGR`, `+CMGD`, `+CNMI` notices,
  arrivals on a schedule, and sending with the prompt, with an error or with no answer, for the
  worker's tests.
- **Device fixtures** of `+CMGL`, `+CMGR` and `+CNMI` answers, the numbers and time stamps
  rewritten, the test messages' texts kept: the codec decodes them exactly.

## 2026-10-04 — M8: data usage counted

The worker reads the modem adapter's byte counters every 30 s, port open or not, and keeps
bytes per day across the counters' resets (`Usage.ps1`; ARCHITECTURE → *Data usage*):
- **Pure where it decides**: accumulating a sample (`Update-DataUsage`), the cycle's first day
  (`Get-UsageCycleStart`), today and the cycle against the quota (`Measure-DataUsage`), and which
  threshold to say (`Resolve-UsageWarning`), each with a matrix of tests.
- **The file holds what a restart needs**: the counters last read, so a save missed loses nothing,
  and the thresholds said this cycle, so a restart never says one again.
- **Never in the connection's way**: reading or saving that fails is logged once, by the
  exception's type — its text may name the user's folder —, and stops nothing.
- The simulated adapter counts traffic while it carries the app's address, and starts over when
  its USB device restarts, as a real adapter is created anew then.
- Two settings, `UsageCycleDay` and `UsageQuotaGB` (decimals read in the invariant culture),
  with the rule's text in the eight languages.

## 2026-10-04 — M8: the SMS codec

Messages are decoded and encoded as PDUs by pure functions written from 3GPP TS 23.040, 23.038,
24.011 and 27.005, V19.0.0, whose facts and clauses are now in `AT-COMMANDS.md` §9 (*SMS PDUs*):
SMS-DELIVER, SMS-SUBMIT and SMS-STATUS-REPORT; addresses, alphanumeric senders included; the time
stamp with its quarter-hour time zone; the data coding scheme; the user data header, long messages
joined (`Join-SmsPart`) and split (`ConvertTo-SmsPdu`, `Measure-SmsText`); GSM 7-bit with the
extension table (`Data/GsmAlphabet.psd1`), UCS2 and 8-bit data. Choices where the standard leaves
room:
- **UCS2 as UTF-16**: phones send emoji as surrogate pairs; they decode whole, and a pair is never
  split between parts — as an escaped GSM character never is.
- **A PDU that can't be read is listed as malformed**, never dropped: the user can still delete it.
- **National language tables are not carried**: a message naming one is read with the default
  tables and flagged. The year of a time stamp is taken in 2000–2099.
- **The tests build their PDUs by hand** from the specifications' layouts, and pack GSM 7-bit text
  with a reference that draws 23.038's figure as a string of bits — independent of the codec's
  arithmetic, checked on the usual `hello` → `E8329BFD06`.
- **Fixtures with PDUs are checked too**: the identifier check decodes them, and their service
  centre and sender must be the documented fakes (`fakes.psd1` gains two sender names).

## 2026-10-04 — Decided: M8's defaults, its quota warnings and what is new

Taken by the maintainer:
- **Billing cycle from day 1** by default; a day the month lacks means its last day.
- **Quota warnings at 80% and 100%**, each once per cycle, in the tray; the quota in gigabytes with
  decimals, off by default; never a disconnection.
- **A new message's notification names the sender only**; its text stays in the window.
- **What is new survives restarts**: remembered on disk, encrypted, by the message rather than its
  storage index, so a re-enumerated modem doesn't mix it up — every unread message, not only the
  last one. The design: a fingerprint per part (no text, no number), in a DPAPI file bounded by
  what the storage holds (ARCHITECTURE → *SMS*). Rejected: keeping it in memory only (lost at every
  restart); no "new" state at all.
- **Counters read every 30 s, the totals saved at most every 5 minutes** (and at a threshold, and
  on exit); **a USSD reply waited 30 s**.

## 2026-10-04 — CI: the linter counts the analyzer's failures per file

CI on main failed at the lint step with ten files "the analyzer could not finish" and no
diagnostic: three analyzer processes in a row had stopped at their first file, the limit that
ended a run. Measured since: analyzed first in a new process, each of the three largest files of
the repository makes PSScriptAnalyzer fail its own command lookups about one time in two (6 of
12), a small file never (0 of 12); limiting the process to one processor changes nothing. So one
large file alone reached the limit about once in eight runs.
- **Failures count against the file the process broke on**, which goes first in the next process.
  A file is given up only after 20 processes failed on it — at one chance in two, about once in a
  million —, and fails the run; the other files go on, so their diagnostics are still reported.
- **No process starts after 80 in all**: a run that can't succeed still ends within minutes.
  A run usually takes about ten.
- **Diagnostics are never retried**, and a PSScriptAnalyzer that can't be loaded ends the run at
  once — before, a missing module would have read as zero diagnostics.
- The decision is a pure function, `Resolve-LintRetry` (`tools/LintRetry.ps1`), with a matrix of
  tests and a run driven end to end against a made-up analyzer; the same rules apply locally and
  in CI.

## 2026-10-04 — eSIM: a profile enabled and disabled on the device

The second part of M9's device session, on slot 1 and back to slot 0, the factory test profile
enabled and disabled again; §8's open questions answered (`AT-COMMANDS.md` §8):
- **The modem routes `+CGLA` by the session ID**, whatever channel the class byte names, and
  carries a 131-byte APDU intact; answers of 207 bytes come in one piece. lpac's default segment,
  120 bytes, fits.
- **A profile switch resets the SIM by itself**: with the refresh flag, the eUICC asks for a UICC
  reset, the modem performs it, and the SIM is ready again within 5 s with no AT command. The
  reset closes the logical channels, so the bridge treats a session that fails after a switch as
  closed (ARCHITECTURE → *eSIM*).
- **The eUICC trusts the GSMA production root** (and a Gemalto test CI): profiles from operators'
  servers can be authenticated by it. Its only profile is a lab tester's (Rohde & Schwarz CMW500),
  of class test, never deleted; download and delete wait for a profile downloaded for the purpose.

## 2026-10-03 — An eUICC on our module's slot 1

The first part of M9's device session: reads on slot 0, then slot 1 selected, its eUICC asked, and
slot 0 written back at the end. Facts in `AT-COMMANDS.md` §8:
- **The logical-channel commands work**, on the physical USIM and on the eUICC: `+CCHO` answers the
  session ID alone, without a prefix; `+CGLA` answers the response quoted, with its status word,
  its length counted in hex characters. The `+CSIM` route is not needed.
- **Slot 1 (SIM2) holds an eUICC**: `+SIMTYPE: 1`, an EID, and `+CPIN: EMPTY_EUICC`, a value the
  SIM-state parser reads as *Other* today. The empty `+EID:` of slot 0 was that slot's, not the
  module's: §8 had concluded too much from it.
- **Switching slots** answers in a fraction of a second, with no re-enumeration and no `+CFUN`;
  back on slot 0 the SIM was ready and registered within 5 s.
- **The ISD-R answers ES10 requests** carried by `+CGLA`: SGP.22 2.2.2, one profile, disabled, of
  class test.

Still open (§8): the longest APDU that reaches the card intact, how the class byte routes, and what
enabling a profile needs.

## 2026-10-03 — Decided: SMS, USSD and data usage before eSIM

M8 is now *SMS, USSD and data usage* (`v1.1.0`) and M9 *eSIM* (`v1.2.0`); lpac ships from
`v1.2.0`. The SMS milestone needs only a physical SIM, which every device session so far has had.
The eSIM milestone needs a module whose eUICC answers, and none has been reached yet: our module's
empty `+EID:` was read with slot 0 (SIM1) selected only, so `AT-COMMANDS.md` §8 no longer
concludes that it has no eUICC, and M9 starts by looking on slot 1 — a persistent write
(`+GTDUALSIM`), put back at the end. Decided with it: eSIM is released only as far as it is
verified on a real eUICC; nothing of it ships proven on the simulated modem alone (its tests still
simulate lpac, as every milestone's tests simulate the modem). Older entries call eSIM M8 and SMS
M9; they are left as written.

## 2026-10-03 — Decided: the IPv6 DNS servers a network gives are said

The review's open decision, taken by the maintainer before the first release. With encrypted DNS
on, IPv6 DNS servers the network gives — from router advertisements or DHCPv6 — are not static: a
reset can't take them off, and Windows may query them in the clear. They are told apart from the
static servers and from Windows' own `fec0:0:0:ffff::1`–`3`, compared in one written form, and
**said**: in the window's DNS line, with their addresses, and once in the log, by number. Nothing
is blocked or changed for them. Rejected: blocking the adapter's configuration — a network that
gives IPv6 DNS servers usually gives an IPv6 address too, which Windows uses without the app, so
the app would look disconnected while traffic, and its DNS in the clear, went on (the option
first recommended, withdrawn for that); turning router-advertised DNS off on the interface — a
persistent setting to own and put back, DHCPv6 left out, and nothing to try it on, since our modem
and operator give none.

## 2026-10-03 — M7 on the device

The release zip as a download leaves it — every file marked as from the internet —, installed and
uninstalled with the real modem, and the system put back after each step. Facts in
`AT-COMMANDS.md` §11:
- **Installing and updating**: one UAC prompt; the app started by its logon task after a restart
  and by its Start-menu entry, the window pinned to the taskbar too; `install.cmd` again over the
  running app, which exited with its connection up and started again. The logon task registered
  off; the *Connection* tab's checkbox turned it on and off again.
- **Listed in Windows' installed apps**, its *Uninstall* running `uninstall.cmd`, which took the
  entry off with the rest; `uninstall.cmd` run by hand did the same.
- **Encrypted DNS** on the modem's adapter with the connection up, by address and by a template's
  name; taken off on the real API — the servers kept, unencrypted — once the fix for empty
  templates was in; an IPv6 static server beside encrypted IPv4 ones taken off by the plan's reset,
  nothing asked at the next pass. No IPv6 DNS server was ever advertised by the network.
- **The update notice** against GitHub's real answers: `404` while no release is published, and
  `403` while the address's quota was used up — which brought the fallback to the release page.
- **Putting the system back** found that clearing an adapter with nothing of the app's on it threw
  (an entry below); with the fix, the same step on the real system did nothing, as it should.

## 2026-10-03 — M7: the review pass

One lite review of M7's changes found five defects in the product, all fixed, each with a test
that fails without the fix (mutation-checked). A targeted re-check of those fixes and of the new
entry in the list of installed apps found four more, fixed the same way, and one open decision. It
found the installer's access checks, tasks, paths with spaces, COM objects and resources, the
uninstall string's quoting and the UI thread sound.
- **Encrypted DNS left a family in the clear.** With an override of one family — IPv4, the usual
  case — the other family's static servers stayed on the adapter unencrypted: the operator's IPv6
  servers from an earlier pass, or its IPv4 one beside an IPv6 override. The plan now takes every
  server of such a family off with a reset — never first stripped of its encryption, which a reset
  that failed would leave in the clear (found by the re-check) — and sets the wanted ones again,
  encrypted. It compares the **static** servers, which the per-interface read already parsed and
  now returns: compared with the servers Windows lists, its own IPv6 ones would have asked for a
  change at every pass — and taking encryption off IPv6 servers would have written them as static
  ones. The simulated adapter reads a DoH property only with its server, as Windows reads it by
  position.
- **A refused read is not "no DoH".** Any exception reading an interface's DoH settings used to
  mean a Windows without the API: DoH users were blocked, and the window greyed the setting out,
  over what may be a transient refusal. Only a missing function means that now; a refused read
  leaves encryption as it is at that pass — with encryption off the servers are still set,
  compared with the ones Windows lists, or a fresh adapter would be online with no DNS server
  (found by the re-check). Windows' list of known templates failing to read no longer fails the
  whole connect pass, nor blocks a valid setting with `DohTemplateMissing` (found by the re-check):
  "not read" is kept apart from "none known"; a server with no given template keeps the one the
  adapter already encrypts it with, and with none encryption is left as it is. Either is logged
  once.
- **The worker spun while a DoH lookup ran.** A lookup that fell due kept its due time in the
  past until it ended, and the cycle's wait became 0: up to 15 s of a core at 100% per slow lookup.
  The due time no longer shortens the wait while a lookup runs; its answer is looked for once a
  second.
- **An update that failed after the app exited left it stopped**: monitoring and recovery off
  until the user noticed. The installer now starts that app again, from the folder in place,
  before saying what failed.
- **An uninstallation that failed after deleting part of the folder** could leave an entry in the
  list of installed apps that no longer uninstalls (found by the re-check). The entry stays only
  while `uninstall.cmd` and the package are whole.
- **Router-advertised IPv6 DNS servers** would stay in the clear with encrypted DNS on, out of a
  reset's reach. None was ever listed on our modem and operator; what the app does about them was
  the maintainer's to decide (the entry above).

## 2026-10-03 — Decided: listed in Windows' installed apps

Decided by the maintainer as proposed: the app is listed in Settings → Apps → Installed apps,
whose *Uninstall* runs `uninstall.cmd` (`Register-AppUninstallEntry`). The key is the app's name
under `Uninstall`, as non-MSI installers name theirs, written whole at every installation; no
*Modify* nor *Repair* — changing the app is installing it again; no publisher. The uninstaller
takes the entry off last, so an uninstallation that failed halfway can run again from the list.
Rejected: after the first release; only `uninstall.cmd`.

Also decided: the program shows its name, **Fibocom FM350-GL Windows GUI**, in the Start menu, the
list of installed apps, the window's title (so the taskbar) and the installer's and the
launcher's messages, where it said *FM350-GL* — the modem's name. The tray's tooltip keeps
*FM350-GL*: it gives the modem's state, in little room. Rejected: the repository's own form,
`fibocom-fm350-gl-windows-gui`, in menus; the long name in the tooltip too.

## 2026-10-03 — The update notice when GitHub's API refuses

Found on the device: three update checks in a row were answered `403`, most likely because other
requests to the API from the same public address had used up its quota. The API allows 60 unauthenticated
requests an hour per address, shared with every other client behind it — a home router, an
office, an operator's address translation when the modem is the computer's way out —, and the one
attempt per app start then fails until the next start, possibly weeks later. Decided by the
maintainer as proposed: the API stays first — documented, it says draft and
prerelease —, and a `403` or `429` makes the same attempt ask the latest release's page once,
reading the tag from its redirect (`Resolve-UpdateRedirect`, pure, matrix-tested; a `HEAD`, the
redirect never followed). Only a redirect to this repository's release page counts; anything else
is a failure, never a second request. The log says whether the rate limit was used up, from
`x-ratelimit-remaining`, not the body, which names the address. Rejected: the page alone (the
redirect is the site's behavior, not an API contract), retrying after the limit's reset (a shared
address may be used up every hour), leaving it.

## 2026-10-03 — Starting at sign-in off by default; two fixes found putting the system back

- **Decided by the maintainer**: the app no longer starts at sign-in unless the user asks. The
  installer registers *Start at logon* disabled — an update keeps it as the user left it —, and
  the *Connection* tab's checkbox turns it on or off: the elevated app enables or disables the
  task, never creates one, and the checkbox reads the task itself (ARCHITECTURE → *Startup,
  elevation, single instance*). Rejected: a question at install time (changing one's mind means
  installing again), both, leaving it always on.
- **Found on the device, putting the system back**: taking encryption off the adapter's servers
  failed with `0x2EE6`. The servers without a template went to the native call as empty strings —
  PowerShell turns a `$null` in a string array into one — and Windows refused a DoH property with
  an empty template (`AT-COMMANDS.md` §11.1). The device session had only ever switched from one
  encrypted server to another; turning encryption off would have failed at every pass. Which
  servers get a property is now decided in PowerShell (`Get-DohServerProperty`, tested), and the
  native call gets only those. Tried again on the device: encryption off, the servers kept.
- **Found on the device, the same way**: clearing an adapter that carries nothing of the app's —
  recovery step R1 on an adapter the modem's DHCP configured — threw instead of doing nothing. The
  plan's `Actions` was `$null`, not an empty array: an `if` statement's output unrolls an array,
  an empty one to nothing, and `@($null)` is one action with no name, which StrictMode refuses to
  read. Both plans, `Resolve-AdapterClearing`'s and `Resolve-AdapterConfiguration`'s, now always
  carry an array — of none, of one — and the tests check the type, not `-BeNullOrEmpty`, which
  passed on `$null`.

## 2026-10-03 — The app's own taskbar identity

Found on the device: the window showed the app's icon in its title bar and PowerShell's on the
taskbar. PowerShell came from its MSIX package, and the taskbar gives a packaged app's windows the
package's identity and icon. Decided by the maintainer as proposed: the window and the Start-menu
shortcut share one AppUserModelID (ARCHITECTURE → *Main window*), so the taskbar shows the app's
icon and name, and pinning the window pins the shortcut — the app started through its task, with
no UAC prompt. Rejected: the window's ID alone (pinning it would pin nothing that starts the app);
leaving it. Microsoft's guidance puts the ID on the shortcut rather than in relaunch properties
when a shortcut exists. The window's ID is removed before it closes, as Windows requires, in a
handler that can't throw: an exception in a WPF handler ends the process. A test caught a removal
that never removed: PowerShell passes `$null` to a .NET string parameter as an empty string, so
removal has a method of its own.

## 2026-10-03 — Decided: x64 only, the app's own icon, eight languages

Decided by the maintainer as proposed, before the first release:
- **The installer refuses a Windows the app can't run on**: anything but 64-bit Windows on an
  x64 processor (`AT-COMMANDS.md` §11.2) — PowerShell 7.6 has no 32-bit build, and Windows on Arm
  loads Arm64 kernel drivers alone, which the modem's driver package lacks. Read from
  `Win32_Processor`, not from environment variables the user can set; a processor that can't be
  read lets the installation go on — the check only explains early what would fail later. Only
  `install.cmd` checks: the app is started only by the tasks it registers.
- **The app's own icon is the logo's glyph** (`assets/logo.html`, `?icon`), drawn in code from the
  logo's geometry at every size, for the window, the taskbar and the Start-menu shortcut. The tray
  keeps its icon of the signal: it says the state, which a logo can't. Rejected: the logo in the
  tray too, its bars lit by the signal (no room for the technology at 16 pixels); the glyph on
  the logo's green tile (less legible at 16 pixels).
- **Languages: English, Italian, German, French, Spanish, Portuguese, Dutch, Polish**, for
  everything the user reads, the installer and the launcher included; chosen from Windows'
  display language, with no setting; the log stays in English (ARCHITECTURE → *Languages*). The
  translations other than Italian were written without a native speaker's review. Rejected: the
  24 official EU languages (thousands of texts nobody here can check, in error messages too);
  Italian alone for now; a language setting.
- The settings' problems became codes — the setting, the rule it breaks, the rule's values — so
  the window can say them in its language while the log keeps the English sentence; a test holds
  the two English renderings equal. A combo box's value is now its `Tag`: its text is translated.
- Two flaws of the window, found by the maintainer at its smallest size: the *Connection* tab
  couldn't scroll, and the footer ran under *Check now*. The tabs that can outgrow the window
  scroll, and the footer wraps.

## 2026-10-03 — Encrypted DNS to a server named by its template

Decided by the maintainer as proposed, before the first release: a resolver at home behind a
dynamic address has a name, never a stable address, and Windows binds encryption to an address
(`AT-COMMANDS.md` §11.1).
- **Without servers of the override, the DoH template's host is the server**: its address, or
  the IPv4 addresses its name is looked up to — when the worker starts, then every
  `DohRefreshMinutes`, a new setting (60 by default, 5 to 1440), and every 30 s while a lookup
  fails, the last addresses kept meanwhile. Rejected: a lookup at every pass (30 s), too much for
  a name that changes a few times a year.
- **The bootstrap goes through Windows**, as any name: over the encrypted server itself while it
  answers. Found while writing its tests: with the modem alone, the first lookup could never
  succeed — the adapter wasn't configured until there were servers —, nor one after the server
  moved — the encrypted server no longer answers, and nothing falls back. Hence three rules
  (ARCHITECTURE → *Network configuration*): the servers the adapter already encrypts with that
  template count as the last ones (Windows keeps them across restarts); until there are any, the
  adapter gets its address and route but **no DNS server at all**; and when Windows can't look
  the name up, the app asks the operator's DNS for that one name, **in the clear**, from the
  modem's address — the one declared exception to "never in the clear": it reveals the resolver,
  never what the user looks up. Rejected: no query in the clear at all (a computer with the modem
  alone stays without DNS until the user acts), a public DoH resolver for the bootstrap (a third
  party learns the resolver, and the app depends on it).
- **The query is the app's own** (RFC 1035): Windows' resolver can't be pointed at one server for
  one name. A random ID and port, and an answer counts only from a server asked, with that ID and
  question (RFC 5452) — a test caught a comparison by culture that let an answer to another type
  through: control characters weigh nothing there. The socket is bound to the modem's address,
  which makes Windows send it through the modem (strong host model, checked on the device).

## 2026-10-03 — Decided: the update notice, the installer, encrypted DNS on Windows 10, the release check

Six decisions of M7, taken by the maintainer as proposed:
- **The update notice** is one item at the top of the tray menu, only when a newer release exists
  — *Version 1.1.0 is available...* —, opening the release's page. Rejected: a balloon besides,
  a line in the window besides.
- **The installer starts the app** at the end of every installation, with its window, through the
  *Open* task. Rejected: only when it was running before; never.
- **The uninstaller asks** whether to delete the settings, the stored SIM PIN and APN password,
  and the logs; no by default. Rejected: keeping them always, deleting them always.
- **Encrypted DNS on Windows 10**: answered from Microsoft's documentation, with the support read
  at run time; where the per-interface API is missing the setting is greyed out with the reason,
  and a settings file that turns it on anyway blocks the adapter's configuration — never plain
  DNS. Rejected: ignoring the setting with a warning (DNS in the clear), hiding it; a trial on a
  Windows 10 computer, not needed for the decision.
- **Timings**: the installer waits 30 s for a running app to exit; the update request gives up
  after 10 s. Rejected: 60 s.
- **The release workflow is verified** by the package CI builds at every push and the tests of
  its script; `gh release create` runs for the first time with the first tag. Rejected: a manual
  dry run uploading the zip as an artifact, a tag on a scratch repository, a draft release from a
  test tag here. **The release stays tag-triggered**: a run that fails before publishing is run
  again, or its tag made again on the mended commit, before any release exists. Rejected: a
  release started by hand as a draft, whose tag GitHub creates at *Publish* (two manual steps, no
  check through the public API); a first trial release `v0.1.0` (no `0.x` releases).

## 2026-10-03 — M7 code-complete: installer, release workflow, update notice, encrypted DNS

Facts first (`AT-COMMANDS.md` §11, each with its source), then the design (ARCHITECTURE →
*Startup, elevation, single instance*, *Installing and updating*, *Updates*, *Network
configuration*):
- **The tasks can't name PowerShell 7.** From 7.6 winget installs its MSIX package by default, and
  from 7.7 there is no MSI: the MSIX lives in a folder named after its version, replaced at every
  update, and its one stable name, the app execution alias, is in the user's profile, which the
  user can write. A task pointing at the versioned folder breaks at the first update; one pointing
  at the alias runs whatever the user puts there, elevated. So the tasks start Windows PowerShell
  5.1 — in every supported Windows, at a fixed place in the system folder — with a launcher that
  finds PowerShell 7 at every start: the MSI's folder or the user's MSIX package, under Program
  Files and signed by Microsoft, 7.6 or later. Rejected: requiring the MSI (gone from 7.7),
  re-pointing the task from the running app (an update applied while it isn't running leaves the
  task dead).
- **No console window.** With Windows Terminal as the default terminal, a console program started
  normally — as Task Scheduler and shortcuts start them — gets a Windows Terminal window that
  `-WindowStyle Hidden` doesn't hide: the app would have shown one for weeks. The launcher starts
  pwsh with `CreateNoWindow`; only the launcher's own console shows, for a moment.
- **Opening a runspace puts the user's module folder back** in the module path of the whole
  process — found while designing the installer: since M3 the elevated worker could load a module
  from the user's `Documents\PowerShell\Modules`. The start script now sets the module path to
  `$PSHOME` and Windows' modules before any command, and the supervisor sets it back as each worker
  runspace opens (a test fails without it). The launcher and the installer do the same.
- **Two tasks**, *Start at logon* (hidden, in the tray) and *Open* (with the window), which the
  Start-menu shortcut runs: a task can't be given arguments when it is run, and the shortcut must
  open the window of an app that isn't running yet. Task Scheduler's defaults are overridden: no
  72-hour limit, started and kept on batteries, priority 5 instead of 7 — the app's process
  inherits the below-normal class otherwise.
- **Literal paths from known folders.** The tasks name Windows PowerShell and the launcher by full
  paths the installer took from Windows' known folders: an environment variable in a task's action
  would be the user's to change.
- **The copy is checked, then swapped in whole.** Only the package's own entries are copied, beside
  the install folder; every file of the copy must be owned and writable by SYSTEM, Administrators
  and TrustedInstaller alone (a pure check over the access rules); then the old folder moves aside
  and the copy takes its place, a failure putting the old one back. A running app is asked to exit
  through an event of its session — which only an elevated process can signal — and its mutex held
  until the copy is in place, so no instance starts on half a version: a worker restarted by the
  old app would import the new core module.
- **The release zip is built at every push.** CI runs `tools/New-ReleasePackage.ps1` after the tests
  and publishes nothing; `release.yml` reuses CI as a called workflow, checks the tag against the
  three modules' version and publishes with `gh release create` and the job's own token — no
  third-party action. `actions/checkout` is pinned to the commit of v7.0.1.
- **The update request never blocks the worker**: HttpClient's task, looked at once a second, gone
  after 10 s. Its user agent is the app's name alone — PowerShell's own would add the Windows build
  and the language. The page linked is built from the tag. A worker replaced mid-request passes it
  on as done: one attempt per app start, as decided.
- **Windows 10 and encrypted DNS: answered from Microsoft's documentation** — DoH in the DNS client
  "starting with Windows Server 2022", its cmdlets documented for Windows Server 2022 and 2025
  only, the per-interface API's DoH parts given builds 19645 and 20348, above Windows 10's last,
  19045. Not tried on Windows 10. Whether a Windows has it is read at run time (the DoH cmdlets and
  a version-3 read of the adapter's settings), not assumed from a build number.
- **Encrypted DNS is set in one call per family**, the servers with their DoH properties together —
  never first in the clear —, `ENABLE` with the template read from Windows' list or the settings,
  never `FALLBACK_TO_UDP`; read back and compared at every pass. What can't be set — no servers of
  the user's, no API, a server without a template — plans no change at all: the adapter stays
  unconfigured and the connection waits for the user (blocked, never escalated). The window checks
  the same before it saves.

## 2026-10-03 — M6: the review pass

One lite review of M6's changes found five defects in the product, all fixed; each fix has a test
that fails without it (mutation-checked). It found the staging folder, the zip extraction, the
check against the install, the catalog check's native code, pnputil's handling and the UI thread
sound.
- **An INF chosen in a shared folder took the folder along.** The published zip has no top
  folder, so "extract here" puts the package straight into Downloads, and choosing its INF copied
  all of Downloads — refused as too big, or copied whole into Windows' temporary folder. For an
  INF only its package's files are copied now: the catalogs and the files its
  `[SourceDisksFiles]` sections name, under the paths of `[SourceDisksNames]` (`AT-COMMANDS.md`
  §1.1). A folder is given up at its first file too many, each file is hashed once — every INF
  hashed its whole subtree before —, and copying and checking keep the heartbeat beating.
- **Uninstalling during a network-mode trial left the trial unable to undo itself**: its write-back
  goes through the AT port. Refused while a mode is on trial, and the button off meanwhile.
- **A PnP read that failed looked like a missing driver**, the window offering an install: since
  the device session, problem 0 without a service meant "no driver". A service read as none (`""`)
  is now told from one not read (`$null`), which leaves it to the opening of the port, as before.
- **The chosen package's folder, which may hold the user's name, reached the log** through the
  message of a file that can't be read; it is now told with the package's name alone.
- **A copy that couldn't be deleted was never tried again**, and an app ended mid-install left its
  copy for good — admin-only, out of the user's clean-up's reach. Such copies are tried again at
  every later clear and when the worker ends, and the first worker of an app deletes those found
  at its start, if administrators own them.

## 2026-10-03 — M6 on the device: a driver just uninstalled has no problem code

The published package and the app's own commands on the real modem, elevated — the worker's
command functions in a process of their own, on a worker that never cycled, so no connect pass
wrote anything:
- **The published copy is the known package**: the zip has the manifest's SHA-256 and holds only
  the package's four files, each with its known SHA-256 — the x86 driver's too, known until now
  only from the research of 2026-09-28. Checked as the app checks it, in a copy only SYSTEM and
  administrators could open (owner Administrators, a protected access list): a verified version.
- **The page opened as the user**: *Open the download page* from the elevated process — Explorer
  from the Windows folder — showed it in Edge, none of whose processes was elevated.
- **Uninstalled** (`pnputil /delete-driver oem24.inf /uninstall`, about a second), the serial
  functions stayed present **without a problem code**, a class or a service, not started — not
  the code 28 of a modem first plugged in without its driver, which comes only with an
  enumeration. Two defects showed at once, both fixed with a test that fails without the fix:
  the PnP reader failed on every key without a value — `Get-PnpDeviceProperty` gives those no
  `Data` member at all —, so the worker could never have seen a modem without its driver; and a
  function with no problem code was taken for working. A function with no problem code and no
  service is now one without its driver (refined by the review: a service read as none). The
  state is a captured fixture (`pnp.7127.uninstalled.json`).
- **Installed again** by the app's commands from the downloaded zip (about a second): every
  serial function at once, on new COM numbers (the AT port on `COM23`, was `COM9`) and under a
  new published name (`oem10.inf`, was `oem24.inf`); the modem answered at once, its network mode
  as before. Nothing of either is remembered: the next look by PnP finds them.

## 2026-10-03 — Decided: the Driver tab, its confirmations, an unknown version, pnputil in the worker

Four decisions of M6, taken by the maintainer as proposed:
- **The *Driver* tab**, opened from the blocker of a modem without its AT-port driver; nothing
  opens by itself; its texts as built. Rejected: a dialog that opens by itself (a second window to
  own, a popup at a hidden start at logon), and a tray menu item besides.
- **Confirmations** before installing a version the app doesn't know and before uninstalling; a
  version it knows installs at *Install*. Rejected: a confirmation for every install, and none at
  all (uninstalling takes the AT port away from the app).
- **A package signed for WHQL for the modem's AT port, with a fingerprint the app doesn't know,
  may be installed** after that confirmation: Windows would take it anyway, and a new MediaTek
  version works without a release of the app. Rejected: refusing it.
- **Uninstall offered; pnputil run by the worker**, its heartbeat beating, stopped after 5 minutes.
  Rejected: 2 minutes (a slow computer), no uninstall in the app, a runspace of its own for
  pnputil (a second owner of system changes).

## 2026-10-03 — M6 code-complete: the driver, brought by the user and checked by the app

"Bring your own driver", guided (ARCHITECTURE → *Drivers*; facts in `AT-COMMANDS.md` §1.1, each
with its source — Microsoft's INF, signing, `WinVerifyTrust` and pnputil pages, and the driver
installed on our device, read only):
- **A manifest of known packages** (`Data/Drivers.psd1`): the SHA-256 of `usb2ser_tm` 3.22.43.1's
  catalog, INF and both drivers, and where a third party publishes a copy — the page pinned to a
  commit, the archive's own SHA-256. The driver store of our device holds the same catalog, INF
  and x64 driver.
- **The package is checked where the user can't change it.** It is copied — a zip extracted, a
  folder copied, at most 1000 files and 64 MB — into a new folder of Windows' temporary folder
  that only SYSTEM and administrators can open, nothing inherited; it is checked there and pnputil
  installs it from there. Checked in place, the package could be swapped between the check and
  the install by any program running as the user, and the elevated app would install a driver
  from a folder the user can write (invariant 10, which now says so).
- **"Signed" is asked of the package's own catalog.** On our device `Get-AuthenticodeSignature`
  calls the driver store's INF and `.sys` signed — type *Catalog* — because the package is
  installed: Windows would vouch for any copy of them. So the INF is checked with
  `WinVerifyTrust` against the catalog it names and no other; a copy with one line added, or the
  INF against another package's catalog, fails. Only the INF is checked: it is the file the app
  reads, and Windows checks every file the INF copies against the catalog when it stages the
  package. PowerShell's `Test-FileCatalog` can't open a driver catalog.
- **WHQL is the signer and its key usage**: *Microsoft Windows Hardware Compatibility Publisher*,
  `O=Microsoft Corporation`, with the WHQL enhanced key usage; an attestation signature, Microsoft's
  too, has another and is refused. The catalog's signer is read with `SignedCms`, nothing fetched
  from the network.
- **The verdict is a pure function** (`Resolve-DriverPackage`): only an INF whose x64 models list
  the modem's AT port counts; required, a catalog in the package, signed for WHQL, vouching for the
  INF; every known hash matching makes a verified version, else a signed version the app doesn't
  know. The INF is read as Windows reads it (`ConvertFrom-DriverInf`): comments, continued lines,
  `[Strings]`, the catalog and the models section decorated for x64 — an undecorated one is x86's.
- **pnputil, in the worker.** Install from the copy (`/add-driver … /install`: `0`, `3010`, `259`
  read), never over an AT port that works; uninstall the package the AT port reports
  (`DEVPKEY_Device_DriverInfPath`, only an `oem<n>.inf`) after closing the port. The worker waits
  at most 5 minutes with its heartbeat beating (`Invoke-Pnputil`, which R6's USB restart now uses
  too), and publishes the command under way first. After an install, a maintenance window as long
  as R6's settle time: a new port may stay silent for minutes. Without the driver the connection
  stays up but unwatched: `NoDriver` is blocked, never escalated.
- **The *Driver* tab**, opened from the blocker: the AT port's driver, where the known copy is
  published and by whom, *Open the download page* (through Explorer: the elevated app never starts
  a browser itself), *Choose the downloaded package…*, the verdict and why a package is refused,
  *Install*, *Uninstall the driver…* — as decided (the entry above).
- **Development mode** checks a package chosen for real, in its own folder; installing and
  uninstalling act on the simulated modem (`NoDriver` comes online once installed).

## 2026-10-03 — Decided: encrypted DNS (DoH) on the modem's adapter, before v1.0.0

The modem adapter's DNS servers can only be chosen in the app: the pass rewrites them at every
connect, so a server set by hand on the adapter lasts until the next pass. Their encryption
belongs with them. Decided by the maintainer, for M7:
- **A DoH setting and an optional template.** The setting turns DoH on for the servers of the DNS
  override; a template field serves a provider whose template Windows doesn't know (NextDNS,
  AdGuard, a private resolver). It needs the override: the operator's servers speak no DoH.
  Rejected: the setting for known templates alone (no custom provider), and documentation only
  (an elevated PowerShell step outside the app).
- **Per interface, not per server.** Windows can also mark a server address for DoH system-wide
  (`Set-DnsClientDohServerAddress -AutoUpgrade`); that changes every adapter using the address,
  against *every change is scoped to the modem's adapter*. The per-interface API
  (`SetInterfaceDnsSettings` with `DNS_INTERFACE_SETTINGS3` and `DnsServerDohProperty`) keeps it
  on the modem's adapter, and the pass re-applies it — on the new adapter a re-enumerated modem
  brings, too.
- **No fallback to plain DNS** when DoH fails: whoever turns encryption on wants no query in the
  clear. The health checks won't notice such a failure: H7 probes by address, not by name.
- **No DoT**: the documented per-interface API describes DoH only, and Windows' DoT client was
  announced for Insider builds.

## 2026-10-03 — M5: the review pass

One lite review of M5's changes found nine defects in the product, all fixed; each fix has a test
that fails without it (mutation-checked):
- **A second choice during a trial ended it without a network**: the same choice applied again
  was saved at once, and *As the modem has it* left the modem in the untried mode — unmanaged, so
  the ladder then reset it for nothing. A choice the modem has already joins the trial, and
  leaving it unmanaged writes the setting before back first.
- **A write the modem refused blocked the data context for good**: retried at every pass ahead of
  the context's steps, while the ladder climbed. A refused write is remembered as one not kept,
  until the port is opened anew; and the step no longer hides what the connection waits for, so
  health and recovery go by the real reason.
- **A revert the modem didn't take still ended the trial**: it now ends only once the modem
  answers `OK`, tried again a pass later and once the modem is back.
- **A trial due while the modem was off USB made the worker spin**: its time no longer wakes the
  worker while the port is closed, nor before a failed attempt is due again.
- **Applying the mode the modem had always wrote**: n77 left out beside n78 counted as a
  difference, so *4G + 5G* registered the modem again for nothing.
- **A write that got no answer started no trial**: it may have landed; it is tried as one that did.
- **A write the modem didn't keep was saved** once it registered with its old mode: a trial is
  confirmed only with the mode in force.
- **A trial was published only at the end of the cycle**: a cycle failing after the command left
  the next worker without it or its window. Both are published at once.
- **One failed read of the mode escalated a narrowed mode**: an unknown setting counts as narrowed
  while the settings narrow it.

## 2026-10-03 — M5 on the device: NR codes restrict NSA; n77 goes with n78

Two sessions on the real modem, the data context up (the modem a backup, metric 500), then
everything put back as found — `AT+GTACT=20,6,3,0`, context 1 deleted, the adapter as it was:
- **NR band codes restrict the NR leg of EN-DC too** (`AT-COMMANDS.md` §7 question 7). With the
  LTE list held on B3, the anchor that carried the NR leg: n78 allowed, the NR leg on n78 in 12
  reads out of 12 and `+CSCON?` connected on LTE and NR; n79 only, no NR leg in 12, connected on
  LTE alone. No measurable traffic flowed in these runs: the NR leg came with the activation of
  the data context, as in M2, and the modem stayed connected throughout. With every NR band the
  leg came back.
- **n77 drops out when n78 is listed too**, whether written by code `0`, code by code or as
  `5077,5078`, in NR-only mode as well and without a registration; written alone, it stays. n78
  lies within n77; why the firmware keeps the narrower band is not documented.
- **No 5G SA for our SIM** (question 10 stays open): in NR-only mode the modem found nothing to
  register on in 90 s, nor in 3 min as an app trial, and listed as serving an NR cell of another
  operator that offers 5G SA there. The window showed "5G SA" for it: fixed — no technology while
  the operator read says the modem is not registered.
- **Every write ends the data context**; the modem registers again 1–2 s after the `OK`, and a
  registration read right after the write can still report the registration it ends — the
  reason a choice is confirmed only from a read 10 s later or more.
- **The app's code on the real modem**: from NR-only, the pass wrote the managed 4G + 5G and was
  online and healthy 11 s later; *4G only* tried and kept in 11 s; *5G only* tried and written
  back exactly 3 min later, online 11 s after that; *4G + 5G* tried and kept. No recovery step,
  every gap inside a maintenance window.
- Seen once, recorded as open: LTE neighbour lines with the NR-style "not known" TAC and a
  six-digit channel ending in `12`; their band is not decoded.

## 2026-10-03 — Decided: the modes, a mode without a network, the default, no confirmation

Four decisions of M5, taken by the maintainer as proposed:
- **Modes**: *4G + 5G* (`20,6,3`), *4G only* (`2,3,3`) and *5G only (SA)* (`14,6,6`). Rejected:
  the minimum of two (no way to try 5G SA from the app), and NR + LTE without UMTS or other
  preferences (3G is off here; mode `17` unverified).
- **A mode that finds no network**: the user's choice is tried and written back as it was without
  a registration by the end of its maintenance window; later, a narrowed mode that loses the
  network takes no recovery step for H4 and is shown red, *No network*, with *Use 4G + 5G, every
  band*. Rejected: an automatic fallback to 4G + 5G (the app writing persistent state on its own,
  a gap at every start), no trial (a remote user could cut themselves off), and the plain ladder
  (resets every hour that mend nothing).
- **Not managed by default**: the app writes no mode until the user chooses one. Rejected:
  managing *4G + 5G* with every band from the first connect (a persistent write without a choice,
  over a configuration made elsewhere), and managing mode and bands separately.
- **No confirmation** before a mode is written; the window says the modem keeps it. Rejected: a
  confirmation for the tray only, or for every change.

## 2026-10-03 — M5: modes and bands

The network mode and its bands (`AT+GTACT`), in the window, the tray and the connect pass
(ARCHITECTURE → *Modes and bands*):
- **Written only when the modem's differs from the settings.** The modem keeps the setting across
  resets and power cycles, and every write registers it again and ends the data context: the pass
  reads it at every connect and writes nothing over a setting that does what the settings ask. A
  band list counts as kept when the modem uses no band the settings leave out — not when it
  lists every band asked: the modem drops n77 by itself, and an exact comparison would register
  it again at every pass. The price, accepted: a list an outside tool narrowed is not widened
  again by the pass; *Apply* writes the very lists.
- **Every managed RAT's list is written**, the bands chosen or every band supported, so nothing of
  an earlier setting survives; UMTS lists are never written. The same command over the same
  setting is never written twice: a modem that doesn't keep it would otherwise be registered
  again at every pass.
- **The user's choice is tried**, in a maintenance window: saved once a registration with it in
  force is read 10 s after the write or later; without one by the window's end, the setting read before the first
  change on trial is written back code by code, and the settings never held the failed choice.
  The pass keeps the choice on trial meanwhile, and a worker that replaces another carries it on.
  Saving the connection settings never changes the network mode.
- **A narrowed mode that loses the network is shown, not escalated**: H4 gets no step while the
  modem is in NR-only mode or on chosen LTE bands, as the settings ask.
- **The simulated modem keeps a network mode** as the device does — one list per RAT, n77 dropped
  with n78, the setting kept across a reset — and registers again after a write in a network with
  given bands, with or without 5G SA; three new scenarios. Thirteen mutations of the new logic
  each make a test fail.

## 2026-10-03 — M4 complete: 24 hours on the real modem

The tray app ran 24 h on the real modem, elevated, the modem a backup (metric 500), sampled every
10 min from outside (145 samples): online in every sample, one worker throughout, no recovery
step, no warning — 12 log lines in a day. *Exit* from its menu, then everything put back as found.
- **Nothing leaks.** Over the last 12 h private memory went down 0.25 MB an hour and handles 1.6
  an hour (least squares). The first hour warms up (private memory 169 → 200 MB); after that it
  stays between 203 and 215 MB, a slow climb at night undone at once by a garbage collection
  (−10.6 MB). GDI objects 32–34 from start to end, though the signal bars changed every few
  seconds for hours and the icon was redrawn each time.
- **The window costs once.** Opening the main window for the first time, from a Remote Desktop
  session, added about 70 handles, 10 USER objects and some threads, which stayed: WPF builds the
  window and closing it hides it. Later reconnections and openings added nothing; the threads
  WPF uses while the window is shown went back once it was closed.

## 2026-10-02 — M4: the review pass

One lite review of M4's changes found six defects in the product, plus two minor ones; all are
fixed but one, which was the maintainer's to decide (next entry). Each fix has a test that fails
without it (mutation-checked):
- **A check that started failing on the way inherited the grace time of the one before**: past
  R3's settle time, one silent read (H2) restarted the USB device at once, skipping R4 and R5 and
  the 3 minutes a silent port is given. Grace is now counted from when that check started failing.
- **What couldn't be read was escalated**: a context whose activation couldn't be read
  (`ContextUnknown`) was deactivated after a minute, the probe blind meanwhile — against the rule
  that one failed read never breaks a connection. `ContextUnknown` and `SimUnknown` are watched,
  never escalated.
- **A step with nothing to act on was counted**: decided after the port had gone in the same
  cycle, R2 ended `NoModem` and the next failure went on to R3. Such a step is now not counted.
- **A step was published only at the end of the cycle**: a step that hung left the replacing
  worker no trace of it, and it was taken again at once. It is published before it runs.
- **R5 could leave a SIM waiting for a PIN the app doesn't have** — PIN request on, no PIN
  stored: a reset turned an outage into one only the user could end. R5 is skipped then.
- **A maintenance window closed at a healthy reading taken before the operation broke the link**
  — harmless for the FCC unlock, wrong for M5's band changes. It closes once health comes back
  after a failure in it.
- **R1 would have removed a DHCP-given route** (no effect on the FM350, which serves no DHCP): an
  adapter with no address of the app's is left alone.

## 2026-10-02 — Decided: a path never answered is not a failure

Raised by the M4 review: on a network that drops ICMP — a private or M2M APN, an operator that
filters it — H7 would fail about 15 s after every connect and the ladder would run over a working
link, up to a modem reset every hour. Taken by the maintainer, as proposed: **until a round has
passed since the app started, failed rounds prove nothing** — logged once and shown, never
escalated. The price, accepted: a path dead from the very first connect isn't mended by H7 until it
has worked once. Rejected for now: a TCP connection to port 443 as a second way to pass a round,
and a setting to turn the probe off.

## 2026-10-02 — M4 on the device: the address settles in 3.5 s; the ladder on the real modem

- **M3's one reply in four was the address settling, not the path.** Right after the adapter is
  configured, Windows holds the address `Tentative` for 3.1 to 3.5 s (five times out of five), and
  an echo request sent from it fails at once; the first reply comes the moment it turns
  `Preferred`. The probe as built never sends from an address that isn't `Preferred` and waits
  5 s, so it never mistakes this for a failure. Settled, a few replies are still lost now and then,
  which a round of three requests and two failed rounds absorb.
- **The worker's ladder, on the real modem.** An outbound firewall rule blocking the probes' echo
  requests from the modem's address stood in for a dead path, and was lifted as soon as the worker
  took its step; four times in a row, so that each failure came back before health had held:
  R2 (online again in 1.5 s), R3 (2 s), R4 (11 s — it started 43 s after the failure, when R3's
  settle time ended), R5 (87 s: the port silent at 22 s, off USB from 51 to 76 s, the context
  defined again by the pass). Throughout the reset the recovery state stayed *settling*: no
  escalation over the silent port or the missing device.
- **R6 and `+CFUN=1,1`.** After `pnputil /restart-device` the port answered at once and only the
  adapter, created anew, had to be configured again. About 73 s later the modem left USB by
  itself and came back without its context — cause unknown, seen once, inside R6's settle time.
  `+CFUN=1,1` leaves USB about 47 s after its `OK`, comes back about 30 s later on the same COM
  numbers, and loses context 1, like `+CFUN=15`. Opening the AT port half a second after PnP lists
  it again can fail with "the requested resource is in use"; the worker's next look opens it.
- **A missing context definition is H5**: the state machine writes the definition before it looks
  at the registration, so the state is the one before registration; the health check named it
  H4 until the device showed a registered modem with no context 1.

## 2026-10-02 — M4 code-complete: health and recovery, proven on the simulated modem

The design of ARCHITECTURE → *Health checks and the recovery ladder* is built. The decisions taken
while building it:
- **The checks are the pass's own reads.** The connect pass already reads the device, the port,
  the SIM, the registration, the context and the adapter in that order and stops at the first
  that fails, so the state it reaches names the failing check (`Resolve-HealthCheck`): no second
  set of reads to keep in step with the first. Only H7 sends something of its own.
- **H7 is ICMP from the modem's address**, through the IP Helper API (`IcmpSendEcho2Ex`): .NET's
  `Ping` can't choose its source address, and a probe that left through the usual route would test
  Ethernet or Wi-Fi, not the modem, which is a backup. The address is checked first: a request
  from an address Windows is still checking (`Tentative`) fails at once, which is no fault of the
  path. One lost round is never a failure; two in a row are. A test sends a real echo request over
  the loopback interface, so the interop is exercised on every run, CI included.
- **Each step does the least and leaves the rest to the pass.** R2 only deactivates the context,
  R3 only deregisters, R4 only turns the radio off; the pass that runs right after takes the steps
  back up with everything it already knows — authentication, the adapter, the APN of the
  settings. R1 removes the adapter's configuration so that the same planner sets it from scratch.
- **The ladder climbs from the last step taken, across checks**: a context restarted, then the
  registration lost, goes on to R4, not back to R3. A failure that comes back before health has
  held 10 min carries on up the ladder too — the last step mended the symptom, not its cause.
- **A step's settle time beats everything but health**: a reset takes the modem off USB, which
  must not read as "no device" and stop the cycle.
- **Recovery's history is in the snapshot**, so a worker that replaces one that crashed carries on
  where it was; and the worker notices a sleep the way the UI does — a wait that ends far past its
  deadline — and gives a failing check its grace time again.
- **R6 is guarded**: the port closed first, the modem found again by PnP (H1 must pass), the
  composite device checked by its hardware ID, `pnputil` run from the system folder, never found
  through `PATH`, since the app runs elevated.
- **An address Windows refused** (`Duplicate`) now counts as not configured, so the pass sets it
  again; before, it would have looked configured while nothing could leave from it.
- **The simulated modem keeps state.** Recovery commands change its answers every time they run
  (standing transitions), only when they succeed — a radio an FCC lock keeps off stays off — and
  device flags model what no answer shows: a data path down, a modem that answers nothing until
  its USB device restarts. Five fault scenarios drive the worker through the ladder in the default
  test run: a path that settles, a data path down (R2), a registration lost (R3, then R4), a modem
  that doesn't answer (R6), a network that refuses it for good (cycles, backoff, slow cadence);
  and the blocked scenarios run two simulated hours without a single step.
- Four mutation checks — escalating a blocked check, probing from a tentative address, not starting
  the rounds over after a step, restarting every cycle at the entry step — each make tests fail.

## 2026-10-02 — Decided: recovery timings, the data-path probe, the recovering state, the soak

Taken by the maintainer, as proposed:
- **Timings**: a failing check is left to the connect pass 3 min (H2), 2 min (H3, H4), 1 min (H5,
  H6), H7 at once after its own two failed rounds; a step settles 30 s (R1), 1 min (R2), 2 min (R3,
  R4), 5 min (R5, R6); cycles 5 min apart, then 15 min, then once an hour — the slow cadence; 10
  min of health start everything over; a maintenance window lasts 3 min, 5 min for the FCC unlock.
  Rejected: faster values (more resets on a flaky network), slower ones (a dead link kept longer).
- **Data-path probe**: ICMP to `1.1.1.1` and `8.8.8.8` in turn, a round every 60 s — up to 3
  requests of 1 s, the next round 10 s after one that failed, the first 5 s after the address was
  set; about 3 MB a month. Rejected: every 30 s (twice the traffic), every 5 min (a dead path kept
  minutes), the operator's DNS servers (a DNS outage would restart a working link).
- **Recovering in the tray**: amber, *Recovering*, with the step; red, *Connection lost*, once
  the cycles have run out. Rejected: a colour of its own, and amber throughout.
- **Soak run**: 24 h on the real modem, with handle, GDI/USER, memory and thread counts.

## 2026-10-01 — CI: the linter retries while it makes progress; failures become annotations

The first push of M3 failed at the lint step on GitHub, while a fresh clone lints clean
locally. A run's log needs authentication to read; its annotations don't. Two changes:
- **`tools/Invoke-Lint.ps1` retries for as long as it makes progress.** The analyzer's own
  breakage ("'Get-Command' is not recognized") ends a child process; the files left over went to
  a new one up to five times, which 67 files can outrun on a slower runner. Now a new process is
  started as long as the last one analyzed a file, and only three in a row that analyzed nothing
  end the run. The list of files reaches the child in a temporary file: on the command line it
  outgrew Windows' limit in a deep folder.
- **Diagnostics, unanalyzed files and failed tests are written as annotations** under GitHub
  Actions: the next failure says what it is without the log. The test step no longer uses
  Pester's `-CI` exit, so that it can write them first; its result is explicit.

## 2026-10-01 — Decided: the FCC unlock on a locked module is optional

Proving the unlock on a module that is really locked, and capturing its locked values, needs
hardware the project doesn't have. It is no longer awaited: taken up only if such a module turns
up or a user needs it. The unlock stays proven on the simulated modem; the locked values stay
documented from `[4PDA]` (`AT-COMMANDS.md` §4).

## 2026-10-01 — M3 complete: the tray app

The app now runs as designed in ARCHITECTURE → *Process model*: a worker in a runspace of its own
owns the modem, the UI thread shows the tray icon and the main window and supervises the worker.
The decisions taken while building it:
- **One link per worker, nothing else shared.** A synchronized hashtable carries the command
  queue, a wake event, the latest snapshot, the heartbeat and the stop request. A new worker gets
  a new link, so one that hung and comes back to life can't write over its successor's state.
  Snapshots are new objects at every publication and are never changed; a test serializes one,
  runs more cycles that change everything, and compares.
- **The heartbeat never waits on the modem.** The worker wraps its transport and reads at most a
  second at a time, the channel reading again until the command's own timeout: a 3-minute
  `AT+COPS` keeps beating, so the hang limit can be a minute instead of longer than the slowest
  command. Only a call that never returns — PnP, the network stack — stops the heartbeat.
- **An error stops the cycle, not the worker.** PowerShell's default would carry on with the
  next statement after an error, half a cycle done on a state the error left behind; the worker
  runs with errors as stops, logs the failed cycle and tries again a second later. Three failed
  cycles in a row end it, and the supervisor's backoff takes over: a failure that every cycle hits
  restarts the worker, one that a single phase hits (a PnP read) is retried on its own cadence.
  A log that can't be written never stops the worker or a pass: monitoring matters more than its
  record.
- **The AT port is found by PnP at every look**, never remembered: after a re-enumeration the
  modem can come back under other COM numbers. Proven with PnP and the serial port mocked around
  the simulated modem: lost on COM14, found on COM15 as a new instance, attached without a write.
- **Without administrator rights** the state machine stops before configuring the adapter
  (`NotElevated`, blocked), instead of a step that fails at every pass. A port another program
  holds is said (`PortInUse`), not blocked: it can be released.
- **The UI never waits.** Buttons queue commands; outcomes come back in snapshots. The texts and
  icon states are pure functions of a snapshot, with a matrix of tests; the window and the tray
  only show them. Hundreds of icon redraws leave the process's GDI and USER object counts flat.
- **Development mode** drives the worker on a simulated modem and adapter with eight scenarios
  (one per state the window has to show), in a data folder of its own; the same scenarios feed
  the tests. **Observe-only** reads and never writes — what made the first device run safe.
- **5G is the NR leg in use.** On the device an idle LTE anchor cell fills `+CESQ`'s NR fields
  with no NR cell listed (`AT-COMMANDS.md` §3), so "NR measured" no longer means 5G: the
  technology comes from the serving cells, and NR measured without a leg is "5G available".

On the device: observing only, the worker and the tray found the modem by PnP, read it every
5 s and released the port on *Exit*; a second launch brought the window back. Elevated, with an
APN: online from nothing in about 3.5 s (context defined and activated, adapter configured), data
through the modem only, still online after *Exit*, and the next start attached without a step.

The lite review of M3 found six defects in the product; all six are fixed, each with a test that
fails without the fix:
- **A modem that stops answering cost the status read three minutes** — `AT+COPS?` carries its
  3-minute timeout — with the window still saying online and commands waiting. The status read now
  stops at the first read without an answer and brings the pass forward, which says what it means.
- **A failed part of a cycle wasn't the one retried**: the look, the pass and the status read were
  marked done before they ran, so the retry a second later found nothing due, and three failures
  in a row could never add up. They are marked done once they have run.
- **After the computer slept, a healthy worker looked hung**: the clock runs on during sleep while
  the worker's waits and the UI's timer don't. Silence is now counted from the resume.
- **One PnP read that missed the network function** left the connection blocked on `NoAdapter` for
  as long as the port stayed open. PnP is read again for it at the scan cadence, the port left open.
- **A second launch without the running instance's administrator rights failed** instead of
  exiting: opening the instance's event is denied, and is now taken as "running".
- **The last signal stayed on screen** when the state fell below a ready SIM without losing the
  port; it is dropped with the readings that stop.
And one found while checking the exit path: a runspace stuck in a call that never returns keeps
the `pwsh` process — and the AT port — alive after the app has closed everything else, so the start
script ends the process itself. The operator alone no longer names the technology "LTE": no
document says so, and no serving cell means no technology to show.

## 2026-10-01 — Decided: the worker's cadence, the supervisor's timings, the icon, 5G

Taken by the maintainer, as proposed:
- **Cadence**: a connect pass every 30 s online, 10 s on its way, 30 s while waiting for the
  user (whose command runs one at once); the radio every 5 s; PnP every 5 s without a port.
- **Supervisor**: hung after 60 s without a heartbeat; a new worker 5 s after a failure, doubling
  up to 5 min, the count reset by 10 min of good running; a failed cycle retried after 1 s, three
  in a row end the worker.
- **Icon and texts**: green online, amber on its way, red when the user must act, grey without a
  modem or a worker; bars from −115/−105/−95/−85 dBm; the 5G/4G label from 24 pixels up; menu
  *Open*, *Check now*, *Exit*; English texts, like the rest of the project.
- **5G only for the NR leg in use**; NR measured on an idle anchor is "LTE, 5G available".
  Rejected: 5G whenever NR is measured, which the icon would show almost always.

## 2026-10-01 — The adapter plan converges on the device

The per-family DNS comparison, written after the review, checked on the real adapter: the app's
own pass, as administrator, defined and activated the context and configured the adapter
(`Online`, data through the modem); a second pass changed nothing. Windows lists three `fec0`
IPv6 DNS servers on an unconfigured adapter and drops them once IPv4 servers are set, so here the
whole-list comparison would have matched too; the per-family one holds either way.

## 2026-10-01 — Decided: an unreadable APN password, a disabled adapter

The two decisions the M2 review left open, taken by the maintainer:
- **An APN password that can't be read is asked for again, never sent empty.** With PAP or CHAP,
  no stored password still means an empty one — some operators expect a user name with an empty
  password — but a stored password that can't be decrypted (another Windows user, a damaged file)
  now stops the pass before activation, blocked (`ApnPasswordUnreadable`): sending an empty one
  instead failed at every pass and would have made M4 escalate for nothing. An active context is
  left alone. Rejected: always requiring a password with PAP or CHAP, which would shut out those
  operators.
- **A disabled adapter stays the user's choice.** The pass stops (`AdapterDisabled`, blocked), as
  built; M3's window offers to enable it (administrator rights). Rejected: enabling it silently,
  which overrides an explicit choice.

## 2026-10-01 — M2 complete: the review pass

One lite review of M2's changes found nine defects in the product; seven are fixed, each with a
test that fails without the fix:
- **A failed read is unknown, never "no".** One error on `+CGPADDR` or `+CGCONTRDP` made a working
  context look address-less: with other settings pending it was deactivated, with an empty APN the
  user was asked for one. Now the context is `ContextUnknown` (no step, not blocked). Likewise a
  definition is written only over a context known to be inactive — `+CGACT?` is read with
  `+CGDCONT?`, registered or not — and a modem error on `+CPIN?` other than the SIM codes is an
  unknown SIM state, not a blocked one.
- **DNS servers are compared per family.** Windows reads IPv4 servers first and lists IPv6 ones
  nobody set, so the whole-list comparison could fail to match for good (an IPv6-first override, IPv6
  servers left on the adapter): it would never count as configured and `SetDns` would run at
  every pass.
- **The PIN attempt is read back before the PIN goes out**: a file that can't be written no longer
  lets an unrecorded PIN through (`Write-AppFile` now throws whatever the caller's error
  preference, and leaves no temporary file). A pending attempt is cleared only by its own SIM.
- **"Remove the PIN"** refuses a PIN that isn't 4 to 8 digits, without echoing it, and sends
  nothing when the PIN request can't be read.
- **A disabled adapter** stops the pass, blocked, instead of failing `ConfigureAdapter` at every
  pass.

Two needed the maintainer: APN credentials whose stored password can't be read, and whether the
app may enable a disabled adapter (decided, entry above).

## 2026-10-01 — M2 on the device: the data context the FM350 really gives, and the SIM PIN

The device session answered M2's open questions (`AT-COMMANDS.md` §1–§4, §7) and changed the code
where the modem differs from its documents:
- **The address comes from `+CGPADDR`.** For the app's context `+CGCONTRDP` gives the APN and the
  DNS servers only — no address, mask or gateway — and the modem serves no DHCP. The observation
  falls back on `+CGPADDR=1`, and the adapter plan, given no mask and no gateway, configures a /32
  with a default route on the link: the modem answers ARP for every destination. Verified carrying
  traffic. Of the plan's problems only a missing address remains.
- **An empty APN is not always the internet.** On two operators' SIMs the network put a context
  defined with an empty APN on the IMS APN — once without an IPv4 address, once with one. A
  context without an address, or whose APN has the network identifier `ims`, counts as carrying no
  internet: with an empty APN in the settings the pass stops with `ApnNeeded` (blocked, the user
  gives an APN); with an APN given, that context — it carries nothing — is deactivated and set up
  again as the settings say (`DeactivateContext`). The default stays empty: it works where the
  network assigns its internet APN. Both paths verified on the device.
- **A written context doesn't survive a reset** on our modem, contrary to the manual. The pass
  already writes it when missing; the documents no longer promise persistence.
- **`+C5GREG?` with `<n>` 0 answers `<n>` alone**, registered or not. Registration read answers are
  parsed as such (`-ReadAnswer`), so a lone value is never taken for "not searching".
- **Attempts left from `+EPINC`.** The FM350 has no `+CPINR`; the first value of `+EPINC?` went
  from 3 to 2 after a wrong PIN. The observation and "remove the PIN" ask `+CPINR` first and fall
  back on it, so the last-attempt rule works on this modem. The PIN rules held on the device: a
  wrong PIN sent once and deleted, the right one entered once, the busy SIM waited out, the PIN
  request turned off with one command.
- **The FCC unlock sequence stays as it was done**, `AT+GTFCCEFFSTATUS=0,0` included and its
  documented error tolerated (the maintainer's decision; the open decision is closed). Our module
  took the mode write with no challenge-response; other sources pass the challenge first, so some
  modules may refuse it.
- **COM numbers change.** After a re-enumeration the modem can come back as a new device instance
  with other COM numbers: the worker (M3) finds the port and the adapter by PnP every time it
  opens them. (Two re-enumerations happened while the SIM was swapped; two later swaps caused
  none, so a loose USB contact is the likelier cause — `AT-COMMANDS.md` §3.)

## 2026-10-01 — M2 code-complete: the connection, proven on the simulated modem

Everything in M2 that doesn't need the device is built and tested; the device session remains.
What it is, in ARCHITECTURE → *Connection state machine*, *SIM PIN*, *FCC lock*, *Network
configuration*, *Settings and logs*. The decisions taken while building it:
- **A pass, not a script.** `Invoke-ModemConnect` observes, lets the pure state machine pick the
  first missing step, runs it, observes again — and never runs a step twice in one pass. Startup
  reconciliation is the same pass: on a connection that is up it changes nothing, which a test
  proves by counting the commands that write. Opening the port and the cadence between passes are
  the worker's (M3).
- **Blocked versus waiting.** When there is no step to take, the state machine says why, and
  whether it is out of the app's reach (no device or driver, a SIM waiting for the user, an FCC
  lock, no adapter): M4 escalates none of those.
- **The app's context is context 1**, beside the modem's own attach context 0. A context that is
  active but differs from the settings is left alone: settings apply at the next connect.
- **SIM PIN**: the attempt is written down before `AT+CPIN` is sent, so a lost answer is never
  followed by a second one; a SIM whose ICCID can't be read is sent nothing; the PIN file keeps a
  SHA-256 of the ICCID, encrypted, never the ICCID itself.
- **The FCC diagnosis needs no time limit.** The vendor manual documents `+GTFCCEFFSTATUS` as
  *effective mode, unlock status*, and one locked module was found on record answering `2`, `0`,
  `2,0` with its radio refused (`AT-COMMANDS.md` §4). So "locked" is a documented value on a modem
  that doesn't register, not a registration that took too long — which also removes a threshold
  the maintainer would have had to set. The rule stands: the values never stop a modem that
  registers. The unlock reads the lock first and writes nothing to a module that isn't locked.
- **Network**: an address the modem hands out by DHCP is kept; otherwise the adapter is configured
  from `+CGCONTRDP`, in the active store, from a plan that is empty once the adapter is right.
  IPv4 only: IPv6 is left to router advertisements, so `IPV6` alone is not offered as a PDP type.
  DNS servers have no active store: they are rewritten at every connect.
- **Settings are read leniently and written strictly**: a bad value falls back to its default
  and is reported, so a damaged file never stops the app; a bad value is never written.
- **The log redacts every line on its way in**, secrets included (`AT+CPIN=`, `AT+CLCK=`,
  `+CGAUTH`); one file a day, 14 kept, 10 MB a day at most. Tests check that the PIN and the APN
  password appear neither in a pass's result nor in the log.
- **Timeouts come from the lookup by default**: `Invoke-AtCommand` without `-TimeoutMs` waits the
  command's documented worst case; a compound line gets the sum.
- **Reading PnP: one call per device, given the device object.** Given several devices,
  `Get-PnpDeviceProperty -InputObject` sometimes labelled one device's properties with another's
  instance ID — on the real modem the network function then lost its parent and showed up as a
  second modem (once in 20 reads); one call per device was right in 200 reads and costs about
  50 ms each, against a second each given an instance ID. The `Hardware` test that caught it reads
  PnP only, so it can run while the app holds the AT port.
- The simulated modem gained answers that change once a command has run (a context activated, a
  SIM unlocked), which the connect-sequence tests are built on.

FCC facts added to `AT-COMMANDS.md` §4 from the vendor manual §17 and three sources new to the
project (`[4PDA]`, `[MM-FCC]`, `[FOUNDATA]`), facts only. One finding is the maintainer's to settle
(ROADMAP → *Open decisions*): the unlock sequence that worked on our module includes a command
the manual documents as answering `ERROR`.

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
