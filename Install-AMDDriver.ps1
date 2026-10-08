<#
.SYNOPSIS
    AMD-Drivers-WinServer - Install AMD Radeon drivers on Windows Server without disabling Secure Boot.

.DESCRIPTION
    AMD's consumer Radeon driver INF files are decorated for Workstation SKUs only
    (ProductType=1), so Windows Server (ProductType=3) falls back to the Microsoft
    Basic Display Adapter. This script patches the INF to add Server decorations and
    re-signs the regenerated catalog with a self-signed certificate.

    Unlike other approaches, it does NOT enable test signing and does NOT require
    Secure Boot to be disabled. This only works when the driver's kernel-mode
    binaries (*.sys) carry a Microsoft WHQL signature inside the ORIGINAL AMD
    catalog: the script registers that original catalog in the system catalog
    store (catdb) so Code Integrity can still find a Microsoft signature for each
    image by hash, while the self-signed catalog only satisfies PnP package trust.

    If any kernel binary is NOT covered by a WHQL signature in the original catalog,
    or the catalog is attestation-signed, the script STOPS before making changes:
    on such a package the only route is test signing with Secure Boot off, which
    this tool deliberately does not do.

    Every change made by -Action Install is recorded in <WorkRoot>\state.json.
    -Action Rollback undoes exactly what is recorded there and nothing else.

.PARAMETER DriverPath
    Path to the extracted AMD driver package, or to the specific display driver
    folder containing the main INF. The script searches recursively for the INF
    that lists your GPU. Required for Verify and Install, not used by Rollback.

.PARAMETER Action
    Verify   - analyse only, make no changes (default).
    Install  - patch, sign, register catalogs and install the driver.
    Rollback - undo the changes recorded in <WorkRoot>\state.json.

.PARAMETER HardwareId
    Optional. Force a specific PCI hardware ID (e.g. 'PCI\VEN_1002&DEV_13C0').
    INF model lines whose ID equals it or extends it ('...&REV_C1') are used.
    If omitted, the script auto-detects the AMD display device and uses its exact
    hardware and compatible IDs.

.PARAMETER TargetOS
    Inf2Cat /os: value. 'Auto' (default) maps the running build:
    20348 -> ServerFE_X64 (Server 2022), 26100 -> Server2025_X64 (Server 2025).

.PARAMETER WorkRoot
    Working directory. Default C:\AMD-Drivers-WinServer. Must be an ASCII path without spaces.

.PARAMETER CertName
    Subject for the self-signed code-signing certificate.
    Default 'CN=AMD-Drivers-WinServer Local Driver Signing'. A new certificate is
    created for every Install; only certificates recorded in state.json are ever removed.

.PARAMETER KeepPrivateKey
    Keep the certificate private key after signing. By default the private key is
    removed from LocalMachine\My once the catalog is signed, leaving only the
    public certificate in Root/TrustedPublisher.

.PARAMETER SkipToolInstall
    Do not attempt to install Windows SDK/WDK via winget. Use if you have
    signtool.exe and Inf2Cat.exe already and they are discoverable.

.EXAMPLE
    .\Install-AMDDriver.ps1 -DriverPath C:\Users\me\Downloads\amd-26.9.2 -Action Verify

.EXAMPLE
    .\Install-AMDDriver.ps1 -DriverPath C:\Users\me\Downloads\amd-26.9.2 -Action Install

.EXAMPLE
    .\Install-AMDDriver.ps1 -Action Rollback

.NOTES
    Run from an elevated PowerShell. See README for the full explanation of the
    signing model and the risks. No AMD files are distributed with this tool.
#>

[CmdletBinding()]
param(
    [string]$DriverPath,

    [ValidateSet('Verify', 'Install', 'Rollback')]
    [string]$Action = 'Verify',

    [string]$HardwareId,

    [string]$TargetOS = 'Auto',

    [string]$WorkRoot = 'C:\AMD-Drivers-WinServer',

    [string]$CertName = 'CN=AMD-Drivers-WinServer Local Driver Signing',

    [switch]$KeepPrivateKey,

    [switch]$SkipToolInstall
)

#region ---------- Infrastructure: logging, errors, environment ----------

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ToolName    = 'AMD-Drivers-WinServer'
$script:ToolVersion = '0.2.0'
$script:StartTime   = Get-Date
$script:LogFile     = $null
$script:LogBuffer   = New-Object System.Collections.Generic.List[string]
$script:LogHeaderWritten = $false
$script:StepIndex   = 0
$script:Warnings    = 0

# Values shown at the top of every log. Filled in as they become known; the
# header is written once they are (see Publish-LogHeader).
$script:LogContext = [ordered]@{
    'Hardware IDs' = '(not detected)'
    'AMD package'  = '(not read)'
    'Secure Boot'  = '(unknown)'
    'HVCI'         = '(unknown)'
    'OS build'     = '(unknown)'
}

$script:Options = [pscustomobject]@{
    DriverPath      = $DriverPath
    Action          = $Action
    HardwareId      = $HardwareId
    TargetOS        = $TargetOS
    WorkRoot        = $WorkRoot
    CertName        = $CertName
    KeepPrivateKey  = [bool]$KeepPrivateKey
    SkipToolInstall = [bool]$SkipToolInstall
}

$script:EkuAttestation   = '1.3.6.1.4.1.311.10.3.5.1'
$script:EkuWhql          = '1.3.6.1.4.1.311.10.3.5'
# Catalog database used by 'signtool catdb' by default (system component and driver database).
$script:DriverCatDbGuid  = '{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
# Certificate subjects used by earlier releases (before state.json existed).
$script:LegacyCertNames  = @('CN=SecureAMD Local Driver Signing')
$script:StateSchemaVersion = 1

function Initialize-Log {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$ActionName)
    $logDir = Join-Path $Root 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $stamp = $script:StartTime.ToString('yyyyMMdd_HHmmss')
    $script:LogFile = Join-Path $logDir ("{0}_{1}_{2}.log" -f $script:ToolName, $ActionName, $stamp)
}

function Set-LogContext {
    param([Parameter(Mandatory = $true)][string]$Key, [AllowEmptyString()][string]$Value)
    $script:LogContext[$Key] = $Value
}

# Write the header (with HWID, package version, Secure Boot and HVCI) followed by
# everything logged so far. Until this runs, log lines are buffered in memory so
# the header always stays at the top of the file.
function Publish-LogHeader {
    if ($script:LogHeaderWritten -or -not $script:LogFile) { return }
    $header = New-Object System.Collections.Generic.List[string]
    $header.Add('===================================================================')
    $header.Add(" $script:ToolName v$script:ToolVersion")
    $header.Add(" Action      : $($script:Options.Action)")
    $header.Add(" Started     : $($script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'))")
    $header.Add(" DriverPath  : $($script:Options.DriverPath)")
    $header.Add(" WorkRoot    : $($script:Options.WorkRoot)")
    $header.Add(" Host OS     : $([System.Environment]::OSVersion.VersionString)")
    $header.Add(" PowerShell  : $($PSVersionTable.PSVersion)")
    foreach ($k in $script:LogContext.Keys) {
        $header.Add((" {0,-12}: {1}" -f $k, $script:LogContext[$k]))
    }
    $header.Add('===================================================================')
    Set-Content -Path $script:LogFile -Value $header.ToArray() -Encoding UTF8
    if ($script:LogBuffer.Count -gt 0) {
        Add-Content -Path $script:LogFile -Value $script:LogBuffer.ToArray() -Encoding UTF8
    }
    $script:LogBuffer.Clear()
    $script:LogHeaderWritten = $true
}

function Write-LogLine {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP', 'DEBUG', 'DATA')]
        [string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    $line = "[{0}] [{1,-5}] {2}" -f $ts, $Level, $Message
    if ($script:LogHeaderWritten) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    } else {
        $script:LogBuffer.Add($line)
    }

    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        'STEP'  { 'Cyan' }
        'DEBUG' { 'DarkGray' }
        'DATA'  { 'Gray' }
        default { 'White' }
    }
    if ($Level -eq 'WARN')  { $script:Warnings++ }
    Write-Host $line -ForegroundColor $color
}

function Write-Step {
    param([string]$Title)
    $script:StepIndex++
    Write-LogLine -Level STEP -Message ("--- Step {0}: {1} ---" -f $script:StepIndex, $Title)
}

# Run an external exe, capturing all output into the log, and return a structured result.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$Context = ''
    )
    $argLine = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    Write-LogLine -Level DEBUG -Message ("exec: `"{0}`" {1}" -f $FilePath, $argLine)
    # Windows PowerShell 5.1 turns native stderr into a terminating error under
    # ErrorActionPreference=Stop when redirected with 2>&1; relax it locally so
    # a failing tool is reported through its exit code instead.
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $eap
    }
    foreach ($o in $out) {
        Write-LogLine -Level DATA -Message ("    | {0}" -f $o)
    }
    Write-LogLine -Level DEBUG -Message ("exit code: {0}{1}" -f $code, $(if ($Context) { " ($Context)" } else { '' }))
    [pscustomobject]@{
        ExitCode = $code
        Output   = ($out -join [Environment]::NewLine)
        Lines    = $out
        Success  = ($code -eq 0)
    }
}

# Fatal stop: log, point at the log file, exit non-zero.
function Stop-WithError {
    param([string]$Message, [string]$Hint)
    Write-LogLine -Level ERROR -Message $Message
    if ($Hint) { Write-LogLine -Level ERROR -Message ("hint: {0}" -f $Hint) }
    Write-LogLine -Level ERROR -Message ("Stopped. Full log: {0}" -f $script:LogFile)
    Publish-LogHeader
    Write-Host ''
    Write-Host "FAILED. Please attach this log file when reporting the issue:" -ForegroundColor Red
    Write-Host "  $script:LogFile" -ForegroundColor Red
    exit 1
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-WithError -Message 'This script must be run as Administrator.' `
            -Hint 'Right-click PowerShell and choose "Run as administrator", then re-run.'
    }
    Write-LogLine -Level OK -Message 'Running elevated.'
}

function Get-SecureBootState {
    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { return 'On' }
        return 'Off'
    } catch {
        return ("unknown ({0})" -f $_.Exception.Message)
    }
}

