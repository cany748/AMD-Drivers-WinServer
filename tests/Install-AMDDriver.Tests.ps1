#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests for the pure functions of Install-AMDDriver.ps1.
# All INF fixtures under tests/fixtures are synthetic and written by hand.

BeforeAll {
    $script:Root     = Split-Path $PSScriptRoot -Parent
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
    # Dot-sourcing loads the functions without running Invoke-Main.
    . (Join-Path $script:Root 'Install-AMDDriver.ps1')

    function Get-FixtureLine {
        param([string]$Name)
        (Read-InfFile -Path (Join-Path $script:Fixtures $Name)).Lines
    }

    # IDs as Windows reports them for PCI\VEN_1002&DEV_13C0&SUBSYS_7E611462&REV_C1.
    $script:DeviceHardwareIds = @(
        'PCI\VEN_1002&DEV_13C0&SUBSYS_7E611462&REV_C1'
        'PCI\VEN_1002&DEV_13C0&SUBSYS_7E611462'
        'PCI\VEN_1002&DEV_13C0&CC_030000'
        'PCI\VEN_1002&DEV_13C0&CC_0300'
    )
    $script:DeviceCompatibleIds = @(
        'PCI\VEN_1002&DEV_13C0&REV_C1'
        'PCI\VEN_1002&DEV_13C0'
        'PCI\VEN_1002&CC_030000'
        'PCI\VEN_1002&CC_0300'
        'PCI\CC_030000'
        'PCI\CC_0300'
    )
    $script:TargetIds = Get-DeviceMatchId -HardwareIds $script:DeviceHardwareIds -CompatibleIds $script:DeviceCompatibleIds
}

Describe 'Fixtures' {
    It 'are marked synthetic' -ForEach @(
        @{ Name = 'display-basic.inf' }
        @{ Name = 'display-multi-entry.inf' }
    ) {
        (Get-Content (Join-Path $script:Fixtures $Name) -TotalCount 1) | Should -Match 'SYNTHETIC TEST FIXTURE'
    }
}

Describe 'Script file' {
    It 'is pure ASCII so Windows PowerShell 5.1 reads it correctly without a BOM' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:Root 'Install-AMDDriver.ps1'))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'Get-InfLineWithoutComment / Get-InfSectionName' {
    It 'strips comments outside quotes only' {
        Get-InfLineWithoutComment -Line 'a = "x;y" ; comment' | Should -Be 'a = "x;y" '
        Get-InfLineWithoutComment -Line 'no comment' | Should -Be 'no comment'
    }
    It 'reads section headers with spaces and trailing comments' {
        Get-InfSectionName -Line '  [ Manufacturer ]  ; c' | Should -Be 'Manufacturer'
        Get-InfSectionName -Line '%a% = b' | Should -BeNullOrEmpty
    }
}

Describe 'Version section' {
    It 'reads DriverVer' {
        $v = Get-InfDriverVer -Lines (Get-FixtureLine 'display-basic.inf')
        $v.Date | Should -Be '07/15/2026'
        $v.Version | Should -Be '32.0.21025.1004'
    }
    It 'prefers CatalogFile.NTamd64 and strips comments' {
        Get-InfCatalogFileName -Lines (Get-FixtureLine 'display-multi-entry.inf') | Should -Be 'fixture64.cat'
        Get-InfCatalogFileName -Lines (Get-FixtureLine 'display-basic.inf') | Should -Be 'fixture.cat'
    }
}

Describe '[Manufacturer] parsing' {
    It 'parses an entry with decorations' {
        $e = ConvertFrom-InfManufacturerEntry -Line '%ATI% = ATI.Mfg, NTamd64.10.0.1..19041, NTamd64.10.0.1 ; c,d'
        $e.Name | Should -Be '%ATI%'
        $e.ModelsSection | Should -Be 'ATI.Mfg'
        $e.Decorations | Should -Be @('NTamd64.10.0.1..19041', 'NTamd64.10.0.1')
    }
    It 'returns nothing for blank and comment lines' {
        ConvertFrom-InfManufacturerEntry -Line '   ' | Should -BeNullOrEmpty
        ConvertFrom-InfManufacturerEntry -Line '; only a comment' | Should -BeNullOrEmpty
    }
    It 'splits a decoration into its fields' {
        $d = ConvertFrom-InfDecoration -Decoration 'NTamd64.10.0.1..19041'
        $d.Arch | Should -Be 'amd64'
        $d.Major | Should -Be '10'
        $d.ProductType | Should -Be '1'
        $d.SuiteMask | Should -Be ''
        $d.Build | Should -Be 19041
        (ConvertFrom-InfDecoration -Decoration 'NTamd64').Build | Should -BeNullOrEmpty
    }
    It 'builds the server decoration keeping the build' {
        ConvertTo-ServerDecoration -Decoration 'NTamd64.10.0.1..22000' | Should -Be 'NTamd64.10.0.3..22000'
        { ConvertTo-ServerDecoration -Decoration 'NTamd64.10.0...22000' } | Should -Throw
    }
}

