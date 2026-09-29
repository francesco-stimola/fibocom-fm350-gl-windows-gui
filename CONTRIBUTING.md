# Contributing

Thanks for your interest in `fibocom-fm350-gl-windows-gui`.

## Independent implementation

This project must stay free of code it has no right to use. Code published **without a license**
— other tools for this modem included — is all-rights-reserved: it cannot be copied, translated or
paraphrased here, however useful it looks.

Facts about the modem are welcome from any source, but they go into
[`docs/AT-COMMANDS.md`](docs/AT-COMMANDS.md) **with that source** (a 3GPP spec, the Fibocom AT
manual, a capture from your own device) before code relies on them. Code under a license
compatible with AGPL-3.0 (MIT, BSD, GPL-3.0, …) may be reused with attribution in the file.

## Captures from your modem

Captures are the most useful thing you can contribute — but they contain identifiers. Before
anything reaches a pull request, replace IMEI, IMSI, ICCID, EID, phone numbers, serial numbers, cell
identity + TAC, message text and USSD replies with fake values of the same shape. Raw captures belong in `captures/`, which git
ignores (see [`docs/SETUP.md`](docs/SETUP.md)).

## Before opening a pull request

- `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1` reports
  nothing, and `Invoke-Pester -Path ./tests` is green.
- Behavior changes come with tests.
- `docs/ROADMAP.md`, `docs/DEVLOG.md` and `CHANGELOG.md` are updated when the change lands a
  roadmap item.
- Everything is written in English.

## License of contributions

By submitting a contribution you agree that it is licensed under the project's license,
[AGPL-3.0-or-later](LICENSE).
