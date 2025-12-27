# Load environment variables from .env file
# This script loads KEY=VALUE pairs from .env into the current PowerShell session
# Source it in your scripts or profiles to populate environment variables

if (Test-Path ".env") {
    Get-Content ".env" | ForEach-Object {
        # Skip comments and empty lines
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') {
            return
        }
        
        # Parse KEY=VALUE
        if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $key = $matches[1]
            $value = $matches[2].Trim()
            
            # Set environment variable
            [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}
