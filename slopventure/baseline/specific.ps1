#Requires -RunAsAdministrator
param(
    [string]$CleanArchive
)

$ErrorActionPreference = "Continue"

# Enable session logging
$LogDir = "C:\ProgramData\.log"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir "baseline-specific.log"
Start-Transcript -Path $LogFile -Append | Out-Null

Write-Host "▗▄▄▖  ▗▄▖  ▗▄▄▖▗▄▄▄▖▗▖   ▗▄▄▄▖▗▖  ▗▖▗▄▄▄▖     ▗▄▄▖▗▄▄▖ ▗▄▄▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▄▄▖ ▗▄▄▖"
Write-Host "▐▌ ▐▌▐▌ ▐▌▐▌   ▐▌   ▐▌     █  ▐▛▚▖▐▌▐▌       ▐▌   ▐▌ ▐▌▐▌   ▐▌     █  ▐▌     █  ▐▌   "
Write-Host "▐▛▀▚▖▐▛▀▜▌ ▝▀▚▖▐▛▀▀▘▐▌     █  ▐▌ ▝▜▌▐▛▀▀▘     ▝▀▚▖▐▛▀▘ ▐▛▀▀▘▐▌     █  ▐▛▀▀▘  █  ▐▌   "
Write-Host "▐▙▄▞▘▐▌ ▐▌▗▄▄▞▘▐▙▄▄▖▐▙▄▄▖▗▄█▄▖▐▌  ▐▌▐▙▄▄▖    ▗▄▄▞▘▐▌   ▐▙▄▄▖▝▚▄▄▖▗▄█▄▖▐▌   ▗▄█▄▖▝▚▄▄▖`n"
Write-Host " ==================================================================== v0.1.2 (Win) ===`n"

function Wait-Interact {
    Read-Host "Press Enter to continue" | Out-Null
}

function Show-Diff {
    param([string]$Title, [string]$CleanPath, [string]$DirtyPath)
    Write-Host "==> $Title" -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $CleanPath) -or -not (Test-Path -LiteralPath $DirtyPath)) {
        Write-Host "    [!] Missing file on one side: Clean=$(Test-Path $CleanPath), Dirty=$(Test-Path $DirtyPath)" -ForegroundColor Yellow
        return
    }

    $diff = Compare-Object `
        -ReferenceObject (Get-Content -LiteralPath $CleanPath) `
        -DifferenceObject (Get-Content -LiteralPath $DirtyPath)

    if (-not $diff) {
        Write-Host "    [OK] No differences found." -ForegroundColor Green
    } else {
        $diff | ForEach-Object {
            if ($_.SideIndicator -eq "=>") { "[DIRTY +] $($_.InputObject)" }
            else { "[CLEAN -] $($_.InputObject)" }
        } | Out-Host -Paging
    }
}

# 1. Run baseline collection on this compromised system
Write-Host "==> Running baseline collection on this compromised system" -ForegroundColor Cyan
$BackupScript = Join-Path (Split-Path -Parent $PSScriptRoot) "Backup.ps1"
& $BackupScript "baseline"

# 2. Locate clean archive (mirrors /var/tmp/*/baseline.tar.gz)
if (-not $CleanArchive) {
    $found = Get-ChildItem -Path "C:\ProgramData\*\baseline.tar.gz" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $CleanArchive = $found.FullName }
}

$DirtyArchive = "C:\ProgramData\baseline.tar.gz"
if (-not $CleanArchive -or -not (Test-Path -LiteralPath $CleanArchive)) {
    Write-Error "[x] Clean baseline archive not found. Pass -CleanArchive <path> or place it in C:\ProgramData\<folder>\baseline.tar.gz"
    Stop-Transcript | Out-Null
    exit 1
}

# 3. Decompress clean & dirty archives
Write-Host "==> Decompressing files" -ForegroundColor Cyan
$CleanRoot = "C:\ProgramData\sys-clean"
$DirtyRoot = "C:\ProgramData\sys-dirty"
Remove-Item -Path $CleanRoot, $DirtyRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $CleanRoot, $DirtyRoot -Force | Out-Null

tar.exe -xzf $CleanArchive -C $CleanRoot
tar.exe -xzf $DirtyArchive -C $DirtyRoot

$Clean = Join-Path $CleanRoot "baseline"
$Dirty = Join-Path $DirtyRoot "baseline"

Write-Host "`n==> Starting interactive baselining script." -ForegroundColor Cyan
Write-Host "    [CLEAN -] = only on clean box | [DIRTY +] = added/changed on this box`n"

Wait-Interact
Show-Diff "Kernel Drivers" (Join-Path $Clean "kerneldrivers.txt") (Join-Path $Dirty "kerneldrivers.txt")

Wait-Interact
Show-Diff "Active Running Services" (Join-Path $Clean "services-active_running.txt") (Join-Path $Dirty "services-active_running.txt")
Show-Diff "Autostart Services" (Join-Path $Clean "services-enabled_autostart.txt") (Join-Path $Dirty "services-enabled_autostart.txt")

Wait-Interact
Show-Diff "Installed Packages" (Join-Path $Clean "packages.txt") (Join-Path $Dirty "packages.txt")

Wait-Interact
Show-Diff "Local Users" (Join-Path $Clean "localusers.txt") (Join-Path $Dirty "localusers.txt")
Show-Diff "Local Administrators" (Join-Path $Clean "localadmins.txt") (Join-Path $Dirty "localadmins.txt")
Show-Diff "Scheduled Tasks" (Join-Path $Clean "scheduledtasks.txt") (Join-Path $Dirty "scheduledtasks.txt")

Wait-Interact
Show-Diff "Open Ports" (Join-Path $Clean "listeningports.txt") (Join-Path $Dirty "listeningports.txt")

Wait-Interact
Show-Diff "Environment Variables" (Join-Path $Clean "environmentalvariables.txt") (Join-Path $Dirty "environmentalvariables.txt")

Wait-Interact
Show-Diff "Firewall Rules" (Join-Path $Clean "firewallrules.txt") (Join-Path $Dirty "firewallrules.txt")

Wait-Interact
Write-Host "`nDone with basic baselining." -ForegroundColor Green
Write-Host "Exit now (Ctrl+C) or press Enter to diff all backed-up filesystem files (hosts, IIS, Tasks, SSH, Startup)."
Wait-Interact

Write-Host "==> Diffing backed-up filesystem trees..." -ForegroundColor Cyan
$cleanFs = Join-Path $Clean "filesystem"
$dirtyFs = Join-Path $Dirty "filesystem"

$cleanFiles = Get-ChildItem -Path $cleanFs -File -Recurse -Force -ErrorAction SilentlyContinue
$dirtyFiles = Get-ChildItem -Path $dirtyFs -File -Recurse -Force -ErrorAction SilentlyContinue

$cleanMap = @{}
foreach ($f in $cleanFiles) { $cleanMap[$f.FullName.Substring($cleanFs.Length)] = (Get-FileHash $f.FullName -Algorithm SHA256).Hash }

foreach ($f in $dirtyFiles) {
    $rel = $f.FullName.Substring($dirtyFs.Length)
    $hash = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    if (-not $cleanMap.ContainsKey($rel)) {
        Write-Host "[NEW FILE] $rel" -ForegroundColor Red
    } elseif ($cleanMap[$rel] -ne $hash) {
        Write-Host "[MODIFIED] $rel" -ForegroundColor Yellow
    }
}

Stop-Transcript | Out-Null
