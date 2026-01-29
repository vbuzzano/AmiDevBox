# IRM/IEX context execut Detection

function Boxing-IsIrmIexContext {
    $command = $MyInvocation.MyCommand
    if (-not $command) { return $false }
    if ($command.Definition) {
        $command = $command.Definition
    } elseif ($command.ScriptBlock) {
        $command = $command.ScriptBlock
    } else {
        return $false
    }
    #$command = "irm https://raw.githubusercontent.com/vbuzzano/AmiDevBox/refs/heads/main/test.ps1 | iex"

    return $command -match '(?i)^(irm)\s+http[s]?://[^\s]+\s+\|\s+(iex).*$'
}

Write-Host ""
Write-Host "=== IRM/IEX Context Detection ==="
Write-Host ""
Write-Host "isIrmIEx: $(Boxing-IsIrmIexContext)"
Write-Host ""
