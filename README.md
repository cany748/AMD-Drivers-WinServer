# AMD-Drivers-WinServer

Install AMD Radeon drivers on **Windows Server** (2022 / 2025) **without disabling Secure Boot** and **without test signing**.

AMD's consumer Radeon driver package refuses to install on Windows Server: the INF files are decorated for Workstation SKUs only (`ProductType=1`), so Server (`ProductType=3`) falls back to the *Microsoft Basic Display Adapter*. This tool patches the INF to add Server support and re-signs the regenerated catalog — while keeping Secure Boot on.

> **No AMD files are included in this repository.** You download the driver from AMD yourself; the script only operates on your local copy.

---

## Why this is different from similar projects

Other tools that enable AMD drivers on Windows Server (and most forum guides) reach the same INF-patching step and then **turn on test signing / turn off Secure Boot** so the kernel will load the re-signed driver. On a production server — for example one running a database — that is a poor trade.

AMD-Drivers-WinServer avoids it. The method rests on one fact you can check before touching anything:

- AMD's kernel-mode driver `amdkmdag.sys` is **not** signed by Microsoft inside the file. Its Microsoft WHQL signature lives only in the package's catalog (`.cat`).
- Code Integrity verifies a kernel image by looking up its hash in the **system catalog store**, not only in the catalog referenced by the INF you install.

So AMD-Drivers-WinServer:

1. Registers the **original** AMD catalog (with its genuine Microsoft signature) into the system catalog store via `signtool catdb`.
2. Patches only the **INF text** (binaries are untouched, so their hashes are unchanged).
3. Signs the **regenerated** catalog with a local self-signed certificate — this satisfies PnP package trust only.

At install and boot, PnP accepts the package through the self-signed catalog, and Code Integrity finds each kernel binary's hash in the registered Microsoft-signed catalog. Secure Boot stays on; no test mode.

**This only works if the package's kernel binaries are genuinely WHQL-signed by Microsoft.** The script verifies this first and **refuses to continue** otherwise (including when the catalog is attestation-signed), because such a package really would need test signing — which this tool does not do.

---

## Requirements