Describe 'Hardware ID matching' {
    It 'keeps only device-specific IDs' {
        $script:TargetIds | Should -Contain 'PCI\VEN_1002&DEV_13C0&REV_C1'
        $script:TargetIds | Should -Contain 'PCI\VEN_1002&DEV_13C0&SUBSYS_7E611462&REV_C1'
        $script:TargetIds | Should -Not -Contain 'PCI\VEN_1002&CC_030000'
        $script:TargetIds | Should -Not -Contain 'PCI\CC_0300'
    }
    It 'matches exactly, case-insensitively' {
        Test-HardwareIdMatch -InfIds @('pci\ven_1002&dev_13c0&rev_c1') -TargetIds $script:TargetIds | Should -BeTrue
        Test-HardwareIdMatch -InfIds @('PCI\VEN_1002&DEV_13C0&REV_C2') -TargetIds $script:TargetIds | Should -BeFalse
    }
    It 'prefix mode matches on a component boundary only' {
        Test-HardwareIdMatch -InfIds @('PCI\VEN_1002&DEV_13C0&REV_C2') -TargetIds @('PCI\VEN_1002&DEV_13C0') -PrefixMatch | Should -BeTrue
        Test-HardwareIdMatch -InfIds @('PCI\VEN_1002&DEV_13C01') -TargetIds @('PCI\VEN_1002&DEV_13C0') -PrefixMatch | Should -BeFalse
    }
    It 'reads the IDs from a model line' {
        Get-InfModelLineId -Line '%D% = inst, PCI\VEN_1002&DEV_13C0&REV_C1, PCI\VEN_1002&DEV_13C0 ; c' |
            Should -Be @('PCI\VEN_1002&DEV_13C0&REV_C1', 'PCI\VEN_1002&DEV_13C0')
        @(Get-InfModelLineId -Line '[Section]').Count | Should -Be 0
    }
}