function Get-HvciState {
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $vbs = switch ([int]$dg.VirtualizationBasedSecurityStatus) {
            0 { 'off' }
            1 { 'enabled, not running' }
            2 { 'running' }
            default { 'unknown' }
        }
        # Security service 2 = Hypervisor-enforced Code Integrity.
        if (@($dg.SecurityServicesRunning) -contains 2) { return "Running (VBS $vbs)" }
        if (@($dg.SecurityServicesConfigured) -contains 2) { return "Configured, not running (VBS $vbs)" }
        return "Off (VBS $vbs)"
    } catch {
        return ("unknown ({0})" -f $_.Exception.Message)
    }
}

function Get-OSContext {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $ctx = [pscustomobject]@{
        Caption      = $os.Caption
        Version      = $os.Version
        BuildNumber  = [int]$os.BuildNumber
        ProductType  = [int]$os.ProductType   # 1=Workstation, 2=DC, 3=Server
        SecureBoot   = Get-SecureBootState
        Hvci         = Get-HvciState
        Manufacturer = $cs.Manufacturer
        Model        = $cs.Model
    }
    Set-LogContext -Key 'OS build' -Value ("{0} ({1}, ProductType={2})" -f $ctx.BuildNumber, $ctx.Caption, $ctx.ProductType)
    Set-LogContext -Key 'Secure Boot' -Value $ctx.SecureBoot
    Set-LogContext -Key 'HVCI' -Value $ctx.Hvci
    Write-LogLine -Level DATA -Message ("OS: {0} (build {1}), ProductType={2}, SecureBoot={3}, HVCI={4}" -f `
        $ctx.Caption, $ctx.BuildNumber, $ctx.ProductType, $ctx.SecureBoot, $ctx.Hvci)
    Write-LogLine -Level DATA -Message ("machine: {0} {1}" -f $ctx.Manufacturer, $ctx.Model)
    if ($ctx.ProductType -eq 1) {
        Write-LogLine -Level WARN -Message 'This is a Workstation SKU. AMD drivers install normally here; this tool is meant for Server.'
    }
    if ($ctx.SecureBoot -ne 'On') {
        Write-LogLine -Level WARN -Message 'Secure Boot is not reported as On. The method does not need it off; the result just proves less.'
    }
    return $ctx
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

#endregion

#region ---------- Pure helpers: INF text, encoding, parsing (covered by Pester) ----------

# Detect the encoding of INF bytes. Names: UTF16LE, UTF16BE, UTF8BOM (with BOM),
# UTF16LENOBOM, UTF8 (no BOM, non-ASCII content that is valid UTF-8), ANSI.
function Get-TextEncodingName {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    $n = $Bytes.Length
    if ($n -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return 'UTF8BOM' }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return 'UTF16LE' }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return 'UTF16BE' }
    if ($n -ge 4 -and ($n % 2) -eq 0) {
        # ASCII-range UTF-16LE text without a BOM has a zero in (almost) every odd byte.
        $sample = [Math]::Min($n, 1024)
        $pairs = [int]($sample / 2)
        $zeros = 0
        for ($i = 1; $i -lt $sample; $i += 2) { if ($Bytes[$i] -eq 0) { $zeros++ } }
        if ($zeros -ge [Math]::Ceiling($pairs * 0.9)) { return 'UTF16LENOBOM' }
    }
    $latin1 = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)
    if ($latin1 -notmatch '[\u0080-\u00FF]') { return 'ANSI' }
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        $null = $strict.GetString($Bytes)
        return 'UTF8'
    } catch {
        return 'ANSI'
    }
}

# .NET encoding for a name from Get-TextEncodingName. ANSI uses Latin-1 (code
# page 28591) because it maps every byte to one char and back, so an ANSI INF in
# any code page is written back byte-for-byte; only ASCII text is ever added.
function Get-TextEncoding {
    param([Parameter(Mandatory = $true)][string]$Name)
    switch ($Name) {
        'UTF8BOM'      { return (New-Object System.Text.UTF8Encoding($true)) }
        'UTF8'         { return (New-Object System.Text.UTF8Encoding($false)) }
        'UTF16LE'      { return (New-Object System.Text.UnicodeEncoding($false, $true)) }
        'UTF16LENOBOM' { return (New-Object System.Text.UnicodeEncoding($false, $false)) }
        'UTF16BE'      { return (New-Object System.Text.UnicodeEncoding($true, $true)) }
        'ANSI'         { return [System.Text.Encoding]::GetEncoding(28591) }
        default        { throw "Unknown encoding name: $Name" }
    }
}

function Read-InfFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $name  = Get-TextEncodingName -Bytes $bytes
    $enc   = Get-TextEncoding -Name $name
    $skip  = $enc.GetPreamble().Length
    $text  = $enc.GetString($bytes, $skip, $bytes.Length - $skip)
    $nl    = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    [pscustomobject]@{
        Path         = $Path
        EncodingName = $name
        NewLine      = $nl
        Lines        = [string[]]($text -split "`r?`n")
    }
}

function Write-InfFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$EncodingName,
        [Parameter(Mandatory = $true)][string]$NewLine
    )
    $enc  = Get-TextEncoding -Name $EncodingName
    $body = $enc.GetBytes(($Lines -join $NewLine))
    $pre  = $enc.GetPreamble()
    $all  = New-Object byte[] ($pre.Length + $body.Length)
    [Array]::Copy($pre, 0, $all, 0, $pre.Length)
    [Array]::Copy($body, 0, $all, $pre.Length, $body.Length)
    [System.IO.File]::WriteAllBytes($Path, $all)
}

# Strip a ';' comment that is not inside double quotes.
function Get-InfLineWithoutComment {
    param([AllowEmptyString()][string]$Line)
    $inQuote = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($c -eq [char]'"') { $inQuote = -not $inQuote }
        elseif ($c -eq [char]';' -and -not $inQuote) { return $Line.Substring(0, $i) }
    }
    return $Line
}

function Get-InfSectionName {
    param([AllowEmptyString()][string]$Line)
    if ($Line -match '^\s*\[\s*([^\]]+?)\s*\]\s*(;.*)?$') { return $Matches[1] }
    return $null
}

# Range of the first section called $Name (case-insensitive). Body is [Start, End).
function Get-InfSectionRange {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Name
    )
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $n = Get-InfSectionName -Line $Lines[$i]
        if ($n -and $n -ieq $Name) {
            $end = $Lines.Count
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if (Get-InfSectionName -Line $Lines[$j]) { $end = $j; break }
            }
            return [pscustomobject]@{ Name = $n; HeaderIndex = $i; Start = $i + 1; End = $end }
        }
    }
    return $null
}

function Get-InfValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $r = Get-InfSectionRange -Lines $Lines -Name $Section
    if (-not $r) { return $null }
    for ($i = $r.Start; $i -lt $r.End; $i++) {
        $t = Get-InfLineWithoutComment -Line $Lines[$i]
        if ($t -match '^\s*([^=]+?)\s*=\s*(.*?)\s*$' -and $Matches[1] -ieq $Key) {
            return $Matches[2].Trim('"')
        }
    }
    return $null
}

function Get-InfDriverVer {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines)
    $raw = Get-InfValue -Lines $Lines -Section 'Version' -Key 'DriverVer'
    if (-not $raw) { return $null }
    $p = $raw -split ','
    [pscustomobject]@{
        Raw     = $raw
        Date    = $p[0].Trim()
        Version = if ($p.Count -gt 1) { $p[1].Trim() } else { '' }
    }
}

# Catalog file named by the INF, most specific directive first.
function Get-InfCatalogFileName {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines)
    foreach ($k in 'CatalogFile.NTamd64', 'CatalogFile.NT', 'CatalogFile') {
        $v = Get-InfValue -Lines $Lines -Section 'Version' -Key $k
        if ($v) { return $v }
    }
    return $null
}

# Parse one [Manufacturer] line: %ATI% = ATI.Mfg, NTamd64.10.0.1..19041, ...
function ConvertFrom-InfManufacturerEntry {
    param([AllowEmptyString()][string]$Line)
    $t = (Get-InfLineWithoutComment -Line $Line).Trim()
    if (-not $t) { return $null }
    $eq = $t.IndexOf('=')
    $name = if ($eq -ge 0) { $t.Substring(0, $eq).Trim() } else { $t }
    $rhs  = if ($eq -ge 0) { $t.Substring($eq + 1) } else { $t }
    $parts = @($rhs.Split(',') | ForEach-Object { $_.Trim().Trim('"') })
    if (-not $parts[0]) { return $null }
    $decos = @()
    if ($parts.Count -gt 1) { $decos = @($parts[1..($parts.Count - 1)] | Where-Object { $_ }) }
    [pscustomobject]@{
        Name          = $name
        ModelsSection = $parts[0]
        Decorations   = $decos
    }
}

# NT<arch>[.<major>[.<minor>[.<productType>[.<suiteMask>[.<build>]]]]]
function ConvertFrom-InfDecoration {
    param([Parameter(Mandatory = $true)][string]$Decoration)
    $p = $Decoration.Split('.')
    if ($p[0] -notmatch '^NT(.*)$') { return $null }
    $arch = $Matches[1]
    $field = @('', '', '', '', '', '')
    for ($i = 1; $i -lt [Math]::Min($p.Count, 6); $i++) { $field[$i] = $p[$i] }
    $build = $null
    if ($field[5] -match '^\d+$') { $build = [int]$field[5] }
    [pscustomobject]@{
        Text        = $Decoration
        Arch        = $arch
        Major       = $field[1]
        Minor       = $field[2]
        ProductType = $field[3]
        SuiteMask   = $field[4]
        Build       = $build
    }
}

# Same decoration with ProductType=3 (Server); suite mask and build are kept.
function ConvertTo-ServerDecoration {
    param([Parameter(Mandatory = $true)][string]$Decoration)
    $p = @($Decoration.Split('.'))
    if ($p.Count -lt 4 -or $p[3] -ne '1') { throw "Not a ProductType=1 decoration: $Decoration" }
    $p[3] = '3'
    return ($p -join '.')
}

# IDs listed on a model line: <desc> = <install-section>, <hw-id>[, <compatible-id>...]
function Get-InfModelLineId {
    param([AllowEmptyString()][string]$Line)
    $t = (Get-InfLineWithoutComment -Line $Line).Trim()
    $eq = $t.IndexOf('=')
    if ($eq -lt 0) { return @() }
    $parts = @($t.Substring($eq + 1).Split(',') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
    if ($parts.Count -lt 2) { return @() }
    return @($parts[1..($parts.Count - 1)])
}

# Exact (case-insensitive) match, or with -PrefixMatch also '<target>&...'.
function Test-HardwareIdMatch {
    param(
        [AllowEmptyCollection()][string[]]$InfIds,
        [Parameter(Mandatory = $true)][string[]]$TargetIds,
        [switch]$PrefixMatch
    )
    foreach ($inf in @($InfIds)) {
        foreach ($t in $TargetIds) {
            if ($inf -ieq $t) { return $true }
            if ($PrefixMatch -and $inf.StartsWith($t + '&', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

# From a device's hardware + compatible IDs keep the ones specific to this GPU
# (VEN_1002&DEV_xxxx...), dropping class-only IDs such as PCI\VEN_1002&CC_0300.
function Get-DeviceMatchId {
    param([AllowEmptyCollection()][string[]]$HardwareIds, [AllowEmptyCollection()][string[]]$CompatibleIds)
    $all = @(@($HardwareIds) + @($CompatibleIds) | Where-Object { $_ -and $_ -match '^PCI\\VEN_1002&DEV_[0-9A-Fa-f]{4}' })
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($id in $all) {
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $out.Add($id) }
    }
    return $out.ToArray()
}

# Decide how to patch: which [Manufacturer] entry and ProductType=1 decoration to
# mirror, the server decoration to add, and the model lines to copy. Mirrors the
# decoration Windows itself would pick on a Workstation of the same build: the
# highest-build ProductType=1 amd64 decoration whose build is <= HostBuild.
function Get-ServerPatchPlan {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string[]]$TargetIds,
        [switch]$PrefixMatch,
        [Parameter(Mandatory = $true)][int]$HostBuild
    )
    $mfg = Get-InfSectionRange -Lines $Lines -Name 'Manufacturer'
    if (-not $mfg) { throw 'No [Manufacturer] section in INF.' }

    $problems = New-Object System.Collections.Generic.List[string]
    for ($i = $mfg.Start; $i -lt $mfg.End; $i++) {
        $entry = ConvertFrom-InfManufacturerEntry -Line $Lines[$i]
        if (-not $entry) { continue }
        $label = "entry '$($entry.Name)' (line $($i + 1))"
        $decos = @($entry.Decorations | ForEach-Object { ConvertFrom-InfDecoration -Decoration $_ } | Where-Object { $_ })
        $nt10  = @($decos | Where-Object { $_.Arch -ieq 'amd64' -and $_.Major -eq '10' })
        $applies = { param($d) ($null -eq $d.Build) -or ($d.Build -le $HostBuild) }

        $server = @($nt10 | Where-Object { $_.ProductType -eq '3' -and (& $applies $_) })
        if ($server.Count -gt 0) {
            $problems.Add("$label already declares a Server decoration ($($server[0].Text)); the INF is already patched or already supports Server")
            continue
        }
        $ws = @($nt10 | Where-Object { $_.ProductType -eq '1' })
        if ($ws.Count -eq 0) {
            $problems.Add("$label has no NTamd64.10.0.1 (ProductType=1) decoration to mirror")
            continue
        }
        $usable = @($ws | Where-Object { & $applies $_ } |
            Sort-Object -Property @{ Expression = { if ($null -eq $_.Build) { 0 } else { $_.Build } } } -Descending)
        if ($usable.Count -eq 0) {
            $min = ($ws | ForEach-Object { $_.Build } | Measure-Object -Minimum).Minimum
            $problems.Add("$label requires build $min or newer; this host is build $HostBuild")
            continue
        }
        $src = $usable[0]
        $srcSection = "$($entry.ModelsSection).$($src.Text)"
        $range = Get-InfSectionRange -Lines $Lines -Name $srcSection
        if (-not $range) {
            $problems.Add("$label`: model section [$srcSection] not found")
            continue
        }
        $modelLines = New-Object System.Collections.Generic.List[string]
        for ($j = $range.Start; $j -lt $range.End; $j++) {
            $ids = @(Get-InfModelLineId -Line $Lines[$j])
            if ($ids.Count -gt 0 -and (Test-HardwareIdMatch -InfIds $ids -TargetIds $TargetIds -PrefixMatch:$PrefixMatch)) {
                $modelLines.Add($Lines[$j])
            }
        }
        if ($modelLines.Count -eq 0) {
            $problems.Add("$label`: no model line in [$srcSection] matches $($TargetIds -join ' | ')")
            continue
        }
        $serverDeco = ConvertTo-ServerDecoration -Decoration $src.Text
        $serverSection = "$($entry.ModelsSection).$serverDeco"
        if (Get-InfSectionRange -Lines $Lines -Name $serverSection) {
            $problems.Add("$label`: section [$serverSection] already exists")
            continue
        }
        $warnings = New-Object System.Collections.Generic.List[string]
        $generic = @($nt10 | Where-Object { $_.ProductType -eq '' -and (& $applies $_) })
        if ($generic.Count -gt 0) {
            $warnings.Add("entry also has decoration(s) without a ProductType: $(($generic | ForEach-Object { $_.Text }) -join ', ')")
        }
        $newer = @($ws | Where-Object { -not (& $applies $_) })
        if ($newer.Count -gt 0) {
            $warnings.Add("ignored decoration(s) for newer builds: $(($newer | ForEach-Object { $_.Text }) -join ', ')")
        }
        return [pscustomobject]@{
            EntryIndex       = $i
            EntryName        = $entry.Name
            ModelsSection    = $entry.ModelsSection
            SourceDecoration = $src.Text
            SourceSection    = $srcSection
            ServerDecoration = $serverDeco
            ServerSection    = $serverSection
            ModelLines       = $modelLines.ToArray()
            Warnings         = $warnings.ToArray()
        }
    }
    if ($problems.Count -eq 0) { $problems.Add('[Manufacturer] has no entries') }
    throw ('INF cannot be patched for this device: ' + ($problems -join '; '))
}

