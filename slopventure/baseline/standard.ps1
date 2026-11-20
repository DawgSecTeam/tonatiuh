#Requires -RunAsAdministrator
$ErrorActionPreference = "Continue"

# Enable session logging
$LogDir = "C:\ProgramData\.log"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir "baseline-standard.log"
Start-Transcript -Path $LogFile -Append | Out-Null

Write-Host "▗▄▄▖  ▗▄▖  ▗▄▄▖▗▄▄▄▖▗▖   ▗▄▄▄▖▗▖  ▗▖▗▄▄▄▖     ▗▄▄▖▗▄▄▄▖▗▄▖ ▗▖  ▗▖▗▄▄▄  ▗▄▖ ▗▄▄▖ ▗▄▄▄ "
Write-Host "▐▌ ▐▌▐▌ ▐▌▐▌   ▐▌   ▐▌     █  ▐▛▚▖▐▌▐▌       ▐▌     █ ▐▌ ▐▌▐▛▚▖▐▌▐▌  █▐▌ ▐▌▐▌ ▐▌▐▌  █"
Write-Host "▐▛▀▚▖▐▛▀▜▌ ▝▀▚▖▐▛▀▀▘▐▌     █  ▐▌ ▝▜▌▐▛▀▀▘     ▝▀▚▖  █ ▐▛▀▜▌▐▌ ▝▜▌▐▌  █▐▛▀▜▌▐▛▀▚▖▐▌  █"
Write-Host "▐▙▄▞▘▐▌ ▐▌▗▄▄▞▘▐▙▄▄▖▐▙▄▄▖▗▄█▄▖▐▌  ▐▌▐▙▄▄▖    ▗▄▄▞▘  █ ▐▌ ▐▌▐▌  ▐▌▐▙▄▄▀▐▌ ▐▌▐▌ ▐▌▐▙▄▄▀`n"
Write-Host " ==================================================================== v0.1.2 (Win) ===`n"

function Wait-Interact {
    Read-Host "Press Enter to continue" | Out-Null
}

# 1. General System Info
Write-Host "GENERAL SYSTEM INFO" -ForegroundColor White
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime | Format-List

Wait-Interact

# 2. Preloaded DLLs / IFEO Debugger Hijacks (LD_PRELOAD equivalent)
Write-Host "Checking AppInit_DLLs and IFEO Debugger hijacks" -ForegroundColor Cyan
$appInitPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Windows"
)
foreach ($p in $appInitPaths) {
    $props = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
    if ($props.AppInit_DLLs) {
        Write-Host "[!] AppInit_DLLs set in ${p}: $($props.AppInit_DLLs)" -ForegroundColor Red
    }
}
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options" -ErrorAction SilentlyContinue | ForEach-Object {
    $dbg = (Get-ItemProperty $_.PSPath -Name Debugger -ErrorAction SilentlyContinue).Debugger
    if ($dbg) { Write-Host "[!] IFEO Debugger on $($_.PSChildName): $dbg" -ForegroundColor Red }
}

Wait-Interact

# 3. PATH variable
Write-Host "Showing PATH variable (check for suspicious dirs)" -ForegroundColor Cyan
$env:Path -split ';'

Wait-Interact

# 4. System time
Write-Host "Is this system time correct?" -ForegroundColor Yellow
Get-Date
Get-TimeZone

Wait-Interact

# 5. Open ports & owning processes
Write-Host "Checking listening ports and owning processes" -ForegroundColor Cyan
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, OwningProcess, @{N='Process';E={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName}} |
    Sort-Object LocalPort | Format-Table -AutoSize

Wait-Interact

# 6. Firewall status & enabled rules
Write-Host "Checking Windows Firewall profiles" -ForegroundColor Cyan
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction | Format-Table -AutoSize

Wait-Interact

# 7. Privileged users & blank-password checks
Write-Host "Listing privileged groups (Administrators, RDP, WinRM)" -ForegroundColor Yellow
foreach ($grp in @("Administrators", "Remote Desktop Users", "Remote Management Users")) {
    Write-Host "=== $grp ===" -ForegroundColor Yellow
    Get-LocalGroupMember -Group $grp -ErrorAction SilentlyContinue | Select-Object Name, ObjectClass, PrincipalSource | Format-Table -AutoSize
}

Write-Host "Checking for accounts without password required or never set" -ForegroundColor Cyan
Get-LocalUser | Where-Object { $_.Enabled -and (-not $_.PasswordRequired -or $null -eq $_.PasswordLastSet) } |
    Select-Object Name, Enabled, PasswordRequired, PasswordLastSet | Format-Table -AutoSize