Describe 'Get-ServerPatchPlan' {
    It 'mirrors the newest ProductType=1 decoration that applies to the host build' {
        $plan = Get-ServerPatchPlan -Lines (Get-FixtureLine 'display-basic.inf') -TargetIds $script:TargetIds -HostBuild 26100
        $plan.SourceDecoration | Should -Be 'NTamd64.10.0.1..22000'
        $plan.ServerDecoration | Should -Be 'NTamd64.10.0.3..22000'
        $plan.ServerSection | Should -Be 'Vendor.Mfg.NTamd64.10.0.3..22000'
        $plan.Warnings | Should -Match '99999'
    }
    It 'copies only the lines whose IDs belong to the device' {
        $plan = Get-ServerPatchPlan -Lines (Get-FixtureLine 'display-basic.inf') -TargetIds $script:TargetIds -HostBuild 26100
        $plan.ModelLines.Count | Should -Be 2
        $plan.ModelLines[0] | Should -Match 'DEV_13C0&REV_C1$'
        $plan.ModelLines[1] | Should -Match 'SUBSYS_7E611462&REV_C1$'
    }
    It 'with -PrefixMatch copies every line of the VEN/DEV pair' {
        $plan = Get-ServerPatchPlan -Lines (Get-FixtureLine 'display-basic.inf') -TargetIds @('PCI\VEN_1002&DEV_13C0') -PrefixMatch -HostBuild 26100
        $plan.ModelLines.Count | Should -Be 3
    }
    It 'uses an older decoration on an older build' {
        $plan = Get-ServerPatchPlan -Lines (Get-FixtureLine 'display-basic.inf') -TargetIds $script:TargetIds -HostBuild 20348
        $plan.SourceDecoration | Should -Be 'NTamd64.10.0.1..19041'
        $plan.ServerDecoration | Should -Be 'NTamd64.10.0.3..19041'
        $plan.ModelLines.Count | Should -Be 1
    }
    It 'refuses when the host is older than every decoration' {
        { Get-ServerPatchPlan -Lines (Get-FixtureLine 'display-basic.inf') -TargetIds $script:TargetIds -HostBuild 17763 } |
            Should -Throw '*requires build 19041*'
    }
    It 'refuses when the device is not listed' {
        { Get-ServerPatchPlan -Lines (Get-FixtureLine 'display-basic.inf') -TargetIds @('PCI\VEN_1002&DEV_FFFF') -HostBuild 26100 } |
            Should -Throw '*no model line*'
    }
    It 'skips entries that do not list the device' {
        $plan = Get-ServerPatchPlan -Lines (Get-FixtureLine 'display-multi-entry.inf') -TargetIds $script:TargetIds -HostBuild 26100
        $plan.EntryName | Should -Be '%Vendor%'
        $plan.ModelLines.Count | Should -Be 1
    }
    It 'refuses an INF that already has a Server decoration' {
        $lines = @(
            '[Manufacturer]'
            '%V% = V.Mfg, NTamd64.10.0.3..19041, NTamd64.10.0.1..19041'
            '[V.Mfg.NTamd64.10.0.1..19041]'
            '%D% = inst, PCI\VEN_1002&DEV_13C0&REV_C1'
        )
        { Get-ServerPatchPlan -Lines $lines -TargetIds $script:TargetIds -HostBuild 26100 } | Should -Throw '*already*'
    }
    It 'refuses an INF without a [Manufacturer] section' {
        { Get-ServerPatchPlan -Lines @('[Version]', 'Class=Display') -TargetIds $script:TargetIds -HostBuild 26100 } |
            Should -Throw '*No `[Manufacturer`]*'
    }
}

Describe 'Add-InfServerSection' {
    BeforeAll {
        $script:Lines = Get-FixtureLine 'display-basic.inf'
        $script:Plan = Get-ServerPatchPlan -Lines $script:Lines -TargetIds $script:TargetIds -HostBuild 26100
        $script:Patched = Add-InfServerSection -Lines $script:Lines -Plan $script:Plan
    }
    It 'adds the server decoration right after the models section name' {
        $script:Patched[$script:Plan.EntryIndex] |
            Should -Be '%Vendor% = Vendor.Mfg, NTamd64.10.0.3..22000, NTamd64.10.0.1..19041, NTamd64.10.0.1..22000, NTamd64.10.0.1..99999'
    }
    It 'adds the section inside the [Manufacturer] block, before the next section' {
        $hdr = [array]::IndexOf($script:Patched, '[Vendor.Mfg.NTamd64.10.0.3..22000]')
        $hdr | Should -BeGreaterThan $script:Plan.EntryIndex
        $next = [array]::IndexOf($script:Patched, '[Vendor.Mfg.NTamd64.10.0.1..19041]')
        $hdr | Should -BeLessThan $next
        $script:Patched[$hdr + 2] | Should -Be $script:Plan.ModelLines[0]
        $script:Patched[$hdr + 3] | Should -Be $script:Plan.ModelLines[1]
    }
    It 'keeps every original line except the manufacturer entry' {
        $added = $script:Patched.Count - $script:Lines.Count
        $added | Should -Be (3 + $script:Plan.ModelLines.Count)
        $kept = @($script:Patched | Where-Object { $script:Lines -contains $_ })
        @($script:Lines | Where-Object { $script:Patched -notcontains $_ }) | Should -Be @($script:Lines[$script:Plan.EntryIndex])
        $kept.Count | Should -BeGreaterThan 0
    }
    It 'passes the post-edit check, and the result cannot be patched twice' {
        Test-InfServerPatch -Lines $script:Patched -Plan $script:Plan | Should -BeTrue
        Test-InfServerPatch -Lines $script:Lines -Plan $script:Plan | Should -BeFalse
        { Get-ServerPatchPlan -Lines $script:Patched -TargetIds $script:TargetIds -HostBuild 26100 } | Should -Throw '*already*'
    }
    It 'keeps a trailing comment on the manufacturer entry' {
        $lines = Get-FixtureLine 'display-multi-entry.inf'
        $plan = Get-ServerPatchPlan -Lines $lines -TargetIds $script:TargetIds -HostBuild 26100
        $out = Add-InfServerSection -Lines $lines -Plan $plan
        $out[$plan.EntryIndex] | Should -Be '%Vendor% = Vendor.Mfg, NTamd64.10.0.3..19041, NTamd64.10.0.1..19041 ; trailing comment, with a comma'
    }
}

