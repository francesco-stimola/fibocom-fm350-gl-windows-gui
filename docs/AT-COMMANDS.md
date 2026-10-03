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
| `[23.003]` | 3GPP TS 23.003 — *Numbering, addressing and identification* (§9.1: an APN is a network identifier followed by an operator identifier, `mnc<MNC>.mcc<MCC>.gprs`) | Public standard |
| `[V.250]` | ITU-T V.250 — *Serial asynchronous automatic dialling and control* | Public standard |
| `[36.101]` | 3GPP TS 36.101 — *E-UTRA UE radio transmission and reception*, **V20.1.0** (`36101-k10.zip`, SHA-256 `9f9a56f5d0535e5f77da0b4154c3056ed6e0d09c4e0ee22b2beb9676de0144ad`) | Public standard |
| `[38.101-1]` | 3GPP TS 38.101-1 — *NR UE radio transmission and reception, FR1*, **V20.1.0** (`38101-1-k10.zip`, SHA-256 `274357963736f04ef5fe419288c2341a7b02897dd478d0bb9c46304a2d9f5eda`) | Public standard |
| `[36.133]` / `[38.133]` | 3GPP TS 36.133 / 38.133 — *Requirements for support of radio resource management* | Public standard |
| `[FIBOCOM]` | Fibocom *FM350 AT Commands User Manual* **V2.10** (2023-07-04), cited as `§<section> p.<page>`. No applicability table; its SAR chapters name the FM350-GL-16 variant (no NR). Copies are published by resellers; the document is marked all rights reserved and confidential, so only facts are taken from it, in our own words. | Vendor documentation — facts only |
| `[FIBOCOM-2.2]` | The same manual, **V2.2** (2021-02-22), whose applicability table names the FM350-GL. Same section numbers; cited only where it differs from V2.10. | Vendor documentation — facts only |
| `[INF]` | The `usb2ser_tm` 3.22.43.1 driver package (MediaTek, WHQL-signed), the FM350 serial-port driver: its INF and its catalog, read in the driver store of our device, where they have the SHA-256 of the published package | Observed file contents (hardware IDs, sections, catalog signature) |
| `[MS-INF]` | Microsoft Learn, read 2026-10-03: *General Syntax Rules for INF Files*, *INF Version Section*, *INF Manufacturer Section*, *INF Models Section*, *INF Strings Section*, *INF SourceDisksFiles Section*, *INF SourceDisksNames Section*, *Creating INF Files for Multiple Platforms and Operating Systems*, *Creating International INF Files* (learn.microsoft.com/windows-hardware/drivers/install/) | Vendor documentation |
| `[MS-SIGN]` | Microsoft Learn, read 2026-10-03: *Catalog Files and Digital Signatures*, *Driver Store*, *WHQL Release Signature* (windows-hardware/drivers/install/); *Validate driver signing* (windows-hardware/drivers/dashboard/code-signing-validate); `IX509ExtensionMSApplicationPolicies` (win32/api/certenroll) | Vendor documentation |
| `[MS-WINTRUST]` | Microsoft Learn, read 2026-10-03: `WinVerifyTrust`, `WINTRUST_DATA`, `WINTRUST_CATALOG_INFO` (win32/api/wintrust); `CryptCATAdminAcquireContext2`, `CryptCATAdminCalcHashFromFileHandle2` (win32/api/mscat); *MakeCat* (win32/seccrypto) | Vendor documentation |
| `[MS-PNPUTIL]` | Microsoft Learn, read 2026-10-03: *PnPUtil Command Syntax*, *PnPUtil Return Values*, *PnPUtil Examples* (windows-hardware/drivers/devtest/) | Vendor documentation |
| `[MS-DNS]` | Microsoft Learn, read 2026-10-03: `SetInterfaceDnsSettings`, `GetInterfaceDnsSettings`, `DNS_INTERFACE_SETTINGS3`, `DNS_SERVER_PROPERTY`, `DNS_SERVER_PROPERTY_TYPE`, `DNS_SERVER_PROPERTY_TYPES`, `DNS_DOH_SERVER_SETTINGS` (win32/api/netioapi); *Secure DNS Client over HTTPS (DoH) on Windows Server 2022* (windows-server/networking/dns/doh-client-support); `Add-DnsClientDohServerAddress` (DnsClient module, documented in the `windowsserver2022-ps` and `windowsserver2025-ps` sets only); *netsh dnsclient* (windows-server/administration/windows-commands) | Vendor documentation |
| `[MS-HOST]` | Microsoft Learn, read 2026-10-03: *The Cable Guy: Strong and Weak Host Models* (TechNet Magazine, 2007; previous-versions/technet-magazine/cc137807); `Set-NetIPInterface` (NetTCPIP module: `WeakHostSend`, `WeakHostReceive`) | Vendor documentation |
| `[RFC1035]` | RFC 1035 — *Domain names — implementation and specification* (1987): sections 2.3.4, 3.2.2, 3.2.4, 3.4.1, 4.1, 4.2.1 | Public standard |
| `[RFC5452]` | RFC 5452 — *Measures for Making DNS More Resilient against Forged Answers* (2009): sections 9.1, 9.2 | Public standard |
| `[RFC5890]` | RFC 5890 — *Internationalized Domain Names for Applications (IDNA): Definitions and Document Framework* (2010): section 2.3.2.1 | Public standard |
| `[MS-WIN10]` | Microsoft Learn, *Windows 10 release information* (windows/release-health), read 2026-10-03 | Vendor documentation |
| `[MS-PWSH]` | Microsoft Learn, read 2026-10-03: *Install PowerShell 7 on Windows* (page of 2026-09-21), `about_PSModulePath` and `about_PowerShell_Config` (PowerShell 7.6) | Vendor documentation |
| `[MS-TASK]` | Microsoft Learn, read 2026-10-03: `New-ScheduledTaskSettingsSet` (ScheduledTasks module); `TaskSettings.ExecutionTimeLimit`, `.Priority`, `.DisallowStartIfOnBatteries`, `.StopIfGoingOnBatteries`, `.MultipleInstances` (win32/taskschd) | Vendor documentation |
| `[MS-APPID]` | Microsoft Learn, read 2026-10-03: *Application User Model IDs (AppUserModelIDs)* (win32/shell/appids); `SHGetPropertyStoreForWindow` (win32/api/shellapi); *System.AppUserModel.ID* (win32/properties) | Vendor documentation |
| `[MS-ARM]` | Microsoft Learn, read 2026-10-03: *Frequently asked questions about support for Windows on Arm* (windows/arm/faq) | Vendor documentation |
| `[MS-WMI]` | Microsoft Learn, read 2026-10-03: `Win32_Processor` class (win32/cimwin32prov) | Vendor documentation |
| `[MS-ARP]` | Microsoft Learn, read 2026-10-03: *Windows Installer Properties for the Uninstall Registry Key*; `ARPNOMODIFY`, `ARPNOREPAIR`, `ARPSIZE` properties (win32/msi) | Vendor documentation |
| `[MS-ENV]` | Microsoft Learn, read 2026-10-03: *Environment Variables* (win32/procthread); `Environment.SpecialFolder` (.NET API) | Vendor documentation |
| `[MSRC]` | Microsoft, *Microsoft Security Servicing Criteria for Windows* (msrc), read 2026-10-03 | Vendor documentation |
| `[GH-API]` | GitHub Docs, REST API, read 2026-10-03: *Get the latest release*, *Create a release* (`make_latest`), *Getting started with the REST API* (User-Agent), *Rate limits for the REST API*, *API Versions* | Vendor documentation |
| `[GH-LINK]` | GitHub Docs, *Linking to releases*, read 2026-10-03 | Vendor documentation |
| `[GH-ACTIONS]` | GitHub Docs, *Secure use reference* (GitHub Actions), read 2026-10-03 | Vendor documentation |
| `[HOST]` | Observed on the development computer, read only unless a row says otherwise: Windows 11 Pro build 26300, PowerShell 7.6.6 from its MSIX package | Ours — first-hand |
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
| `[UNLOCK]` | The maintainer's FCC unlock of our module, before this project's device session (2026): the commands, their order, the state after. No challenge-response tool was used: the three lock values were read — a mode other than `0`, a state other than `0`, an effective status other than `0,1` — and the five commands sent. The exact answers read while the module was locked were not kept. | Ours — first-hand, not captured |
| `[4PDA]` | 4pda.to forum, topic 1057776 *Fibocom FM350-GL* — posts #3304 (2024-08-21), #3306 and #3308 (2024-08-22): one user's FM350-GL from a Lenovo laptop, firmware `81600.0000.00.29.19.16`, used over USB, read while FCC-locked and after unlocking | User report — facts only |
| `[MM-FCC]` | ModemManager `data/dispatcher-fcc-unlock/14c3` at main `338ecc06f294` (2026-09-22; first released in 1.24.0) — the FCC unlock of the Lenovo-shipped FM350-GL on PCIe (`14c3:4d75`) | CC0-1.0 (the script), ModemManager GPL-2.0-or-later — facts only |
| `[FOUNDATA]` | foundata blog, *Rolling Wireless RW350R-GL / Fibocom FM350R-GL (5G module) on Linux* (2026-09-07) — an FM350R-GL locked in a ThinkPad | © foundata — facts only |

When a source is added, record its exact version or commit here.

## 1. USB identity

