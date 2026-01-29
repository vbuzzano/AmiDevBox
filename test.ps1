# IRM/IEX context execut Detection

Write-Host ""
Write-Host "=== IRM/IEX Context Detection ==="
Write-Host ""
Write-Host "PSScriptRoot: $PSScriptRoot"
Write-Host "------------------------------"
Write-Host "IsIrmIexContext variable exists: $(Get-Variable -Name IsIrmIexContext -Scope Script -ErrorAction SilentlyContinue -ne $null)"
Write-Host "--> Object:"
Get-Variable -Name IsIrmIexContext -Scope Script
Write-Host "------------------------------"

# IRM/IEX context execut Detection
$script:IsIrmIex = (-not $PSScriptRoot) -or (Get-Variable -Name IsIrmIexContext -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
echo "IsIrmIex: $script:IsIrmIex"

Write-Host "------------------------------"

Write-Host ""
Write-Host ""
Write-Host ""

Write-Host "Variables"
Write-Host "------------------------------"
Get-Variable -Scope Script

