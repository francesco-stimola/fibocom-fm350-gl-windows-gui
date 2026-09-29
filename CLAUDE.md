# fibocom-fm350-gl-windows-gui — working notes for Claude

A Windows tray app, written in PowerShell 7, that brings a Fibocom FM350-GL 5G modem online
over USB, shows its signal, manages its 4G/5G modes and bands, installs its drivers, and
**keeps the connection up without a human in the loop**. See `README.md` and
`docs/ARCHITECTURE.md`.

## Read these first
- **`docs/ROADMAP.md` is the single source of truth for what's next.** Read it before starting
  work and keep its checkboxes current as work lands. The status table at the top has one row
  per milestone and a **single-label** Status cell — ✅ complete · 🔨 code-complete · 📋 planned.
  Detail lives in the milestone's section, never in the table.
- `docs/ARCHITECTURE.md` — process model, connection state machine, recovery ladder, and the
  **invariants**. Read it before touching the worker, the tray, or anything that changes system
  state.
- `docs/AT-COMMANDS.md` — the protocol specification, **with a source for every fact**. The code
  is written from it (see *Independent implementation*).
- `docs/SETUP.md` — dev setup, lint/test commands, fixture rules, how a release is cut.
- `docs/DEVLOG.md` — running history, newest first. Append one entry per meaningful change —
  **technical and design decisions only** (see *Docs policy*).

