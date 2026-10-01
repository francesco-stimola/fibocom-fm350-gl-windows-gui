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
