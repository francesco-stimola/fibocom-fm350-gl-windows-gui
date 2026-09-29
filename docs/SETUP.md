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
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path ./tests -ExcludeTagFilter Hardware
```

Both must be clean: zero diagnostics, zero failures. CI (`.github/workflows/ci.yml`) runs the same
two commands on every push to `main` and every pull request.

- **This test command needs no modem and no admin rights.** Tests that talk to a real device are
  tagged `Hardware`, and every documented command excludes them: Pester itself runs every tag
  unless told otherwise. Run them on purpose with `Invoke-Pester -Path ./tests -TagFilter Hardware`
  on a machine where the modem is attached **and this app is not running** (it would hold the AT
  port).
- CI's `pwsh` shell sets `$ErrorActionPreference = 'Stop'`; a test that expects an error passes
  `-ErrorAction` explicitly so it behaves the same in CI and in an interactive session.
- Tests import the module **through its manifest**, the way the app does, so a function missing
  from `FunctionsToExport` fails the tests instead of passing them.

### Current tests

| File | What it proves |
|---|---|
| `tests/Bands.Tests.ps1` | `AT+GTACT` band codes: encoding matrix per RAT, rejected inputs, decoding matrix, unknown codes kept as-is, empty or malformed fields refused (never read as "all bands"), full encode→decode round trip. |
| `tests/Module.Tests.ps1` | The manifest is valid and exports exactly the public functions. |

## Fixtures (from M1)

Raw captures go to `captures/` at the repository root, which git ignores. Redacted copies go to
`tests/fixtures/`, one file per command and situation. Before a fixture is committed, identifiers are replaced with obviously fake values of
the same shape: IMEI, IMSI, ICCID, EID, MSISDN and other phone numbers, serial numbers, cell
identity + TAC, message text and USSD replies. M1 adds a test
that fails on any fixture still carrying something that looks like a real identifier.

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