| Fact | Status | Source |
|---|---|---|
| USB vendor ID `0E8D` (MediaTek). | 📄 | `[INF]` |
| Two USB compositions, product IDs `7126` and `7127`. The INF also lists `7128` (MD AT on `MI_05`) and `7129` (on `MI_06`), which no FM350 document names: the app does not treat them as an FM350. | 📄 | `[INF]` |
| The modem AT port ("MD AT") is interface `MI_04` on `7126` and `MI_06` on `7127`. | ✅ 7127 · 📄 7126 | `[INF]`; `[DEVICE]` `pnp.7127.driver.json` |
| With the driver, each serial function of `7127` is a COM port named by the INF: `MI_02` "USB AP Log Port", `MI_03` "USB AP GNSS Port", `MI_04` "USB AP META Port", `MI_06` **"USB MD AT Port"**, `MI_07` "USB MD META Port", `MI_08` "USB NPT Port", `MI_09` "USB Debug Port". Windows numbers the COM ports when the driver is installed (here `COM3`–`COM9`, AT on `COM9`); the number is read from the device (`Device Parameters\PortName`), never assumed. | ✅ | `[DEVICE]` `pnp.7127.driver.json` |
| **The COM numbers can change.** After a re-enumeration the modem came back as a **new device instance**, on another USB location of the host: the AT port on `COM14` instead of `COM9`, the network adapter under a new name (`… #2`); the old instance stayed behind, not present. The app finds the AT port and the adapter by PnP every time it opens them (ARCHITECTURE → *AT channel*). | ✅ | `[DEVICE]` (PnP read after a re-enumeration while the SIM was swapped, §3) |
| `usb2ser_tm` 3.22.43.1 installs with `pnputil /add-driver <inf> /install` and loads with **Memory Integrity** (HVCI) on: every serial function starts, problem code 0. | ✅ | `[DEVICE]` `pnp.7127.driver.json` (Windows 11 build 26300) |
| The serial-port driver package covers **only** the serial functions (INF class `Ports`); the network function is served by a different driver. | 📄 | `[INF]` |
| `7126` (mode 40) has 8 interfaces: `0` RNDIS control (class `02/02/ff`), `1` RNDIS data (`0a/00/00`), `2` and `4`–`7` vendor-class serial (`ff/00/00`), `3` vendor `ff/42/01` with no Linux driver. `7127` (mode 41) has 10, with serial interfaces up to `9`. | 📄 | `[LINUX-OPTION]` |
| On `7127` Windows enumerates **nine functions** under the composite device (`usbccgp`, reported name `FM350-GL`): `MI_00` RNDIS (interfaces 0–1 as one function, compatible class `e0/01/03`); `MI_02`–`MI_04` and `MI_06`–`MI_09` "USB COM Port", class `ff/00/00`; `MI_05` "ADB Interface", class `ff/42/01`, which Windows' own WinUSB driver serves (`winusb.inf`). | ✅ | `[DEVICE]` `pnp.7127.nodriver.json` |
| The network function is **RNDIS** in both compositions. | 📄 | `[LINUX-OPTION]`, `[FIBOCOM]` §13.1.1 p.232 |
| Windows' built-in RNDIS driver serves it (`wceisvista.inf`, service `usbrndis6`, `usb80236.sys`), matched on the compatible ID `USB\Class_e0&SubClass_01&Prot_03`: **no driver to install for the network adapter.** With no data context active the adapter is up but disconnected, DHCP on, with a link-local address. | ✅ | `[DEVICE]` `pnp.7127.nodriver.json` (7127); 7126 not observed |
| **The modem serves no DHCP.** With a data context active the adapter connects (it is up only while a context is active) but stays on its link-local address for over a minute; `AT+GTRNDIS` is absent. Configured by hand — the context's IPv4 address as a **/32**, a default route **on the link** (next hop `0.0.0.0`), DHCP off — it carries traffic: the modem answers ARP for every destination. Configured that way in the active store, the address, route, DHCP state and metric took; DNS servers set on the adapter persist until reset. Unconfigured, Windows lists three IPv6 DNS servers of its own (`fec0:0:0:ffff::1`–`3`); once the app sets the IPv4 servers it lists none, and a reset brings them back. The app's own pass configured it (`Online`), a second pass changed nothing, and it was put back as found. | ✅ | `[DEVICE]` (adapter configured during data sessions: ping and a 10 MB download through it) |
| **An address just set is not usable for about 3.5 s.** Windows holds it `Tentative` while it checks that no other host has it — 3.1 to 3.5 s, five times out of five: after the connect pass, after three re-configurations, after a context restart — and an echo request sent from it fails at once (IP status 1214); the first reply comes the moment it turns `Preferred`. That was the one reply in four of a `ping -n 4` right after the adapter was configured, and the four in four after a 3 s wait. Settled, a few replies are lost now and then (up to 7 requests in 41, 500 ms timeout). The probe (ARCHITECTURE → *The data-path probe*) sends nothing from an address that isn't `Preferred`, and a round passes on any of its replies. | ✅ | `[DEVICE]` (address state every 100 ms and an echo request every 250 ms from the moment it was set) |
| **The adapter is created anew when the USB device restarts**: after `pnputil /restart-device` (the recovery step R6) its address, route and metric were gone while the context stayed active; the next pass set them again. | ✅ | `[DEVICE]` |
| The AT/serial interfaces are **vendor class** (`ff`), which Windows' built-in `usbser.sys` (CDC ACM) does not claim: the AT ports need the MediaTek serial driver. Without it every serial function stands with **problem code 28** (drivers not installed), no class and no service, and no COM port exists. | ✅ | `[LINUX-OPTION]`, `[INF]`; `[DEVICE]` `pnp.7127.nodriver.json` |
| The composite device's instance ID is **generated by Windows** (`<n>&<hash>&<n>&<port>`), not a USB serial number, so it changes when the modem moves to another USB port. The modem is found by hardware ID, never by a remembered instance ID. | ✅ | `[DEVICE]` (shape of the captured instance ID; redacted in the fixture) |
| The MediaTek serial driver is **not** on the Microsoft Update Catalog (searched by hardware ID, file name and version on 2026-09-28), so Windows Update will not install it by itself. | 📄 | Microsoft Update Catalog |
| The FM350 "Ports" drivers that **are** on the catalog — Fibocom and HP 0.6.200.352, Palcom 5933.0.6.1 — serve the **PCIe** module only (`PCI\VID_8087&PID_0B5D`…, `PCI\VID_14C0&PID_0B5D`…, `PCI\VEN_14C3&DEV_4D75`): laptops use the FM350 over PCIe, so laptop driver packages don't carry the USB serial driver. | 📄 | Microsoft Update Catalog (packages inspected 2026-09-29) |
| `AT+GTUSBMODE` reports the USB composition. Mode `40`: RNDIS, AT, GNSS, META, debug and ADB functions; mode `41` adds log and META ports and is the **documented default**. Mode `40` is the `7126` composition and `41` the `7127` one. The setting is **persistent** and applies after a reset or power cycle — never changed by this app without a human decision. | 📄 | `[FIBOCOM]` §13.1.1 p.232; mode ↔ product ID: `[3GINFO]` (file header), `[LINUX-OPTION]` |
| Our device enumerates as **`7127`** (mode 41, the default), with the network adapter on Windows' RNDIS driver (above). | ✅ | `[DEVICE]` `pnp.7127.nodriver.json` |
| Every function of one physical modem — the AT port and the network adapter included — shares one Windows **container ID**, and hangs from one composite device (`Parent`). The app links them through the composite device: a container ID is shared with the whole computer when the port is non-removable (ARCHITECTURE → *Drivers*). | ✅ | `[DEVICE]` `pnp.7127.nodriver.json` |
| `+GTDIPCMODE` (persistent, applied after a reset) chooses between PCIe-only and dual mode, and whether the AT port is on USB (the default) or PCIe. Reading it can explain a missing USB AT port; the app never writes it. | 📄 | `[FIBOCOM]` §13.1.3 p.234 |

### 1.1 The AT-port driver package (M6)

What the app reads and checks before it installs a driver package the user hands over
(ARCHITECTURE → *Drivers*).