# Apply a plan: add the server decoration to the manufacturer entry (right after
# the models-section name) and append the server model section at the end of
# [Manufacturer]. All other lines are kept byte-for-byte.
function Add-InfServerSection {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory = $true)]$Plan
    )
    $out = New-Object System.Collections.Generic.List[string]
    $out.AddRange([string[]]$Lines)

    $entryLine = $out[$Plan.EntryIndex]
    $eq = $entryLine.IndexOf('=')
    $comma = $entryLine.IndexOf(',', [Math]::Max($eq, 0))
    if ($comma -lt 0) { throw "Manufacturer entry has no decorations: $entryLine" }
    $out[$Plan.EntryIndex] = $entryLine.Substring(0, $comma) + ', ' + $Plan.ServerDecoration + $entryLine.Substring($comma)

    $mfg = Get-InfSectionRange -Lines $out.ToArray() -Name 'Manufacturer'
    $insertAt = $mfg.End
    # Keep blank lines that close [Manufacturer] after our section, not before it.
    while ($insertAt -gt $mfg.Start -and $out[$insertAt - 1].Trim() -eq '') { $insertAt-- }

    $block = New-Object System.Collections.Generic.List[string]
    $block.Add('')
    $block.Add("[$($Plan.ServerSection)]")
    $block.Add("; Added by $($script:ToolName): Server (ProductType=3) copy of [$($Plan.SourceSection)] limited to the target device.")
    $block.AddRange([string[]]$Plan.ModelLines)
    $out.InsertRange($insertAt, $block)
    return $out.ToArray()
}

# Post-edit check on the re-read file: the entry carries the server decoration
# and the server section exists with the expected number of model lines.
function Test-InfServerPatch {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory = $true)]$Plan
    )
    $entry = ConvertFrom-InfManufacturerEntry -Line $Lines[$Plan.EntryIndex]
    if (-not $entry -or @($entry.Decorations) -notcontains $Plan.ServerDecoration) { return $false }
    $r = Get-InfSectionRange -Lines $Lines -Name $Plan.ServerSection
    if (-not $r) { return $false }
    $count = 0
    for ($i = $r.Start; $i -lt $r.End; $i++) {
        if (@(Get-InfModelLineId -Line $Lines[$i]).Count -gt 0) { $count++ }
    }
    return ($count -eq @($Plan.ModelLines).Count)
}

# Inf2Cat /os: identifier for a Windows Server build.
function Get-Inf2CatTarget {
    param([Parameter(Mandatory = $true)][int]$Build)
    switch ($Build) {
        20348 { return 'ServerFE_X64' }     # Windows Server 2022
        26100 { return 'Server2025_X64' }   # Windows Server 2025
        default { return $null }
    }
}

function Get-CatalogEkuVerdict {
    param([AllowEmptyCollection()][string[]]$Oids)
    if (@($Oids) -contains $script:EkuAttestation) { return 'Attestation' }
    if (@($Oids) -contains $script:EkuWhql) { return 'Whql' }
    return 'NoWhql'
}

# signtool (not localized) prints the signing chain with /v.
function Test-MicrosoftChainText {
    param([AllowEmptyString()][string]$Text)
    return ($Text -match 'Microsoft Windows Hardware Compatibility Publisher') -or
           ($Text -match 'Microsoft Windows Third Party Component CA')
}

# Path of $FullPath relative to $Root, with '\' separators.
function Get-RelativePath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$FullPath)
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $f = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $f.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { throw "$FullPath is not under $Root" }
    return $f.Substring($r.Length).TrimStart('\', '/').Replace('/', '\')
}