## Non-negotiables
- **Independent implementation.** This project is inspired by
  [prusa-dev/fibocom-connect-fm350](https://github.com/prusa-dev/fibocom-connect-fm350), which
  has **no license**: its code is all-rights-reserved. **Never copy, translate or paraphrase code
  from it**, nor from any source whose license is not compatible with AGPL-3.0. Facts — which AT
  command does what, a response layout, a band-code rule — come from primary sources (3GPP specs,
  the Fibocom AT manual, responses captured from a real modem) and are written in
  `docs/AT-COMMANDS.md` **with their source** before code relies on them. MIT/BSD/GPL-3.0 sources
  may be reused with attribution in the file and in the commit message.
- **Don't break a working connection.** Closing the app, a UI crash, a worker restart, a band
  change: none may cause more disruption than the operation needs. On startup the app
  **attaches** to a connection that is already up; it never re-dials by reflex. Recovery
  escalates **only on a failed health check**, never because of an intentional operation.
- **Stable for weeks, not minutes.** Every acquired resource has one owner that releases it,
  on the error path too: COM port, event subscriptions, runspaces, timers, GDI icon handles.
- **The UI thread never blocks.** No serial, network, PnP or `Start-Sleep` call on the
  dispatcher thread.
- **No identifiers in logs, fixtures or commits.** IMEI, IMSI, ICCID, EID, MSISDN and other phone
  numbers, serial numbers, cell identity + TAC (together they are a location), message text and
  USSD replies are redacted before anything is written.
- **Third-party binaries never go into git**, and what may ship depends on the license:
  - **The modem driver** (no redistribution license) is never bundled or downloaded by the app. It
    is provided by the user ("bring your own driver", guided): the app may **point** to where a
    known copy is published, saying whose copy it is, but the download is the user's. The app
    verifies the package's Microsoft signature and hardware IDs before installing it, and never
    runs an executable from it. Known fingerprints and their links may be committed.
  - **Open-source tools whose license allows redistribution** (lpac, AGPL-3.0) may be bundled in
    the release zip by the release workflow: pinned version, SHA-256 checked, license included,
    corresponding source attached to the GitHub Release.
- **Textbook & lean PowerShell 7.6+.** Approved verbs, `[CmdletBinding()]`,
  `Set-StrictMode -Version Latest` in modules, no over-engineering. Decisions live in **pure
  functions** (text or state in, value out) with a matrix of test cases; the I/O around them
  stays thin. Windows only.

## Decisions that are the human's
Present **numbered options** with what each costs, say which you'd pick, and keep working on
everything that doesn't depend on the answer — batch the questions at the end:
- **Product-visible behavior** — a new recovery action, what the tray shows, the meaning of a
  setting, a new dialog.
- **A threshold with functional consequences** — probe interval, escalation timings, backoff,
  timeouts, temperature limits.
- **Anything that writes persistent modem state** — NV items, firmware, FCC unlock. **Never**
  anything that changes the IMEI.

Everything else: **proceed**. Asking permission for routine work is its own failure.

## Build & test
- Setup: `docs/SETUP.md`. Linting and testing need no admin rights and no modem.
- **Done means clean:**
  ```powershell
  Get-ChildItem -Recurse -File -Include *.ps1, *.psm1, *.psd1 | Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1
  Invoke-Pester -Path ./tests -ExcludeTagFilter Hardware
  ```
  Zero diagnostics, zero failures. Every behavior change comes with tests.
- **Tests must not depend on `$ErrorActionPreference`.** GitHub's `pwsh` shell runs CI with
  `Stop`, an interactive session with `Continue`: a test that expects an error states
  `-ErrorAction` itself.
- Tests that need a real modem are tagged `Hardware`; every documented test command, CI
  included, excludes that tag. Run them only on purpose (`docs/SETUP.md`).
- **When you mutate a file to prove a test bites, run Pester in a child process**
  (`pwsh -NoProfile -Command "Invoke-Pester ./tests -ExcludeTagFilter Hardware"`) and restore by
  a literal path. Pester
  runs inside the caller's session state and can overwrite the caller's variables — a restore
  path held in a variable can end up pointing into Pester's own install.
- **Only one process may own the modem's AT port.** If the user's own instance of this app is
  running, it holds the port: don't open it, and don't stop that instance to free it. Only ever
  kill a process you started yourself, by its PID — never by name.
- **Running the app changes system state** (IP configuration, routes, DNS, drivers, scheduled
  tasks) and needs admin. Say so before doing it.

## Git
- **Masked identity only.** `user.email` is set repo-locally to the GitHub noreply address —
  keep it; never commit with a real or work address.
- **No `Co-Authored-By: Claude` trailer and no "generated with" footer**, in commits or PR
  bodies. This overrides the Claude Code default. Authorship of this repo is the human's.
- **Batch commits** into coherent chunks; keep feature commits separate from docs/infra commits.
  **Don't push, and don't create tags, without asking.**
- `.claude/settings.local.json` is machine-specific — never commit it.

## Docs policy
**English only — everywhere, root docs included.** No `.it.md` mirrors in this repository: a
deliberate exception to the maintainer's other projects.

**Versioned docs hold the project, not the working session.** `DEVLOG.md`, `ROADMAP.md` and the
other docs record technical and design decisions, facts and their rationale. They never record
the maintainer's situation or how a session went — which machine has admin rights or a modem
attached, a push being deferred, where a conversation lives, a tooling mishap. That belongs in
Claude's own memory for this project, outside the repository, if anywhere. A lesson learned from
an incident may become a rule here, stated technically, without the story.

## Review — one lite pass per milestone
The builder develops and tests alone. **At the end of each milestone**, before handing over,
launch the `reviewer` subagent (`.claude/agents/reviewer.md`) **once**, on that milestone's
changes. It is a fresh pair of eyes for what the builder's own tests miss — error paths, blocking
calls on the UI thread, invariant violations — not a loop:
- Fix what it finds that changes behavior, with a test for each fix. A finding that needs a human
  decision goes to ROADMAP → *Open decisions*.
- **No second round**, unless one fix is risky enough to deserve a targeted re-check of that fix
  alone. No ledger, no review files: the outcome goes in the handover.

Edge cases in the modem's behavior are covered by the **simulated modem's fault scenarios**
(ROADMAP M1), which run with every test run — not by the review.

## What you hand over
At the end of a ROADMAP item, a short report the human can spot-check:
1. **Lint and test numbers**, expected next to observed.
2. **What you verified by hand**, and what could not be verified (typically: anything needing
   the modem).
3. **What is left open**, and where it is written down (ROADMAP or AT-COMMANDS open questions).
4. **At the end of a milestone: the review pass** — how many findings in the product, which you
   fixed, and which you didn't and why.