| Fact | Status | Source |
|---|---|---|
| The package `usb2ser_tm` 3.22.43.1 is four files: `usb2ser_tm.inf`, the catalog `usb2ser_tm.cat`, `x64\usb2ser_tm.sys` and `x86\usb2ser_tm.sys` (`[SourceDisksFiles.amd64]` names `.\x64`). INF class `Ports`, provider MediaTek, `DriverVer = 10/18/2022,3.22.43.1`, service `usb2ser_tm`. The SHA-256 of the four files are the known fingerprints (`Data/Drivers.psd1`); in our device's driver store the `.cat`, the `.inf` and the x64 `.sys` have them. The published copy (`Data/Drivers.psd1`) is a zip of those four files and nothing else — 156,914 bytes, the SHA-256 of the manifest —, all four with the known SHA-256. | 📄 | `[INF]`; the published zip, read 2026-10-03 |
| **INF syntax.** Section names, keys and directives are case-insensitive; a `;` starts a comment unless it is inside a quoted string or a `%strkey%` token; `\` continues a line; sections with the same name merge. A `%strkey%` token is defined in `[Strings]` (or a `[Strings.<LanguageID>]` matching the system's language), whose values lose their outermost quotes; `""` is a quote and `%%` a percent sign. An INF is ASCII — characters translated with the current locale — or UTF-16, either byte order. | 📄 | `[MS-INF]` |
| **The catalog.** `[Version]` names it with `CatalogFile=`, a file "in the same location as the INF file"; a decorated `CatalogFile.NTamd64=` (`.NT`, `.NTx86`, `.NTarm64`…) serves one platform, the undecorated entry the platforms without one. An INF with no `CatalogFile` entry is treated as unsigned. `usb2ser_tm.inf` has the undecorated `CatalogFile=usb2ser_tm.cat`. | 📄 | `[MS-INF]`; `[INF]` |
| **The hardware IDs.** `[Manufacturer]` lines are `%strkey%=models-section[,TargetOSVersion]…`, `TargetOSVersion` being `NT[Architecture][.major[.minor[…]]]`; on x64 Windows uses the models section decorated `NTamd64` — an undecorated one is for x86 only since Windows Server 2003 SP1. A models line is `description=install-section,hw-id[,compatible-id…]`. `usb2ser_tm.inf` lists the same IDs in `DeviceList.NTx86` and `DeviceList.NTamd64`: the MD AT port as `USB\VID_0E8D&PID_7126&MI_04` and `USB\VID_0E8D&PID_7127&MI_06`, without a revision, among other MediaTek IDs — other compositions and the download modes `PID_0003`, `PID_2000`, `PID_2001`. | 📄 | `[MS-INF]`; `[INF]` |
| **The package's files.** `[SourceDisksFiles]` lists the files the INF installs, `filename=diskid[,[subdir][,size]]`, `subdir` relative to the `path` that `[SourceDisksNames]` gives the disk, `diskid = disk-description[,[tag-or-cab-file],[unused],[path],…]`, itself relative to the installation root — for a package on disk, the INF's folder. Both sections may be decorated per architecture with `.x86`, `.amd64`, `.arm64`… — not `.ntamd64` —, the decorated one looked up before the undecorated one. A `tag-or-cab-file` lies in that `path` or in the root. `usb2ser_tm.inf` has `1=%INST_DISK_NAME%` (no path) and `usb2ser_tm.sys = 1,.\x64` (`.amd64`) and `= 1,.\x86` (`.x86`). | 📄 | `[MS-INF]` (*INF SourceDisksFiles Section*, *INF SourceDisksNames Section*); `[INF]` |
| **The AT port names its driver.** Its hardware IDs are `USB\VID_0E8D&PID_7127&REV_0001&MI_06` and `USB\VID_0E8D&PID_7127&MI_06`. With the driver: `DEVPKEY_Device_DriverInfPath` `oem24.inf` — the name the package was published under in the driver store, `oem<n>.inf` —, `DEVPKEY_Device_DriverVersion` `3.22.43.1`, `DEVPKEY_Device_DriverProvider` `MediaTek`, `DEVPKEY_Device_MatchingDeviceId` `usb\vid_0e8d&pid_7127&mi_06` (the INF's ID that matched, lower case). | ✅ | `[DEVICE]` `pnp.7127.driver.json` (hardware IDs, INF path); version, provider and matching ID read on the device |
| **What a catalog vouches for.** It holds a hash for each file of the package; PnP installation takes the package's signature as invalid if any file — the INF, the catalog, every file its `CopyFiles` copy — changed after signing, even by a byte. Before a package is staged to the driver store, Windows verifies it: "The catalog file must contain hashes for the INF file and any files referenced in the INF file. The catalog file must be signed with a trusted digital signature." Staging installs the catalog in the system's catalog store (CatRoot). | 📄 | `[MS-SIGN]` |
| **WHQL.** "A WHQL release signature consists of a digitally signed catalog file." The signer's certificate carries the enhanced key usage `1.3.6.1.4.1.311.10.3.5`, *Windows Hardware Quality Labs (WHQL) cryptography*; an attestation signature — Microsoft's too, but not Windows Certified — carries an OID ending in `1` instead. | 📄 | `[MS-SIGN]` |
| **Our catalog's signature.** One signer: *Microsoft Windows Hardware Compatibility Publisher*, `O=Microsoft Corporation`, issued by *Microsoft Windows Third Party Component CA 2012*, chained to *Microsoft Root Certificate Authority 2010*; enhanced key usages `1.3.6.1.4.1.311.10.3.5`, `1.3.6.1.4.1.311.10.3.39` and code signing. The certificate was valid from 2022-03-10 to 2023-03-08; the signature carries a Microsoft time stamp, so it still verifies. The catalog is a PKCS #7 signed message holding a certificate trust list (content type `1.3.6.1.4.1.311.10.1`), which .NET's `SignedCms` decodes. | 📄 | `[INF]` (read with `Get-AuthenticodeSignature` and `SignedCms`) |
| **"Signed" depends on the machine.** With the package installed, `Get-AuthenticodeSignature` reports the driver store's INF and `.sys` as `Valid`, signature type `Catalog`: Windows finds their hashes in its installed catalogs, and would for any copy of them. A package's file is therefore checked against **the package's own catalog**: `WinVerifyTrust` with `WTD_CHOICE_CATALOG`, the file's hash from `CryptCATAdminCalcHashFromFileHandle2` given as the member tag in hexadecimal; zero is the only success. On our device: the INF and the x64 `.sys` against their catalog → `0`, for an SHA-256 and an SHA-1 hash alike; the INF with one line added → `0x800B0100` (`TRUST_E_NOSIGNATURE`); the INF against another package's signed catalog → `0x800B0100`; a file that is no catalog → `0x80092003`. PowerShell's `Test-FileCatalog` can't open this catalog. | ✅ | `[MS-WINTRUST]`; `[DEVICE]` (the driver store's copy, read only) |
| **Right after its driver is uninstalled** (`pnputil /delete-driver <oem#.inf> /uninstall`, exit code `0` in about a second), each serial function stays present with **no problem code** — not 28 —, no class, no service, no driver properties, not started (`DEVPKEY_Device_DevNodeStatus` without `DN_DRIVER_LOADED` and `DN_STARTED`), and no COM port, while Windows calls its status `OK`. Problem code 28 comes with an enumeration that finds no driver (`pnp.7127.nodriver.json`). The app takes a function with no problem code and a service read as none for one without its driver; a service that couldn't be read is not none. | ✅ | `[DEVICE]` `pnp.7127.uninstalled.json` (a key read without a value as `""`) |
| A key a device has no value for — the service and the driver keys of a function without its driver — comes back from `Get-PnpDeviceProperty` with type `Empty` and **no `Data` member** at all. | ✅ | `[DEVICE]` (the functions above, read on the device) |
| **Installed again** (`pnputil /add-driver <inf> /install` on a copy of the published package, exit code `0` in about a second), every serial function works at once — on **new COM numbers** (`COM17`–`COM23`, the AT port on `COM23` instead of `COM9`: uninstalling deleted the ports' names) and under a **new published name** (`oem10.inf` instead of `oem24.inf`). Neither is ever remembered (§1). The modem answered on its new AT port at once, its network mode as before. | ✅ | `[DEVICE]` |
| **pnputil** is in `%windir%\System32` on every Windows since Vista. `/add-driver <inf> /install` (Windows 10 1607 and later) adds the package to the driver store and installs it on the matching devices — not on a device whose driver ranks higher; `/delete-driver <oem#.inf> /uninstall` uninstalls it from the devices that use it and deletes it from the store (`/force`: even when devices use it). Most commands need administrator rights. Return values: `0` success; `259` (`ERROR_NO_MORE_ITEMS`) "No devices match the supplied driver or the target device is already using a better or newer driver"; `3010` success, a restart needed to finish; `1641` a restart under way (with `/reboot`, which the app never passes); for actionable values, one INF at a time. No output format is documented for `/enum-drivers` (`/format` exists only for `/enum-containers`, from Windows 11 23H2). | 📄 | `[MS-PNPUTIL]` |

## 2. Transport

| Fact | Status | Source |
|---|---|---|
| Commands end with `CR`; responses are framed by `CR LF` and end with a final result code: `OK`, `ERROR`, or `+CME ERROR: <err>`. Result codes are verbose by default; unsolicited codes are framed the same way. | 📄 | `[V.250]`, `[27.007]`, `[FIBOCOM]` §2.4 p.13–14 |
| Command echo is **on** by default (`ATE1`) and comes back on after a reset; `ATE0` turns it off. The echo ends with CR alone. | ✅ | `[V.250]`, `[FIBOCOM]` §4.1 p.47; `[DEVICE]` (every captured exchange: `AT\r` echoed, then `\r\nOK\r\n`) |
| **We keep echo on and anchor every answer on it**: a command's answer starts after its echo, so anything else arriving before the echo is left over from an earlier command (a late answer after a timeout) and is discarded. The modem runs one command at a time, so a late answer always comes out before the next command's echo. | — | Project design (ARCHITECTURE → *AT channel*) |
| `AT+CMEE=1` makes `+CME ERROR` and `+CMS ERROR` carry a **number**, `=2` verbose text; default `0`: plain `ERROR`. **We use `1`** and map the numbers ourselves, rather than depend on firmware wording. | 📄 | `[27.007]`, `[FIBOCOM]` §20.1.1 p.324 |
| The port speaks the 7-bit IRA character set by default (`+CSCS`); PDUs and UCS-2 strings travel as hex. So the channel reads bytes as text and drops anything outside printable ASCII as line noise. | 📄 | `[FIBOCOM]` §8.1.1 p.85 |
| **Our device answers `+CSCS: "UCS2"`, not `"IRA"`**, after an `AT+CFUN=15` reset too. Supported: `"IRA"`, `"GSM"`, `"HEX"`, `"PCCP437"`, `"8859-1"`, `"UCS2"`, `"UCS2_0X81"`. Whatever the set shapes (text-mode SMS, USSD strings, alphanumeric operator names) arrives hex-encoded unless the app chooses the set itself. | ✅ | `[DEVICE]` (read before and after the reset) |
| Unsolicited codes the app enables, told apart from answers by their prefix: `+CREG`, `+CGREG`, `+CEREG`, `+C5GREG`, `+CSCON`, `+CMTI`, `+CDSI`, `+CUSD`, `+CGEV`. A prefix equal to the pending command's own is read as the answer when the command is a read, test or execute form (`+CEREG:` after `AT+CEREG?`); a set form (`AT+CEREG=2`, `AT+CUSD=1,…`) answers only with a final result, so a line with its prefix is unsolicited. Two-line codes (`+CMT`, `+CDS`) are never enabled. | 📄 | `[27.007]`, `[27.005]`; the FM350's actual URCs are a device question (§7) |
| **What the device actually sends** with `+CREG`, `+CGREG`, `+CEREG`, `+C5GREG` at `2` and `+CSCON` at `1`, through registration, mode changes, a radio drop and recovery: `+CREG` and `+CEREG` codes at every change; **no `+CGREG`, no `+C5GREG`, no `+CSCON`** — the connection state went from idle to connected and back between reads without a code. The checks therefore read the state instead of waiting for codes (ARCHITECTURE → *Health checks*). | ✅ | `[DEVICE]` (question 9) |
| **Codes emitted while no one has the port open are delivered at the next open**: ten registration reports, five of each, came out at once when the port was opened after a pause. A program that opens the port reads the current state; it never takes what arrives first for it. | ✅ | `[DEVICE]` |
| MediaTek's own codes arrive unasked, interleaved with answers: `+ESIMS: 1,29` (waiting on the port at power-on, SIM inserted), `+CIREPI: 0`/`1` (radio service lost/back), `+EONSNWNAME: 0`, `+CTZV: +8,1` (time zone in quarter hours, with daylight saving), `+EDSBP: …`, `+EMCFRPT: …`, `+CNEMIU: 0`. Not on the channel's list, one of them can land among a command's answer lines, so parsers select lines by prefix or shape (ARCHITECTURE → *AT channel*). | ✅ | `[DEVICE]` (questions 9 and 13) |
| DTR and RTS asserted on the USB virtual port, as a modem expects from a ready terminal. The FM350 answers with any combination of the two, and its port reports DSR, CTS and CD always low: the lines carry nothing either way. | ✅ | `[DEVICE]` (`AT` answered with DTR/RTS off/off, on/off, off/on, on/on) |
| **The port can stay silent after it is first opened**: once, right after the serial driver was installed, the modem answered nothing for about 45 s — no echo, no result — then delivered a burst of 20 lines and answered normally from then on. Later opens, the first one after an `AT+CFUN=15` reset (2.5 min after it) included, answered at once. Seen again: about 54 s of silence at the first open after the host restarted with the modem attached; and after a re-enumeration while the SIM was swapped (§3), no answer until about 2 min 40 s after its AT port appeared. Cause not known (ARCHITECTURE → *AT channel* says how the worker copes). | ❓ | `[DEVICE]` |
| **A port that disappears is reported, not hung**: after the cable is pulled, the next write fails at once with "the device does not exist" — never a write timeout — and the transport marks the port lost; after `AT+CFUN=15`, a pending read ends with "the operation was canceled" when the USB device drops. `pwsh` survives both, the release of the port and its finalizers included. | ✅ | `[DEVICE]` (question 14 below) |
| **Right after the modem is back on USB, its AT port may refuse to open** with "the requested resource is in use", as it did half a second after PnP listed it again after `AT+CFUN=1,1`, and while the modem was leaving USB; opened a few seconds later, it answered at once. The worker's next look for the modem, 5 s later, opens it; another program holding the port is a different error (access denied, `PortInUse`). | ✅ | `[DEVICE]` |
| **The modem left USB by itself once, about 73 s after its USB device was restarted** (`pnputil /restart-device`, after which it had answered and gone online again): Windows reset the RNDIS interface, the device was back about 40 s later, without the app's context 1 — as after a reset. Whether the restart caused it is not known: seen once. The recovery step R6's settle time (5 min) covers it. | ❓ | `[DEVICE]` |
| `SerialPort.GetPortNames()` (the registry's `SERIALCOMM`) keeps listing a port that was open when its device left, until the device is back: the app tells whether the modem is present from PnP, never from the list of port names. | ✅ | `[DEVICE]` (COM9 listed during the whole reset) |
| Error codes worth recognizing: CME `14` and CMS `314` = SIM busy; CME `149` = PDP authentication failure. `+CEER` gives the reason for the last failure, attach and activation errors included. | 📄 | `[27.007]`, `[FIBOCOM]` §20.1.2 p.325, §20.2 p.327, §20.3 p.332 |
| Codes seen on the device: CME `10` (SIM not inserted) for `+CPIN?` without a SIM, and CMS `310` for SMS commands then; CME `100` (unknown) for a command it doesn't take in that state; CME `0` for a read of an undefined context (`+CGPADDR=1`, `+CGCONTRDP=1`, `+GTDNS=1`) and for `+GTDIPCMODE?` and `+SIMTYPE?`. `+CEER` with nothing to report: `+CEER: 0,NONE`. | ✅ | `[DEVICE]` `cpin.nosim.txt`, `cgauth.test.txt` |
| Unsolicited result codes (URCs) can arrive **between** a command and its final result code. The reader must separate them from the response. | 📄 | `[27.007]` |
| Commands have documented worst-case durations — `+COPS` up to 3 min, `+CMGS` 60 s, `+CGACT` 30 s, `+CGATT` 15 s, `+CUSD` 10 s, `+CMGL` 5 s, `+CMGR` and `+CSIM` 2 s, most others under 3 s. **Each command's timeout is its documented duration, never less than 3 s** (decided 2026-09-29); a compound line runs its commands one after the other, so it gets the sum. | 📄 | `[FIBOCOM]` (each command's attribute table) |
| Baud rate and flow control settings are irrelevant on the USB virtual COM port. | ❓ | `[DEVICE]` |

## 3. Standard commands we rely on (`[27.007]`)

Each is 📄 `[27.007]` until a capture makes it ✅. The notes record what the vendor manual
`[FIBOCOM]` adds, and where it is silent or disagrees.

| Purpose | Command | Notes |
|---|---|---|
| Identify manufacturer / model / firmware | `+CGMI`, `+CGMM`, `+CGMR` | `[FIBOCOM]` §3.1–3.6 p.17–21. See §4 for the quoted `?` forms. ✅ `identity.txt`; plain `AT+CGMR` answers the bare firmware string. |
| IMEI | `+CGSN` | **Identifier — never logged, redacted in fixtures.** `[FIBOCOM]` §3.7 p.21: `=2` IMEISV, `=3` SVN. |
| IMSI | `+CIMI` | **Identifier.** Needs the SIM unlocked (`[FIBOCOM]` §3.9 p.25). |
| SIM state | `+CPIN?` | `READY` or the code of what the SIM is waiting for. `[FIBOCOM]` §10.1.1 p.132. ✅ Without a SIM: `+CME ERROR: 10` (`cpin.nosim.txt`); a SIM with its PIN request on: `+CPIN: SIM PIN` (`cpin.pin.txt`); for a few seconds after the right PIN, `+CME ERROR: 14`, SIM busy (`cpin.busy.txt`), then `READY`. |
| Enter the SIM PIN | `+CPIN=<pin>[,<newpin>]` | **PIN — never logged.** Answers `OK`, or `+CME ERROR: 16` (incorrect password); three wrong PINs leave the SIM asking for its PUK (`+CPIN: SIM PUK`). `<newpin>` is for entering a PUK and a new PIN — never sent by this app. The SIM can answer busy (`14`) for a while after. The app sends the PIN quoted, `AT+CPIN="<pin>"`, and stores only PINs of 4 to 8 digits, the usual length ❓ (ETSI TS 102 221 to be checked). ✅ On the device: `OK` for the right PIN, then busy as above; `+CME ERROR: 16` for a wrong one, which spends one attempt (`epinc.wrong-pin.txt`). |
| PIN attempts left | `+CPINR[=<sel_code>]` | `+CPINR: <code>,<retries>,<default retries>` per PIN or PUK, e.g. `SIM PIN,3,3`; without `<sel_code>` every code is listed. ✅ **Absent on the FM350**: `AT+CPINR`, `AT+CPINR="SIM PIN"`, `AT+CPINR="SIM*"` and `AT+CPINR=?` all answer `+CME ERROR: 100` (`cpinr.absent.txt`). The app asks it first and falls back on `+EPINC` (next row). |
| PIN attempts left (MediaTek) | `+EPINC?` | ✅ `+EPINC: <a>, <b>, <c>, <d>`, a blank after each comma: `3, 3, 10, 10` with three PIN attempts left, **`2, 3, 10, 10` after one wrong PIN** — the first value is the SIM PIN attempts left (`epinc.txt`, `epinc.wrong-pin.txt`). The others did not move; by their values they would be PIN2, PUK and PUK2 attempts ❓, and the app doesn't use them. Without a SIM: `+CME ERROR: 10`. |
| SIM PIN on or off | `+CLCK="SC",<mode>[,<passwd>]` | Facility `"SC"` is the SIM's PIN request: mode `2` reads it (`+CLCK: <status>`, `1` on), `0` turns it off, `1` on, the PIN as `<passwd>` — a **persistent change on the SIM card**, and a wrong PIN spends an attempt. ✅ On the device: `+CLCK: 1` with the request on, `0` off; `AT+CLCK="SC",0,"<pin>"` answered `OK`, the read then gave `0` and the attempts left did not change. **Without a SIM the read answers `+CLCK: 0`**, which means nothing: the app reads it only with the SIM ready. |
| SIM error codes | `+CME ERROR` | `10` SIM not inserted, `11` SIM PIN required, `12` SIM PUK required, `13` SIM failure, `14` SIM busy, `16` incorrect password. ✅ `10` (`cpin.nosim.txt`), `14` (`cpin.busy.txt`), `16` (above); the others ❓. |
| SIM removed or inserted | — | ✅ **Removed, the modem stays on USB and sends no code**: `+CPIN?` then answers `+CME ERROR: 10`, `+CEREG: 0,4`, `+COPS:0,255,"",0`. **Inserted, it reads the SIM and registers**, no code either; `+CPIN: READY` and registered within a minute. SIM hot-plug detection is on (`+MSMPD: 1`, §4). ❓ Twice, while the SIM was being swapped, the modem also dropped off USB and came back as a new device instance (§1), silent for minutes (§2) — most likely a loose USB contact as the module was handled, since two other swaps did not; not reproduced on purpose. The app handles both: a lost port, then a SIM to read again. |
| Radio power / reset | `+CFUN=<fun>[,<rst>]` | `1` full, `4` RF off, `0` minimum. `<rst>=1` resets the MT before applying `<fun>`. `[FIBOCOM]` §4.2 p.48 adds `15` = **reset** (no `<rst>` with it); after `0` or `15` the `OK` may never arrive. The read form is `+CFUN: <power_mode>,<STK_mode>`. ✅ On the device the read form carries one value (`+CFUN: 1`); `=?` gives `(0,1,4,15),(0-1)`. **`AT+CFUN=15` answers `OK` at once, the USB device drops about 49 s later, and every port is back about 28 s after that, with the same COM numbers** (question 8). `AT+CFUN=4` answers in under 100 ms and leaves the registration at `<stat>` **4 (unknown)**, not 0, with no operator (`cereg.radiooff.txt`); after `AT+CFUN=1` the modem was registered again on LTE in about a second. `+CSCON?` answers `+CME ERROR: 100` while there is no service. ✅ **As recovery steps, the app's worker on the device** (M4): after `AT+CFUN=4`, the pass's `AT+CFUN=1` and context activation had it online again in about 11 s. After `AT+CFUN=15` the AT port stopped answering about 22 s after the `OK` while the device was still on USB, the device left USB at about 51 s and was back at about 76 s, its port answering at once, the SIM busy (`+CME ERROR: 14`) for about 10 s; the app's context 1 was gone, and the pass had it online again at about 87 s. ✅ **`AT+CFUN=1,1` (question 8)** answers `OK` at once, the modem keeps answering for a while, leaves USB about 47 s after the `OK` and is back about 30 s later, **with the same COM numbers**; a context 1 defined before it is gone after it, as after `+CFUN=15`. |
| Operator selection | `+COPS` | `=0` automatic, `=2` deregister, `=3,<format>` sets the name format for the read. `?` returns `<mode>,<format>,<oper>,<AcT>`. Up to 3 min (`[FIBOCOM]` §11.1.6 p.160). ✅ Unregistered, the device answers `+COPS:0,255,"",0` — no blank after the colon, and a format and an `<AcT>` that mean nothing without an operator (`cops.nosim.txt`). ✅ `AT+COPS=2` answers `OK` and deregisters; as the recovery step R3 on the device, the pass's `AT+COPS=0` and context activation had the modem online again in about 2 s. |
| Registration status | `+CREG`, `+CGREG`, `+CEREG`, `+C5GREG` | `<stat>`: `1` home, `5` roaming, `2` searching, `3` denied, `0` not searching. `[FIBOCOM]` §11.1.3–11.1.5 p.150–157 documents the first three; `+CEREG` gives TAC and cell ID as quoted hex strings and, for `<n>` 3–5, the reject cause of a denied registration. **`+C5GREG` is in neither manual**, but the device takes it (`=?` gives `(0-3)`). ✅ Without a SIM: `+CEREG: 0,0` (and the same for `+CREG`, `+CGREG`), while `+C5GREG?` answers a single value, `+C5GREG: 0` (`cereg.nosim.txt`, `c5greg.nosim.txt`). ✅ **With `<n>` 0 — what a reset leaves — `+C5GREG?` answers that one value with a SIM and registered on LTE too**: it is `<n>`, with no status after it, so the app reads a read answer's first value as `<n>` and takes a lone one as "no 5GS status", never as `<stat>` 0. ✅ Registered on LTE with `<n>`=2, every domain answers the full read form (`creg.lte.txt`, `cgreg.lte.txt`, `cereg.lte.txt`, `c5greg.lte.txt`): `+CREG` stat `6` (home, **SMS only** — no circuit-switched voice), the others stat `1`; **`+C5GREG` reports the EPS registration too**, NR off or not, so a 5GS stat of 1 doesn't mean a 5G core. Location fields are hex but padded per domain: TAC 4 digits (6 in `+C5GREG`), cell identity 8 digits (9 in `+CREG`, 10 in `+C5GREG`); `+CGREG` adds a 2-digit RAC. While searching the modem fills them with a **"not known" pattern** — `"FFFF"`, `"00FFFFFFF"`, `"000000"` — which the parser reads as no location. Registration took about 2 s from power-on, `<stat>` going 2 (searching), 4 (unknown), then 1. A set form with `<n>`>0 (`AT+C5GREG=2`) answers with a report line before its `OK`: the channel queues it as unsolicited. |
| Registration report layout | `+CREG`, `+CGREG`, `+CEREG`, `+C5GREG` | The read answer starts with `<n>`, the unsolicited code doesn't: `+CEREG: <n>,<stat>[,…]` versus `+CEREG: <stat>[,…]`. After `<stat>`: `+CREG`/`+CEREG` `<lac or tac>,<ci>,<AcT>[,<cause_type>,<reject_cause>]`; `+CGREG` puts `<rac>` before the cause; `+C5GREG` puts `<Allowed_NSSAI_length>,<Allowed_NSSAI>` before it. Location fields are quoted hex. |
| Legacy signal quality | `+CSQ` | `<rssi>` 0–31, `99` unknown: `0` is −113 dBm or less, `1` −111, `2`–`30` −109 to −53 dBm in 2 dB steps, `31` −51 dBm or more. Not meaningful for LTE/NR quality. ✅ The device puts a blank after the comma: `+CSQ: 99, 99` (`csq.nosim.txt`), `+CSQ: 11, 99` on LTE (`csq.lte.txt`). |
| Extended signal quality | `+CESQ` | RSRQ/RSRP for LTE and SS-RSRQ/SS-RSRP/SS-SINR for NR — the **standard** way to read LTE/NR quality. `[FIBOCOM]` §11.1.2 p.145: nine fields; the NR fields are valid on NR **and EN-DC** (so NSA reports them), the LTE ones on LTE and EN-DC; `<ber>` is always 99. ✅ Nine fields, all "not known" without a SIM (`cesq.nosim.txt`); on LTE the LTE fields and a GSM-style `<rxlev>` are filled, the NR fields `255` (`cesq.lte.txt`, NR switched off); **idle on an LTE anchor cell with NR allowed, the NR fields are filled with no NR leg** (`cesq.idle-anchor.txt`, see *`+COPS` access technology* below). |
| Define data context | `+CGDCONT=<cid>,<PDP_type>,<APN>` | `<PDP_type>` `IP`, `IPV6`, `IPV4V6`. The read form lists one `+CGDCONT: <cid>,<PDP_type>,<APN>,<PDP_addr>,…` line per defined context. **Persistent** on the FM350 (`[FIBOCOM]` §12.2.1 p.193): the connect sequence reads `+CGDCONT?` and writes only what differs. ✅ **Contradicted on the device: context 1, defined by the app, was gone after `AT+CFUN=15`** (and its `+CGAUTH` credentials with it); the connect sequence writes it again when it finds it missing, so nothing depends on it surviving. The read form of a context the app defined leaves its trailing fields empty: `+CGDCONT: 1,"IPV4V6","<apn>","",,,,,,,,,,`. An empty APN means the subscription's own. ✅ **On two operators' SIMs the network put a context defined with an empty APN on the IMS APN** — no internet either way: one gave it no IPv4 address (only an IPv6 interface identifier in `+CGPADDR`), the other an IPv4 one (`cgcontrdp.app-ims.txt`, `cgpaddr.app-ims.txt`). So an empty APN is not enough to get online on every network: the app recognizes the IMS APN in `+CGCONTRDP` and asks for one (ARCHITECTURE → *Connection state machine*). ✅ `=?` gives `<cid>` `0`–`49` and the three types (`cgdcont.test.txt`); our device has **no context defined**, before and after `AT+CFUN=15` and a power cycle (`cgdcont.empty.txt`). Once attached on LTE the modem lists a context `0` of its own — type `IPV4V6`, empty APN (`cgdcont.attached.txt`) — which `+CGACT?` doesn't list. |
| APN authentication | `+CGAUTH=<cid>,<auth_prot>,<user>,<password>` | **Password — never logged.** **In neither vendor manual** ❓: probe with `AT+CGAUTH=?`. The only documented alternative is `+EIAAPN` (§4), which writes persistent state. ✅ **`+CGAUTH` is there, though its test form fails**: `AT+CGAUTH=?` answers `+CME ERROR: 100` with and without a SIM (`cgauth.test.txt`), while the read form answers `+CGAUTH: 0,0,"",""` — the attach context, no authentication (`cgauth.read.txt`). `+EIAAPN` answers neither its test nor its read form: absent on this firmware. So credentials go through `+CGAUTH`; that its set form takes them on the app's context, and whether they persist: M2. `<auth_prot>`: `0` none, `1` PAP, `2` CHAP (`[27.007]`). **The device's read form carries a fourth value after the user — the password** (empty in `cgauth.read.txt`): the app never returns it from the parser and redacts it in the log, like the set command. ✅ The set form takes credentials on the app's context, and the read form then gives the password back **in clear** (`cgauth.probe.txt`, probe values); they don't survive `AT+CFUN=15` (above). |
| PS attach | `+CGATT` | Up to 15 s (`[FIBOCOM]` §12.2.2 p.198). |
| Activate context | `+CGACT=<state>,<cid>` | Attaches first if needed; deactivating the last EPS context is refused. Up to 30 s (`[FIBOCOM]` §12.2.4 p.202). The read form lists `+CGACT: <cid>,<state>` per context, `1` active (`[27.007]`). ✅ On the device deactivating context 1 answered in about 100 ms; activation and deactivation are each followed by an unsolicited `+CGEV: ME PDN ACT 1` or `+CGEV: ME PDN DEACT 1`; the attach context `0` is not listed. Not registered (no SIM), the read form answers `OK` with no line. ✅ Deactivated and activated again (the recovery step R2), context 1 was back within about 1.5 s; once it carried a **new IPv4 address**, which the pass then set on the adapter. |
| Context address | `+CGPADDR=<cid>` | With dual stack, the first address is IPv4 and the second IPv6 (`[FIBOCOM]` §12.2.5 p.204). ✅ **Where the app's data context gets its IPv4 address**: `+CGPADDR: 1,"<IPv4>",""` (`cgpaddr.app.txt`), since `+CGCONTRDP` leaves it out (next row). An address is IPv4 or IPv6 by its shape, not by its position: on the IMS APN one network gave only an IPv6 one, written as 16 dotted numbers, in the first position. |
| Dynamic context parameters | `+CGCONTRDP=<cid>` | `+CGCONTRDP: <cid>,<bearer_id>,<apn>,<address and mask>,<gateway>,<DNS 1>,<DNS 2>,…`. **Address and mask are one string**: `"a1.a2.a3.a4.m1.m2.m3.m4"` for IPv4, 32 numbers for IPv6. Dual stack gives an IPv4 line, then an IPv6 line; more than two DNS servers add lines; a missing value is an empty string (`[FIBOCOM]` §12.2.10 p.215). The standard source for configuring the adapter. ✅ in part (`cgcontrdp.ims.txt`): with no `<cid>` it lists the attach bearer — context `0`, bearer `5`, on the **IMS APN** the network assigns, no address for the host, an IPv4 line then an IPv6 one, IPv6 written as 16 dotted numbers, IPv4 MTU `1500` in the 12th field, 24 fields in all. `+CGPADDR` with no `<cid>` answers `+CME ERROR: 100`. ✅ **For the app's data context the FM350 leaves out the address, the mask and the gateway**: `+CGCONTRDP: 1,<bearer>,"<apn>","","","<DNS 1>","<DNS 2>",…` — the DNS servers only (`cgcontrdp.app.txt`, two operators alike); the address comes from `+CGPADDR`. The APN comes back as the network names it: the APN given, followed by the operator identifier `mnc<MNC>.mcc<MCC>.gprs` (`[23.003]` §9.1). **On the IMS APN its network identifier is `ims`** — `ims.mnc<MNC>.mcc<MCC>.gprs`, with one DNS server (`cgcontrdp.app-ims.txt`): that is how the app tells a context that carries no internet. `+GTDNS=1` answers the same servers. |
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

✅ **On the device `<AcT>` is `13` on an LTE cell with NR switched off** (`+GTACT` LTE only):
`+COPS:0,2,"<oper>",13`, and the same `13` in `+CREG`, `+CGREG`, `+CEREG` and `+C5GREG`, while
`+CESQ` carries no NR value and `+GTCCINFO` only LTE cells (`cops.lte.txt`, `cesq.lte.txt`,
`gtccinfo.lte.txt`). So the device uses the 27.007 numbering — `13` doesn't exist in the vendor's
table — and `13` says the LTE cell **can anchor EN-DC**, not that NR is in use. `+ERAT?` answers
`13,0,3,0,0` there, and `+GTDUALSIM?` names the service `"NR"`: neither tells NR in use either.

✅ **Under EN-DC, with an NR leg carrying traffic, `<AcT>` stays `13`** — the same as on LTE with
NR off — while `+GTCCINFO` lists an NR serving line and `+GTCAINFO` an NR primary carrier
(`gtccinfo.endc.txt`, §4.1–4.2), and `+CESQ` fills its NR fields. No 5G SA network was available
to read `11`.

✅ **Idle on an LTE anchor cell, in automatic mode, `+CESQ` fills its NR fields too**, though
`+GTCCINFO` lists LTE cells only and `+CSCON?` says idle (mode `0`): `+CESQ: 27,99,255,255,18,45,89,54,83`
with no context active but the attach one (`cesq.idle-anchor.txt`). An NR measurement is no NR leg.
So **NR in use is told from an NR serving line in `+GTCCINFO`**, never from `<AcT>` nor from
`+CESQ` alone; `+CESQ`'s NR fields without an NR serving cell mean 5G the modem measures, not one
it uses. On the device the NR serving line appeared as soon as the app's data context was active.

## 4. Fibocom commands (`[FIBOCOM]`)

Proprietary. Layouts come from the vendor manual, from captures, and from sources whose license
allows it (`[3GINFO]`, `[MODEMBAND]`) — never from unlicensed code.

| Purpose | Command | Status | Notes |
|---|---|---|---|
| RAT mode, preference and band lock | `+GTACT` | 📄 `[FIBOCOM]` §11.1.14 p.175 | See §5. |
| Serving and neighbour cells | `+GTCCINFO?` | 📄 `[FIBOCOM]` §11.1.15 p.179, `[3GINFO]` | Layout in §4.1. **Cell identity + TAC is a location — redact.** |
| Carrier aggregation | `+GTCAINFO?` | 📄 `[FIBOCOM]` §11.1.16 p.187, `[3GINFO]` | Layout in §4.2. Can be queried together with the above: `AT+GTCCINFO?;+GTCAINFO?`. |
| Current access technology | `+ERAT?` | 📄 `[FIBOCOM]` §11.1.11 p.169 | `<AcT>` `11` NR on a 5G core (SA), `12` NR on EPC, `13` NG-RAN, **`14` EN-DC (NSA)**, `255` unknown. Unregistered, the device answers five values: `+ERAT: 255,0,3,0,0`. On LTE it answers `13` (see §3 on `<AcT>` 13), and its third value follows the `+GTACT` mode plus one: `3` in LTE-only (`2`), `21` in automatic (`20`), `15` in NR-only (`14`). |
| Signalling connection | `+CSCON` | 📄 `[FIBOCOM]` §12.2.13 p.223 | Standard command, FM350 values: an unsolicited `+CSCON: <mode>[,<state>[,<access>[,<core>]]]` — `<mode>` `0` idle, `1` connected; `<state>` `7` LTE connected, `8` NR connected, `9` NR inactive; `<access>` `3`/`4` LTE TDD/FDD, `5` NR; `<core>` `0` EPC, `1` 5G core. Under EN-DC the read form lists the master RAT, then the secondary. |
| SIM slot | `+GTDUALSIM` | 📄 `[FIBOCOM]` §4.3 p.50 | Slot `0` = SIM1 (default), `1` = SIM2. **Persistent**, takes effect immediately. Read form: `+GTDUALSIM: <slot>,<SUB1 or SUB2>,<service: No Service, N, L or W>`. See §8 for the eSIM. The device writes a blank **before** the colon and quotes the strings: `+GTDUALSIM : 0, "SUB1", "NO SERVICE"`. |
| DNS servers | `+GTDNS=<cid>` | 📄 `[FIBOCOM]` §12.2.17 p.230 | Answers `<cid>,<DNS 1>,<DNS 2>`. A fallback if `+CGCONTRDP` leaves DNS empty. |
| Module temperature | `AT+GTSENRDTEMP=<id>` | ✅ `[FIBOCOM]` §18.3 p.310, `[3GINFO]`; `[DEVICE]` `gtsenrdtemp.all.txt` | `0` lists every sensor, one line each; `1`–`23` one sensor (1–22 in `[FIBOCOM-2.2]`): `1` SoC maximum, `10` 5G modem, `11` 4G modem, `14` LTE PA, `15` NR PA, `16` RF, `19` PMIC, `23` crystal. Answers `+GTSENRDTEMP: <sensor>,<value>`. The manual gives no unit; `[3GINFO]` reads thousandths of °C, consistent with the manual's thermal thresholds (e.g. `32000`). The device lists all 23 sensors at 31–36 °C in thousandths, except `17` and `18`, which answer `0`: no sensor there. |
| Model / manufacturer / firmware | `AT+CGMM?`, `AT+CGMI?`, `AT+GMR?` | ✅ `[FIBOCOM]` §3.1–3.6 p.17–21, `[3GINFO]` `[MODEMBAND]`; `[DEVICE]` `identity.txt` | Values are **quoted**: `+CGMI: "<manufacturer>"`, `+CGMM: "<model>","<short name>"`. The firmware answer's prefix is `+CGMR:` in V2.10 and `+GMR:` in `[FIBOCOM-2.2]`: accept both, strip the quotes. The device answers `+CGMM: "FM350-GL"` with **no short name**, `+GMR:` to `AT+GMR?` and `+CGMR:` to `AT+CGMR?`. Our device: `Fibocom Wireless Inc.`, firmware `81600.0000.00.29.22.06`. |
| Firmware package version | `+GTPKGVER?` | ✅ `[FIBOCOM]` §3.21 p.38; `[DEVICE]` `identity.txt` | `+GTPKGVER: "<package>"` — a different string from `+CGMR` (`81600.0000.00.29.22.06_5006.0000.065.006.048_E09`). |
| Identification | `ATI<n>` | ✅ `[FIBOCOM]` §3.18 p.35; `[DEVICE]` | `0` build time, `3`/`7` product name, `5` platform, `8` software version, `9` hardware version — quoted on the device: `"2023/03/09 16:59"`, `"FM350"`, `"MT6880"`, the firmware, `"V1.0.6"`. **Plain `ATI` prints the IMEI** (after manufacturer, model, revision and SVN lines): an identifier, so the app doesn't send it. |
| Supported commands | `+CLAC` | ✅ `[FIBOCOM]` §3.14 p.31; `[DEVICE]` | Documented as the list of the commands this firmware accepts; on the device it lists **37 MediaTek extended commands only** (`+ERAT`, `+E5GOPT`, `+EPBSE`…), not even `+CGDCONT`. A command's `=?` form is the way to probe it. |
| Module serial number | `+CFSN?` | 📄 `[FIBOCOM]` §3.16 p.33 | `+CFSN: "<10 characters>"`. **Identifier.** |
| ICCID | `AT+ICCID` | ✅ `[FIBOCOM]` §3.12 p.29, `[3GINFO]`; `[DEVICE]` `iccid.locked.txt` | Answers `+ICCID: <iccid>`, unquoted; works with the SIM locked. `+CCID` (§3.11) is the same. **Identifier.** On the device it answers with the SIM waiting for its PIN, 19 digits and a filler `f` in **lower case**: the app compares ICCIDs in upper case. |
| Vendor reset | `AT+CFUN=15` | 📄 `[FIBOCOM]` §4.2 p.48; ✅ `[DEVICE]` | Also `+CFUN=<fun>,1`. ✅ Both re-enumerate on USB and come back under the **same COM numbers**, without the app's context 1 (§3, `+CFUN` row; §7 question 8). `+CPWROFF` (§4.8) switches the modem off with no documented way back — never used. |
| FCC lock mode | `+GTFCCLOCKMODE` | 📄 `[FIBOCOM]` §17.1 p.302–303; ✅ `0` (`fcc.unlocked.txt`) | Read `+GTFCCLOCKMODE: <mode>`, set `=<mode>`, test `(0-2)`. `0` no lock; `1` unlocked once and for all ("one-time unlock"); `2` to be unlocked after every power-on ("power-up unlock"). Kept in NVRAM; a mode written **takes effect only after a restart**. |
| FCC lock state | `+GTFCCLOCKSTATE` | 📄 `[FIBOCOM]` §17.2 p.303–304; ✅ `0` (`fcc.unlocked.txt`) | Read `+GTFCCLOCKSTATE: <state>`, test `(0-1)`. `0` not unlocked yet, `1` unlocked. Kept in NVRAM, in effect at once. In mode `0` there is nothing to unlock: our module, which registers, reads `0`. |
| FCC lock in effect | `+GTFCCEFFSTATUS?` | 📄 `[FIBOCOM]` §17.3 p.304–305; ✅ `0,1` (`fcc.unlocked.txt`) | Read-only: `+GTFCCEFFSTATUS: <effective mode>,<unlock status>` — the mode in force now, which differs from `+GTFCCLOCKMODE?` between a mode write and the next restart, then `0` **locked** or `1` unlocked (mode `0`; mode `1` with state `1`; or a vendor unlock that succeeded). **Its set and test forms answer `ERROR`**; on the device the test form answers `+CME ERROR`. Read together on our module: `AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?` → `0`, `0`, `0,1` — no lock in effect, unlocked. |
| Vendor unlock | `+GTFCCLOCKGEN`, `+GTFCCLOCKVER` | 📄 `[FIBOCOM]` §17.4–17.5 p.305–307, `[MM-FCC]` | A challenge-response: the execute form `AT+GTFCCLOCKGEN` answers a hex challenge, and `AT+GTFCCLOCKVER=<response>` answers `+GTFCCLOCKVER: 1` (unlocked) or `0` (still locked). The response is computed from the challenge with a secret of the laptop's maker: **this app never implements it**. ModemManager does it for Lenovo's FM350 on PCIe at every power-on, without writing the mode. |
| **What a locked module answers** | `AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?`, `AT+CFUN=1` | 📄 `[4PDA]` (one module) · ❓ on our device | `2`, `0`, `2,0` — power-up unlock, not unlocked, locked — and `AT+CFUN=1` refused with `+CME ERROR: 0` (*phone failure*, `[FIBOCOM]` §20.2 p.327): the radio doesn't come on, so the module never searches for a network. The same module after its owner's unlock read `0`, `0`, `0,1`, as ours. A Lenovo-origin FM350-GL, firmware `81600.0000.00.29.19.16`, over USB. The lock comes back at a power loss, not at a warm restart (`[FOUNDATA]`, an FM350R-GL on PCIe). ✅ needs a capture from a locked module. |
| Laptop modules | — | `[UNLOCK]`, `[4PDA]`, `[MM-FCC]` | Modules taken from laptops are often locked by the laptop's maker, so that they work only in its machines (seen on Lenovo modules). A locked module answers AT commands but doesn't search for networks. |
| Unlocking, as done on our module | `AT+GTFCCLOCKMODE=0`, `AT+GTFCCLOCKSTATE=0`, `AT+GTFCCEFFSTATUS=0,0`, `AT&W`, `AT+CFUN=1,1` | ✅ after · first-hand before — `[UNLOCK]`; `[DEVICE]` `fcc.unlocked.txt` for the state after | **Writes persistent modem state.** Afterwards the three reads answer `0`, `0`, `0,1` and the module registers; the exact answers while it was locked were not kept. Per `[FIBOCOM]` §17.1–17.3 the third command answers `ERROR` (the status is read-only), the mode and the state are written to NVRAM by their own commands — so `AT&W` (store the profile, `[V.250]`) adds nothing documented — and the restart is what puts mode `0` in effect. **Our module took `AT+GTFCCLOCKMODE=0` with no challenge-response before it** (`[UNLOCK]`), unlike the unlocks the other sources describe, which pass the vendor's challenge first (`[MM-FCC]`, `[4PDA]`): whether every locked module does is not known ❓, so the app's unlock may be refused on some. The app sends the sequence as it was done, the third command included, and tolerates its error (decided 2026-10-01). |

**Persistent settings the app only reads** (writing any of them is a human decision, see
`CLAUDE.md`): `+E5GOPT` — which of LTE, 5G SA ("option 2") and 5G NSA ("option 3") are enabled, as
a bitmap (`[FIBOCOM]` §12.2.15 p.228; the listed values `0x01`, `0x02`, `0x05` are ❓);
`+EIAAPN` — the initial-attach APN with its authentication (none, PAP, CHAP), user and password
(§12.2.14 p.226; **password — never logged**); `+GTFMODE` — whether the flight-mode and GNSS
hardware pins are honoured (§13.1.2 p.233); `+MSMPD` — SIM hot-plug detection, on by default
(§4.7 p.60); `+GTUSBMODE`, `+GTDIPCMODE` (§1); `+GTDUALSIM` (above); `+GTESIMCFG` (§8).
`+EPBSEH` (§11.1.12 p.171) shows the band selection as MediaTek bitmaps, a cross-check for
`+GTACT`.

What our device answers to them (`[DEVICE]`, read only): `+GTUSBMODE: 41`, with `=?` offering
`(40,41)`; `+E5GOPT: 7`, a value the manual doesn't list (presumably all three of LTE, SA and NSA
❓); `+GTFMODE: 1,0`; `+MSMPD: 1`; `+GTESIMCFG: 0,0,0`; `+EPBSEH:` four quoted hex bitmaps;
`+EIAAPN?` and `+EIAAPN=?` `+CME ERROR: 100`, with a SIM too — the command is absent; `+GTDIPCMODE?` `+CME ERROR: 0`, so this firmware has
no USB/PCIe mode to read.

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
  they are printed in hex is not stated (`[3GINFO]` reads the TAC as hex). ✅ **Hex** on the
  device, the same values as `+CEREG`'s, the cell identity padded to 9 digits
  (`gtccinfo.lte.txt`). Neighbour lines carry no location — TAC `FFFF`, cell identity
  `00FFFFFFF` — and no MCC/MNC.