# Inf2Cat regenerates every catalog in the tree, which drops the Microsoft
# signature of subcomponent catalogs (amdxe, amdfendr, ...). Put every original
# catalog back except the main one (which is re-signed with our certificate).
function Restore-SubcomponentCatalog {
    param(
        [Parameter(Mandatory = $true)][string]$OrigDir,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [Parameter(Mandatory = $true)][string]$MainCatalogRelativePath
    )
    $main = $MainCatalogRelativePath.Replace('/', '\').TrimStart('\')
    $orig = @{}
    $work = @{}
    Get-ChildItem -LiteralPath $OrigDir -Recurse -File -Filter '*.cat' | ForEach-Object {
        $orig[(Get-RelativePath -Root $OrigDir -FullPath $_.FullName)] = $_.FullName
    }
    Get-ChildItem -LiteralPath $WorkDir -Recurse -File -Filter '*.cat' | ForEach-Object {
        $work[(Get-RelativePath -Root $WorkDir -FullPath $_.FullName)] = $_.FullName
    }
    $keys = @(@($orig.Keys) + @($work.Keys) | Sort-Object -Unique)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($k in $keys) {
        if ($k -ieq $main) { continue }
        if (-not $orig.ContainsKey($k)) {
            $results.Add([pscustomobject]@{ RelativePath = $k; Action = 'NoOriginal' })
            continue
        }
        $dst = Join-Path $WorkDir ($k.Replace('\', [System.IO.Path]::DirectorySeparatorChar))
        if ($work.ContainsKey($k) -and (Get-FileSha256 -Path $work[$k]) -eq (Get-FileSha256 -Path $orig[$k])) {
            $results.Add([pscustomobject]@{ RelativePath = $k; Action = 'Unchanged' })
            continue
        }
        $dstDir = Split-Path $dst -Parent
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $orig[$k] -Destination $dst -Force
        $results.Add([pscustomobject]@{ RelativePath = $k; Action = 'Restored' })
    }
    return $results.ToArray()
}

#endregion

#region ---------- State file (what Install changed, what Rollback may undo) ----------

function New-ToolState {
    [pscustomobject]@{
        SchemaVersion = $script:StateSchemaVersion
        Tool          = $script:ToolName
        Installs      = @()
    }
}

function New-InstallRecord {
    param([string]$InfName, [string]$SourceInf, $DriverVer, [string]$MainCatalog, [string[]]$HardwareIds)
    [pscustomobject]@{
        Id            = [guid]::NewGuid().ToString()
        StartedAt     = (Get-Date).ToString('s')
        ToolVersion   = $script:ToolVersion
        Status        = 'InProgress'
        Package       = [pscustomobject]@{
            InfName     = $InfName
            SourceInf   = $SourceInf
            DriverVer   = if ($DriverVer) { $DriverVer.Raw } else { $null }
            Version     = if ($DriverVer) { $DriverVer.Version } else { $null }
            MainCatalog = $MainCatalog
        }
        HardwareIds   = @($HardwareIds)
        Catalog       = $null
        Certificate   = $null
        DriverPackage = $null
    }
}

function Read-ToolState {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $s = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($s.SchemaVersion -ne $script:StateSchemaVersion) {
        throw "Unsupported state file schema $($s.SchemaVersion) in $Path"
    }
    $s.Installs = @($s.Installs | Where-Object { $_ })
    return $s
}

function Save-ToolState {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Path)
    $json = $State | ConvertTo-Json -Depth 10
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Everything Rollback will do, newest install first: driver package, then the
# registered catalog, then the certificate in each store it was put into.
# Only items recorded in the state are ever returned.
function Get-RollbackPlan {
    param([Parameter(Mandatory = $true)]$State)
    $actions = New-Object System.Collections.Generic.List[object]
    $installs = @($State.Installs)
    for ($i = $installs.Count - 1; $i -ge 0; $i--) {
        $inst = $installs[$i]
        if ($inst.DriverPackage -and $inst.DriverPackage.PublishedName) {
            $actions.Add([pscustomobject]@{
                InstallId = $inst.Id; Kind = 'DriverPackage'
                Target = $inst.DriverPackage.PublishedName; Sha256 = $inst.DriverPackage.StagedInfSha256
                Store = $null; Subject = $null
            })
        }
        if ($inst.Catalog -and $inst.Catalog.RegisteredByTool -and $inst.Catalog.CatRootName) {
            $actions.Add([pscustomobject]@{
                InstallId = $inst.Id; Kind = 'Catalog'
                Target = $inst.Catalog.CatRootName; Sha256 = $inst.Catalog.Sha256
                Store = $null; Subject = $null
            })
        }
        if ($inst.Certificate -and $inst.Certificate.Thumbprint) {
            foreach ($store in @($inst.Certificate.Stores)) {
                $actions.Add([pscustomobject]@{
                    InstallId = $inst.Id; Kind = 'Certificate'
                    Target = $inst.Certificate.Thumbprint; Sha256 = $null
                    Store = $store; Subject = $inst.Certificate.Subject
                })
            }
        }
    }
    return $actions.ToArray()
}

# Mark one rollback action as done in the state; drop installs with nothing left.
function Complete-RollbackAction {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)]$RollbackAction)
    foreach ($inst in @($State.Installs)) {
        if ($inst.Id -ne $RollbackAction.InstallId) { continue }
        switch ($RollbackAction.Kind) {
            'DriverPackage' { $inst.DriverPackage = $null }
            'Catalog'       { $inst.Catalog.RegisteredByTool = $false }
            'Certificate'   { $inst.Certificate.Stores = @($inst.Certificate.Stores | Where-Object { $_ -ne $RollbackAction.Store }) }
        }
    }
    $State.Installs = @($State.Installs | Where-Object {
        $_.DriverPackage -or
        ($_.Catalog -and $_.Catalog.RegisteredByTool) -or
        ($_.Certificate -and @($_.Certificate.Stores).Count -gt 0)
    })
}

#endregion

#region ---------- Tool discovery (signtool, Inf2Cat) ----------

function Find-KitTool {
    param([Parameter(Mandatory = $true)][string]$ExeName, [string]$ArchPreference = 'x64')
    $roots = @(
        'C:\Program Files (x86)\Windows Kits\10\bin',
        'C:\Program Files\Windows Kits\10\bin'
    ) | Where-Object { Test-Path $_ }
    if (-not $roots) { return $null }

    $found = foreach ($r in $roots) {
        Get-ChildItem $r -Recurse -Filter $ExeName -ErrorAction SilentlyContinue
    }
    if (-not $found) { return $null }

    # Prefer the requested architecture subfolder, then the newest version.
    $archPattern = "\\$ArchPreference\\"
    $ranked = @($found | Sort-Object `
        @{ Expression = { $_.FullName -match $archPattern }; Descending = $true }, `
        @{ Expression = { $_.FullName }; Descending = $true })
    return $ranked[0].FullName
}

function Install-BuildTool {
    if ($script:Options.SkipToolInstall) {
        Write-LogLine -Level INFO -Message 'SkipToolInstall set; not installing SDK/WDK.'
        return
    }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-LogLine -Level WARN -Message 'winget not found; cannot auto-install SDK/WDK. Install them manually if tools are missing.'
        return
    }
    $build = [System.Environment]::OSVersion.Version.Build
    # Map the running build to the matching SDK/WDK package line where possible.
    $sdkId = "Microsoft.WindowsSDK.10.0.$build"
    $wdkId = "Microsoft.WindowsWDK.10.0.$build"
    Write-LogLine -Level INFO -Message ("Attempting SDK install: {0}" -f $sdkId)
    Invoke-Native -FilePath 'winget' -Arguments @('install', '--id', $sdkId, '--accept-source-agreements', '--accept-package-agreements', '--silent') -Context 'winget SDK' | Out-Null
    Write-LogLine -Level INFO -Message ("Attempting WDK install: {0}" -f $wdkId)
    Invoke-Native -FilePath 'winget' -Arguments @('install', '--id', $wdkId, '--accept-source-agreements', '--accept-package-agreements', '--silent') -Context 'winget WDK' | Out-Null
}

function Resolve-BuildTool {
    param([switch]$NeedInf2Cat)
    $signtool = Find-KitTool -ExeName 'signtool.exe' -ArchPreference 'x64'
    $inf2cat  = Find-KitTool -ExeName 'Inf2Cat.exe'  -ArchPreference 'x86'

    if (-not $signtool -or ($NeedInf2Cat -and -not $inf2cat)) {
        Write-LogLine -Level WARN -Message 'signtool or Inf2Cat not found; trying to install build tools.'
        Install-BuildTool
        $signtool = Find-KitTool -ExeName 'signtool.exe' -ArchPreference 'x64'
        $inf2cat  = Find-KitTool -ExeName 'Inf2Cat.exe'  -ArchPreference 'x86'
    }

    if (-not $signtool) {
        Stop-WithError -Message 'signtool.exe not found and could not be installed.' `
            -Hint 'Install the Windows SDK (Signing Tools feature) from the Microsoft site, then re-run.'
    }
    if ($NeedInf2Cat -and -not $inf2cat) {
        Stop-WithError -Message 'Inf2Cat.exe not found and could not be installed.' `
            -Hint 'Install the Windows Driver Kit (WDK) matching your OS build, then re-run.'
    }
    Write-LogLine -Level OK -Message ("signtool: {0}" -f $signtool)
    if ($inf2cat) { Write-LogLine -Level OK -Message ("Inf2Cat : {0}" -f $inf2cat) }
    [pscustomobject]@{ SignTool = $signtool; Inf2Cat = $inf2cat }
}

#endregion

#region ---------- Device + INF discovery ----------

function Get-DeviceIdProperty {
    param([string]$InstanceId, [string]$KeyName)
    try {
        return @((Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop).Data | Where-Object { $_ })
    } catch {
        return @()
    }
}

