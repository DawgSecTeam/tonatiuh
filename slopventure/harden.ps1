#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Password,

    # Accounts to keep enabled and permitted in Administrators
    [string[]]$AllowedUsers = @("bluey", "Administrator"),

    # Optional: enable system-wide PowerShell Constrained Language Mode (closest lightweight rbash equivalent)
    [switch]$LockdownPowerShell
)

$ErrorActionPreference = "Stop"

# Safety check: LocalAccounts cmdlets do not apply to Domain Controllers
$domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
if ($domainRole -ge 4) {
    Write-Error "[x] This host is a Domain Controller (DomainRole $domainRole). Use an Active Directory hardening script instead."
    exit 1
}

# --------------------------------------------------
# 1. Backup current account & security state
# --------------------------------------------------
Write-Host -NoNewline "Backing up local accounts and security policy..."
$BackupDir = "C:\ProgramData\.harden_backup"
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

Get-LocalUser | Export-Clixml (Join-Path $BackupDir "local_users.xml")
Get-LocalGroupMember -Group "Administrators" | Export-Clixml (Join-Path $BackupDir "local_admins.xml")
secedit /export /cfg (Join-Path $BackupDir "secpol.cfg") /quiet
Write-Host " [DONE]" -ForegroundColor Green

# --------------------------------------------------
# 2. Provision 'bluey' admin account
# --------------------------------------------------
$SecurePass = ConvertTo-SecureString $Password -AsPlainText -Force
$existingBluey = Get-LocalUser -Name "bluey" -ErrorAction SilentlyContinue

if ($existingBluey) {
    Set-LocalUser -Name "bluey" -Password $SecurePass -PasswordNeverExpires $true
    Enable-LocalUser -Name "bluey"
    Write-Host "[*] Updated existing user 'bluey'"
} else {
    New-LocalUser -Name "bluey" -Password $SecurePass -FullName "Blue Team" `
        -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    Write-Host "[+] Added user 'bluey'"
}

# Clean up bluey's profile directory if it already exists
if (Test-Path "C:\Users\bluey") {
    Get-ChildItem -Path "C:\Users\bluey" -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[*] Cleaned up C:\Users\bluey"
}

# Add bluey to Administrators (sudo/wheel equivalent)
Add-LocalGroupMember -Group "Administrators" -Member "bluey" -ErrorAction SilentlyContinue
Write-Host "[+] Added 'bluey' to Administrators group"

# --------------------------------------------------
# 3. Strip unauthorized Admins & RDP/WinRM users
# --------------------------------------------------
$PrivilegedGroups = @("Administrators", "Remote Desktop Users", "Remote Management Users")

foreach ($group in $PrivilegedGroups) {
    $members = Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue
    foreach ($member in $members) {
        # Strip machine prefix (e.g., "HOST\username" -> "username")
        $shortName = $member.Name.Split('\')[-1]
        if ($shortName -notin $AllowedUsers) {
            Remove-LocalGroupMember -Group $group -Member $member.Name -ErrorAction SilentlyContinue
            Write-Host "[-] Removed '$($member.Name)' from $group" -ForegroundColor Yellow
        }
    }
}

# --------------------------------------------------
# 4. Disable all local accounts not in AllowedUsers
# --------------------------------------------------
foreach ($user in Get-LocalUser) {
    if ($user.Name -in $AllowedUsers) {
        continue
    }
    if ($user.Enabled) {
        Disable-LocalUser -Name $user.Name -ErrorAction SilentlyContinue
        Write-Host "[-] Disabled account: $($user.Name)" -ForegroundColor Yellow
    }
}

# --------------------------------------------------
# 5. Shell restriction (rbash / /rbin equivalent)
# --------------------------------------------------
if ($LockdownPowerShell) {
    # Forces PowerShell into Constrained Language Mode for non-elevated/non-trusted sessions
    [Environment]::SetEnvironmentVariable("__PSLockdownPolicy", "4", "Machine")
    Write-Host "[+] Enabled PowerShell Constrained Language Mode (__PSLockdownPolicy=4)" -ForegroundColor Cyan
}

# --------------------------------------------------
# 6. Securely wipe temporary password files (shred -uf /var/tmp/pass_*)
# --------------------------------------------------
$PassFiles = Get-ChildItem -Path @("C:\ProgramData\pass_*", "$env:TEMP\pass_*") -File -ErrorAction SilentlyContinue
foreach ($file in $PassFiles) {
    try {
        $len = $file.Length
        if ($len -gt 0) {
            $rand = New-Object byte[] $len
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rand)
            [System.IO.File]::WriteAllBytes($file.FullName, $rand)
        }
        Remove-Item -LiteralPath $file.FullName -Force
        Write-Host "[*] Shredded $($file.FullName)"
    } catch {
        Write-Warning "Failed to shred $($file.FullName): $_"
    }
}

Write-Host "[+] Hardening complete." -ForegroundColor Green