- The level field uses the RSRP index scale; how it differs from the RSRP field is not stated ❓
  (on the device they are always equal).
- The bandwidth field has no code table in this section; presumably the codes of §4.3. ✅ `100` for
  a 20 MHz LTE carrier, as `+GTCAINFO` reports it (`gtccinfo.connected.txt`).
- ✅ **The serving cell's band and bandwidth are filled only while the modem is connected**
  (`+CSCON: 1,1`); idle, both fields are empty (`gtccinfo.lte.txt`, `gtccinfo.connected.txt`).
  The parser then takes the band from the channel number (§6).
- ❓ Connected, an LTE neighbour line carried `82` in its RSRQ field, beyond the documented index
  range `0`–`34`: the parser leaves such a value out.
- `255` = not known or not detectable. Conversions in §6.
- ✅ **Under EN-DC the NR serving line follows the LTE one**, as documented: RAT `9`, band `5078`
  (n78), NR-ARFCN `645312`, bandwidth `400` (80 MHz), **no MCC or MNC**, and the "not known"
  location `FFFFFFF` / `00FFFFFFF` (`gtccinfo.endc.txt`).
- ✅ **A serving line is no registration.** In NR-only mode, where the SIM's operator offers no 5G
  SA, the unregistered modem lists as serving an NR cell of another operator, with that
  operator's MCC and MNC and its location (`gtccinfo.nr-camped.txt`). The app names a technology
  only while the operator read reports one (ARCHITECTURE → *Tray icon*).