# Returns the target device (may be $null when -HardwareId names a device that is
# not present) plus the IDs used to select INF model lines.
function Get-TargetDevice {
    $all = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VEN_1002' })
    $devices = foreach ($d in $all) {
        $service = $null
        if ($d.PSObject.Properties['Service']) { $service = $d.Service }
        [pscustomobject]@{
            FriendlyName  = $d.FriendlyName
            InstanceId    = $d.InstanceId
            Status        = $d.Status
            Service       = $service
            HardwareIds   = Get-DeviceIdProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds'
            CompatibleIds = Get-DeviceIdProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_CompatibleIds'
        }
    }
    $devices = @($devices)
    foreach ($d in $devices) {
        Write-LogLine -Level DATA -Message ("AMD display device: {0} [{1}] status={2} service={3}" -f $d.FriendlyName, $d.InstanceId, $d.Status, $d.Service)
        foreach ($id in @($d.HardwareIds)) { Write-LogLine -Level DATA -Message ("    hardware id  : {0}" -f $id) }
        foreach ($id in @($d.CompatibleIds)) { Write-LogLine -Level DATA -Message ("    compatible id: {0}" -f $id) }
    }

    $forced = $script:Options.HardwareId
    if ($forced) {
        Write-LogLine -Level INFO -Message ("Using hardware ID from parameter: {0}" -f $forced)
        $hit = @($devices | Where-Object {
            Test-HardwareIdMatch -InfIds (@($_.HardwareIds) + @($_.CompatibleIds)) -TargetIds @($forced) -PrefixMatch
        })
        $dev = $null
        if ($hit.Count -ge 1) { $dev = $hit[0] }
        if ($hit.Count -gt 1) { Write-LogLine -Level WARN -Message 'More than one present device matches -HardwareId; logging the first.' }
        $ids = if ($dev) { @($dev.HardwareIds) } else { @($forced) }
        Set-LogContext -Key 'Hardware IDs' -Value (($ids -join ', ') + ' (forced: ' + $forced + ')')
        return [pscustomobject]@{ Device = $dev; TargetIds = @($forced); PrefixMatch = $true }
    }

    if ($devices.Count -eq 0) {
        Stop-WithError -Message 'No AMD (VEN_1002) display device found.' `
            -Hint 'Pass -HardwareId "PCI\VEN_1002&DEV_XXXX" explicitly, or check the GPU is present.'
    }
    $pick = $devices
    if ($devices.Count -gt 1) {
        $pick = @($devices | Where-Object { $_.Service -eq 'BasicDisplay' -or $_.Status -ne 'OK' })
        if ($pick.Count -ne 1) {
            Stop-WithError -Message 'Several AMD display devices found; cannot tell which one to patch for.' `
                -Hint 'Pass -HardwareId with the ID of the device that shows as Microsoft Basic Display Adapter (see the device list above).'
        }
    }
    $dev = $pick[0]
    $ids = @(Get-DeviceMatchId -HardwareIds $dev.HardwareIds -CompatibleIds $dev.CompatibleIds)
    if ($ids.Count -eq 0) {
        Stop-WithError -Message ("Could not read hardware IDs of {0}." -f $dev.InstanceId) `
            -Hint 'Pass -HardwareId "PCI\VEN_1002&DEV_XXXX" explicitly.'
    }
    Set-LogContext -Key 'Hardware IDs' -Value (@($dev.HardwareIds) -join ', ')
    Write-LogLine -Level OK -Message ("target device: {0}" -f $dev.InstanceId)
    foreach ($id in $ids) { Write-LogLine -Level DATA -Message ("    match id: {0}" -f $id) }
    return [pscustomobject]@{ Device = $dev; TargetIds = $ids; PrefixMatch = $false }
}

function Find-DisplayInf {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][int]$HostBuild
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        Stop-WithError -Message ("DriverPath does not exist: {0}" -f $Root)
    }
    $first = @($Target.TargetIds)[0]
    if ($first -notmatch '(VEN_1002&DEV_[0-9A-Fa-f]{4})') {
        Stop-WithError -Message ("Hardware ID is not an AMD PCI device ID: {0}" -f $first)
    }
    $devToken = $Matches[1]
    Write-LogLine -Level INFO -Message ("Searching INFs under {0} for {1}" -f $Root, $devToken)

    $infs = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue)
    Write-LogLine -Level DATA -Message ("found {0} INF files total" -f $infs.Count)

    $infCandidates = @(foreach ($inf in $infs) {
        $hit = Select-String -LiteralPath $inf.FullName -Pattern $devToken -SimpleMatch -List -ErrorAction SilentlyContinue
        if ($hit) { $inf }
    })
    if ($infCandidates.Count -eq 0) {
        Stop-WithError -Message ("No INF references {0}." -f $devToken) `
            -Hint 'Check that the package matches this GPU, or pass the display-driver folder directly as -DriverPath.'
    }

    $usable = New-Object System.Collections.Generic.List[object]
    foreach ($c in $infCandidates) {
        $file = Read-InfFile -Path $c.FullName
        try {
            $plan = Get-ServerPatchPlan -Lines $file.Lines -TargetIds $Target.TargetIds -PrefixMatch:$Target.PrefixMatch -HostBuild $HostBuild
            Write-LogLine -Level DATA -Message ("    candidate: {0} (encoding {1}) -> usable" -f $c.FullName, $file.EncodingName)
            $usable.Add([pscustomobject]@{ File = $c; Inf = $file; Plan = $plan })
        } catch {
            Write-LogLine -Level DATA -Message ("    candidate: {0} -> {1}" -f $c.FullName, $_.Exception.Message)
        }
    }
    if ($usable.Count -eq 0) {
        Stop-WithError -Message ("None of the INFs that mention {0} can be patched for this device (see candidates above)." -f $devToken)
    }
    if ($usable.Count -gt 1) {
        Write-LogLine -Level WARN -Message ("Multiple INFs list this device; choosing the largest (most complete).")
    }
    $chosen = $usable | Sort-Object -Property @{ Expression = { $_.File.Length } } -Descending | Select-Object -First 1
    Write-LogLine -Level OK -Message ("selected INF: {0}" -f $chosen.File.FullName)
    return $chosen
}

#endregion

#region ---------- WHQL precondition check (the core safety gate) ----------

# Catalogs to try for a .sys: its own folder first, then each parent up to the
# package root (some .sys live in a subfolder such as B0xxxxx). Within a folder
# the package's main catalog is tried first.
function Get-CatalogCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$SysPath,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$MainCatalogPath
    )
    $root = [System.IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')
    $dir  = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($SysPath))
    $out  = New-Object System.Collections.Generic.List[string]
    while ($dir -and $dir.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $cats = @(Get-ChildItem -LiteralPath $dir -Filter *.cat -File -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($c in $cats) { if ($c.FullName -eq $MainCatalogPath) { $out.Add($c.FullName) } }
        foreach ($c in $cats) { if ($c.FullName -ne $MainCatalogPath) { $out.Add($c.FullName) } }
        if ($dir.Length -le $root.Length) { break }
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
    return $out.ToArray()
}

# The decisive check: every kernel driver (*.sys) in the package must verify under
# kernel policy (/kp) against an ORIGINAL package catalog that chains to Microsoft.
# Files that fail here would be rejected by Code Integrity with Secure Boot on,
# so Install refuses to continue.
function Test-KernelSignature {
    param(
        [Parameter(Mandatory = $true)][string]$SignTool,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$MainCatalogPath
    )
    Write-Step 'Verifying kernel-mode driver signatures (WHQL precondition)'

    $sysFiles = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Filter *.sys -File -ErrorAction SilentlyContinue)
    if ($sysFiles.Count -eq 0) {
        Write-LogLine -Level ERROR -Message 'No .sys files found under the package folder.'
        return [pscustomobject]@{ AllSigned = $false; Results = @() }
    }
    Write-LogLine -Level DATA -Message ("found {0} kernel binaries" -f $sysFiles.Count)

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($sys in $sysFiles) {
        $r = [pscustomobject]@{
            Name     = $sys.Name
            Path     = $sys.FullName
            Catalog  = $null
            InMain   = $false
            Verified = $false
            MsChain  = $false
            Detail   = 'no catalog found in folder or parents'
        }
        foreach ($cat in @(Get-CatalogCandidate -SysPath $sys.FullName -PackageRoot $PackageRoot -MainCatalogPath $MainCatalogPath)) {
            $v = Invoke-Native -FilePath $SignTool -Arguments @('verify', '/kp', '/v', '/c', $cat, $sys.FullName) -Context "verify $($sys.Name)"
            $r.Catalog  = $cat
            $r.Verified = $v.Success
            $r.MsChain  = $v.Success -and (Test-MicrosoftChainText -Text $v.Output)
            if ($r.MsChain) { break }
        }
        $catName = if ($r.Catalog) { Split-Path $r.Catalog -Leaf } else { '-' }
        if ($r.Verified -and $r.MsChain) {
            $r.InMain = ($r.Catalog -eq $MainCatalogPath)
            $r.Detail = 'verified, Microsoft chain'
            Write-LogLine -Level OK -Message ("{0,-24} OK    (MS chain via {1})" -f $sys.Name, $catName)
        } elseif ($r.Verified) {
            $r.Detail = 'verified but no Microsoft chain in signtool output'
            Write-LogLine -Level WARN -Message ("{0,-24} FAIL  ({1}, {2})" -f $sys.Name, $r.Detail, $catName)
        } elseif ($r.Catalog) {
            $r.Detail = 'kernel-policy verification failed against every candidate catalog'
            Write-LogLine -Level WARN -Message ("{0,-24} FAIL  ({1})" -f $sys.Name, $r.Detail)
        } else {
            Write-LogLine -Level WARN -Message ("{0,-24} FAIL  ({1})" -f $sys.Name, $r.Detail)
        }
        $results.Add($r)
    }

    $allOk = @($results | Where-Object { -not ($_.Verified -and $_.MsChain) }).Count -eq 0
    return [pscustomobject]@{ AllSigned = $allOk; Results = $results.ToArray() }
}

# The main catalog must be WHQL-signed, not attestation-signed.
function Test-CatalogEku {
    param([Parameter(Mandatory = $true)][string]$CatalogPath)
    Write-Step 'Checking main catalog signer EKU'
    $sig = Get-AuthenticodeSignature -LiteralPath $CatalogPath
    if (-not $sig.SignerCertificate) {
        Write-LogLine -Level ERROR -Message ("catalog has no signer certificate: {0}" -f $CatalogPath)
        return 'NoSigner'
    }
    Write-LogLine -Level DATA -Message ("catalog signer: {0}" -f $sig.SignerCertificate.Subject)
    $ekus = @($sig.SignerCertificate.EnhancedKeyUsageList)
    foreach ($e in $ekus) {
        Write-LogLine -Level DATA -Message ("catalog EKU: {0} ({1})" -f $e.FriendlyName, $e.ObjectId)
    }
    $verdict = Get-CatalogEkuVerdict -Oids @($ekus | ForEach-Object { "$($_.ObjectId)" })
    switch ($verdict) {
        'Attestation' { Write-LogLine -Level ERROR -Message 'Catalog is ATTESTATION-signed (1.3.6.1.4.1.311.10.3.5.1). Not usable on Server with this method.' }
        'Whql'        { Write-LogLine -Level OK -Message 'Catalog carries the WHQL EKU (Windows Hardware Driver Verification).' }
        default       { Write-LogLine -Level WARN -Message 'Catalog signer has no WHQL EKU; relying on the per-file Microsoft chain check.' }
    }
    return $verdict
}

#endregion

#region ---------- Catalog registration, certificate, signing, install ----------

function Backup-Package {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Root)
    $orig = Join-Path $Root 'orig'
    $work = Join-Path $Root 'gpu'
    foreach ($d in @($orig, $work)) {
        if (Test-Path -LiteralPath $d) {
            Write-LogLine -Level DEBUG -Message ("removing stale {0}" -f $d)
            Remove-Item -LiteralPath $d -Recurse -Force
        }
    }
    Write-LogLine -Level INFO -Message ("copying package to {0} and {1}" -f $orig, $work)
    Copy-Item -LiteralPath $Source -Destination $orig -Recurse -Force
    Copy-Item -LiteralPath $Source -Destination $work -Recurse -Force
    Write-LogLine -Level OK -Message 'package copied (orig = pristine, gpu = working).'
    [pscustomobject]@{ Orig = $orig; Work = $work }
}

