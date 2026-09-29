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
