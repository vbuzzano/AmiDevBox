# IRM/IEX context execut Detection

function Boxing-IsIrmIexContext {
<#
    .SYNOPSIS
        Detects if the current script is being executed in an IRM/IEX context.

    .PARAMETER MyCommand
        MyInvocation.MyCommand object representing the current command.
#>
    param(
        [Parameter(Mandatory = $false)]
        [Object]$MyCommand = $null
    )

    Write-Host "command -> $Mycommand"
    if (-not $Mycommand) {
        Write-Host "no command - false"
        return $false
    }


    $definition = $Mycommand.Definition
    #$definition = "irm https://raw.githubusercontent.com/vbuzzano/AmiDevBox/refs/heads/main/test.ps1 | iex"

    if ($definition -and ($definition -match '(?i)^(irm)\s+http[s]?://[^\s]+\s+\|\s+(iex).*$')) {
        Write-Host "matched - true"
        return $true
    }
    Write-Host "no Definition or ScriptBlock - false"
    return $false
}

Write-Host ""
Write-Host "=== IRM/IEX Context Detection ==="
Write-Host ""
Write-Host "isIrmIEx: $(Boxing-IsIrmIexContext -MyCommand $MyInvocation.MyCommand)"
Write-Host ""