function Edit-Inf {
    param([Parameter(Mandatory = $true)][string]$InfPath, [Parameter(Mandatory = $true)]$Target, [Parameter(Mandatory = $true)][int]$HostBuild)
    Write-Step 'Patching INF for Server (ProductType=3)'
    $inf  = Read-InfFile -Path $InfPath
    Write-LogLine -Level DATA -Message ("INF encoding: {0}, line ending: {1}" -f $inf.EncodingName, $(if ($inf.NewLine -eq "`r`n") { 'CRLF' } else { 'LF' }))
    $plan = Get-ServerPatchPlan -Lines $inf.Lines -TargetIds $Target.TargetIds -PrefixMatch:$Target.PrefixMatch -HostBuild $HostBuild
    Write-LogLine -Level DATA -Message ("manufacturer entry: {0}" -f $inf.Lines[$plan.EntryIndex].Trim())
    Write-LogLine -Level DATA -Message ("source deco: {0}  ->  server deco: {1}" -f $plan.SourceDecoration, $plan.ServerDecoration)
    foreach ($w in @($plan.Warnings)) { Write-LogLine -Level WARN -Message $w }
    Write-LogLine -Level OK -Message ("copying {0} model line(s) from [{1}] into [{2}]" -f @($plan.ModelLines).Count, $plan.SourceSection, $plan.ServerSection)
    foreach ($ml in $plan.ModelLines) { Write-LogLine -Level DATA -Message ("    {0}" -f $ml.Trim()) }

    $patched = Add-InfServerSection -Lines $inf.Lines -Plan $plan
    Write-LogLine -Level DATA -Message ("new manufacturer entry: {0}" -f $patched[$plan.EntryIndex].Trim())
    Write-InfFile -Path $InfPath -Lines $patched -EncodingName $inf.EncodingName -NewLine $inf.NewLine
    Write-LogLine -Level OK -Message ("INF patched and saved ({0})." -f $inf.EncodingName)

    $check = Read-InfFile -Path $InfPath
    if ($check.EncodingName -ne $inf.EncodingName -or -not (Test-InfServerPatch -Lines $check.Lines -Plan $plan)) {
        Stop-WithError -Message 'Post-edit check failed: re-read INF does not contain the server decoration and section as written.'
    }
    Write-LogLine -Level OK -Message 'post-edit check passed.'
    return $plan
}

function Get-CatRootDirectory {
    return (Join-Path $env:windir ("System32\CatRoot\{0}" -f $script:DriverCatDbGuid))
}

function Register-OriginalCatalog {
    param([string]$SignTool, [string]$OrigMainCatalog)
    Write-Step 'Registering original AMD catalog (Microsoft signature) in system store'
    if (-not (Test-Path -LiteralPath $OrigMainCatalog)) {
        Stop-WithError -Message ("original main catalog not found: {0}" -f $OrigMainCatalog)
    }
    $catRoot = Get-CatRootDirectory
    $hash    = Get-FileSha256 -Path $OrigMainCatalog
    $size    = (Get-Item -LiteralPath $OrigMainCatalog).Length
    $sameHash = {
        @(Get-ChildItem -LiteralPath $catRoot -Filter *.cat -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -eq $size -and (Get-FileSha256 -Path $_.FullName) -eq $hash } |
            ForEach-Object { $_.Name })
    }
    $beforeNames = @(Get-ChildItem -LiteralPath $catRoot -Filter *.cat -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $beforeSame  = @(& $sameHash)
    Write-LogLine -Level DATA -Message ("catalog sha256 {0}; already registered copies: {1}" -f $hash, $beforeSame.Count)

    $r = Invoke-Native -FilePath $SignTool -Arguments @('catdb', '/v', '/u', $OrigMainCatalog) -Context 'catdb add'
    if (-not $r.Success) {
        Stop-WithError -Message 'Failed to register original catalog via signtool catdb.' `
            -Hint 'See the exec output above in the log; the main catalog may be missing or corrupt.'
    }

    $afterSame = @(& $sameHash)
    $newSame   = @($afterSame | Where-Object { $beforeSame -notcontains $_ })
    $record = [pscustomobject]@{
        SourcePath       = $OrigMainCatalog
        Sha256           = $hash
        CatRootName      = $null
        CatRootDirectory = $catRoot
        RegisteredByTool = $false
    }
    if ($newSame.Count -ge 1) {
        $record.CatRootName = $newSame[0]
        $record.RegisteredByTool = $true
    } elseif ($beforeSame.Count -ge 1) {
        $record.CatRootName = $beforeSame[0]
        Write-LogLine -Level INFO -Message 'Catalog was already registered before this run; Rollback will leave it in place.'
    } else {
        # Not byte-identical in CatRoot: fall back to the one new catalog file, if exactly one appeared.
        $newNames = @(Get-ChildItem -LiteralPath $catRoot -Filter *.cat -File -ErrorAction SilentlyContinue |
            Where-Object { $beforeNames -notcontains $_.Name })
        if ($newNames.Count -ne 1) {
            Stop-WithError -Message ("catdb reported success but the catalog could not be identified in {0} ({1} new files)." -f $catRoot, $newNames.Count)
        }
        $record.CatRootName = $newNames[0].Name
        $record.Sha256 = Get-FileSha256 -Path $newNames[0].FullName
        $record.RegisteredByTool = $true
        Write-LogLine -Level WARN -Message 'Registered catalog differs from the source bytes; identified it as the only new file in CatRoot.'
    }
    Write-LogLine -Level OK -Message ("Original catalog registered as {0}\{1}" -f $catRoot, $record.CatRootName)
    return $record
}

# After catdb: every kernel binary covered by the main catalog must now verify
# through the system catalog database (/a). amdkmdag.sys first.
function Test-KernelSignatureViaStore {
    param([string]$SignTool, [object[]]$MainSysResults)
    Write-Step 'Verifying kernel binaries resolve via the system catalog database'
    $ordered = @($MainSysResults | Sort-Object -Property @{ Expression = { $_.Name -ne 'amdkmdag.sys' } }, Name)
    if ($ordered.Count -eq 0) {
        Stop-WithError -Message 'No kernel binary of the main package was verified against the main catalog; nothing ties the package to the registered catalog.'
    }
    if (@($ordered | Where-Object { $_.Name -eq 'amdkmdag.sys' }).Count -eq 0) {
        Write-LogLine -Level WARN -Message 'amdkmdag.sys is not among the main-catalog binaries of this package.'
    }
    $failed = 0
    foreach ($s in $ordered) {
        $chk = Invoke-Native -FilePath $SignTool -Arguments @('verify', '/kp', '/a', '/v', $s.Path) -Context "verify via store $($s.Name)"
        $inCat = @($chk.Lines | Where-Object { $_ -match 'signed in catalog' }) | Select-Object -First 1
        if ($chk.Success -and $inCat -and (Test-MicrosoftChainText -Text $chk.Output)) {
            Write-LogLine -Level OK -Message ("{0,-24} OK    ({1})" -f $s.Name, $inCat.Trim())
        } else {
            Write-LogLine -Level ERROR -Message ("{0,-24} FAIL  (does not resolve to a Microsoft-signed catalog in the system database)" -f $s.Name)
            $failed++
        }
    }
    if ($failed -gt 0) {
        Stop-WithError -Message ("{0} kernel binary/binaries do not resolve via the registered catalog; the driver would fail with Code 52." -f $failed) `
            -Hint 'Nothing was installed yet. Run -Action Rollback to unregister the catalog.'
    }
}

function New-SigningCert {
    param([Parameter(Mandatory = $true)][string]$Subject, [Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$Install, [scriptblock]$OnChange)
    Write-Step 'Creating self-signed code-signing certificate'
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject `
        -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(10)
    $Install.Certificate = [pscustomobject]@{ Thumbprint = $cert.Thumbprint; Subject = $cert.Subject; Stores = @('My') }
    & $OnChange
    Write-LogLine -Level OK -Message ("certificate created: {0} (thumbprint {1})" -f $Subject, $cert.Thumbprint)

    $certDir = Join-Path $Root 'certs'
    New-Item -ItemType Directory -Path $certDir -Force | Out-Null
    $cerPath = Join-Path $certDir ("{0}.cer" -f $cert.Thumbprint)
    Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null
    foreach ($store in 'Root', 'TrustedPublisher') {
        Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
        $Install.Certificate.Stores = @($Install.Certificate.Stores) + $store
        & $OnChange
    }
    Write-LogLine -Level OK -Message 'certificate trusted (Root + TrustedPublisher).'
    return $cert
}

function New-Catalog {
    param([string]$Inf2Cat, [string]$WorkDir, [string]$OsList)
    Write-Step ("Generating catalog with Inf2Cat (/os:{0})" -f $OsList)
    $r = Invoke-Native -FilePath $Inf2Cat -Arguments @("/driver:$WorkDir", "/os:$OsList", '/verbose') -Context 'inf2cat'
    if (-not $r.Success) {
        Stop-WithError -Message 'Inf2Cat failed to generate the catalog.' `
            -Hint 'Check the "Errors:" block in the log. A missing referenced file, an INF syntax error or a wrong -TargetOS is the usual cause.'
    }
    Write-LogLine -Level OK -Message 'Catalog generated.'
}

function Invoke-SignCatalog {
    param([string]$SignTool, [string]$CatalogPath, [string]$Thumbprint)
    Write-Step 'Signing main catalog with self-signed certificate'
    $r = Invoke-Native -FilePath $SignTool -Arguments @('sign', '/fd', 'sha256', '/sm', '/s', 'My', '/sha1', $Thumbprint, $CatalogPath) -Context 'sign cat'
    if (-not $r.Success) {
        Stop-WithError -Message 'signtool failed to sign the catalog.'
    }
    $v = Invoke-Native -FilePath $SignTool -Arguments @('verify', '/pa', '/v', $CatalogPath) -Context 'verify signed cat'
    if (-not $v.Success) {
        Stop-WithError -Message 'Signed catalog failed verification (/pa).'
    }
    Write-LogLine -Level OK -Message 'Catalog signed and verified.'
}