Describe 'INF encoding round trip' {
    BeforeAll {
        $script:Text = (Get-FixtureLine 'display-basic.inf') -join "`r`n"
        # A non-ASCII string makes the encodings distinguishable.
        $script:Text = $script:Text.Replace('"Fixture Vendor"', ('"Fixture Vendor ' + [char]0x00E9 + [char]0x00AE + '"'))
        $script:Variants = @{
            UTF16LE = { param($t) $e = New-Object System.Text.UnicodeEncoding($false, $true); [byte[]]($e.GetPreamble() + $e.GetBytes($t)) }
            UTF8BOM = { param($t) $e = New-Object System.Text.UTF8Encoding($true); [byte[]]($e.GetPreamble() + $e.GetBytes($t)) }
            ANSI    = { param($t) [System.Text.Encoding]::GetEncoding(28591).GetBytes($t) }
            UTF8    = { param($t) (New-Object System.Text.UTF8Encoding($false)).GetBytes($t) }
        }
    }
    It 'detects <Name> and writes it back byte-for-byte' -ForEach @(
        @{ Name = 'UTF16LE' }, @{ Name = 'UTF8BOM' }, @{ Name = 'ANSI' }, @{ Name = 'UTF8' }
    ) {
        $path = Join-Path $TestDrive "$Name.inf"
        $bytes = & $script:Variants[$Name] $script:Text
        [System.IO.File]::WriteAllBytes($path, $bytes)
        $inf = Read-InfFile -Path $path
        $inf.EncodingName | Should -Be $Name
        $inf.NewLine | Should -Be "`r`n"
        Write-InfFile -Path $path -Lines $inf.Lines -EncodingName $inf.EncodingName -NewLine $inf.NewLine
        [System.IO.File]::ReadAllBytes($path) | Should -Be $bytes
    }
    It 'keeps the encoding when the patch is applied (<Name>)' -ForEach @(
        @{ Name = 'UTF16LE' }, @{ Name = 'UTF8BOM' }, @{ Name = 'ANSI' }
    ) {
        $path = Join-Path $TestDrive "patch-$Name.inf"
        [System.IO.File]::WriteAllBytes($path, (& $script:Variants[$Name] $script:Text))
        $inf = Read-InfFile -Path $path
        $plan = Get-ServerPatchPlan -Lines $inf.Lines -TargetIds $script:TargetIds -HostBuild 26100
        Write-InfFile -Path $path -Lines (Add-InfServerSection -Lines $inf.Lines -Plan $plan) -EncodingName $inf.EncodingName -NewLine $inf.NewLine
        $again = Read-InfFile -Path $path
        $again.EncodingName | Should -Be $Name
        Test-InfServerPatch -Lines $again.Lines -Plan $plan | Should -BeTrue
        ($again.Lines -join "`n") | Should -Match ([regex]::Escape('Fixture Vendor ' + [char]0x00E9 + [char]0x00AE))
    }
    It 'keeps ANSI bytes of any code page unchanged' {
        $path = Join-Path $TestDrive 'cp1251.inf'
        # "Vendor" in Cyrillic, cp1251 bytes; not valid UTF-8.
        $bytes = [byte[]](@([byte][char]'[', [byte][char]'S', [byte][char]']', 13, 10) + @(0xC2, 0xE5, 0xED, 0xE4, 0xEE, 0xF0) + @(13, 10))
        [System.IO.File]::WriteAllBytes($path, $bytes)
        $inf = Read-InfFile -Path $path
        $inf.EncodingName | Should -Be 'ANSI'
        Write-InfFile -Path $path -Lines $inf.Lines -EncodingName $inf.EncodingName -NewLine $inf.NewLine
        [System.IO.File]::ReadAllBytes($path) | Should -Be $bytes
    }
    It 'detects UTF-16LE without a BOM' {
        $bytes = (New-Object System.Text.UnicodeEncoding($false, $false)).GetBytes("[Version]`r`nClass=Display`r`n")
        Get-TextEncodingName -Bytes $bytes | Should -Be 'UTF16LENOBOM'
    }
}

