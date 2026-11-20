#Requires -RunAsAdministrator
param(
    [Parameter(Position = 0)]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$SnapshotName
)

$ErrorActionPreference = "Continue"

$BackupDir = "C:\ProgramData\bk"
$LogDir    = "C:\ProgramData\.log"
$LogFile   = Join-Path $LogDir "backup.log"
$SourcesFile = Join-Path $BackupDir "sources.txt"

$script:Snapshot = "default"
$script:Extended = $false

# Create backup & log directories
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# Restrict backup directory permissions to Administrators and SYSTEM (chmod 700 equivalent)
icacls $BackupDir /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" /Q | Out-Null

# Default Windows competition config paths (equivalent to /etc, /var/www, systemd, etc.)
if (-not (Test-Path -LiteralPath $SourcesFile)) {
    @(
        "C:\Windows\System32\drivers\etc"
        "C:\Windows\System32\inetsrv\config"
        "C:\inetpub\wwwroot"
        "C:\ProgramData\ssh"
        "C:\Windows\System32\Tasks"
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
        "C:\Windows\System32\GroupPolicy"
    ) | Set-Content -LiteralPath $SourcesFile
}

function Get-SnapshotRelPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    return ($full -replace '^([A-Za-z]):\\', '$1\')
}

function Assert-SnapshotNotExists {
    $snapPath = Join-Path $BackupDir $script:Snapshot
    if (Test-Path -LiteralPath $snapPath) {
        Write-Error "[ERROR] Snapshot '$($script:Snapshot)' already exists. Pick another name, or delete it first."
        exit 1
    }
}

function Test-DiskSpace {
    $needBytes = 0L
    foreach ($src in Get-Content -LiteralPath $SourcesFile) {
        $src = $src.Trim()
        if ([string]::IsNullOrWhiteSpace($src) -or -not (Test-Path -LiteralPath $src -PathType Container)) { continue }
        $sum = (Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($sum) { $needBytes += $sum }
    }
    $needBytes *= 2

    $driveLetter = ([System.IO.Path]::GetPathRoot($BackupDir)).Substring(0, 1)
    $freeBytes = (Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue).Free
    if ($null -eq $freeBytes) { return }

    if ($needBytes -gt $freeBytes) {
        $needMB = [math]::Ceiling($needBytes / 1MB)
        $freeMB = [math]::Ceiling($freeBytes / 1MB)
        Write-Host "== WARNING: snapshot needs about $needMB MB, only $freeMB MB free on $BackupDir ==" -ForegroundColor Yellow
    }
}

function Invoke-Backup {
    Write-Host "========================`nRUNNING BACKUP`n========================" -ForegroundColor Cyan
    Test-DiskSpace

    $snapRoot = Join-Path $BackupDir $script:Snapshot
    New-Item -ItemType Directory -Path $snapRoot -Force | Out-Null

    # 1. Filesystem backup (robocopy handles locked files and preserves timestamps cleanly)
    foreach ($src in Get-Content -LiteralPath $SourcesFile) {
        $src = $src.Trim()
        if ([string]::IsNullOrWhiteSpace($src) -or -not (Test-Path -LiteralPath $src -PathType Container)) { continue }
        $dest = Join-Path (Join-Path $snapRoot "filesystem") (Get-SnapshotRelPath $src)
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        robocopy $src $dest /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
    }

    # 2. Processes and services
    Get-CimInstance Win32_Process |
        Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine |
        Format-Table -AutoSize | Out-String -Width 4096 |
        Set-Content (Join-Path $snapRoot "processes-list.txt")

    Get-Service | Where-Object { $_.Status -eq 'Running' } |
        Select-Object Name, DisplayName, StartType, Status |
        Format-Table -AutoSize | Out-String -Width 4096 |
        Set-Content (Join-Path $snapRoot "services-active_running.txt")

    Get-Service | Where-Object { $_.StartType -eq 'Automatic' } |
        Select-Object Name, DisplayName, StartType, Status |
        Format-Table -AutoSize | Out-String -Width 4096 |
        Set-Content (Join-Path $snapRoot "services-enabled_autostart.txt")

    Get-Service |
        Select-Object Name, DisplayName, StartType, Status |
        Format-Table -AutoSize | Out-String -Width 4096 |
        Set-Content (Join-Path $snapRoot "services-all.txt")

    # 3. Installed software / packages
    $uninstallPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher |
        Sort-Object DisplayName |
        Format-Table -AutoSize | Out-String -Width 4096 |
        Set-Content (Join-Path $snapRoot "packages.txt")

    # 4. Ports and firewall
    $tcp = Get-NetTCPConnection -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess
    $udp = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess
    @("=== TCP ===", ($tcp | Format-Table -AutoSize | Out-String -Width 4096),
      "=== UDP ===", ($udp | Format-Table -AutoSize | Out-String -Width 4096)) |
        Set-Content (Join-Path $snapRoot "listeningports.txt")

    netsh advfirewall export (Join-Path $snapRoot "firewall.wfw") | Out-Null
    Get-NetFirewallRule -Enabled True |
        Select-Object DisplayName, Direction, Action, Profile, Group |
        Format-Table -AutoSize | Out-String -Width 4096 |
        Set-Content (Join-Path $snapRoot "firewallrules.txt")

    # 5. Kernel drivers (lsmod equivalent)
    driverquery /v > (Join-Path $snapRoot "kerneldrivers.txt")

    # 6. Extended baseline fields
    if ($script:Extended) {
        Get-ChildItem Env: | Format-Table -AutoSize | Out-String -Width 4096 |
            Set-Content (Join-Path $snapRoot "environmentalvariables.txt")

        Get-LocalUser | Select-Object Name, Enabled, LastLogon, PasswordLastSet |
            Format-Table -AutoSize | Out-String -Width 4096 |
            Set-Content (Join-Path $snapRoot "localusers.txt")

        Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
            Format-Table -AutoSize | Out-String -Width 4096 |
            Set-Content (Join-Path $snapRoot "localadmins.txt")

        Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' } |
            Select-Object TaskPath, TaskName, State |
            Format-Table -AutoSize | Out-String -Width 4096 |
            Set-Content (Join-Path $snapRoot "scheduledtasks.txt")
    }

    # Date taken
    (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") | Set-Content (Join-Path $snapRoot "date_taken")

    # 7. Compress backup
    Write-Host "== Archiving directory... =="
    $archiveDir = Join-Path $BackupDir "archives"
    New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null

    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        $archiveFile = Join-Path $archiveDir "$($script:Snapshot).tar.gz"
        tar.exe -czf $archiveFile -C $BackupDir $script:Snapshot
    } else {
        $archiveFile = Join-Path $archiveDir "$($script:Snapshot).zip"
        Compress-Archive -Path $snapRoot -DestinationPath $archiveFile -Force
    }
    icacls $archiveFile /inheritance:r /grant:r "Administrators:F" "SYSTEM:F" /Q | Out-Null

    Write-Host "============`nBACKUP COMPLETED`n============" -ForegroundColor Green
}

function Invoke-Restore {
    Write-Host "========================`nRUNNING RESTORE`n========================" -ForegroundColor Cyan
    $snapRoot = Join-Path $BackupDir $script:Snapshot
    $fsRoot   = Join-Path $snapRoot "filesystem"

    if (-not (Test-Path -LiteralPath $fsRoot -PathType Container)) {
        Write-Host "============`nINVALID SNAPSHOT, RESTORE FAILED`n============" -ForegroundColor Red
        return
    }

    Write-Host "Please note that restore only applies to files"
    $extrasFile = Join-Path $snapRoot "restore-extras.txt"
    $extrasList = [System.Collections.Generic.List[string]]::new()

    foreach ($src in Get-Content -LiteralPath $SourcesFile) {
        $src = $src.Trim()
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        $dest = Join-Path $fsRoot (Get-SnapshotRelPath $src)
        if (-not (Test-Path -LiteralPath $dest -PathType Container)) { continue }

        # Record files present live that were NOT in the snapshot
        if (Test-Path -LiteralPath $src -PathType Container) {
            $snapFiles = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Substring($dest.Length) })
            $liveFiles = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Substring($src.Length) })

            $diff = Compare-Object -ReferenceObject $snapFiles -DifferenceObject $liveFiles |
                Where-Object { $_.SideIndicator -eq '=>' }

            foreach ($item in $diff) {
                $extrasList.Add("$src$($item.InputObject)")
            }
        }

        # Restore files from snapshot back to live path
        robocopy $dest $src /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
    }

    if ($extrasList.Count -gt 0) {
        Set-Content -LiteralPath $extrasFile -Value $extrasList
        Write-Host "== Present now but NOT in the snapshot, and NOT removed: ==" -ForegroundColor Yellow
        $extrasList | ForEach-Object { Write-Host $_ }
        Write-Host "== Saved to $extrasFile =="
    }

    Write-Host "============`nRESTORE COMPLETED`n============" -ForegroundColor Green
}