function Get-ThirdPartyDriver {
    return @(Get-WindowsDriver -Online -ErrorAction Stop)
}

# Identify the published oemNN.inf of our package without parsing localized
# pnputil text: the staged INF in the driver store is compared by hash with the
# INF we installed; if that fails, the single new entry with the same INF name.
function Find-StagedDriverPackage {
    param([string]$InfPath, [string[]]$Before)
    $leaf = Split-Path $InfPath -Leaf
    $hash = Get-FileSha256 -Path $InfPath
    $cands = @(Get-ThirdPartyDriver | Where-Object { $_.OriginalFileName -and (Split-Path $_.OriginalFileName -Leaf) -ieq $leaf })
    foreach ($c in $cands) {
        if ((Test-Path -LiteralPath $c.OriginalFileName) -and (Get-FileSha256 -Path $c.OriginalFileName) -eq $hash) {
            return [pscustomobject]@{ PublishedName = $c.Driver; StagedInf = $c.OriginalFileName; StagedInfSha256 = $hash; MatchedBy = 'hash' }
        }
    }
    $new = @($cands | Where-Object { $Before -notcontains $_.Driver })
    if ($new.Count -eq 1 -and (Test-Path -LiteralPath $new[0].OriginalFileName)) {
        return [pscustomobject]@{
            PublishedName = $new[0].Driver; StagedInf = $new[0].OriginalFileName
            StagedInfSha256 = (Get-FileSha256 -Path $new[0].OriginalFileName); MatchedBy = 'new entry'
        }
    }
    return $null
}