Describe 'Restore-SubcomponentCatalog' {
    BeforeEach {
        $script:Orig = Join-Path $TestDrive ('orig' + [guid]::NewGuid().ToString('N'))
        $script:Work = Join-Path $TestDrive ('gpu' + [guid]::NewGuid().ToString('N'))
        foreach ($d in $script:Orig, $script:Work) {
            New-Item -ItemType Directory -Path (Join-Path $d 'amdxe') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $d 'amdfendr') -Force | Out-Null
        }
        Set-Content -Path (Join-Path $script:Orig 'main.cat') -Value 'original main'
        Set-Content -Path (Join-Path $script:Orig 'second.cat') -Value 'original second'
        Set-Content -Path (Join-Path $script:Orig 'amdxe/amdxe.cat') -Value 'original amdxe'
        Set-Content -Path (Join-Path $script:Orig 'amdfendr/amdfendr.cat') -Value 'original amdfendr'
        # What Inf2Cat leaves behind: everything regenerated, plus one new catalog.
        Set-Content -Path (Join-Path $script:Work 'main.cat') -Value 'regenerated main'
        Set-Content -Path (Join-Path $script:Work 'second.cat') -Value 'regenerated second'
        Set-Content -Path (Join-Path $script:Work 'amdxe/amdxe.cat') -Value 'regenerated amdxe'
        Set-Content -Path (Join-Path $script:Work 'amdfendr/amdfendr.cat') -Value 'original amdfendr'
        Set-Content -Path (Join-Path $script:Work 'amdxe/extra.cat') -Value 'new'
    }
    It 'restores every catalog except the main one' {
        $r = Restore-SubcomponentCatalog -OrigDir $script:Orig -WorkDir $script:Work -MainCatalogRelativePath 'main.cat'
        Get-Content (Join-Path $script:Work 'main.cat') | Should -Be 'regenerated main'
        Get-Content (Join-Path $script:Work 'second.cat') | Should -Be 'original second'
        Get-Content (Join-Path $script:Work 'amdxe/amdxe.cat') | Should -Be 'original amdxe'
        ($r | Where-Object RelativePath -eq 'amdxe\amdxe.cat').Action | Should -Be 'Restored'
        ($r | Where-Object RelativePath -eq 'amdfendr\amdfendr.cat').Action | Should -Be 'Unchanged'
        ($r | Where-Object RelativePath -eq 'amdxe\extra.cat').Action | Should -Be 'NoOriginal'
        @($r | Where-Object RelativePath -eq 'main.cat').Count | Should -Be 0
    }
    It 'puts back a catalog missing from the work tree' {
        Remove-Item (Join-Path $script:Work 'amdxe/amdxe.cat')
        $r = Restore-SubcomponentCatalog -OrigDir $script:Orig -WorkDir $script:Work -MainCatalogRelativePath 'main.cat'
        Get-Content (Join-Path $script:Work 'amdxe/amdxe.cat') | Should -Be 'original amdxe'
        ($r | Where-Object RelativePath -eq 'amdxe\amdxe.cat').Action | Should -Be 'Restored'
    }
    It 'matches the main catalog name case-insensitively' {
        $null = Restore-SubcomponentCatalog -OrigDir $script:Orig -WorkDir $script:Work -MainCatalogRelativePath 'MAIN.CAT'
        Get-Content (Join-Path $script:Work 'main.cat') | Should -Be 'regenerated main'
    }
}

Describe 'Small helpers' {
    It 'maps builds to Inf2Cat identifiers' {
        Get-Inf2CatTarget -Build 20348 | Should -Be 'ServerFE_X64'
        Get-Inf2CatTarget -Build 26100 | Should -Be 'Server2025_X64'
        Get-Inf2CatTarget -Build 17763 | Should -BeNullOrEmpty
    }
    It 'classifies catalog EKUs' {
        Get-CatalogEkuVerdict -Oids @('1.3.6.1.4.1.311.10.3.5.1', '1.3.6.1.4.1.311.10.3.5') | Should -Be 'Attestation'
        Get-CatalogEkuVerdict -Oids @('1.3.6.1.5.5.7.3.3', '1.3.6.1.4.1.311.10.3.5') | Should -Be 'Whql'
        Get-CatalogEkuVerdict -Oids @('1.3.6.1.5.5.7.3.3') | Should -Be 'NoWhql'
    }
    It 'recognises a Microsoft chain in signtool output' {
        Test-MicrosoftChainText -Text "Issued to: Microsoft Windows Hardware Compatibility Publisher" | Should -BeTrue
        Test-MicrosoftChainText -Text "Issued to: Advanced Micro Devices, Inc.`nIssued by: Sectigo" | Should -BeFalse
    }
}