# --------------------------------------------------
# Main Dispatch (CLI args vs Interactive Menu)
# --------------------------------------------------
if ($Action -eq "backup") {
    $script:Snapshot = if ($SnapshotName) { $SnapshotName } else { "auto-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    Assert-SnapshotNotExists
    Invoke-Backup 2>&1 | Tee-Object -FilePath $LogFile -Append
}
elseif ($Action -eq "restore") {
    if ([string]::IsNullOrWhiteSpace($SnapshotName)) {
        Write-Host "No restore name given, exiting."
    } else {
        $script:Snapshot = $SnapshotName
        Invoke-Restore 2>&1 | Tee-Object -FilePath $LogFile -Append
    }
}
elseif ($Action -eq "baseline") {
    $script:Snapshot = "baseline"
    $script:Extended = $true
    $oldBaseline = Join-Path $BackupDir $script:Snapshot
    if (Test-Path -LiteralPath $oldBaseline) {
        Remove-Item -LiteralPath $oldBaseline -Recurse -Force
    }
    Invoke-Backup 2>&1 | Tee-Object -FilePath $LogFile -Append

    $tarSrc = Join-Path $BackupDir "archives\baseline.tar.gz"
    if (Test-Path -LiteralPath $tarSrc) {
        Copy-Item -LiteralPath $tarSrc -Destination "C:\ProgramData\baseline.tar.gz" -Force
    }
}
else {
    Write-Host "Welcome to the backup toolkit, choose an option:`n [1] Create new backup`n [2] Restore backup`n [3] Exit"
    $option = Read-Host

    if ($option -eq "1") {
        $script:Snapshot = Read-Host "Name the backup"
        Assert-SnapshotNotExists
        Invoke-Backup 2>&1 | Tee-Object -FilePath $LogFile -Append
    }
    elseif ($option -eq "2") {
        Write-Host "Choose a backup to restore from:"
        Get-ChildItem -LiteralPath $BackupDir -Directory | Where-Object { $_.Name -ne "archives" } | ForEach-Object {
            $dateFile = Join-Path $_.FullName "date_taken"
            $saveDate = if (Test-Path $dateFile) { Get-Content $dateFile -First 1 } else { "unknown date" }
            Write-Host "> $($_.Name) saved on $saveDate"
        }
        $script:Snapshot = Read-Host "restore from"
        Invoke-Restore 2>&1 | Tee-Object -FilePath $LogFile -Append
    }
    else {
        Write-Host "Exiting"
    }
}
