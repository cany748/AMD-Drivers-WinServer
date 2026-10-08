# Settings for Invoke-ScriptAnalyzer (used locally and in CI).
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # Coloured console output is the interface of this interactive tool; every
        # line is also written to the log file, so nothing is lost when the host
        # does not render it.
        'PSAvoidUsingWriteHost'

        # -Action Verify is the dry run for the whole script. The internal
        # New-/Remove-/Set- helpers are not public cmdlets, and per-function
        # -WhatIf would not describe the multi-step install any better.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules        = @{
        # The script must run on Windows PowerShell 5.1, the default on Windows Server.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