- ❓ Seen in one session (2026-10-03): some LTE neighbour lines carry the 7-digit "not known" TAC
  `FFFFFFF` of NR lines and a six-digit channel ending in `12` — `640012`, `185012`, `525012`,
  `302512` — next to lines with the 4-digit `FFFF` and plain EARFCNs, and one of them an RSRP
  index of `406`. What those fields hold is not known; the parser finds no band for such a
  channel and shows the line without one.
- ✅ With no network the device answers a bare `+GTCCINFO:` header and no cell line; to
  `AT+GTCCINFO?;+GTCAINFO?` it adds nothing for `+GTCAINFO` — not even its header — before the
  `OK` (`gtccinfo.nosim.txt`).

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
- ✅ **On the device the `PCC:` line has ten fields, with the UL bandwidth after the DL one** —
  as in `SCC<n>:` lines, unlike the manual's nine: `PCC:103,<pci>,1850,100,100,1,1,2,1,-96`
  (`gtccinfo.connected.txt`). The parser reads a primary line of ten fields or more that way, a
  shorter one as the manual lays it out. The trailing RSRP is in **dBm** (`-96`).
- ✅ `+GTCAINFO` answers only while the modem is connected: idle, not even its header comes back
  (`gtccinfo.lte.txt`).
- ✅ **The device writes `SCC <n>:` with a blank** (`SCC 1:`), as `[3GINFO]` expects; LTE-A seen
  with three secondary carriers, one of them with uplink CA (`gtccinfo.ltea.txt`).