- Windows Server 2022 or 2025 (build 20348 / 26100), x64.
- An AMD Radeon GPU currently showing as *Microsoft Basic Display Adapter*.
- Administrator PowerShell.
- Windows SDK (`signtool.exe`) and WDK (`Inf2Cat.exe`). The script can install them via `winget` if missing.
- The AMD driver, downloaded and **extracted** by you (run AMD's installer once; it extracts to `C:\AMD\...` before the OS check, or use 7-Zip).

---

## Usage

Always start with a dry run. It makes **no changes**:

```powershell
.\Install-AMDDriver.ps1 -DriverPath "C:\AMD\your-extracted-package" -Action Verify
```

Read the output. If it ends with *"Package is compatible with this method"*, proceed:

```powershell
.\Install-AMDDriver.ps1 -DriverPath "C:\AMD\your-extracted-package" -Action Install
```

Then **reboot** and check:

```powershell
Get-PnpDevice -Class Display | Select FriendlyName, Status, Problem
```

`AMD Radeon(TM) Graphics` with `Status = OK` means success.

### Rollback

```powershell
.\Install-AMDDriver.ps1 -Action Rollback
```

Then reboot.

`-Action Install` records every change it makes in `<WorkRoot>\state.json`: the published driver package (`oemNN.inf`) and the hash of its staged INF, the name and hash of the catalog registered in `CatRoot`, the thumbprint of the certificate and the stores it was added to, and the package version. Rollback undoes **only what is recorded there**:

- the driver package is removed only if `oemNN.inf` still holds the INF with the recorded hash (oem numbers are reused);
- the catalog is unregistered (`signtool catdb /r`) only if the file in `CatRoot` still has the recorded hash, and only if this tool registered it (a catalog that was already registered is left alone);
- certificates are removed by thumbprint, never by subject.

Items that could not be undone stay in `state.json`, so Rollback can be re-run. When everything is undone the file is archived as `state.rolledback_<timestamp>.json`.

Other AMD drivers (chipset, etc.) are never touched. If there is no `state.json` (for example, after an install made by a version before 0.2.0, when the tool was called SecureAMD), Rollback removes nothing. It only lists the display driver packages and the certificates with the old subject `CN=SecureAMD Local Driver Signing`, and gives the commands to remove them by hand.

### Parameters

| Parameter | Purpose |
|---|---|
| `-DriverPath` | Path to the extracted AMD package (or the display-driver folder). Required for `Verify` and `Install`. |
| `-Action` | `Verify` (default), `Install`, or `Rollback`. |
| `-HardwareId` | Force a PCI ID, e.g. `PCI\VEN_1002&DEV_13C0`; every INF line for that ID (any `SUBSYS`/`REV`) is used. If omitted, the device is auto-detected and only INF lines that match its exact hardware or compatible IDs are used. |
| `-TargetOS` | Inf2Cat `/os:` value. `Auto` (default): build 20348 → `ServerFE_X64` (Server 2022), 26100 → `Server2025_X64` (Server 2025). |
| `-WorkRoot` | Working directory. Default `C:\AMD-Drivers-WinServer`. ASCII path, no spaces. |
| `-CertName` | Subject of the self-signed cert. Default `CN=AMD-Drivers-WinServer Local Driver Signing`. A new certificate is created on every install. |
| `-KeepPrivateKey` | Keep the signing private key after install (default: removed). |
| `-SkipToolInstall` | Don't try to install SDK/WDK via winget. |

---

## Logs

Every run writes a detailed log to `<WorkRoot>\logs\AMD-Drivers-WinServer_<action>_<timestamp>.log`, including every external command, its full output and exit code. The header at the top of the log shows the GPU hardware IDs, the AMD package version (`DriverVer` from the INF), the OS build, and the Secure Boot and HVCI state. **When reporting an issue, attach this log.** It is designed to make the tool debuggable from user reports alone.

---

## Known limitations

- Each AMD driver **update** requires re-running the tool: the new package has different file hashes and a new catalog.
- Software components (OpenCL, AMD noise suppression, etc.) may not install on Server; the display driver works without them.
- `-TargetOS Auto` only knows Server 2022 (20348) and Server 2025 (26100). On other builds pass `-TargetOS` yourself.
- The INF must declare a `NTamd64.10.0.1` decoration whose build is not newer than the host build; otherwise the tool stops (it does not lower the build requirement).
- Tested primarily on Server 2025 with a Granite Ridge (RDNA2) integrated GPU on a Ryzen 9000 series CPU. Reports from other GPUs are welcome.

---

## How it works (step by step)

1. Detect the AMD display device and read its hardware and compatible IDs.
2. Find the INF in your package that lists one of those IDs in a `ProductType=1` model section.
3. Read the main catalog (the INF's `CatalogFile`) and its signer EKU. **Stop if it is attestation-signed** (`1.3.6.1.4.1.311.10.3.5.1`).
4. **Verify every `*.sys` under kernel policy (`signtool verify /kp /v /c <original .cat>`) with a chain to Microsoft.** Stop if any fails.
5. Copy the package to a pristine `orig\` and a working `gpu\`.
6. Patch the INF: add `NTamd64.10.0.3..<build>` to `[Manufacturer]` (mirroring the `NTamd64.10.0.1..<build>` decoration Windows would pick on a workstation of the same build) and a model section with only your GPU's lines. The INF is saved in its original encoding (ANSI, UTF-16LE or UTF-8 with BOM).
7. Register the original catalog in the system store (`signtool catdb /v /u`) and record its `CatRoot` name.
8. Check that every kernel binary of the main package, `amdkmdag.sys` first, now verifies through the system catalog database (`signtool verify /kp /a`). Stop if not.
9. Create a new self-signed code-signing certificate; trust it (Root + TrustedPublisher).
10. Regenerate the catalogs (`Inf2Cat /os:<TargetOS>`).
11. Restore every original catalog except the main one (Inf2Cat regenerates subcomponent catalogs such as amdxe and amdfendr).
12. Sign the main catalog with the self-signed cert (selected by thumbprint).
13. Install with `pnputil /add-driver /install`. The published `oemNN.inf` is found by comparing the hash of the INF in the driver store with the patched INF, not by reading pnputil's (localized) output.
14. Remove the signing private key (unless `-KeepPrivateKey`).

Each step that changes the system is written to `state.json` as soon as it is done, so an install that stops halfway can still be rolled back.

---

## Development

The functions that parse and patch the INF, restore catalogs and plan the rollback are pure and covered by Pester tests. The tests use **hand-written synthetic INF fixtures** in `tests/fixtures/`. No AMD files are used. Dot-sourcing the script (`. .\Install-AMDDriver.ps1`) loads the functions without running anything.

```powershell
Install-Module Pester -MinimumVersion 5.6.0 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser

Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester .\tests
```

CI (`.github/workflows/ci.yml`) runs both on Windows, with Pester under PowerShell 7 and Windows PowerShell 5.1. The script must stay ASCII-only and compatible with Windows PowerShell 5.1.

---

## Disclaimer

This tool modifies driver installation metadata for an operating-system scenario AMD does not officially support. Use at your own risk. Keep a system image or recovery path before running `-Action Install`. If the re-signed driver is rejected, the device simply falls back to the basic display adapter and the driver can be removed with `-Action Rollback`; it does not require disabling Secure Boot to recover.

AMD-Drivers-WinServer is not affiliated with or endorsed by AMD or Microsoft. AMD driver files are the property of Advanced Micro Devices, Inc. and are subject to AMD's license terms; this repository distributes none of them.

## License

MIT — see [LICENSE](LICENSE). Applies to the AMD-Drivers-WinServer scripts only.
