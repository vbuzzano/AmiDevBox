# Load .env file into environment
if (Test-Path .env) {
    Get-Content .env | ForEach-Object {
        if ($_ -match '^([^#=]+)=(.*)$') {
            Set-Item "env:$($matches[1])" $matches[2]
        }
    }
}

# Add .box and scripts to PATH
$env:PATH = "$pwd\.box;$pwd\scripts;$env:PATH"
