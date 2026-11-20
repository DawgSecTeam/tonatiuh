#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Password,

    [string]$StageDir = $PSScriptRoot
)

$ErrorActionPreference = "Continue"
Write-Host "Starting activation script..." -ForegroundColor Cyan

Set-Location -LiteralPath $StageDir

# ############################
# Creating directories
# ############################
$LogDir = Join-Path $StageDir ".log"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# ############################
# Setting up lax firewall (-Download)
# ############################
Write-Host "Starting Autofirewall.ps1 with package manager / download ports"
& (Join-Path $StageDir "Autofirewall.ps1") -Download 2>&1 | Tee-Object -FilePath (Join-Path $LogDir "autofirewall.log")
Write-Host "Finished Autofirewall.ps1 with download ports"

# ############################
# Taking initial backup
# ############################
Write-Host "==> Deploying backup" -ForegroundColor Cyan
$BackupScript = Join-Path $StageDir "Backup.ps1"
if (Test-Path -LiteralPath $BackupScript) {
    & $BackupScript "backup" "initial" 2>&1 | Tee-Object -FilePath (Join-Path $LogDir "backup.log")
} else {
    Write-Warning "Backup.ps1 not found in $StageDir; skipping initial backup."
}

# ############################
# Setting up auditing (Sysmon + Windows Audit Policy)
# ############################
Write-Host "==> Deploying Sysmon & Audit Policy" -ForegroundColor Cyan

# Enable core Windows Advanced Audit Policies (process creation, logon, account management)
auditpol /set /subcategory:"Process Creation" /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Logon" /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"User Account Management" /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Security Group Management" /success:enable /failure:enable | Out-Null

# Log full command lines in Event ID 4688
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" `
    -Name "ProcessCreationIncludeCmdLine_Enabled" -Value 1 -Type DWord

# Install or update Sysmon if bundled in binaries\
$SysmonExe = Join-Path $StageDir "binaries\Sysmon64.exe"
$SysmonCfg = Join-Path $StageDir "sysmonconfig.xml"

if (Test-Path -LiteralPath $SysmonExe) {
    $sysmonSvc = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
    if ($sysmonSvc) {
        Write-Host "====> Sysmon already installed; updating rules"
        if (Test-Path -LiteralPath $SysmonCfg) {
            & $SysmonExe -c $SysmonCfg
        }
    } else {
        Write-Host "====> Installing Sysmon64"
        if (Test-Path -LiteralPath $SysmonCfg) {
            & $SysmonExe -accepteula -i $SysmonCfg
        } else {
            & $SysmonExe -accepteula -i
        }
    }
} else {
    Write-Warning "binaries\Sysmon64.exe not found; relying on native Windows Audit Policy."
}

# ############################
# Deploying watchdawg
# ############################
Write-Host "==> Deploying watchdawg" -ForegroundColor Cyan
$KernelDir = "C:\ProgramData\kernel"
New-Item -ItemType Directory -Path $KernelDir -Force | Out-Null

$WdScriptDest  = Join-Path $KernelDir "Watchdawg.ps1"
$WdSourcesDest = Join-Path $KernelDir "sources"
$WdInitState   = Join-Path $KernelDir "init-state"
$WdOutLog      = Join-Path $KernelDir "out.log"

if (Test-Path -LiteralPath (Join-Path $StageDir "Watchdawg.ps1")) {
    Move-Item -LiteralPath (Join-Path $StageDir "Watchdawg.ps1") -Destination $WdScriptDest -Force
}
if (Test-Path -LiteralPath (Join-Path $StageDir "watchdawg-sources.txt")) {
    Move-Item -LiteralPath (Join-Path $StageDir "watchdawg-sources.txt") -Destination $WdSourcesDest -Force
}

# Launch Watchdawg detached in the background (nohup ... & equivalent)
Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$WdScriptDest`" `"$WdInitState`" `"$WdSourcesDest`"" `
    -WindowStyle Hidden `
    -RedirectStandardOutput $WdOutLog `
    -RedirectStandardError (Join-Path $KernelDir "err.log")

Write-Host "[+] Watchdawg launched in background (log: $WdOutLog)"

# ############################
# Setting up trusted static tools (busybox equivalent)
# ############################
Write-Host "==> Deploying trusted static binaries (Sysinternals/tools)" -ForegroundColor Cyan
$ToolsDest = "C:\ProgramData\trusted-bin"
$BinSource = Join-Path $StageDir "binaries"

if (Test-Path -LiteralPath $BinSource) {
    New-Item -ItemType Directory -Path $ToolsDest -Force | Out-Null
    Copy-Item -Path (Join-Path $BinSource "*") -Destination $ToolsDest -Recurse -Force

    # Prepend to Machine PATH so clean binaries take priority
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($currentPath -notlike "*$ToolsDest*") {
        [Environment]::SetEnvironmentVariable("Path", "$ToolsDest;$currentPath", "Machine")
        $env:Path = "$ToolsDest;$env:Path"
    }
    Write-Host "[DONE] Open a new shell session to pick up updated PATH"
}

# ############################
# Running Autofirewall.ps1 (strict lockdown)
# ############################
Write-Host "Starting Autofirewall.ps1" -ForegroundColor Cyan
& (Join-Path $StageDir "Autofirewall.ps1") 2>&1 | Tee-Object -FilePath (Join-Path $LogDir "autofirewall.log")
Write-Host "Finished Autofirewall.ps1"

# ############################
# Running Harden.ps1
# ############################
Write-Host "Starting Harden.ps1" -ForegroundColor Cyan
& (Join-Path $StageDir "Harden.ps1") -Password $Password 2>&1 | Tee-Object -FilePath (Join-Path $LogDir "harden.log")
Write-Host "Finished Harden.ps1"

Write-Host "`nFinished activation script" -ForegroundColor Green
Write-Host "Check out the baselining scripts Standard.ps1 and Specific.ps1"