function Install-Driver {
    param([string]$InfPath)
    Write-Step 'Installing driver with pnputil'
    $before = @(Get-ThirdPartyDriver | ForEach-Object { $_.Driver })
    $r = Invoke-Native -FilePath 'pnputil' -Arguments @('/add-driver', $InfPath, '/install') -Context 'pnputil add'
    $pkg = Find-StagedDriverPackage -InfPath $InfPath -Before $before
    if (-not $pkg) {
        Stop-WithError -Message ("pnputil exit code {0}; the patched package is not in the driver store." -f $r.ExitCode) `
            -Hint 'See the pnputil output above. Run -Action Rollback to undo the catalog and certificate changes.'
    }
    Write-LogLine -Level OK -Message ("Driver package staged as {0} (identified by {1})." -f $pkg.PublishedName, $pkg.MatchedBy)
    switch ($r.ExitCode) {
        0       { Write-LogLine -Level OK -Message 'pnputil reported success.' }
        3010    { Write-LogLine -Level OK -Message 'pnputil reported success; a reboot is required.' }
        default { Write-LogLine -Level WARN -Message ("pnputil exit code {0}: package is staged but may not have been installed on the device; check status after reboot." -f $r.ExitCode) }
    }
    return $pkg
}

function Remove-PrivateKey {
    param([Parameter(Mandatory = $true)]$Install, [scriptblock]$OnChange)
    if ($script:Options.KeepPrivateKey) {
        Write-LogLine -Level INFO -Message 'KeepPrivateKey set; leaving private key in LocalMachine\My.'
        return
    }
    Write-Step 'Removing certificate private key'
    $thumb = $Install.Certificate.Thumbprint
    $item = "Cert:\LocalMachine\My\$thumb"
    if (Test-Path -LiteralPath $item) {
        Remove-Item -LiteralPath $item -DeleteKey -Force
        Write-LogLine -Level OK -Message ("removed certificate and private key from My: {0}" -f $thumb)
    }
    $Install.Certificate.Stores = @($Install.Certificate.Stores | Where-Object { $_ -ne 'My' })
    & $OnChange
    Write-LogLine -Level INFO -Message 'Public cert remains in Root and TrustedPublisher for the installed package.'
}

function Write-DeviceStatus {
    param($Device)
    if (-not $Device) { return }
    $d = Get-PnpDevice -InstanceId $Device.InstanceId -ErrorAction SilentlyContinue
    if (-not $d) { return }
    $inf = Get-DeviceIdProperty -InstanceId $Device.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath'
    Write-LogLine -Level DATA -Message ("device now: {0} status={1} driver inf={2}" -f $d.FriendlyName, $d.Status, ($inf -join ','))
}

#endregion

#region ---------- Rollback ----------

function Remove-RecordedDriverPackage {
    param($Item)
    $pkg = @(Get-ThirdPartyDriver | Where-Object { $_.Driver -ieq $Item.Target }) | Select-Object -First 1
    if (-not $pkg) {
        Write-LogLine -Level INFO -Message ("{0} is no longer in the driver store." -f $Item.Target)
        return $true
    }
    $staged = $pkg.OriginalFileName
    if (-not (Test-Path -LiteralPath $staged) -or (Get-FileSha256 -Path $staged) -ne $Item.Sha256) {
        Write-LogLine -Level ERROR -Message ("{0} now belongs to a different package ({1}); not removing it." -f $Item.Target, $staged)
        return $false
    }
    $r = Invoke-Native -FilePath 'pnputil' -Arguments @('/delete-driver', $Item.Target, '/uninstall', '/force') -Context "delete $($Item.Target)"
    $still = @(Get-ThirdPartyDriver | Where-Object { $_.Driver -ieq $Item.Target })
    if ($still.Count -eq 0) {
        Write-LogLine -Level OK -Message ("removed driver package {0} (pnputil exit code {1})" -f $Item.Target, $r.ExitCode)
        return $true
    }
    Write-LogLine -Level ERROR -Message ("failed to remove {0} (pnputil exit code {1}); see log" -f $Item.Target, $r.ExitCode)
    return $false
}

function Remove-RecordedCatalog {
    param($Item, [string]$SignTool)
    $path = Join-Path (Get-CatRootDirectory) $Item.Target
    if (-not (Test-Path -LiteralPath $path)) {
        Write-LogLine -Level INFO -Message ("catalog {0} is no longer registered." -f $Item.Target)
        return $true
    }
    if ((Get-FileSha256 -Path $path) -ne $Item.Sha256) {
        Write-LogLine -Level ERROR -Message ("{0} in CatRoot does not match the recorded hash; not removing it." -f $Item.Target)
        return $false
    }
    if (-not $SignTool) {
        Write-LogLine -Level ERROR -Message ("signtool not available; remove manually: signtool catdb /v /r {0}" -f $Item.Target)
        return $false
    }
    $r = Invoke-Native -FilePath $SignTool -Arguments @('catdb', '/v', '/r', $Item.Target) -Context 'catdb remove'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-LogLine -Level OK -Message ("unregistered catalog {0}" -f $Item.Target)
        return $true
    }
    Write-LogLine -Level ERROR -Message ("catalog {0} is still present (signtool exit code {1})" -f $Item.Target, $r.ExitCode)
    return $false
}

function Remove-RecordedCertificate {
    param($Item)
    $path = "Cert:\LocalMachine\$($Item.Store)\$($Item.Target)"
    $c = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $c) {
        Write-LogLine -Level INFO -Message ("certificate {0} is not in {1}." -f $Item.Target, $Item.Store)
        return $true
    }
    if ($c.Subject -ne $Item.Subject) {
        Write-LogLine -Level ERROR -Message ("certificate {0} in {1} has subject '{2}', expected '{3}'; not removing." -f $Item.Target, $Item.Store, $c.Subject, $Item.Subject)
        return $false
    }
    if ($Item.Store -eq 'My') { Remove-Item -LiteralPath $path -DeleteKey -Force } else { Remove-Item -LiteralPath $path -Force }
    Write-LogLine -Level OK -Message ("removed certificate from {0}: {1}" -f $Item.Store, $Item.Target)
    return $true
}

# No state file: earlier versions did not record anything. Report, never delete.
function Write-LegacyRollbackHint {
    Write-LogLine -Level WARN -Message 'No state file found, so nothing is removed automatically.'
    foreach ($store in 'My', 'Root', 'TrustedPublisher') {
        Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction SilentlyContinue |
            Where-Object { $script:LegacyCertNames -contains $_.Subject -or $_.Subject -eq $script:Options.CertName } |
            ForEach-Object {
                Write-LogLine -Level DATA -Message ("certificate in {0}: {1} {2}" -f $store, $_.Thumbprint, $_.Subject)
                Write-LogLine -Level DATA -Message ("    to remove: Remove-Item Cert:\LocalMachine\{0}\{1}" -f $store, $_.Thumbprint)
            }
    }
    foreach ($d in @(Get-ThirdPartyDriver | Where-Object { $_.ClassName -eq 'Display' })) {
        Write-LogLine -Level DATA -Message ("display driver package: {0} ({1}, {2}, {3})" -f $d.Driver, (Split-Path $d.OriginalFileName -Leaf), $d.ProviderName, $d.Version)
        Write-LogLine -Level DATA -Message ("    to remove: pnputil /delete-driver {0} /uninstall" -f $d.Driver)
    }
    Write-LogLine -Level INFO -Message 'Review the list above and remove only what an earlier run of this tool installed.'
}

function Invoke-Rollback {
    param([Parameter(Mandatory = $true)][string]$StatePath)
    Write-Step 'Rollback: reading state file'
    $state = Read-ToolState -Path $StatePath
    if (-not $state) {
        Write-LegacyRollbackHint
        return
    }
    $plan = @(Get-RollbackPlan -State $state)
    if ($plan.Count -eq 0) {
        Write-LogLine -Level INFO -Message 'State file records nothing left to undo.'
        return
    }
    foreach ($a in $plan) {
        Write-LogLine -Level DATA -Message ("planned: {0,-13} {1} {2}" -f $a.Kind, $a.Target, $(if ($a.Store) { "($($a.Store))" } else { '' }))
    }
    $signtool = $null
    if (@($plan | Where-Object { $_.Kind -eq 'Catalog' }).Count -gt 0) {
        $signtool = Find-KitTool -ExeName 'signtool.exe' -ArchPreference 'x64'
    }

    Write-Step 'Rollback: undoing recorded changes'
    $failed = 0
    foreach ($a in $plan) {
        $ok = switch ($a.Kind) {
            'DriverPackage' { Remove-RecordedDriverPackage -Item $a }
            'Catalog'       { Remove-RecordedCatalog -Item $a -SignTool $signtool }
            'Certificate'   { Remove-RecordedCertificate -Item $a }
        }
        if ($ok) {
            Complete-RollbackAction -State $state -RollbackAction $a
            Save-ToolState -State $state -Path $StatePath
        } else {
            $failed++
        }
    }
    if (@($state.Installs).Count -eq 0) {
        $archive = "{0}.rolledback_{1}.json" -f ($StatePath -replace '\.json$', ''), $script:StartTime.ToString('yyyyMMdd_HHmmss')
        Move-Item -LiteralPath $StatePath -Destination $archive -Force
        Write-LogLine -Level OK -Message ("All recorded changes undone; state archived to {0}" -f $archive)
    }
    if ($failed -gt 0) {
        Write-LogLine -Level WARN -Message ("{0} item(s) could not be undone and remain in {1}; re-run Rollback after fixing the cause." -f $failed, $StatePath)
    }
    Write-LogLine -Level INFO -Message 'Rollback complete. Reboot to return to the Microsoft Basic Display Adapter.'
}

#endregion

#region ---------- Main ----------

function Invoke-Main {
    $o = $script:Options
    Initialize-Log -Root $o.WorkRoot -ActionName $o.Action
    Write-LogLine -Level INFO -Message ("=== {0} starting, action: {1} ===" -f $script:ToolName, $o.Action)
    Assert-Admin
    $os = Get-OSContext
    $statePath = Join-Path $o.WorkRoot 'state.json'

    if ($o.Action -eq 'Rollback') {
        Publish-LogHeader
        Invoke-Rollback -StatePath $statePath
        Write-Summary
        return
    }

    if (-not $o.DriverPath) {
        Stop-WithError -Message "-DriverPath is required for -Action $($o.Action)."
    }
    if ($o.WorkRoot -notmatch '^[\x21-\x7E]+$') {
        Stop-WithError -Message ("WorkRoot must be an ASCII path without spaces: {0}" -f $o.WorkRoot)
    }

    $tools  = Resolve-BuildTool -NeedInf2Cat:($o.Action -eq 'Install')
    $target = Get-TargetDevice
    $found  = Find-DisplayInf -Root $o.DriverPath -Target $target -HostBuild $os.BuildNumber
    $infInSource = $found.File.FullName
    $driverVer = Get-InfDriverVer -Lines $found.Inf.Lines
    $verText = if ($driverVer) { "DriverVer $($driverVer.Raw)" } else { 'DriverVer not found' }
    Set-LogContext -Key 'AMD package' -Value ("{0} ({1})" -f $verText, $found.File.Name)
    Publish-LogHeader

    $osList = $o.TargetOS
    if ($osList -eq 'Auto') {
        $osList = Get-Inf2CatTarget -Build $os.BuildNumber
        if (-not $osList) {
            Stop-WithError -Message ("No Inf2Cat OS identifier known for build {0}." -f $os.BuildNumber) `
                -Hint 'Pass -TargetOS with the Inf2Cat /os: value for this Windows Server version.'
        }
    }
    Write-LogLine -Level DATA -Message ("Inf2Cat target OS: {0}" -f $osList)

    # The display-driver folder is the INF's own folder (contains subfolders + .cat).
    $pkgFolder = Split-Path $infInSource -Parent
    $catName = Get-InfCatalogFileName -Lines $found.Inf.Lines
    $mainCat = $null
    if ($catName) { $mainCat = Join-Path $pkgFolder $catName }
    if (-not $mainCat -or -not (Test-Path -LiteralPath $mainCat)) {
        Stop-WithError -Message ("Catalog named by the INF ('{0}') not found next to it in {1}" -f $catName, $pkgFolder)
    }
    Write-LogLine -Level DATA -Message ("package folder: {0}" -f $pkgFolder)
    Write-LogLine -Level DATA -Message ("main catalog  : {0}" -f $mainCat)
    Write-LogLine -Level DATA -Message ("server deco   : {0} (mirrors {1}), {2} model line(s)" -f `
        $found.Plan.ServerDecoration, $found.Plan.SourceDecoration, @($found.Plan.ModelLines).Count)
    foreach ($ml in $found.Plan.ModelLines) { Write-LogLine -Level DATA -Message ("    {0}" -f $ml.Trim()) }

    # Core safety gate: EKU and kernel signatures of the ORIGINAL package.
    $eku = Test-CatalogEku -CatalogPath $mainCat
    $sig = Test-KernelSignature -SignTool $tools.SignTool -PackageRoot $pkgFolder -MainCatalogPath $mainCat
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($eku -eq 'Attestation' -or $eku -eq 'NoSigner') { $reasons.Add("main catalog: $eku") }
    if (-not $sig.AllSigned) {
        $failedSys = @($sig.Results | Where-Object { -not ($_.Verified -and $_.MsChain) })
        Write-LogLine -Level ERROR -Message ("{0} kernel binary/binaries lack a usable Microsoft signature:" -f $failedSys.Count)
        foreach ($f in $failedSys) { Write-LogLine -Level ERROR -Message ("    {0}: {1}" -f $f.Name, $f.Detail) }
        $reasons.Add("$($failedSys.Count) kernel binary/binaries without a Microsoft signature")
    }
    if ($reasons.Count -gt 0) {
        if ($o.Action -eq 'Install') {
            Stop-WithError -Message ('Refusing to install: ' + ($reasons -join '; ') + '. This package would require test signing / Secure Boot off.') `
                -Hint 'This tool only supports packages whose kernel drivers are WHQL-signed by Microsoft. See README.'
        }
        Write-LogLine -Level WARN -Message 'Verify mode: package is NOT installable by this tool without test signing.'
    } else {
        Write-LogLine -Level OK -Message 'All kernel binaries carry a Microsoft signature. Package is compatible with this method.'
    }

    if ($o.Action -eq 'Verify') {
        Write-LogLine -Level OK -Message 'Verify complete. No changes made. Re-run with -Action Install to proceed.'
        Write-Summary
        return
    }

    # -------- Install path --------
    $fullWork = [System.IO.Path]::GetFullPath($o.WorkRoot).TrimEnd('\')
    if ([System.IO.Path]::GetFullPath($pkgFolder).StartsWith($fullWork + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError -Message 'DriverPath is inside WorkRoot; point -DriverPath at the extracted AMD package instead.'
    }

    $state = Read-ToolState -Path $statePath
    if (-not $state) { $state = New-ToolState }
    $install = New-InstallRecord -InfName $found.File.Name -SourceInf $infInSource -DriverVer $driverVer `
        -MainCatalog $catName -HardwareIds $(if ($target.Device) { @($target.Device.HardwareIds) } else { @($target.TargetIds) })
    $state.Installs = @($state.Installs) + $install
    # Invoked from helper functions; resolves $state and $statePath from this scope.
    $save = { Save-ToolState -State $state -Path $statePath }
    & $save
    Write-LogLine -Level DATA -Message ("state file: {0} (install id {1})" -f $statePath, $install.Id)

    $paths = Backup-Package -Source $pkgFolder -Root $o.WorkRoot
    $workInf = Join-Path $paths.Work $found.File.Name
    $origMainCat = Join-Path $paths.Orig $catName

    Edit-Inf -InfPath $workInf -Target $target -HostBuild $os.BuildNumber | Out-Null

    $install.Catalog = Register-OriginalCatalog -SignTool $tools.SignTool -OrigMainCatalog $origMainCat
    & $save
    Test-KernelSignatureViaStore -SignTool $tools.SignTool -MainSysResults @($sig.Results | Where-Object { $_.InMain })

    $cert = New-SigningCert -Subject $o.CertName -Root $o.WorkRoot -Install $install -OnChange $save
    New-Catalog -Inf2Cat $tools.Inf2Cat -WorkDir $paths.Work -OsList $osList

    Write-Step 'Restoring original subcomponent catalogs'
    $restored = @(Restore-SubcomponentCatalog -OrigDir $paths.Orig -WorkDir $paths.Work -MainCatalogRelativePath $catName)
    foreach ($x in $restored) {
        $lvl = if ($x.Action -eq 'NoOriginal') { 'WARN' } else { 'DATA' }
        Write-LogLine -Level $lvl -Message ("{0,-10} {1}" -f $x.Action, $x.RelativePath)
    }
    Write-LogLine -Level OK -Message ("restored {0} subcomponent catalog(s)" -f @($restored | Where-Object { $_.Action -eq 'Restored' }).Count)

    Invoke-SignCatalog -SignTool $tools.SignTool -CatalogPath (Join-Path $paths.Work $catName) -Thumbprint $cert.Thumbprint

    $install.DriverPackage = Install-Driver -InfPath $workInf
    & $save
    Remove-PrivateKey -Install $install -OnChange $save

    $install.Status = 'Installed'
    & $save
    Write-DeviceStatus -Device $target.Device
    Write-LogLine -Level OK -Message 'Install steps complete.'
    Write-LogLine -Level INFO -Message 'REBOOT, then check: Get-PnpDevice -Class Display | Select FriendlyName, Status, Problem'
    Write-Summary
}

function Write-Summary {
    $dur = (New-TimeSpan -Start $script:StartTime -End (Get-Date))
    Write-LogLine -Level INFO -Message '==================================================================='
    Write-LogLine -Level INFO -Message ("Action    : {0}" -f $script:Options.Action)
    Write-LogLine -Level INFO -Message ("Warnings  : {0}" -f $script:Warnings)
    Write-LogLine -Level INFO -Message ("Duration  : {0:n1}s" -f $dur.TotalSeconds)
    Write-LogLine -Level INFO -Message ("Log file  : {0}" -f $script:LogFile)
    Write-LogLine -Level INFO -Message '==================================================================='
    Write-Host ''
    Write-Host "Done. Log saved to:" -ForegroundColor Green
    Write-Host "  $script:LogFile" -ForegroundColor Green
}

# Dot-sourcing (". .\Install-AMDDriver.ps1") only loads the functions; the Pester tests rely on this.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    Invoke-Main
} catch {
    # Catch anything unhandled and make it a reportable log entry.
    if ($script:LogFile) {
        Write-LogLine -Level ERROR -Message ("UNHANDLED: {0}" -f $_.Exception.Message)
        Write-LogLine -Level ERROR -Message ("at: {0}" -f $_.InvocationInfo.PositionMessage)
        Write-LogLine -Level ERROR -Message ("stack: {0}" -f $_.ScriptStackTrace)
        Publish-LogHeader
        Write-Host ''
        Write-Host "FAILED (unhandled). Attach this log when reporting:" -ForegroundColor Red
        Write-Host "  $script:LogFile" -ForegroundColor Red
    } else {
        Write-Host "FAILED before logging was initialised: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}

#endregion