- ✅ **Under EN-DC both blocks appear, NR first, with no header line**: the NR `PCC:` line, then the
  LTE `PCC:` line and its `SCC <n>:` lines (`gtccinfo.endc.txt`). An LTE secondary carrier and
  the NR primary one are told apart by their band code.

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
| Band code `0` means **automatic band selection** for the RATs named in the command, or for every RAT if none is named. | ✅ | `[FIBOCOM]`, `[UPSTREAM-README]`, `[MODEMBAND]`; `[DEVICE]` `gtact.auto.txt` — after `AT+GTACT=20,6,3,0` the read form lists the UMTS, LTE and NR codes |
| **n77 drops out when n78 is listed too**: right after a write, `AT+GTACT?` lists `5077`; once the modem has tried to register, it doesn't — whether n77 came from a code `0`, from the full NR list written code by code, or from `5077,5078` (`gtact.auto.txt`, `gtact.n77-n78.txt`), in mode `20` and in mode `14` alike, with or without a registration (`gtact.nronly.txt`). **Written alone, n77 stays** (`gtact.n77-alone.txt`). n78 (3300–3800 MHz) lies within n77 (3300–4200 MHz); why the firmware keeps only the narrower band is not documented ❓. The app never writes again for a band the modem leaves out (ARCHITECTURE → *Modes and bands*). | ✅ | `[DEVICE]` `gtact.auto.txt`, `gtact.n77-n78.txt`, `gtact.n77-alone.txt`, `gtact.nronly.txt` |
| In a multi-RAT mode the read form lists the **UMTS codes** too (`1,2,4,5,8`), before the LTE ones; the band codec keeps them as `Unknown` with their raw value. | ✅ | `[DEVICE]` `gtact.auto.txt` |
| **LTE band N is written `100 + N`** (B1 → `101`, B3 → `103`, … B71 → `171`). | 📄 | `[FIBOCOM]`, `[UPSTREAM-README]`, `[MODEMBAND]` |
| **NR band N is written `"50"` followed by N** (n1 → `501`, n9 → `509`, n10 → `5010`, n78 → `5078`, up to n512 → `50512`). | 📄 | `[FIBOCOM]`, `[MODEMBAND]` |
| UMTS band N is written N (`1`–`10`). The app doesn't manage UMTS bands and keeps their codes as read. | 📄 | `[FIBOCOM]` |
| **Band lists are per RAT.** Writing LTE codes changes only the LTE list; the UMTS and NR lists stay as they were. `AT+GTACT=20,6,3,103,107` restricts LTE to B3 and B7 and leaves NR as it was. | ✅ | `[FIBOCOM]` (note 5); `[UPSTREAM-README]` shows the command; `[DEVICE]` `gtact.ltefull-n78.txt` — every LTE code written, NR stayed on n78 |
| `AT+GTACT?` answers `+GTACT: <rat>,<pref1>,<pref2>,<band>,<band>,…` with the band codes currently set. | ✅ | `[FIBOCOM]`, `[MODEMBAND]`; `[DEVICE]` `gtact.lteonly.txt` |
| With every band of a RAT enabled, `AT+GTACT?` lists **each code**, not `0`: our device answers `2,3,3` (LTE only) followed by all 31 LTE codes, and no NR code. | ✅ | `[DEVICE]` `gtact.lteonly.txt` |
| `AT+GTACT=?` lists the supported values: RATs, first and second preference, then GSM, UMTS, LTE, CDMA, EVDO and NR band codes. | ✅ | `[FIBOCOM]`; `[DEVICE]` `gtact.test.txt` — nine parenthesized groups: `(1,2,4,10,14,16,17,20)`, `(2,3,6)`, `(2,3,6)`, `()`, `(1,2,4,5,8)`, the LTE codes, `()`, `()`, the NR codes |
| To change bands without changing the mode: read `AT+GTACT?`, keep its first three values, and write them back followed by the new codes. | 📄 | `[MODEMBAND]` |
| Band lists supported by the FM350-GL — LTE: 1 2 3 4 5 7 8 12 13 14 17 18 19 20 25 26 28 29 30 32 34 38 39 40 41 42 43 46 48 66 71; 5G: n1 n2 n3 n5 n7 n8 n20 n25 n28 n30 n38 n40 n41 n48 n66 n71 n77 n78 n79; UMTS: 1 2 4 5 8. | ✅ | `[MODEMBAND]` (its default lists), `[FIBOCOM]` §13.1.6 p.241 (the same bands); `[DEVICE]` `gtact.test.txt` — exactly these on our firmware (other variants differ: the FM350-GL-16 has no NR) |
| The `OK` comes back at once; the modem then **registers again** with the new setting. | ✅ | `[FIBOCOM]`; `[DEVICE]` — `OK` in 70–400 ms, registration reports going to 0, 2 or 4, registered again on LTE 1–2 s later; 1.0–2.0 s after each of the session's writes on 2026-10-03 |
| **A write ends the data context**: context 1, active before six writes, was gone each time once the modem had registered again; activated again, it carried an address within a second. | ✅ | `[DEVICE]` (M5 session) |
| **Right after a write, a registration read can still report the registration the write ends**: after `AT+GTACT=14,6,6,0` the first `+CEREG?` said registered (stat `1`), the next ones searching, not searching or unknown (`2`, `0`, `4`). The app confirms a mode the user chose only from a registration read 10 s after the write or later (ARCHITECTURE → *Modes and bands*). | ✅ | `[DEVICE]` (M5 session) |
| In NR-only mode (`AT+GTACT=14,6,6,0`) where no 5G SA network is offered the modem stays unregistered (`<stat>` 2, `+GTDUALSIM` service `"NO SERVICE"`, `+ERAT: 255,0,15,0,0`). It lists as serving an NR cell of **another operator** that offers 5G SA there, with that operator's MCC and MNC (`gtccinfo.nr-camped.txt`): a serving line is no registration. | ✅ | `[DEVICE]` (60 s without registering; again 90 s on 2026-10-03, and 3 min as an app trial) |
| **Not persistent**: a reset loses the setting. | 📄 | `[FIBOCOM]` (attribute table) — contradicted on the device (next row). |
| **Contradicted on the device: the setting survives `AT+CFUN=15`.** Our modem came in LTE-only mode, set before this project touched it, and was still in it after the reset **and after a power cycle** (the USB cable pulled and plugged back). So the app reads it at every connect and writes it only when it differs from what the settings ask: a mode that works is never written again for nothing, and a mode the app sets stays after it exits. | ✅ | `[DEVICE]` `gtact.lteonly.txt` (read before and after the reset and the power cycle) |
| How one RAT goes back to all bands while another stays restricted: `0` applies to every RAT named, so by listing every supported band of that RAT. | ✅ | `[DEVICE]` `gtact.ltefull-n78.txt` |
| Whether LTE and NR codes can be listed in one command. ✅ They can: `AT+GTACT=20,6,3,103,120,5078` reads back as `20,6,3,1,2,4,5,8,103,120,5078` — LTE B3 and B20, NR n78, the UMTS list kept. | ✅ | `[DEVICE]` `gtact.combined.txt` |
| **NR band codes restrict NSA (EN-DC) too**, not only SA. The LTE list held on B3, the anchor that carried the NR leg: with n78 allowed (`AT+GTACT=20,6,3,103,5078`) the NR leg on n78 was there in 12 reads out of 12, `+CSCON?` connected on LTE and NR (states `7` and `8`); with n79 only (`…103,5079`) in none of 12, connected on LTE alone. `[MODEMBAND]` handles them as SA bands. | ✅ | `[DEVICE]` (M5 session, data context active) |

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

Collected for the first session with the modem; each answer became a fixture and flipped a row
above to ✅. What one session could not answer says where it will be: a data session (M2), the
modes and bands work (M5), the recovery work (M4), a module with an eUICC (M8).

