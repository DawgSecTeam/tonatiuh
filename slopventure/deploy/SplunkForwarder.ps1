#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$SplunkServerIP,

    [string]$SplunkVersion = "10.2.0",
    [string]$SplunkBuild   = "d749cb17ea65"
)

$ErrorActionPreference = "Stop"

# Prompt securely for Splunk admin password (mirrors stty -echo)
$secPass = Read-Host "Enter Splunk admin password" -AsSecureString
$bstr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
$AdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

$MsiName     = "splunkforwarder-$SplunkVersion-$SplunkBuild-windows-x64.msi"
$DownloadUrl = "https://download.splunk.com/products/universalforwarder/releases/$SplunkVersion/windows/$MsiName"
$Installer   = Join-Path $env:TEMP $MsiName
$SplunkHome  = "C:\Program Files\SplunkUniversalForwarder"

# 1. Download MSI (or use a local copy if pre-staged in binaries\)
$LocalMsi = Join-Path (Split-Path -Parent $PSScriptRoot) "binaries\$MsiName"
if (Test-Path -LiteralPath $LocalMsi) {
    Write-Host "[*] Using pre-staged installer: $LocalMsi" -ForegroundColor Cyan
    $Installer = $LocalMsi
} else {
    Write-Host "[*] Downloading $MsiName..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $Installer
}

# 2. Silent install + configure indexer, credentials, and core Windows Event Logs
Write-Host "[*] Installing Splunk Universal Forwarder..." -ForegroundColor Cyan
$msiArgs = @(
    "/i", "`"$Installer`"",
    "AGREETOLICENSE=Yes",
    "RECEIVING_INDEXER=`"${SplunkServerIP}:9997`"",
    "SPLUNKUSERNAME=admin",
    "SPLUNKPASSWORD=`"$AdminPassword`"",
    "WINEVENTLOG_SEC_ENABLE=1",
    "WINEVENTLOG_SYS_ENABLE=1",
    "WINEVENTLOG_APP_ENABLE=1",
    "LAUNCHSPLUNK=1",
    "/quiet"
)

$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Error "[x] MSI install failed with exit code $($proc.ExitCode)"
    exit $proc.ExitCode
}

# 3. Also forward Sysmon logs if Sysmon is installed
$InputsConf = Join-Path $SplunkHome "etc\system\local\inputs.conf"
@"
[WinEventLog://Microsoft-Windows-Sysmon/Operational]
disabled = 0
renderXml = true
"@ | Add-Content -LiteralPath $InputsConf

Restart-Service -Name "SplunkForwarder" -Force
Start-Sleep -Seconds 5

# 4. Verify forwarder connection
Write-Host "`n[*] Verifying forwarder status..." -ForegroundColor Cyan
& (Join-Path $SplunkHome "bin\splunk.exe") list forward-server -auth "admin:$AdminPassword"
