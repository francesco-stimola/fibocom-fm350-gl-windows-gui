# AT command specification

This is the protocol the code is written **from**. Every fact the code relies on — which command
does what, a response's layout, a code table — is written here first, **with its source and its
status**. Nothing in `src/` should encode a modem fact that isn't on this page.

Why this discipline exists: the project that inspired this one,
[prusa-dev/fibocom-connect-fm350](https://github.com/prusa-dev/fibocom-connect-fm350), has no
license, so its code cannot be reused (see `CLAUDE.md` → *Independent implementation*). Facts are
not copyrightable; code is. Writing the facts down with their origin is what keeps the line
between the two visible.

## Status legend

| Mark | Meaning |
|---|---|
| ✅ | **Verified on a device** — a redacted capture lives in `tests/fixtures/` and a test parses it. |
| 📄 | **Documented** — stated by the cited source, not yet observed on our device. |
| ❓ | **To verify** — assumed, inferred, or contradicted between sources. Code relying on it must say so. |

A `[DEVICE]` fact names its fixture under `tests/fixtures/device/`.

## Sources

| Key | Source | License / nature |
|---|---|---|
| `[27.007]` | 3GPP TS 27.007 — *AT command set for User Equipment (UE)* (V19.6.0 checked for byte counters) | Public standard |
| `[27.005]` | 3GPP TS 27.005 — *Use of DTE-DCE interface for SMS and CBS* | Public standard |
| `[23.040]` | 3GPP TS 23.040 — *Technical realization of the Short Message Service* (PDU layouts) | Public standard |
| `[23.038]` | 3GPP TS 23.038 — *Alphabets and language-specific information* (GSM 7-bit, UCS-2, data coding scheme) | Public standard |
| `[V.250]` | ITU-T V.250 — *Serial asynchronous automatic dialling and control* | Public standard |
| `[36.101]` | 3GPP TS 36.101 — *E-UTRA UE radio transmission and reception*, **V20.1.0** (`36101-k10.zip`, SHA-256 `9f9a56f5d0535e5f77da0b4154c3056ed6e0d09c4e0ee22b2beb9676de0144ad`) | Public standard |
| `[38.101-1]` | 3GPP TS 38.101-1 — *NR UE radio transmission and reception, FR1*, **V20.1.0** (`38101-1-k10.zip`, SHA-256 `274357963736f04ef5fe419288c2341a7b02897dd478d0bb9c46304a2d9f5eda`) | Public standard |
| `[36.133]` / `[38.133]` | 3GPP TS 36.133 / 38.133 — *Requirements for support of radio resource management* | Public standard |
| `[FIBOCOM]` | Fibocom *FM350 AT Commands User Manual* **V2.10** (2023-07-04), cited as `§<section> p.<page>`. No applicability table; its SAR chapters name the FM350-GL-16 variant (no NR). Copies are published by resellers; the document is marked all rights reserved and confidential, so only facts are taken from it, in our own words. | Vendor documentation — facts only |
| `[FIBOCOM-2.2]` | The same manual, **V2.2** (2021-02-22), whose applicability table names the FM350-GL. Same section numbers; cited only where it differs from V2.10. | Vendor documentation — facts only |
| `[INF]` | `usb2ser_tm.inf` 3.22.43.1 (MediaTek, WHQL-signed), the FM350 serial-port driver | Observed file contents (hardware IDs) |
| `[MODEMBAND]` | [prusa-dev/luci-app-modemband](https://github.com/prusa-dev/luci-app-modemband) — `modemband/files/usr/share/modemband/_fibocom_fm350_common` (FM350-GL support, 2024-04-17) | MIT |
| `[3GINFO]` | [prusa-dev/luci-app-3ginfo-lite](https://github.com/prusa-dev/luci-app-3ginfo-lite) — `luci-app-3ginfo-lite/root/usr/share/3ginfo-lite/modem/usb/0e8d7126` at commit `05465f45` (FM350-GL support by the same author, April 2024) | GPL-3.0 — compatible with this project's AGPL-3.0 |
| `[LPAC-WRAPPER]` | [prusa-dev/lpac-fibocom-wrapper](https://github.com/prusa-dev/lpac-fibocom-wrapper) — README | MIT |
| `[LPAC]` | [estkme-group/lpac](https://github.com/estkme-group/lpac) — `driver/apdu/stdio.c`, `docs/ENVVARS.md`, `docs/USAGE.md` (branch `main`, read 2026-09-29) | AGPL-3.0-only (core), LGPL-2.1 (`euicc/`) |
| `[SMS-TOOL]` | [obsy/sms_tool](https://github.com/obsy/sms_tool) at commit `866e7d7` (2026-08-15) — how it sends USSD requests and decodes replies | Apache-2.0 |
| `[FM350-UTIL]` | [wargio/fm350-util](https://github.com/wargio/fm350-util) at commit `4536075` (2026-07-17) — reads SMS from an FM350-GL | MIT |
| `[WWAN-29]` | [ddimension/wwand issue #29](https://github.com/ddimension/wwand/issues/29) (2026-09-14) — a user's SMS session with an FM350-GL on OpenWrt | User report — facts only |
| `[LINUX-OPTION]` | Linux kernel patch *"USB: serial: option: add Fibocom FM350-GL"* (Bjørn Mork, June 2024, [LKML](https://lkml.iu.edu/hypermail/linux/kernel/2406.3/04255.html)) — its commit message lists the USB interfaces | GPL-2.0 — facts only |
| `[UPSTREAM-README]` | [prusa-dev/fibocom-connect-fm350](https://github.com/prusa-dev/fibocom-connect-fm350) — **README only** (usage examples) | No license — facts only, never code |
| `[DEVICE]` | Responses captured from a real FM350-GL, redacted, in `tests/fixtures/` | Ours |

When a source is added, record its exact version or commit here.

## 1. USB identity

| Fact | Status | Source |
|---|---|---|
| USB vendor ID `0E8D` (MediaTek). | 📄 | `[INF]` |
| Two USB compositions, product IDs `7126` and `7127`. | 📄 | `[INF]` |
| The modem AT port ("MD AT") is interface `MI_04` on `7126` and `MI_06` on `7127`. | 📄 | `[INF]` |
| The serial-port driver package covers **only** the serial functions (INF class `Ports`); the network function is served by a different driver. | 📄 | `[INF]` |
| `7126` (mode 40) has 8 interfaces: `0` RNDIS control (class `02/02/ff`), `1` RNDIS data (`0a/00/00`), `2` and `4`–`7` vendor-class serial (`ff/00/00`), `3` vendor `ff/42/01` with no Linux driver. `7127` (mode 41) has 10, with serial interfaces up to `9`. | 📄 | `[LINUX-OPTION]` |
| On `7127` Windows enumerates **nine functions** under the composite device (`usbccgp`, reported name `FM350-GL`): `MI_00` RNDIS (interfaces 0–1 as one function, compatible class `e0/01/03`); `MI_02`–`MI_04` and `MI_06`–`MI_09` "USB COM Port", class `ff/00/00`; `MI_05` "ADB Interface", class `ff/42/01`, which Windows' own WinUSB driver serves (`winusb.inf`). | ✅ | `[DEVICE]` `pnp.7127.nodriver.json` |
| The network function is **RNDIS** in both compositions. | 📄 | `[LINUX-OPTION]`, `[FIBOCOM]` §13.1.1 p.232 |
| Windows' built-in RNDIS driver serves it (`wceisvista.inf`, service `usbrndis6`, `usb80236.sys`), matched on the compatible ID `USB\Class_e0&SubClass_01&Prot_03`: **no driver to install for the network adapter.** With no data context active the adapter is up but disconnected, DHCP on, with a link-local address. | ✅ | `[DEVICE]` `pnp.7127.nodriver.json` (7127); 7126 not observed |
| The AT/serial interfaces are **vendor class** (`ff`), which Windows' built-in `usbser.sys` (CDC ACM) does not claim: the AT ports need the MediaTek serial driver. Without it every serial function stands with **problem code 28** (drivers not installed), no class and no service, and no COM port exists. | ✅ | `[LINUX-OPTION]`, `[INF]`; `[DEVICE]` `pnp.7127.nodriver.json` |
| The composite device's instance ID is **generated by Windows** (`<n>&<hash>&<n>&<port>`), not a USB serial number, so it changes when the modem moves to another USB port. The modem is found by hardware ID, never by a remembered instance ID. | ✅ | `[DEVICE]` (shape of the captured instance ID; redacted in the fixture) |
| The MediaTek serial driver is **not** on the Microsoft Update Catalog (searched by hardware ID, file name and version on 2026-09-28), so Windows Update will not install it by itself. | 📄 | Microsoft Update Catalog |
| The FM350 "Ports" drivers that **are** on the catalog — Fibocom and HP 0.6.200.352, Palcom 5933.0.6.1 — serve the **PCIe** module only (`PCI\VID_8087&PID_0B5D`…, `PCI\VID_14C0&PID_0B5D`…, `PCI\VEN_14C3&DEV_4D75`): laptops use the FM350 over PCIe, so laptop driver packages don't carry the USB serial driver. | 📄 | Microsoft Update Catalog (packages inspected 2026-09-29) |
| `AT+GTUSBMODE` reports the USB composition. Mode `40`: RNDIS, AT, GNSS, META, debug and ADB functions; mode `41` adds log and META ports and is the **documented default**. Mode `40` is the `7126` composition and `41` the `7127` one. The setting is **persistent** and applies after a reset or power cycle — never changed by this app without a human decision. | 📄 | `[FIBOCOM]` §13.1.1 p.232; mode ↔ product ID: `[3GINFO]` (file header), `[LINUX-OPTION]` |
| Our device enumerates as **`7127`** (mode 41, the default), with the network adapter on Windows' RNDIS driver (above). | ✅ | `[DEVICE]` `pnp.7127.nodriver.json` |
| Every function of one physical modem — the AT port and the network adapter included — shares one Windows **container ID**, and hangs from one composite device (`Parent`). The app links them through the composite device: a container ID is shared with the whole computer when the port is non-removable (ARCHITECTURE → *Drivers*). | ✅ | `[DEVICE]` `pnp.7127.nodriver.json` |
| `+GTDIPCMODE` (persistent, applied after a reset) chooses between PCIe-only and dual mode, and whether the AT port is on USB (the default) or PCIe. Reading it can explain a missing USB AT port; the app never writes it. | 📄 | `[FIBOCOM]` §13.1.3 p.234 |

## 2. Transport

| Fact | Status | Source |
|---|---|---|
| Commands end with `CR`; responses are framed by `CR LF` and end with a final result code: `OK`, `ERROR`, or `+CME ERROR: <err>`. Result codes are verbose by default; unsolicited codes are framed the same way. | 📄 | `[V.250]`, `[27.007]`, `[FIBOCOM]` §2.4 p.13–14 |
| Command echo is **on** by default (`ATE1`) and comes back on after a reset; `ATE0` turns it off. The echo ends with CR alone. | 📄 | `[V.250]`, `[FIBOCOM]` §4.1 p.47 |
| **We keep echo on and anchor every answer on it**: a command's answer starts after its echo, so anything else arriving before the echo is left over from an earlier command (a late answer after a timeout) and is discarded. The modem runs one command at a time, so a late answer always comes out before the next command's echo. | — | Project design (ARCHITECTURE → *AT channel*) |
| `AT+CMEE=1` makes `+CME ERROR` and `+CMS ERROR` carry a **number**, `=2` verbose text; default `0`: plain `ERROR`. **We use `1`** and map the numbers ourselves, rather than depend on firmware wording. | 📄 | `[27.007]`, `[FIBOCOM]` §20.1.1 p.324 |
| The port speaks the 7-bit IRA character set by default (`+CSCS`); PDUs and UCS-2 strings travel as hex. So the channel reads bytes as text and drops anything outside printable ASCII as line noise. | 📄 | `[FIBOCOM]` §8.1.1 p.85 |
| Unsolicited codes the app enables, told apart from answers by their prefix: `+CREG`, `+CGREG`, `+CEREG`, `+C5GREG`, `+CSCON`, `+CMTI`, `+CDSI`, `+CUSD`, `+CGEV`. A prefix equal to the pending command's own is read as the answer when the command is a read, test or execute form (`+CEREG:` after `AT+CEREG?`); a set form (`AT+CEREG=2`, `AT+CUSD=1,…`) answers only with a final result, so a line with its prefix is unsolicited. Two-line codes (`+CMT`, `+CDS`) are never enabled. | 📄 | `[27.007]`, `[27.005]`; the FM350's actual URCs are a device question (§7) |
| DTR and RTS asserted on the USB virtual port, as a modem expects from a ready terminal. | ❓ | `[DEVICE]` — does the FM350 answer without them? |
| Error codes worth recognizing: CME `14` and CMS `314` = SIM busy; CME `149` = PDP authentication failure. `+CEER` gives the reason for the last failure, attach and activation errors included. | 📄 | `[27.007]`, `[FIBOCOM]` §20.1.2 p.325, §20.2 p.327, §20.3 p.332 |
| Unsolicited result codes (URCs) can arrive **between** a command and its final result code. The reader must separate them from the response. | 📄 | `[27.007]` |
| Commands have documented worst-case durations — `+COPS` up to 3 min, `+CMGS` 60 s, `+CGACT` 30 s, `+CGATT` 15 s, `+CUSD` 10 s, `+CMGL` 5 s, `+CMGR` and `+CSIM` 2 s, most others under 3 s. **Each command's timeout is its documented duration, never less than 3 s** (decided 2026-09-29). | 📄 | `[FIBOCOM]` (each command's attribute table) |
| Baud rate and flow control settings are irrelevant on the USB virtual COM port. | ❓ | `[DEVICE]` |

## 3. Standard commands we rely on (`[27.007]`)

Each is 📄 `[27.007]` until a capture makes it ✅. The notes record what the vendor manual
`[FIBOCOM]` adds, and where it is silent or disagrees.

| Purpose | Command | Notes |
|---|---|---|
| Identify manufacturer / model / firmware | `+CGMI`, `+CGMM`, `+CGMR` | `[FIBOCOM]` §3.1–3.6 p.17–21. See §4 for the quoted `?` forms. |
| IMEI | `+CGSN` | **Identifier — never logged, redacted in fixtures.** `[FIBOCOM]` §3.7 p.21: `=2` IMEISV, `=3` SVN. |
| IMSI | `+CIMI` | **Identifier.** Needs the SIM unlocked (`[FIBOCOM]` §3.9 p.25). |
| SIM state | `+CPIN?` | `READY` or the code of what the SIM is waiting for. `[FIBOCOM]` §10.1.1 p.132. |
| Radio power / reset | `+CFUN=<fun>[,<rst>]` | `1` full, `4` RF off, `0` minimum. `<rst>=1` resets the MT before applying `<fun>`. `[FIBOCOM]` §4.2 p.48 adds `15` = **reset** (no `<rst>` with it); after `0` or `15` the `OK` may never arrive. The read form is `+CFUN: <power_mode>,<STK_mode>`. |
| Operator selection | `+COPS` | `=0` automatic, `=2` deregister, `=3,<format>` sets the name format for the read. `?` returns `<mode>,<format>,<oper>,<AcT>`. Up to 3 min (`[FIBOCOM]` §11.1.6 p.160). |
| Registration status | `+CREG`, `+CGREG`, `+CEREG`, `+C5GREG` | `<stat>`: `1` home, `5` roaming, `2` searching, `3` denied, `0` not searching. `[FIBOCOM]` §11.1.3–11.1.5 p.150–157 documents the first three; `+CEREG` gives TAC and cell ID as quoted hex strings and, for `<n>` 3–5, the reject cause of a denied registration. **`+C5GREG` is in neither manual** ❓. |
| Registration report layout | `+CREG`, `+CGREG`, `+CEREG`, `+C5GREG` | The read answer starts with `<n>`, the unsolicited code doesn't: `+CEREG: <n>,<stat>[,…]` versus `+CEREG: <stat>[,…]`. After `<stat>`: `+CREG`/`+CEREG` `<lac or tac>,<ci>,<AcT>[,<cause_type>,<reject_cause>]`; `+CGREG` puts `<rac>` before the cause; `+C5GREG` puts `<Allowed_NSSAI_length>,<Allowed_NSSAI>` before it. Location fields are quoted hex. |
| Legacy signal quality | `+CSQ` | `<rssi>` 0–31, `99` unknown: `0` is −113 dBm or less, `1` −111, `2`–`30` −109 to −53 dBm in 2 dB steps, `31` −51 dBm or more. Not meaningful for LTE/NR quality. |
| Extended signal quality | `+CESQ` | RSRQ/RSRP for LTE and SS-RSRQ/SS-RSRP/SS-SINR for NR — the **standard** way to read LTE/NR quality. `[FIBOCOM]` §11.1.2 p.145: nine fields; the NR fields are valid on NR **and EN-DC** (so NSA reports them), the LTE ones on LTE and EN-DC; `<ber>` is always 99. |
| Define data context | `+CGDCONT=<cid>,<PDP_type>,<APN>` | `<PDP_type>` `IP`, `IPV6`, `IPV4V6`. **Persistent** on the FM350 (`[FIBOCOM]` §12.2.1 p.193): the connect sequence reads `+CGDCONT?` and writes only what differs. An empty APN means the subscription's own. |
| APN authentication | `+CGAUTH=<cid>,<auth_prot>,<user>,<password>` | **Password — never logged.** **In neither vendor manual** ❓: probe with `AT+CGAUTH=?`. The only documented alternative is `+EIAAPN` (§4), which writes persistent state. |
| PS attach | `+CGATT` | Up to 15 s (`[FIBOCOM]` §12.2.2 p.198). |
| Activate context | `+CGACT=<state>,<cid>` | Attaches first if needed; deactivating the last EPS context is refused. Up to 30 s (`[FIBOCOM]` §12.2.4 p.202). |
| Context address | `+CGPADDR=<cid>` | With dual stack, the first address is IPv4 and the second IPv6 (`[FIBOCOM]` §12.2.5 p.204). |
| Dynamic context parameters | `+CGCONTRDP=<cid>` | `+CGCONTRDP: <cid>,<bearer_id>,<apn>,<address and mask>,<gateway>,<DNS 1>,<DNS 2>,…`. **Address and mask are one string**: `"a1.a2.a3.a4.m1.m2.m3.m4"` for IPv4, 32 numbers for IPv6. Dual stack gives an IPv4 line, then an IPv6 line; more than two DNS servers add lines; a missing value is an empty string (`[FIBOCOM]` §12.2.10 p.215). The standard source for configuring the adapter. |
| IPv6 address format | `+CGPIAF` | Only needed if IPv6 is parsed. Referenced by the vendor manual, not documented in it. |

### `+COPS` access technology (`<AcT>`)

As defined by `[27.007]`:

| Value | Access technology |
|---|---|
| 0 | GSM |
| 1 | GSM Compact |
| 2 | UTRAN |
| 3 | GSM w/EGPRS |
| 4 | UTRAN w/HSDPA |
| 5 | UTRAN w/HSUPA |
| 6 | UTRAN w/HSDPA and HSUPA |
| 7 | E-UTRAN (LTE) |
| 8 | EC-GSM-IoT |
| 9 | E-UTRAN (NB-S1 mode) |
| 10 | E-UTRA connected to a 5GCN |
| 11 | NR connected to a 5GCN (**5G SA**) |
| 12 | NG-RAN |
| 13 | E-UTRA-NR dual connectivity (**5G NSA / EN-DC**) |

📄 `[3GINFO]` reads the FM350's `<AcT>` with this same table: `7` LTE (LTE-A when a secondary
carrier is listed by `+GTCAINFO`), `11` 5G SA, `13` 5G NSA.

❓ **The vendor manual disagrees.** Its `<AcT>` table (`[FIBOCOM]` §11.1.6 p.162, the same in
`[FIBOCOM-2.2]`) follows 27.007 up to `7`, then lists `8` CDMA, `9` CDMA and EVDO, `10` EVDO,
`11` eMTC, `12` NB-IoT, with no NR value — most likely a table inherited from another product
line. Captures of `+COPS?` on LTE, NSA and SA decide. `+ERAT?` (§4) reports the access technology
with its own numbering, EN-DC included, as a second opinion.

## 4. Fibocom commands (`[FIBOCOM]`)

Proprietary. Layouts come from the vendor manual, from captures, and from sources whose license
allows it (`[3GINFO]`, `[MODEMBAND]`) — never from unlicensed code.

| Purpose | Command | Status | Notes |
|---|---|---|---|
| RAT mode, preference and band lock | `+GTACT` | 📄 `[FIBOCOM]` §11.1.14 p.175 | See §5. |
| Serving and neighbour cells | `+GTCCINFO?` | 📄 `[FIBOCOM]` §11.1.15 p.179, `[3GINFO]` | Layout in §4.1. **Cell identity + TAC is a location — redact.** |
| Carrier aggregation | `+GTCAINFO?` | 📄 `[FIBOCOM]` §11.1.16 p.187, `[3GINFO]` | Layout in §4.2. Can be queried together with the above: `AT+GTCCINFO?;+GTCAINFO?`. |
| Current access technology | `+ERAT?` | 📄 `[FIBOCOM]` §11.1.11 p.169 | `<AcT>` `11` NR on a 5G core (SA), `12` NR on EPC, `13` NG-RAN, **`14` EN-DC (NSA)**, `255` unknown. |
| Signalling connection | `+CSCON` | 📄 `[FIBOCOM]` §12.2.13 p.223 | Standard command, FM350 values: an unsolicited `+CSCON: <mode>[,<state>[,<access>[,<core>]]]` — `<mode>` `0` idle, `1` connected; `<state>` `7` LTE connected, `8` NR connected, `9` NR inactive; `<access>` `3`/`4` LTE TDD/FDD, `5` NR; `<core>` `0` EPC, `1` 5G core. Under EN-DC the read form lists the master RAT, then the secondary. |
| SIM slot | `+GTDUALSIM` | 📄 `[FIBOCOM]` §4.3 p.50 | Slot `0` = SIM1 (default), `1` = SIM2. **Persistent**, takes effect immediately. Read form: `+GTDUALSIM: <slot>,<SUB1 or SUB2>,<service: No Service, N, L or W>`. See §8 for the eSIM. |
| DNS servers | `+GTDNS=<cid>` | 📄 `[FIBOCOM]` §12.2.17 p.230 | Answers `<cid>,<DNS 1>,<DNS 2>`. A fallback if `+CGCONTRDP` leaves DNS empty. |
| Module temperature | `AT+GTSENRDTEMP=<id>` | 📄 `[FIBOCOM]` §18.3 p.310, `[3GINFO]` | `0` lists every sensor, one line each; `1`–`23` one sensor (1–22 in `[FIBOCOM-2.2]`): `1` SoC maximum, `10` 5G modem, `11` 4G modem, `14` LTE PA, `15` NR PA, `16` RF, `19` PMIC, `23` crystal. Answers `+GTSENRDTEMP: <sensor>,<value>`. The manual gives no unit; `[3GINFO]` reads thousandths of °C, consistent with the manual's thermal thresholds (e.g. `32000`). |
| Model / manufacturer / firmware | `AT+CGMM?`, `AT+CGMI?`, `AT+GMR?` | 📄 `[FIBOCOM]` §3.1–3.6 p.17–21, `[3GINFO]` `[MODEMBAND]` | Values are **quoted**: `+CGMI: "<manufacturer>"`, `+CGMM: "<model>","<short name>"`. The firmware answer's prefix is `+CGMR:` in V2.10 and `+GMR:` in `[FIBOCOM-2.2]`: accept both, strip the quotes. |
| Firmware package version | `+GTPKGVER?` | 📄 `[FIBOCOM]` §3.21 p.38 | `+GTPKGVER: "<package>"` — a different string from `+CGMR`. |
| Identification | `ATI<n>` | 📄 `[FIBOCOM]` §3.18 p.35 | `0` build time, `3`/`7` product name, `5` platform, `8` software version, `9` hardware version. |
| Supported commands | `+CLAC` | 📄 `[FIBOCOM]` §3.14 p.31 | Lists the commands this firmware accepts — the first thing to capture. |
| Module serial number | `+CFSN?` | 📄 `[FIBOCOM]` §3.16 p.33 | `+CFSN: "<10 characters>"`. **Identifier.** |
| ICCID | `AT+ICCID` | 📄 `[FIBOCOM]` §3.12 p.29, `[3GINFO]` | Answers `+ICCID: <iccid>`, unquoted; works with the SIM locked. `+CCID` (§3.11) is the same. **Identifier.** |
| Vendor reset | `AT+CFUN=15` | 📄 `[FIBOCOM]` §4.2 p.48 | Also `+CFUN=<fun>,1`. Whether the USB device re-enumerates, and under which COM number: ❓. `+CPWROFF` (§4.8) switches the modem off with no documented way back — never used. |
| FCC lock state | `+GTFCCEFFSTATUS?` | 📄 `[FIBOCOM]` §17.3 p.304 | Read-only: `0` locked, `1` unlocked. The lock itself lives in NVRAM and is unlocked by a vendor challenge-response — **never** touched by this app. |

**Persistent settings the app only reads** (writing any of them is a human decision, see
`CLAUDE.md`): `+E5GOPT` — which of LTE, 5G SA ("option 2") and 5G NSA ("option 3") are enabled, as
a bitmap (`[FIBOCOM]` §12.2.15 p.228; the listed values `0x01`, `0x02`, `0x05` are ❓);
`+EIAAPN` — the initial-attach APN with its authentication (none, PAP, CHAP), user and password
(§12.2.14 p.226; **password — never logged**); `+GTFMODE` — whether the flight-mode and GNSS
hardware pins are honoured (§13.1.2 p.233); `+MSMPD` — SIM hot-plug detection, on by default
(§4.7 p.60); `+GTUSBMODE`, `+GTDIPCMODE` (§1); `+GTDUALSIM` (above); `+GTESIMCFG` (§8).
`+EPBSEH` (§11.1.12 p.171) shows the band selection as MediaTek bitmaps, a cross-check for
`+GTACT`.

### 4.1 `+GTCCINFO` layout

📄 `[FIBOCOM]` §11.1.15 p.179–187, `[3GINFO]`; ❓ until captured. A `+GTCCINFO:` line, then one
line per cell (up to ten per RAT), comma-separated; positions are 1-based. **Serving and neighbour
lines have different layouts**: read position 1 first. Under EN-DC (5G NSA) there are two serving
lines, LTE then NR, followed by the LTE neighbours. Answers in under 3 s.

| Pos. | Serving cell (LTE or NR) | Neighbour cell, LTE | Neighbour cell, NR |
|---|---|---|---|
| 1 | `1` = serving | `2` = neighbour | `2` = neighbour |
| 2 | RAT: `4` LTE, `9` NR (`2` WCDMA, `0` none) | `4` | `9` |
| 3–8 | MCC, MNC, TAC, cell identity, ARFCN (EARFCN / NR-ARFCN), PCI | same | same |
| 9 | Band, encoded like `+GTACT` (§5) | Bandwidth | SS-SINR index |
| 10 | Bandwidth | Level (RSRP scale) | Level (SS-RSRP scale) |
| 11 | SINR index — LTE RSSNR or NR SS-SINR | RSRP index | SS-RSRP index |
| 12 | Level (RSRP scale) | RSRQ index | SS-RSRQ index |
| 13 | RSRP index (NR: SS-RSRP) | — | — |
| 14 | RSRQ index (NR: SS-RSRQ) | — | — |

- **TAC and cell identity are location data.** Ranges `0`–`0xFFFF` and `0`–`0xFFFFFFFF`; whether
  they are printed in hex is not stated (`[3GINFO]` reads the TAC as hex) ❓.
- The level field uses the RSRP index scale; how it differs from the RSRP field is not stated ❓.
- The bandwidth field has no code table in this section; presumably the codes of §4.3 ❓.
- `255` = not known or not detectable. Conversions in §6.

### 4.2 `+GTCAINFO` layout

📄 `[FIBOCOM]` §11.1.16 p.187–191, `[3GINFO]`; ❓ until captured. A `+GTCAINFO:` line, then for each
RAT (LTE, NR) a `PCC:` line for the primary carrier and zero or more `SCC<n>:` lines for the
secondary ones, comma-separated after the prefix. The manual writes `SCC1:` without a space;
`[3GINFO]` expects `SCC <n>:` — accept both.

| Line | Fields, in order |
|---|---|
| `PCC:` | band code (§5), PCI, ARFCN, DL bandwidth (§4.3), DL MIMO layers, UL MIMO layers, DL modulation, UL modulation, RSRP |
| `SCC<n>:` | state — `1` configured, deactivated; `2` configured and **active**; uplink CA on this cell (`0`/`1`); band code; PCI; ARFCN; DL bandwidth; UL bandwidth; DL MIMO layers; UL MIMO layers; DL modulation; UL modulation; RSRP |

- MIMO layers: `1`–`4`. Modulation: `0` BPSK, `1` QPSK, `2` 16QAM, `3` 64QAM, `4` 256QAM, `5`
  1024QAM, `6` unknown.
- **Parse from the start of the line, never from its end.** The trailing fields changed in manual
  V2.7 (`[FIBOCOM-2.2]` ended the lines differently), so older firmware may differ at the tail.
- ❓ The encoding of the trailing RSRP; whether the LTE and NR blocks carry a header line; whether
  both blocks appear under EN-DC.

### 4.3 Bandwidth codes

📄 `[FIBOCOM]` §11.1.16 p.189–190, `[3GINFO]`: the code is the bandwidth in MHz × 5, except `6` =
1.4 MHz. LTE: `6` 1.4, `15` 3, `25` 5, `50` 10, `75` 15, `100` 20 MHz. NR adds `125` 25, `150`
30, `200` 40, `250` 50, `300` 60, `400` 80, `450` 90, `500` 100, `1000` 200, `2000` 400 MHz. `0`
= not reported (`[3GINFO]`; not stated by the manual).

## 5. `+GTACT` — mode and bands

📄 `[FIBOCOM]` §11.1.14 p.175–179 (identical in `[FIBOCOM-2.2]`).
Syntax: `AT+GTACT=[<rat>[,[<pref1>],[<pref2>][,<band>...]]]`. The RAT part and the band part can
each be set alone.

| `<rat>` | Mode |
|---|---|
| `1` | UMTS |
| `2` | LTE |
| `4` | LTE + UMTS |
| `10` | Automatic — reads back as `20` |
| `14` | NR |
| `16` | NR + UMTS |
| `17` | NR + LTE |
| `20` | NR + UMTS + LTE |

`<pref1>`, `<pref2>` are the first and second preferred RAT — `2` UMTS, `3` LTE, `6` NR — and must
belong to `<rat>`. In a two-RAT mode only `<pref1>` counts. With `20` the manual lists the accepted
combinations: no preference, one, or two different ones; anything else is rejected.

| Fact | Status | Source |
|---|---|---|
| `AT+GTACT=20,6,3,0` — NR + UMTS + LTE, NR preferred then LTE, all bands. | 📄 | `[UPSTREAM-README]`, `[FIBOCOM]` |
| `AT+GTACT=2,3,3,0` — LTE only, all bands. | 📄 | `[UPSTREAM-README]` |
| Band code `0` means **automatic band selection** for the RATs named in the command, or for every RAT if none is named. | 📄 | `[FIBOCOM]`, `[UPSTREAM-README]`, `[MODEMBAND]` |
| **LTE band N is written `100 + N`** (B1 → `101`, B3 → `103`, … B71 → `171`). | 📄 | `[FIBOCOM]`, `[UPSTREAM-README]`, `[MODEMBAND]` |
| **NR band N is written `"50"` followed by N** (n1 → `501`, n9 → `509`, n10 → `5010`, n78 → `5078`, up to n512 → `50512`). | 📄 | `[FIBOCOM]`, `[MODEMBAND]` |
| UMTS band N is written N (`1`–`10`). The app doesn't manage UMTS bands and keeps their codes as read. | 📄 | `[FIBOCOM]` |
| **Band lists are per RAT.** Writing LTE codes changes only the LTE list; the UMTS and NR lists stay as they were. `AT+GTACT=20,6,3,103,107` restricts LTE to B3 and B7 and leaves NR as it was. | 📄 | `[FIBOCOM]` (note 5); `[UPSTREAM-README]` shows the command |
| `AT+GTACT?` answers `+GTACT: <rat>,<pref1>,<pref2>,<band>,<band>,…` with the band codes currently set. | 📄 | `[FIBOCOM]`, `[MODEMBAND]` |
| `AT+GTACT=?` lists the supported values: RATs, first and second preference, then GSM, UMTS, LTE, CDMA, EVDO and NR band codes. | 📄 | `[FIBOCOM]` |
| To change bands without changing the mode: read `AT+GTACT?`, keep its first three values, and write them back followed by the new codes. | 📄 | `[MODEMBAND]` |
| Band lists supported by the FM350-GL — LTE: 1 2 3 4 5 7 8 12 13 14 17 18 19 20 25 26 28 29 30 32 34 38 39 40 41 42 43 46 48 66 71; 5G: n1 n2 n3 n5 n7 n8 n20 n25 n28 n30 n38 n40 n41 n48 n66 n71 n77 n78 n79; UMTS: 1 2 4 5 8. | 📄 | `[MODEMBAND]` (its default lists), `[FIBOCOM]` §13.1.6 p.241 (the same bands); ❓ confirm with `AT+GTACT=?` — firmware variants differ (the FM350-GL-16 has no NR) |
| The `OK` comes back at once; the modem then **registers again** with the new setting. | 📄 | `[FIBOCOM]` |
| **Not persistent**: a reset loses the setting. | 📄 | `[FIBOCOM]` (attribute table) — the app re-applies it on every connect regardless. |
| How one RAT goes back to all bands while another stays restricted: `0` applies to every RAT named, so presumably by listing every supported band of that RAT. | ❓ | Inferred; verify on `[DEVICE]` |
| Whether LTE and NR codes can be listed in one command. | ❓ | Not stated; verify on `[DEVICE]` |
| Whether NR band codes also restrict NR in **NSA** mode, or only SA. `[MODEMBAND]` handles them as SA bands. | ❓ | `[DEVICE]` |

The codec lives in `src/FibocomFm350/Bands.ps1`. It encodes LTE B1–B99 and NR n1–n512; LTE bands
from 100 up have no documented code (`100 + N` would leave the `101`–`199` range), so it refuses
them instead of guessing. It decodes a code it doesn't recognize — UMTS codes included — as
`Unknown`, keeping the raw value, so writing a band list back never silently drops something the
modem reported (ARCHITECTURE → *Invariants*).

## 6. Measurements and bands from radio numbers

| Fact | Status | Source |
|---|---|---|
| LTE RSRP/RSRQ and NR SS-RSRP/SS-RSRQ/SS-SINR are reported as **indexes** that map to dBm/dB ranges. | 📄 | `[36.133]`, `[38.133]`, `[27.007]` (`+CESQ`), `[FIBOCOM]` §11.1.15 p.182–187 |
| Index → value for `+GTCCINFO` (§4.1), `255` meaning *not available*: LTE RSRP = idx − 141 dBm; NR RSRP = idx − 157 dBm; LTE RSRQ = idx/2 − 20 dB; NR RSRQ = idx/2 − 43.5 dB; NR SINR = idx/2 − 23.5 dB — each the **lower edge** of the index's range. LTE SINR (RSSNR) = idx/2 dB, the **upper** edge, on a signed index. | 📄 | `[3GINFO]`, `[FIBOCOM]` (range tables below) |
| The range edges, per the table below. | 📄 | `[FIBOCOM]` §11.1.15 p.182–187 and §11.1.2 p.145–149, which cite the 3GPP clauses listed |
| LTE band and downlink frequency from EARFCN: `F_DL = F_DL_low + 0.1 (N_DL − N_Offs-DL)` MHz, with `F_DL_low`, `N_Offs-DL` and the range of `N_DL` per band from Table 5.7.3-1. Downlink channel numbers are unique across bands. Transcribed in `src/FibocomFm350/Data/EutraBands.psd1` (70 bands). | 📄 | `[36.101]` clause 5.7.3, Table 5.7.3-1 |
| NR frequency from NR-ARFCN (FR1): `F_REF = F_REF-Offs + ΔF_Global (N_REF − N_REF-Offs)`; `0`–`599999`: 5 kHz steps from 0 MHz; `600000`–`2016666`: 15 kHz steps from 3000 MHz. | 📄 | `[38.101-1]` clause 5.4.2.1, Table 5.4.2.1-1 |
| NR bands from NR-ARFCN: the downlink range of each band (first to last, over all its raster steps), supplementary-uplink bands left out. Transcribed in `src/FibocomFm350/Data/NrBands.psd1` (61 bands). | 📄 | `[38.101-1]` Table 5.4.2.3-1 |
| NR-ARFCN ranges **overlap** between bands (n77/n78, n1/n65/n66 ...), so ARFCN alone can be ambiguous: prefer the band the modem reports, fall back to the table (all candidate bands). | 📄 | `[38.101-1]` |

| Measure | Index `0` | Index *i* covers | Top index | 3GPP clause cited |
|---|---|---|---|---|
| LTE RSRP | below −140 dBm | [*i* − 141, *i* − 140) dBm | `97`: −44 dBm and above | 36.133 §9.1.4 |
| LTE RSRQ | below −19.5 dB | [*i*/2 − 20, *i*/2 − 19.5) dB | `34`: −3 dB and above | 36.133 §9.1.7 |
| LTE SINR (RSSNR), signed −100…100 | — | (*i*/2 − 0.5, *i*/2] dB | `−100`: −50 dB and below; `100`: above 50 dB | vendor-defined |
| NR SS-RSRP | below −156 dBm | [*i* − 157, *i* − 156) dBm | `126`: −31 dBm and above | 38.133 §10.1.6 |
| NR SS-RSRQ | below −43 dB | [*i*/2 − 43.5, *i*/2 − 43) dB | `126`: [19.5, 20) dB | 38.133 §10.1.11 |
| NR SS-SINR | below −23 dB | [*i*/2 − 23.5, *i*/2 − 23) dB | `127`: 40 dB and above | 38.133 §10.1.16 |

`255` is *not known or not detectable* for the NR fields and RSSNR; for LTE RSRP the manual says
index `0` also covers *not detectable*.

## 7. Open questions for the first device session

Collected here so one session with the modem answers all of them. Each answer becomes a fixture
and flips a row above to ✅.

1. `AT+CLAC` — which commands this firmware accepts, in particular `+CGAUTH`, `+C5GREG`, `+CCHO`/`+CGLA`/`+CCHC`, and any undocumented traffic-statistics command. Then `ATI`, `+CGMM?`, `+CGMR`, `+GTPKGVER?` — which exact model and firmware.
2. Which USB composition (`7126`/`7127`), which COM port is "MD AT", which driver serves the network adapter, and whether it shares a container ID with the AT port. *Answered (§1) except the COM port, which needs the serial driver.*
3. `+COPS?` on LTE, on 5G NSA and on 5G SA — does `<AcT>` follow `[27.007]` or the vendor table (§3)? Compare with `+ERAT?`.
4. `+CESQ` on LTE, NSA and SA — confirm the documented NR fields.
5. `+CGCONTRDP=1` — confirm the documented layout (address and mask in one string, gateway, DNS).
6. Does the network adapter answer DHCP, or must the address be configured statically?
7. `AT+GTACT=?` and `AT+GTACT?` — the actual values; whether LTE and NR codes can be combined in one write; how to return one RAT to all bands; whether NR codes apply in NSA.
8. `+CFUN=1,1` and `+CFUN=15` — does the device re-enumerate on USB, and under the same COM number?
9. URCs seen during registration and during a drop, with `+CSCON` enabled.
10. `AT+GTCCINFO?;+GTCAINFO?` on LTE, LTE-A, NSA and SA — confirm §4.1/§4.2: hex or decimal TAC and cell ID, the bandwidth codes in `+GTCCINFO`, the NR block of `+GTCAINFO` under EN-DC.
11. APN credentials: if `+CGAUTH` is missing, the only documented route is `+EIAAPN`, which writes persistent state — a human decision then.
12. `+CGDCONT?` before and after a power cycle — is it persistent, as documented?
13. The serial port: does the FM350 answer with DTR and RTS asserted (and without)? Which URCs arrive unprompted after power-on, and with which prefixes?
14. Unplugging the modem while the app holds the AT port: does the `pwsh` process survive? `System.IO.Ports` has a history of crashing the process from its background thread when a USB serial device disappears; if it happens, the transport needs a different implementation.

## 8. eSIM (M8)

The eUICC is driven by [lpac](https://github.com/estkme-group/lpac), an open-source LPA (the
component that speaks GSMA SGP.22 to the eSIM and to the operator's SM-DP+ server). This app does
not reimplement that protocol: it runs lpac as an external process and carries its APDUs to the
eUICC over the AT port it already owns.

| Fact | Status | Source |
|---|---|---|
| The eUICC is reached through **logical channels**: `AT+CCHO=<AID>` opens one and returns `<sessionid>`; `AT+CGLA=<sessionid>,<length>,<command>` exchanges an APDU and answers `+CGLA: <length>,<response>`; `AT+CCHC=<sessionid>` closes it. | 📄 | `[27.007]`, `[LPAC-WRAPPER]` |
| `+CCHO`/`+CGLA`/`+CCHC` are **in neither vendor manual**; `AT+CSIM=<length>,<command>` is (`<length>` counts hex characters). Without the logical-channel commands, a channel could be opened with a MANAGE CHANNEL APDU sent through `+CSIM`. | ❓ | `[FIBOCOM]` §10.1.4 p.139; `[DEVICE]` |
| The FM350 needs the eSIM slot selected first: `AT+GTDUALSIM=1`. The manual only calls the slots SIM1 and SIM2 and says the setting is **persistent** (§4) — switching slots writes persistent modem state. | 📄 | `[LPAC-WRAPPER]`, `[FIBOCOM]` §4.3 p.50 |
| `AT+SIMTYPE?` tells which kind of SIM is in use: `0` USIM (default), `1` eSIM. | 📄 | `[FIBOCOM]` §3.15 p.32 |
| `AT+EID?` answers the EID quoted, 32 digits, or an empty string when there is none; needs the SIM unlocked. **Identifier.** | 📄 | `[FIBOCOM]` §3.13 p.30 |
| `+GTESIMCFG` (firmware from manual V2.8) can disable the eSIM function globally (`0` enabled, the default; `1` disabled) or by SKU or IMSI rules (off by default). Reading it explains a disabled eUICC; it is persistent and never written by this app. | 📄 | `[FIBOCOM]` §3.28 p.45 |
| lpac's APDU backend `stdio` exchanges **one JSON object per line**. lpac writes `{"type":"apdu","payload":{"func":<f>,"param":<hex or null>}}`; the host answers on lpac's stdin `{"type":"apdu","payload":{"ecode":<int>,"data":<hex, optional>}}`. | 📄 | `[LPAC]` `driver/apdu/stdio.c` |
| The functions: `connect` and `disconnect` (answer `ecode` 0); `logic_channel_open` (param = AID; answer `ecode` = the channel number); `logic_channel_close` (param = the channel byte); `transmit` (param = command APDU; answer `data` = response APDU **including** the status word, e.g. `…9000`). | 📄 | `[LPAC]` `driver/apdu/stdio.c` |
| lpac's own results are JSON too: `{"type":"lpa","payload":{"code":0,"message":"success","data":{…}}}`; `code` ≠ 0 is an error. The host tells the two kinds of line apart by `type`. | 📄 | `[LPAC]` `docs/USAGE.md`, `driver/apdu/stdio.c` |
| Settings: `LPAC_APDU=stdio` selects the backend; the ISD-R AID defaults to `A0000005591010FFFFFFFF8900000100` (`LPAC_CUSTOM_ISD_R_AID`); ES10x segments default to 120 bytes (`LPAC_CUSTOM_ES10X_MSS`, 6–255); on Windows the HTTP backend is `winhttp`. | 📄 | `[LPAC]` `docs/ENVVARS.md` |
| Commands used: `chip info`; `profile list`, `enable`, `disable`, `nickname`, `download`, `delete`; `notification list`, `process`, `remove`. `chip purge` (erase every profile) is **never** exposed. | 📄 | `[LPAC]` `docs/USAGE.md` |
| **Identifiers:** EID (`chip info`) and ICCIDs (`profile list`) are identifiers — redacted in logs and fixtures like IMEI and IMSI. Activation codes are secrets. | — | Project rule |

Open questions for the device (a module **with** an eUICC — not every FM350 has one):
1. Does the FM350 accept `+CCHO/+CGLA/+CCHC`, and up to which APDU length through `+CGLA`? If not, does a logical channel opened through `+CSIM` work?
2. Which slot holds the eUICC (`+SIMTYPE?` after each `+GTDUALSIM`), and does a slot change need re-registration or `+CFUN` cycling?
3. After `profile enable`, what does the modem need to use the new profile (refresh, re-registration)?

## 9. SMS and USSD (M9)

Standard commands from `[27.005]` (SMS) and `[27.007]` (USSD), message formats from `[23.040]` and
`[23.038]`. The vendor manual documents all of them for the FM350 (`[FIBOCOM]` §8 and §5.3.1).

### SMS

| Fact | Status | Source |
|---|---|---|
| SMS works over the FM350-GL's AT port: `AT+CMGL=4` in PDU mode lists the stored messages with valid PDUs. | 📄 | `[WWAN-29]`, `[FM350-UTIL]` |
| `+CMGF`: `0` PDU (the default), `1` text. This app uses PDU mode. | 📄 | `[FIBOCOM]` §8.1.4 p.89 |
| `+CSCS`: `"IRA"` (the default), `"GSM"`, `"UCS2"`, `"HEX"`. It shapes text-mode strings and USSD strings, not PDUs. | 📄 | `[FIBOCOM]` §8.1.1 p.85 |
| `+CPMS=<mem1>,<mem2>,<mem3>` selects the storage for reading and deleting, writing, and receiving: `"SM"` (SIM), `"ME"` (modem), `"BM"` (broadcast), `"SR"` (status reports). The setting **may revert to `"SM"` after a power cycle**, so the app sets it on every connect. | 📄 | `[FIBOCOM]` §8.1.3 p.87 |
| Which storages the FM350 accepts, and their sizes. | ❓ | `[DEVICE]` |
| `+CNMI=<mode>,<mt>,<bm>,<ds>,<bfr>`: every value **defaults to `0`** — no new-message notice until the app sets one. `<mt>=1`: the message is stored and announced as `+CMTI: <mem>,<index>`. `<mt>=2`: the message goes straight to the port as `+CMT: [<alpha>],<length>` with the PDU on the next line, **without being stored**, and the modem waits up to **15 s** for `+CNMA`, sending the notice again until it arrives. Class 2 messages are stored and announced with `+CMTI` either way. | 📄 | `[FIBOCOM]` §8.1.8 p.96, §8.1.9 p.101 |
| Which AT port the notices go to, and whether they arrive while data is up. | ❓ | Not stated; `[DEVICE]` |
| `+CMGL=<stat>`: `0` unread, `1` read, `2` stored unsent, `3` stored sent, `4` all; indexes `1`–`352`. Listing marks unread messages as read. In PDU mode each entry is `+CMGL: <index>,<stat>,[<alpha>],<length>` followed by the PDU. | 📄 | `[FIBOCOM]` §8.1.10 p.103; PDU-mode layout `[27.005]` |
| `+CMGR=<index>` reads one message and marks it read. | 📄 | `[FIBOCOM]` §8.1.11 p.106 |
| `+CMGD=<index>[,<flag>]`: `0` that index; `1` every read message; `2` read and sent; `3` read, sent and unsent; `4` all. With a flag above `0` the index is ignored. | 📄 | `[FIBOCOM]` §8.1.14 p.112 |
| Sending in PDU mode: `AT+CMGS=<length>`, the length counting the TPDU octets **without** the service-centre part, then the PDU in hex and Ctrl-Z (ESC cancels). Answers `+CMGS: <mr>`; up to 60 s. The `> ` prompt before the PDU is from `[27.005]`; the vendor manual doesn't show it. | 📄 | `[FIBOCOM]` §8.1.16 p.114, `[27.005]` |
| In PDU mode the SIM's service-centre number (`+CSCA`) is used only when the PDU's own service-centre field has length `0`. | 📄 | `[FIBOCOM]` §8.1.5 p.90 |
| `+CMMS=1` keeps the radio link open between the parts of a long message; it falls back to `0` after a short idle gap. | 📄 | `[FIBOCOM]` §8.1.19 p.118 |
| `+CSAS` / `+CRES` save and restore the SMS settings in the modem's non-volatile memory — **persistent, not used** by this app. | 📄 | `[FIBOCOM]` §8.1.17–8.1.18 p.116–117 |
| PDU layouts (SMS-DELIVER, SMS-SUBMIT, status report), the header that joins the parts of a long message, GSM 7-bit packing with its extension table, UCS-2, and the data coding scheme. | 📄 | `[23.040]`, `[23.038]` |
| Whether messages arrive in every mode (LTE only, NSA, SA). | ❓ | `[DEVICE]` |

### USSD

| Fact | Status | Source |
|---|---|---|
| `AT+CUSD=[<n>[,<str>[,<dcs>]]]`: `<n>` `0` notices off, `1` on, `2` cancel the session; `<dcs>` defaults to `15`. Up to 10 s for the command; needs the SIM unlocked. | 📄 | `[FIBOCOM]` §5.3.1 p.65, `[27.007]` |
| The reply arrives **later**, as an unsolicited `+CUSD: <m>[,<str>,<dcs>]` after the command's `OK`. `<m>`: `0` done, `1` the network expects an answer, `2` ended by the network, `3` answered by another local client, `4` not supported, `5` network timeout. | 📄 | `[FIBOCOM]` §5.3.1, `[27.007]` |
| How `<str>` is written: with a 7-bit data coding scheme it follows `+CSCS` (`"HEX"`: two hex digits per GSM character, unpacked); 8-bit data takes two hex digits per octet; UCS-2 four hex digits per character. | 📄 | `[FIBOCOM]` §5.3.1 |
| A reply can be split over several lines, and some modems report a 7-bit coding scheme on a UCS-2 payload, so a robust decoder checks the payload too. | 📄 | `[SMS-TOOL]` — behaviour seen across modems, not specific to the FM350 |
| Whether USSD works on the FM350 over LTE, NSA and SA with a given operator: the network has to fall back to 2G/3G or carry USSD over IMS. No source confirms it either way. | ❓ | `[DEVICE]` |

Open questions for the device:
1. `AT+CPMS=?` and `AT+CPMS?` — which storages, how many messages each; does the setting revert after a power cycle?
2. `AT+CNMI=?` — the accepted values; does `+CMTI` arrive on the MD AT port, with data up?
3. A message received on LTE, NSA and SA.
4. `AT+CMGD=1,4` — accepted?
5. `AT+CUSD=?` and a real request on LTE, NSA and SA — the string format under the default character set, the coding scheme of the reply, the errors or `+CUSD: 4` seen.

## 10. Data usage (M9)

| Fact | Status | Source |
|---|---|---|
| The FM350 has **no command reporting bytes or packets transferred**, and 3GPP TS 27.007 has none either: `+CGCONTRDP`, `+CGPADDR` and `+CGEQOSRDP` report addresses and QoS, not traffic. | 📄 | `[FIBOCOM]`, `[FIBOCOM-2.2]` (full text), `[27.007]` V19.6.0 |
| Windows keeps byte counters per network interface (`InOctets`/`OutOctets` of `MIB_IF_ROW2`, shown by `Get-NetAdapterStatistics`), readable without administrator rights. When they reset is not documented: the app assumes they can restart from zero at any time. | 📄 | Microsoft documentation of `MIB_IF_ROW2`; read without admin rights on 2026-09-29 |