1. `AT+CLAC` — which commands this firmware accepts, in particular `+CGAUTH`, `+C5GREG`, `+CCHO`/`+CGLA`/`+CCHC`, and any undocumented traffic-statistics command. Then `ATI`, `+CGMM?`, `+CGMR`, `+GTPKGVER?` — which exact model and firmware. *Answered (§4): `+CLAC` lists only 37 MediaTek commands, so the `=?` forms decide — `+C5GREG` and the logical-channel commands are there; `+CGAUTH=?` answers `+CME ERROR: 100` but `AT+CGAUTH?` works (§3). No traffic-statistics command was found. Firmware `81600.0000.00.29.22.06`.*
2. Which USB composition (`7126`/`7127`), which COM port is "MD AT", which driver serves the network adapter, and whether it shares a container ID with the AT port. *Answered in §1.*
3. `+COPS?` on LTE, on 5G NSA and on 5G SA — does `<AcT>` follow `[27.007]` or the vendor table (§3)? Compare with `+ERAT?`. *LTE answered (§3): 27.007 numbering, `13` on an EN-DC-capable LTE cell with NR off. NSA answered (§3): still `13` with an NR leg in use. No 5G SA network here.*
4. `+CESQ` on LTE, NSA and SA — confirm the documented NR fields. *LTE answered (§3); NSA answered: the NR fields are filled under EN-DC (§3). SA: none here.*
5. `+CGCONTRDP=1` — confirm the documented layout (address and mask in one string, gateway, DNS). *Answered (§3): for the app's context the device leaves out the address, the mask and the gateway; the address comes from `+CGPADDR`.*
6. Does the network adapter answer DHCP, or must the address be configured statically? *Answered (§1): no DHCP; the address is configured as a /32 with a default route on the link.*
7. `AT+GTACT=?` and `AT+GTACT?` — the actual values; whether LTE and NR codes can be combined in one write; how to return one RAT to all bands; whether NR codes apply in NSA. *Answered (§5). NR in NSA answered in M5: NR band codes restrict the NR leg of EN-DC too.*
8. `+CFUN=1,1` and `+CFUN=15` — does the device re-enumerate on USB, and under the same COM number? *Answered (§3): both re-enumerate — `+CFUN=15` leaves USB about 49 s after its `OK`, `+CFUN=1,1` about 47 s — and come back about 30 s later with the same COM numbers, the app's context 1 gone.*
9. URCs seen during registration and during a drop, with `+CSCON` enabled. *Answered (§2): `+CREG` and `+CEREG` only, never `+CSCON`.*
10. `AT+GTCCINFO?;+GTCAINFO?` on LTE, LTE-A, NSA and SA — confirm §4.1/§4.2: hex or decimal TAC and cell ID, the bandwidth codes in `+GTCCINFO`, the NR block of `+GTCAINFO` under EN-DC. *LTE answered (§4.1, §4.2): hex, codes of §4.3, band and carriers only while connected. LTE-A and NSA answered (§4.1, §4.2): `SCC <n>:` with a blank; under EN-DC an NR serving line and the NR block first. SA: still none for our SIM in M5 — in NR-only mode the modem found no network to register on in 90 s, nor in 3 min as an app trial, and camped on another operator's 5G SA cell (§4.1); `+GTCAINFO` on SA stays to be seen where the SIM's operator offers it.*
11. APN credentials: if `+CGAUTH` is missing, the only documented route is `+EIAAPN`, which writes persistent state — a human decision then. *Answered (§3): `+CGAUTH` is there — its read form answers, only its test form fails — and `+EIAAPN` is absent. Its set form takes credentials on the app's context, and its read form gives the password back in clear.*
12. `+CGDCONT?` before and after a power cycle — is it persistent, as documented? *No context is defined on our modem, before and after a power cycle; the modem adds context 0 on attach (§3). **Contradicted for a context the app writes**: context 1 was gone after `AT+CFUN=15` (§3).*
13. The serial port: does the FM350 answer with DTR and RTS asserted (and without)? Which URCs arrive unprompted after power-on, and with which prefixes? *Answered (§2): DTR and RTS make no difference; after power-on `+ESIMS: 1,29` waits on the port.*
14. Unplugging the modem while the app holds the AT port: does the `pwsh` process survive? `System.IO.Ports` has a history of crashing the process from its background thread when a USB serial device disappears; if it happens, the transport needs a different implementation. *Answered (§2): it survives, and the port is reported lost at once.*

## 8. eSIM (M8)