$blankPolicy = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name LimitBlankPasswordUse -ErrorAction SilentlyContinue).LimitBlankPasswordUse
if ($blankPolicy -eq 0) {
    Write-Host "[!] LimitBlankPasswordUse is DISABLED (0) - blank passwords allowed over network!" -ForegroundColor Red
}

Wait-Interact

# 8. Authorized SSH keys (if OpenSSH is used)
Write-Host "Showing authorized SSH keys" -ForegroundColor Cyan
$adminKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
if (Test-Path $adminKeys) {
    Write-Host "=== Administrators ==="
    Get-Content $adminKeys
}
Get-ChildItem "C:\Users\*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $k = Join-Path $_.FullName ".ssh\authorized_keys"
    if (Test-Path $k) {
        Write-Host "=== User: $($_.Name) ==="
        Get-Content $k
    }
}

Wait-Interact

# 9. Startup persistence (Run keys + Startup folders)
Write-Host "Checking Registry Run keys and Startup folders" -ForegroundColor Yellow
$runKeys = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
)
foreach ($rk in $runKeys) {
    if (Test-Path $rk) {
        Write-Host "=== $rk ==="
        Get-ItemProperty $rk | Format-List
    }
}
Get-ChildItem "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup", "C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup" -Force -ErrorAction SilentlyContinue

Wait-Interact

# 10. Suspicious processes
Write-Host "Searching for suspicious processes (shells, netcat, scripting engines)" -ForegroundColor Cyan
Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match '^(nc|ncat|netcat|cmd|powershell|pwsh|python|perl|wscript|cscript|mshta|certutil|bitsadmin)' } |
    Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize

Wait-Interact

# 11. Non-Microsoft Scheduled Tasks (cron / systemd timers equivalent)
Write-Host "Showing active non-Microsoft Scheduled Tasks" -ForegroundColor Cyan
Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' } |
    Select-Object TaskPath, TaskName, State, @{N='Action';E={$_.Actions.Execute + ' ' + $_.Actions.Arguments}} |
    Format-Table -AutoSize

Wait-Interact

# 12. Docker / Podman containers
Write-Host "Checking Docker/Podman containers" -ForegroundColor Cyan
if (Get-Command docker -ErrorAction SilentlyContinue) { docker ps -a }
elseif (Get-Command podman -ErrorAction SilentlyContinue) { podman ps -a }
else { Write-Host "Neither Docker nor Podman found." }

Wait-Interact

# 13. Common Windows comp vulnerabilities (SMBv1 & Print Spooler)
Write-Host "Checking SMBv1 and Print Spooler status" -ForegroundColor Cyan
$smb1 = (Get-SmbServerConfiguration -ErrorAction SilentlyContinue).EnableSMB1Protocol
if ($smb1) { Write-Host "[!] SMBv1 is ENABLED! Run: Set-SmbServerConfiguration -EnableSMB1Protocol `$false -Force" -ForegroundColor Red }
$spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
if ($spooler -and $spooler.Status -eq 'Running') {
    Write-Host "[!] Print Spooler is RUNNING (PrintNightmare risk if unpatched/unneeded)" -ForegroundColor Yellow
}

Wait-Interact

# 14. Suspicious executables/scripts in webroot & Temp
Write-Host "Checking for executables/scripts in C:\inetpub\wwwroot and C:\Windows\Temp" -ForegroundColor Cyan
Get-ChildItem -Path "C:\inetpub\wwwroot", "C:\Windows\Temp" -Include *.exe,*.dll,*.ps1,*.bat,*.vbs,*.aspx,*.php -Recurse -Force -ErrorAction SilentlyContinue |
    Select-Object FullName, LastWriteTime | Format-Table -AutoSize

Wait-Interact

# 15. Launch WinPEAS in background (linpeas equivalent)
$WinPeas = "C:\ProgramData\trusted-bin\winPEASx64.exe"
if (-not (Test-Path $WinPeas)) { $WinPeas = Join-Path (Split-Path -Parent $PSScriptRoot) "binaries\winPEASx64.exe" }

if (Test-Path $WinPeas) {
    Write-Host "Starting WinPEAS in background -> C:\ProgramData\winpeas.txt" -ForegroundColor Cyan
    Start-Process -FilePath $WinPeas -WindowStyle Hidden -RedirectStandardOutput "C:\ProgramData\winpeas.txt"
} else {
    Write-Host "winPEASx64.exe not found in binaries\; skipping." -ForegroundColor Yellow
}

Write-Host "`nDone. Check the tool output files once they finish scanning." -ForegroundColor Green
Stop-Transcript | Out-Null
