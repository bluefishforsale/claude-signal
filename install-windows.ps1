# Windows entry point. signal-mcp doesn't run natively on Windows, so this puts
# it in WSL2 (Ubuntu) and lets the Linux installer register it with Claude
# Desktop and Claude Code on the Windows side.
#
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1 [install.sh options]
#
# Any options (e.g. --readonly, --bot-number +15551234567) pass through to install.sh.

param(
    [string]$Distro = "Ubuntu",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$InstallArgs = @()
)

$ErrorActionPreference = "Stop"
$bootstrapUrl = "https://raw.githubusercontent.com/bluefishforsale/claude-signal/main/wsl-bootstrap.sh"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "WSL isn't available on this version of Windows. Windows 10 2004+ or Windows 11 is required."
}

# NOTE: probe by running a command rather than parsing `wsl -l`, whose output is
# UTF-16 and reads as garbled text with NULs in between when captured here.
& wsl.exe -d $Distro -e true 2>$null
if ($LASTEXITCODE -ne 0) {
    if (-not (Test-Admin)) {
        throw "WSL distro '$Distro' isn't installed. Rerun this from an Administrator PowerShell to install it."
    }
    Write-Host "==> Installing WSL2 with $Distro. Windows may ask to restart."
    & wsl.exe --install -d $Distro
    Write-Host ""
    Write-Host "When $Distro has finished setting up (and you've created your Linux user, restarting first if asked),"
    Write-Host "run this script again, from a normal PowerShell this time, to finish."
    exit 0
}

# Single-quote each argument for bash so values with spaces survive the trip.
$quoted = ($InstallArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join " "
$command = "curl -fsSL $bootstrapUrl -o /tmp/claude-signal-bootstrap.sh && bash /tmp/claude-signal-bootstrap.sh $quoted"

Write-Host "==> Running the installer inside $Distro"
& wsl.exe -d $Distro -- bash -c $command
exit $LASTEXITCODE
