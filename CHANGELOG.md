# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/). A release's section becomes its GitHub Release notes
(see `docs/SETUP.md` → *Releasing*).

## [Unreleased]

### Added
- Project setup: documentation (architecture, AT command specification, roadmap, setup), lint and
  test tooling, CI on every push and pull request, logo.
- Core module `FibocomFm350` with the `AT+GTACT` band-code codec: `ConvertTo-GtactBandCode` and
  `ConvertFrom-GtactBandCode`.
- AT channel: `Open-SerialAtTransport`, `New-AtChannel`, `Initialize-AtChannel`,
  `Invoke-AtCommand`, `Receive-AtUrc`, `Close-AtChannel`, with the line framing and classification
  `Split-AtText` and `Resolve-AtLine`.
- Simulated modem for tests and development: `New-SimulatedModem`, `Import-AtFixture`.
- Parsers: `ConvertFrom-AtIdentity`, `ConvertFrom-AtSimState`, `ConvertFrom-AtRegistration`,
  `ConvertFrom-AtOperator`, `ConvertFrom-AtSignalQuality`, `ConvertFrom-AtTemperature`,
  `ConvertFrom-AtCellInfo`, `ConvertFrom-AtCarrierAggregation`.
- Measurements and channels: `ConvertFrom-MeasurementIndex`, `ConvertFrom-Earfcn`,
  `ConvertFrom-NrArfcn`, with the 3GPP band tables as data.
- Connection: the state machine and the connect pass (attach without re-dialing), the SIM PIN
  rules, the FCC lock diagnosis and unlock, the modem adapter's configuration, settings, the
  redacted rolling log.
- Tray app (`src/App/Start-Fm350App.ps1`): a worker that owns the modem and keeps the connection
  up, supervised and restarted without re-dialing; one instance; a tray icon with signal bars,
  state and technology; a main window with status, signal, cells, carrier aggregation, what blocks
  the connection and how to unblock it, the SIM PIN and the connection settings; a development
  mode on a simulated modem and an observe-only mode.
- Health and recovery: checks from "is the modem on USB?" down to "do packets get through?" — a
  data-path probe sent from the modem's own address —, and a recovery ladder that starts from the
  gentlest step the failing check allows (configure the adapter again, restart the data
  connection, register again, radio off and on, restart the modem, restart its USB device) and
  climbs only while the link stays down, with grace and settle times, backoff and a slow cadence
  after the last step. Nothing is escalated for what no reset fixes — a SIM waiting for its PIN, an
  FCC lock, an APN to give, a disabled adapter — nor during maintenance windows. *Recovering* in
  the tray and the window. Proven over 24 hours on a real modem.
- Modes and bands: the modem's network mode and bands read at every pass; a *Network* tab and a
  tray submenu to keep 4G + 5G, 4G only, 5G only (SA) or the modem's own mode, with a checkbox per
  LTE and NR band. A new mode is tried first: kept once the modem registers with it, undone when it
  finds no network. Re-applied at every connect, never written when the modem has it already.
- Driver installation, "bring your own driver": the *Driver* tab says the app doesn't come with the
  modem's driver, where a copy of MediaTek's driver is published and by whom. The package you
  choose is copied where only administrators can write, checked — signed by Microsoft (WHQL), its
  catalog vouching for the INF, written for your modem's AT port, a version the app knows or one
  you accept — and installed with pnputil; nothing in it is ever run. Uninstalling it is offered.
- Installer: `install.cmd` copies the app under Program Files and checks that only administrators
  can change it, registers the tasks that start it with administrator rights from the Start-menu
  entry and at sign-in — off until you turn it on in the *Connection* tab —, one UAC prompt at
  install time, none afterwards; running it again updates the app, the running one exiting with
  its connection left up, and started again if the update fails. The app is listed in Settings →
  Apps → Installed apps, whose *Uninstall* runs `uninstall.cmd`, which removes it all.
  It installs on 64-bit Windows on an x64 processor only, and says so elsewhere.
- The app's own icon, the logo's glyph, on its window, the taskbar and the Start-menu entry; the
  window pinned to the taskbar starts the app as the Start-menu entry does.
- Languages: the app, its installer and its launcher speak English, Italian, German, French,
  Spanish, Portuguese, Dutch and Polish, as Windows' display language asks; the log stays in
  English.
- The window at its smallest size: the tabs scroll, and the footer no longer runs under *Check
  now*.
  PowerShell 7 is found at every start, as installed by winget, the Microsoft Store or its MSI, and
  the elevated app loads modules only from PowerShell's and Windows' own folders.
- Encrypted DNS: DNS over HTTPS to the DNS servers you choose, on the modem's adapter alone, with
  the template Windows knows for each server or the one you give; never falling back to plain DNS.
  Or to the server your template names, even by a name — a resolver at home on a dynamic address:
  the app looks the name up at the start and every hour (a setting). Should Windows be unable to,
  it asks the operator's DNS for that one name, in the clear: the only query the app sends
  unencrypted. The *Connection* tab shows whether it is on, and names any IPv6 DNS servers the
  network gives besides, which Windows may use in the clear. Needs Windows 11.
- Update notice: once per start, when the connection first comes online, the app asks GitHub for
  the latest release — through its release page when GitHub's API refuses, as it does once other
  clients sharing your address have used up its hourly limit —, and the tray menu says when a
  newer one is out, with a link to its
  page. It never downloads or installs anything, sends nothing about you or your computer, and a
  setting turns it off.
- Releases: a workflow publishes the zip and these notes from a `v*` tag, after the same lint,
  tests and package as CI.