Describe 'State file and rollback plan' {
    BeforeAll {
        function New-TestInstall {
            param([string]$Oem, [string]$Cat, [bool]$Registered, [string]$Thumb, [string[]]$Stores)
            $i = New-InstallRecord -InfName 'u0000000.inf' -SourceInf 'C:\pkg\u0000000.inf' -DriverVer $null -MainCatalog 'u0000000.cat' -HardwareIds @('PCI\VEN_1002&DEV_13C0')
            if ($Oem) { $i.DriverPackage = [pscustomobject]@{ PublishedName = $Oem; StagedInf = 'x'; StagedInfSha256 = "H-$Oem"; MatchedBy = 'hash' } }
            if ($Cat) { $i.Catalog = [pscustomobject]@{ SourcePath = 'x'; Sha256 = "H-$Cat"; CatRootName = $Cat; CatRootDirectory = 'x'; RegisteredByTool = $Registered } }
            if ($Thumb) { $i.Certificate = [pscustomobject]@{ Thumbprint = $Thumb; Subject = 'CN=Test'; Stores = @($Stores) } }
            $i
        }
    }
    It 'round-trips through JSON, including single-element arrays' {
        $s = New-ToolState
        $s.Installs = @(New-TestInstall -Oem 'oem7.inf' -Cat 'a.cat' -Registered $true -Thumb 'AA' -Stores @('Root'))
        $path = Join-Path $TestDrive 'state.json'
        Save-ToolState -State $s -Path $path
        $r = Read-ToolState -Path $path
        @($r.Installs).Count | Should -Be 1
        $r.Installs[0].DriverPackage.PublishedName | Should -Be 'oem7.inf'
        @($r.Installs[0].Certificate.Stores) | Should -Be @('Root')
    }
    It 'returns $null when there is no state file' {
        Read-ToolState -Path (Join-Path $TestDrive 'missing.json') | Should -BeNullOrEmpty
    }
    It 'plans only recorded items, newest install first, driver before catalog before certificate' {
        $s = New-ToolState
        $s.Installs = @(
            (New-TestInstall -Oem 'oem3.inf' -Cat 'old.cat' -Registered $true -Thumb 'OLD' -Stores @('Root', 'TrustedPublisher'))
            (New-TestInstall -Oem 'oem9.inf' -Cat 'new.cat' -Registered $true -Thumb 'NEW' -Stores @('Root'))
        )
        $plan = @(Get-RollbackPlan -State $s)
        ($plan | ForEach-Object { "$($_.Kind):$($_.Target)" }) | Should -Be @(
            'DriverPackage:oem9.inf', 'Catalog:new.cat', 'Certificate:NEW',
            'DriverPackage:oem3.inf', 'Catalog:old.cat', 'Certificate:OLD', 'Certificate:OLD'
        )
        $plan[0].Sha256 | Should -Be 'H-oem9.inf'
    }
    It 'never plans a catalog that was already registered before the install' {
        $s = New-ToolState
        $s.Installs = @(New-TestInstall -Cat 'shared.cat' -Registered $false -Thumb 'T' -Stores @('Root'))
        @(Get-RollbackPlan -State $s | Where-Object Kind -eq 'Catalog').Count | Should -Be 0
    }
    It 'drops an install once everything recorded for it is undone' {
        $s = New-ToolState
        $s.Installs = @(New-TestInstall -Oem 'oem5.inf' -Cat 'c.cat' -Registered $true -Thumb 'T' -Stores @('Root', 'TrustedPublisher'))
        $plan = @(Get-RollbackPlan -State $s)
        foreach ($a in $plan[0..2]) { Complete-RollbackAction -State $s -RollbackAction $a }
        @($s.Installs).Count | Should -Be 1
        @($s.Installs[0].Certificate.Stores) | Should -Be @('TrustedPublisher')
        Complete-RollbackAction -State $s -RollbackAction $plan[3]
        @($s.Installs).Count | Should -Be 0
    }
}