The eUICC is driven by [lpac](https://github.com/estkme-group/lpac), an open-source LPA (the
component that speaks GSMA SGP.22 to the eSIM and to the operator's SM-DP+ server). This app does
not reimplement that protocol: it runs lpac as an external process and carries its APDUs to the
eUICC over the AT port it already owns.

| Fact | Status | Source |
|---|---|---|
| The eUICC is reached through **logical channels**: `AT+CCHO=<AID>` opens one and returns `<sessionid>`; `AT+CGLA=<sessionid>,<length>,<command>` exchanges an APDU and answers `+CGLA: <length>,<response>`; `AT+CCHC=<sessionid>` closes it. | 📄 | `[27.007]`, `[LPAC-WRAPPER]` |
| `+CCHO`/`+CGLA`/`+CCHC` are **in neither vendor manual**; `AT+CSIM=<length>,<command>` is (`<length>` counts hex characters). Without the logical-channel commands, a channel could be opened with a MANAGE CHANNEL APDU sent through `+CSIM`. | ❓ | `[FIBOCOM]` §10.1.4 p.139; `[DEVICE]` |
| The firmware takes the test forms `AT+CCHO=?`, `AT+CGLA=?`, `AT+CCHC=?` and `AT+CSIM=?` (`OK`, no values). Whether the commands themselves work needs a SIM. | ✅ | `[DEVICE]` |
| Without a SIM, `AT+EID?` answers an empty `+EID:` and `+SIMTYPE?` / `+SIMTYPE=?` answer `+CME ERROR: 0`. With a physical SIM, unlocked: `+SIMTYPE: 0` (USIM) and still an empty `+EID:` — **our module has no eUICC**, so the questions below wait for one that has. `+GTESIMCFG: 0,0,0`. | ✅ | `[DEVICE]` |
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
| Which storages the FM350 accepts, and their sizes. | ❓ | `[DEVICE]` — without a SIM, `AT+CPMS=?` offers `("SM"), ("SM"), ("SM")` only, `AT+CPMS?` and `AT+CMGF?` answer `+CMS ERROR: 310`, and `AT+CMGD=?` gives indexes `(1-50)` and flags `(0-4)`; with a SIM, `AT+CMGF?` is `0` (PDU) and `AT+CPMS?` reports a storage `"MT"`, which `=?` doesn't offer, with 70 places for each of the three uses (`cpms.sim.txt`) |
| `AT+CNMI=?` on the device: `(0-3), (0-3), (0,2,3), (0,1), (0,1)`; the read form starts at `0, 0, 0, 0, 0`, blanks after the commas. | ✅ | `[DEVICE]` |
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
| On the device `AT+CUSD=?` gives `(0-2)` and the read form is `+CUSD: 1` — notices on — before the app sets anything, after a reset too. | ✅ | `[DEVICE]` |
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

## 11. Windows facts (M7)

Not the modem's protocol, but facts about Windows, PowerShell and GitHub that the installer, the
encrypted DNS and the update notice are written from — with their sources, like the rest of this
page.

### 11.1 Encrypted DNS on one interface

| Fact | Status | Source |
|---|---|---|
| `SetInterfaceDnsSettings(GUID Interface, const DNS_INTERFACE_SETTINGS *Settings)` and `GetInterfaceDnsSettings` (`iphlpapi.dll`) set and read one interface's DNS settings, the interface named by its GUID. The structure's `Version` says which one it is: `DNS_INTERFACE_SETTINGS` (`1`), `DNS_INTERFACE_SETTINGS_EX` (`2`), `DNS_INTERFACE_SETTINGS3` (`3`). To set, only the fields whose flag is set are filled, the others zeroed; to read, only `Version` is set and `Flags` left empty, and the result is freed with `FreeInterfaceDnsSettings`. `NO_ERROR` is success. Minimum client given for both functions: Windows 10 build 19041. | 📄 | `[MS-DNS]` |
| `DNS_INTERFACE_SETTINGS3`, in order: `Version` (ULONG), `Flags` (ULONG64), `Domain`, `NameServer`, `SearchList` (PWSTR), `RegistrationEnabled`, `RegisterAdapterName`, `EnableLLMNR`, `QueryAdapterName` (ULONG), `ProfileNameServer` (PWSTR), `DisableUnconstrainedQueries` (ULONG, reserved), `SupplementalSearchList` (PWSTR), `cServerProperties` (ULONG), `ServerProperties` (`DNS_SERVER_PROPERTY*`), `cProfileServerProperties` (ULONG), `ProfileServerProperties`. Flags used here: `DNS_SETTING_IPV6` `0x1` (the servers are IPv6 ones; IPv4 without it), `DNS_SETTING_NAMESERVER` `0x2` — "static adapter DNS servers on the specified interface via the `NameServer` member" —, `DNS_SETTING_DOH` `0x1000` — with it, `NameServer` must hold the servers, comma- or space-separated. At most one property per server; its `ServerIndex` is the server's position in `NameServer`, from `0`. Minimum client given: build 19645. | 📄 | `[MS-DNS]` |
| `DNS_SERVER_PROPERTY`: `Version` (`1`), `ServerIndex` (ULONG), `Type` (`DNS_SERVER_PROPERTY_TYPE`), `Property` (a union of pointers; `DohSettings` for DoH). `DNS_SERVER_PROPERTY_TYPE`: `DnsServerInvalidProperty` `0`, `DnsServerDohProperty` `1`, and a `DnsServerDotProperty` the page lists without describing; minimum client given: build 20348. `DNS_DOH_SERVER_SETTINGS`: `Template` (PWSTR), `Flags` (ULONG64): `ENABLE_AUTO` `0x1` — the template from the system's list of known DoH servers, `Template` NULL —, `ENABLE` `0x2` — `Template` given —, never both; `FALLBACK_TO_UDP` `0x4` — the server may fall back to unencrypted resolution when DoH fails —; `DNS_DOH_AUTO_UPGRADE_SERVER` `0x8` (NRPT rules). A template whose host is an IP address other than the server's is invalid. | 📄 | `[MS-DNS]` |
| On x64 the three structures are 112, 24 and 16 bytes. | ✅ | `[HOST]` (marshalled sizes) |
| **Windows 10 has no DoH client.** Microsoft documents DNS over HTTPS in the DNS client "starting with Windows Server 2022" (build 20348); the DnsClient module's DoH cmdlets (`Add-`, `Get-`, `Set-`, `Remove-DnsClientDohServerAddress`) are documented for Windows Server 2022 and 2025 only, not in the set that covers Windows 10; and the parts of the per-interface API that carry DoH are given builds 19645 and 20348, which no Windows 10 release reached: the last one is version 22H2, build 19045, out of support since 2025-10-14. Not tried on a Windows 10 computer. | 📄 | `[MS-DNS]`, `[MS-WIN10]` |
| **Known DoH servers.** Windows ships a list of servers with their templates, read with `Get-DnsClientDohServerAddress`: Cloudflare `1.1.1.1`, `1.0.0.1`, `2606:4700:4700::1111`, `2606:4700:4700::1001`; Google `8.8.8.8`, `8.8.4.4`, `2001:4860:4860::8888`, `2001:4860:4860::8844`; Quad9 `9.9.9.9`, `149.112.112.112`, `2620:fe::fe`, `2620:fe::fe:9`. `Add-DnsClientDohServerAddress` adds one, system-wide. In the Settings app, *Encrypted only* means no resolution when the server can't answer over DoH; *Encrypted preferred, unencrypted allowed* falls back without notice. `netsh dnsclient set global doh=no` forbids DoH on every interface. | 📄 | `[MS-DNS]` |
| On our host: those twelve servers, templates `https://cloudflare-dns.com/dns-query`, `https://dns.google/dns-query`, `https://dns.quad9.net/dns-query`, fallback and auto-upgrade off; `netsh dnsclient show global` says DoH enabled. `GetInterfaceDnsSettings` with version `3` on the modem's adapter — disconnected, no static DNS — answers `NO_ERROR`: no flags, no name server, no server property. Set by the app on the modem's adapter, online: `SetInterfaceDnsSettings` took the servers with the flag `ENABLE` (`0x2`) and read back as set; the DNS client then reached them over TCP port 443 from the modem's address, and opened no connection to port 53. | ✅ | `[HOST]` |
| **What a restart keeps.** `Set-NetIPInterface -Dhcp` "is persistent across reboots and only stored in the active policy store". On our host, after a restart, the modem's adapter had lost the app's address, default route and metric (active store), but kept DHCP off, its IPv4 DNS server and that server's DoH property (`ENABLE`, with its template): the app's first pass set the address, the route and the metric again, and nothing else. | 📄 · ✅ | `[MS-HOST]` (*Set-NetIPInterface*); `[HOST]` |
| **A DoH property needs a template.** `SetInterfaceDnsSettings` refused a server property whose template was an empty string with `12006` (`0x2EE6`, "the URL scheme could not be recognized"); with the `DNS_SETTING_DOH` flag and no server property at all, it takes the servers and leaves none of them encrypted. | ✅ | `[HOST]` |
| **Static servers, and the ones Windows lists.** On our host, the modem's adapter disconnected: with no static server, `GetInterfaceDnsSettings` gave no name server for either family while `Get-DnsClientServerAddress` listed `fec0:0:0:ffff::1`, `::2` and `::3` for IPv6. With two IPv4 servers encrypted and one IPv6 server set static, `Set-DnsClientServerAddress -ResetServerAddresses` followed by the IPv4 servers set again with their DoH properties left the IPv4 servers encrypted and no IPv6 server, static or listed; the plan asked for nothing more at its next pass. A reset with nothing set again brought the `fec0` servers back to the list. | ✅ | `[HOST]` |
| **No IPv6 DNS server from the network.** On our host, in every reading with the connection up — an `IPV4V6` context, 18 readings over the device sessions —, the modem's adapter listed no IPv6 DNS server: none from router advertisements, and not Windows' `fec0` ones, which it listed only with no DNS server set at all. Whether another modem firmware or operator advertises one is not known. | ✅ | `[HOST]` |
| **Encryption belongs to an address, never to a name.** A DoH property points at a server by its position in `NameServer`, a list of addresses; `netsh dnsclient add encryption` takes `server=<IP address>` with `dohtemplate=` (DoH) or `dothost=<hostname>:<port>` (DoT). The template's or the host's name is for the request and the certificate, not for finding the server: a server known only by its name is looked up first. | 📄 | `[MS-DNS]` |
| **A DNS message.** A 12-octet header — the ID (16 bits), the flags `QR` (an answer), `TC` (cut short to fit), `RD` (recursion desired), `RCODE` (`0` no error, `2` server failure, `3` the name does not exist), then the counts of questions, answers, authority and additional records —, the question — the name as labels, each one length octet (`0`–`63`) then its octets, ended by a zero octet; then `QTYPE` and `QCLASS` —, then the records: `NAME`, `TYPE`, `CLASS`, `TTL` (32 bits), `RDLENGTH`, `RDATA`. `A` is type `1` (its `RDATA` the four octets of an IPv4 address), `CNAME` type `5`, class `IN` `1`. A name may end in a pointer, two octets whose top bits are `11`, the rest an offset in the message. Names are at most 255 octets; over UDP, servers listen on port 53 and messages are at most 512 octets. | 📄 | `[RFC1035]` |
| **An answer is matched to its query.** A resolver MUST use an unpredictable source port and an unpredictable ID over the whole range `0`–`65535`, and match an answer's source address, destination address and port, ID, and question — name, class and type — to the query's. | 📄 | `[RFC5452]` |
| A name outside ASCII travels in its ASCII form, the A-label (`xn--` and the rest). | 📄 | `[RFC5890]` |
| **A packet leaves through the interface that has its source address.** Since Windows Vista every interface uses the strong host model for sends by default (`WeakHostSend` `Disabled`): when a program sets the source address, Windows looks the route up among that interface's routes alone. On our host `WeakHostSend` is `Disabled` on every IPv4 interface; with the modem online and the Ethernet adapter holding the preferred default route, a DNS query from a UDP socket bound to the modem's address left through the modem — the public address the server saw was not the one seen through Ethernet. | 📄 · ✅ | `[MS-HOST]`; `[HOST]` |

### 11.2 Installing: PowerShell, the logon task, the console

| Fact | Status | Source |
|---|---|---|
| **Where pwsh can be.** The MSI installs into `$Env:ProgramFiles\PowerShell\7` (`7-preview` for previews; `INSTALLFOLDER` changes the parent, never the versioned subfolder). **From the PowerShell 7.6.0 package, winget installs the MSIX by default** (the MSI with `--installer-type wix`); **from 7.7.0 there is no MSI** at all. The MSIX — from the Microsoft Store, winget, or by hand — is installed for one user, with `$PSHOME` under `$Env:ProgramFiles\WindowsApps\`; its folder is named after the package's version. A ZIP runs from wherever it was extracted; the .NET global tool from `$HOME\.dotnet\tools`. | 📄 | `[MS-PWSH]` |
| On our host PowerShell 7.6.6 is the MSIX (signature kind `Store`), `$PSHOME` `C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe`. `pwsh` on the PATH resolves to that folder, and also to the app execution alias `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`, in the user's profile. The package folder grants full control to TrustedInstaller and SYSTEM, read and execute to Administrators and Users; the user can't list `WindowsApps` itself. `pwsh.exe` is Authenticode-signed, signer `CN=Microsoft Corporation, O=Microsoft Corporation`, file version `7.6.6.500`. `Get-AppxPackage -Name Microsoft.PowerShell` gives the package's `InstallLocation`. `C:\Program Files` grants Users read and execute; its subfolders inherit full control for SYSTEM, Administrators, TrustedInstaller and the creator-owner. | ✅ | `[HOST]` |
| **PSModulePath.** PowerShell 7 builds it at startup: the CurrentUser module path (`Documents\PowerShell\Modules`, or the one a user's `powershell.config.json` names), then the AllUsers one (`$Env:ProgramFiles\PowerShell\Modules`), `$PSHOME\Modules`, then what the process inherited. Module autoloading searches it in that order. The CurrentUser folder is the user's to write. | 📄 | `[MS-PWSH]` |
| **Opening a runspace puts the user's module folder back.** With `$env:PSModulePath` set to `$PSHOME\Modules;<System>\WindowsPowerShell\v1.0\Modules`, opening a runspace — with `InitialSessionState.Create()` or `CreateDefault2()`, every time — prefixes the CurrentUser and AllUsers paths again, in the environment of the **whole process**, not only the runspace's. | ✅ | `[HOST]` |
| The Windows modules the app uses — `NetAdapter`, `NetTCPIP`, `DnsClient`, `PnpDevice`, `ScheduledTasks` — are in `<System>\WindowsPowerShell\v1.0\Modules`, declare the editions `Desktop` and `Core`, and require no other module. | ✅ | `[HOST]` |
| **Task Scheduler's defaults**: a task is stopped 72 hours after it starts (`ExecutionTimeLimit`; `PT0S` lets it run indefinitely); it doesn't start on batteries and is stopped when the computer goes on batteries (`DisallowStartIfOnBatteries`, `StopIfGoingOnBatteries`: `True`); priority `7`, the below-normal priority class meant for background tasks — `4` to `6` are the normal class, for interactive ones. `MultipleInstances`: `Parallel` starts a new instance while one runs, `IgnoreNew` doesn't. | 📄 | `[MS-TASK]` |
| **A console program opens a Windows Terminal window.** On our host the default terminal is left to Windows (no delegation values under `HKCU\Console\%%Startup`), which picks Windows Terminal: `powershell.exe -WindowStyle Hidden`, started the way a shortcut or Task Scheduler starts a program, showed a Windows Terminal window for its whole life — the switch hides nothing there. Started with `CreateNoWindow`, or with `SW_HIDE` (`Start-Process -WindowStyle Hidden`), no window appeared. | ✅ | `[HOST]` |
| **The environment is the user's.** Every process has user and system environment variables, inherited by its children; the user sets their own without administrator rights. `[Environment]::GetFolderPath` returns the known folders (`KNOWNFOLDERID`), not the variables: on our host it gave the real Program Files, System and Windows folders while `ProgramFiles`, `windir` and `SystemRoot` named another folder in the process. | 📄 · ✅ | `[MS-ENV]`; `[HOST]` |
| **UAC is not a security boundary**: Microsoft lists User Account Control among the defense-in-depth features, which it doesn't service as security boundaries. | 📄 | `[MSRC]` |
| **Where the app can run.** PowerShell 7.6 is published for x64 and Arm64 only — MSI, ZIP and MSIX alike. On Windows on Arm, kernel-mode drivers "MUST be built as native Arm64 binaries"; x86 and x64 emulation is for applications. The modem's driver package has x64 and x86 drivers only (§1.1). So the app runs on 64-bit Windows on an x64 processor alone. | 📄 | `[MS-PWSH]`, `[MS-ARM]`, `[INF]` |
| **The taskbar groups windows by AppUserModelID.** An application may set its own — at most 128 characters, no spaces, `CompanyName.ProductName[.SubProduct]` — on a window (`SHGetPropertyStoreForWindow`, property `System.AppUserModel.ID`, format `9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3`, id `5`, a string), on the process, and on its shortcut; a window's overrides the process's. When a shortcut launches the application, the same ID goes on the shortcut, whose command line, icon and name the taskbar then uses — pinning included — instead of the relaunch properties. A window's properties must be removed before it closes (set to `VT_EMPTY`), or their resources are not returned to the system. | 📄 | `[MS-APPID]` |
| On our host, with PowerShell from its MSIX package, the app's window showed its own icon in its title bar and PowerShell's on the taskbar. With the window's AppUserModelID set, `SetValue` with `VT_EMPTY` removes it (`S_OK`); an empty string is refused (`0x8007007B`). | ✅ | `[HOST]` |
| `Win32_Processor.Architecture` is the "processor architecture used by the platform": `0` x86, `5` ARM, `6` ia64, `9` x64, `12` ARM64 (and older ones); `AddressWidth` is `32` on a 32-bit operating system, `64` on a 64-bit one. On our host: `9` and `64`. | 📄 · ✅ | `[MS-WMI]`; `[HOST]` |
| **The list of installed apps** reads `HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall`, one subkey per application (Windows Installer names it by the product code). Values: `DisplayName`, `DisplayVersion`, `Publisher`, `InstallLocation`, `URLInfoAbout`, `UninstallString` — "a command line for removing the product" —, `EstimatedSize` — "the estimated size of the application in kilobytes" —, `NoModify` — disables *Modify* (*Change*) for the product in *Add or Remove Programs* —, `NoRepair` (`ARPNOREPAIR`: no *Repair*). | 📄 | `[MS-ARP]` |
| On our host, 27 of the 59 subkeys of that key are named by their application, not by a product code (`7-Zip`, `Git_is1`, `DBeaver`…), each with `DisplayName`, `UninstallString` — the path of the application's own uninstaller, in quotes — and most with `DisplayIcon`, `NoModify` `1` and `EstimatedSize` as a DWORD. | ✅ | `[HOST]` |
| On our host, with the app's key written as the installer writes it — `UninstallString` `"C:\WINDOWS\system32\cmd.exe" /c ""C:\Program Files\fibocom-fm350-gl-windows-gui\uninstall.cmd""`, `DisplayIcon` the app's `.ico` —, Settings → Apps → Installed apps listed the app by its `DisplayName`, with its version and icon; its *Uninstall* ran `uninstall.cmd`, whose UAC prompt and question came up as from the `.cmd`, and the key was gone with the rest. | ✅ | `[HOST]` |

### 11.3 GitHub releases

| Fact | Status | Source |
|---|---|---|
| `GET https://api.github.com/repos/{owner}/{repo}/releases/latest` returns "the most recent non-prerelease, non-draft release, sorted by the `created_at` attribute": `200`, or `404` when there is none. Its fields include `tag_name`, `html_url`, `prerelease`, `draft`. No authentication is needed for a public repository's published releases. | 📄 | `[GH-API]` |
| A request without a `User-Agent` header is rejected; GitHub asks for the user name or the application's name. Unauthenticated requests are limited to **60 an hour per originating IP address**. Without `X-GitHub-Api-Version` the API answers as version `2022-11-28`, supported until 2028-03-10; `2026-03-10` is the newest. | 📄 | `[GH-API]` |
| **Over the rate limit**: "you will receive a `403` or `429` response, and the `x-ratelimit-remaining` header will be `0`"; a request should not be retried before the time in `x-ratelimit-reset`. | 📄 | `[GH-API]` |
| On our host, the latest-release endpoint answered the app's request `403` at each of three app starts within fifteen minutes — most likely because other requests to the API from the same public address had used up its unauthenticated quota that hour; later it answered `404` (no release published yet), with `x-ratelimit-remaining` at 54 of 60. The modem's adapter had metric 500 (a backup route): the requests went out through the host's other network. The `403` answers' body and headers were not recorded. | ✅ | `[HOST]` |
| **The latest release's page**: "You can share a link to the latest release for a repository by adding `releases/latest` to the end of a repository's URL" — `https://github.com/{owner}/{repo}/releases/latest`. A repository has one latest release: "Drafts and prereleases cannot be set as latest". | 📄 | `[GH-LINK]`; `[GH-API]` (*Create a release*) |
| On our host, that page asked with `HEAD`, its redirect not followed, answered `302` with `Location: https://github.com/{owner}/{repo}/releases/tag/<tag>` for a public repository with releases, and `Location: https://github.com/{owner}/{repo}/releases` for this one, with none yet; neither answer carried an `x-ratelimit-*` header. The redirect is the site's behavior, not part of the documented API. | ✅ | `[HOST]` |
| A workflow should pin a third-party action to a **full-length commit SHA**: a tag can be moved or deleted by whoever gains access to the action's repository. | 📄 | `[GH-ACTIONS]` |
