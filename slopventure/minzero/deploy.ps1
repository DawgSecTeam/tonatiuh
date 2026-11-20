#Requires -RunAsAdministrator
param(
    [string]$HostFile = (Join-Path $PSScriptRoot "hostfile"),
    [int]$ThrottleLimit = 10,
    [switch]$TrustAllHosts
)

$ErrorActionPreference = "Continue"
$RootDir    = Split-Path -Parent $PSScriptRoot
$SystemsDir = Join-Path $RootDir "systems"
$LogFile    = Join-Path $PSScriptRoot "deploy.log"
$Archive    = Join-Path $PSScriptRoot "resources.zip"

Start-Transcript -Path $LogFile -Append | Out-Null
Write-Host "=== Starting deployment script ===" -ForegroundColor Cyan

# Workgroup/IP-based WinRM requires target IPs in TrustedHosts
if ($TrustAllHosts) {
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
    Write-Host "[*] Configured WSMan TrustedHosts = *" -ForegroundColor Yellow
}

# --------------------------------------------------
# 1. Compress resources (mirrors resources.tar.gz)
# --------------------------------------------------
Write-Host "=== Compressing resources ===" -ForegroundColor Cyan
if (Test-Path -LiteralPath $Archive) { Remove-Item -LiteralPath $Archive -Force }

$ResourceItems = @(
    "Harden.ps1",
    "Autofirewall.ps1",
    "Activate.ps1",
    "AngryC2Scanner.ps1",
    "Backup.ps1",
    "Watchdawg.ps1",
    "watchdawg-sources.txt",
    "sysmonconfig.xml",
    "binaries",
    "baseline"
) | ForEach-Object { Join-Path $RootDir $_ } | Where-Object { Test-Path -LiteralPath $_ }

Compress-Archive -Path $ResourceItems -DestinationPath $Archive -Force
Write-Host "[+] Created $Archive ($($ResourceItems.Count) items)" -ForegroundColor Green

# --------------------------------------------------
# 2. Parse hostfile (ignore comments & blank lines)
# --------------------------------------------------
if (-not (Test-Path -LiteralPath $HostFile)) {
    Write-Error "[x] Hostfile not found at $HostFile"
    Stop-Transcript | Out-Null
    exit 1
}

$Targets = Get-Content -LiteralPath $HostFile |
    Where-Object { $_ -notmatch '^\s*#' -and -not [string]::IsNullOrWhiteSpace($_) }

Write-Host "=== Running deploy across $($Targets.Count) hosts (max $ThrottleLimit parallel) ===" -ForegroundColor Cyan

# --------------------------------------------------
# 3. Per-host deployment scriptblock
# --------------------------------------------------
$DeployBlock = {
    param($Line, $ArchivePath, $SystemsPath)

    $parts = $Line.Trim() -split '\s+'
    if ($parts.Count -lt 5) {
        Write-Output "[ERROR] Malformed hostfile line: $Line"
        return
    }

    $Dir     = $parts[0]
    $IP      = $parts[1]
    $User    = $parts[2]
    $OldPass = $parts[3]
    $NewPass = $parts[4]

    Write-Output "[$Dir] Begin system $IP with user $User"

    try {
        $secPass = ConvertTo-SecureString $OldPass -AsPlainText -Force
        $cred    = New-Object System.Management.Automation.PSCredential($User, $secPass)

        # Open WinRM session
        $sess = New-PSSession -ComputerName $IP -Credential $cred -ErrorAction Stop

        # Create remote staging & logging directories
        Invoke-Command -Session $sess -ScriptBlock {
            New-Item -ItemType Directory -Path "C:\ProgramData\qz-stage", "C:\ProgramData\.log" -Force | Out-Null
        } | Out-Null

        # Transfer resources.zip, port-sources, and system-specific folder (e.g., clean baseline.tar.gz)
        Copy-Item -Path $ArchivePath -Destination "C:\ProgramData\qz-stage\resources.zip" -ToSession $sess -Force

        $sysFolder = Join-Path $SystemsPath $Dir
        if (Test-Path -LiteralPath $sysFolder) {
            $portFile = Join-Path $sysFolder "port-sources"
            if (Test-Path -LiteralPath $portFile) {
                Copy-Item -Path $portFile -Destination "C:\ProgramData\port-sources" -ToSession $sess -Force
            }
            Copy-Item -Path $sysFolder -Destination "C:\ProgramData\$Dir" -ToSession $sess -Recurse -Force
        }

        Write-Output "[$Dir] Files transferred successfully."

        # Unpack and run Activate.ps1
        Write-Output "[$Dir] Starting Activate.ps1 (autofirewall, backup, sysmon, watchdawg, tools, harden)"
        $remoteOut = Invoke-Command -Session $sess -ArgumentList $NewPass -ScriptBlock {
            param($BlueyPass)
            Expand-Archive -Path "C:\ProgramData\qz-stage\resources.zip" -DestinationPath "C:\ProgramData\qz-stage" -Force
            & "C:\ProgramData\qz-stage\Activate.ps1" -Password $BlueyPass -StageDir "C:\ProgramData\qz-stage" 2>&1 |
                Tee-Object -FilePath "C:\ProgramData\.log\activate.log"
        }

        foreach ($outLine in $remoteOut) {
            Write-Output "[$Dir] $outLine"
        }

        Remove-PSSession -Session $sess -ErrorAction SilentlyContinue
        Write-Output "[$Dir] --- All done ---"
    }
    catch {
        Write-Output "[$Dir] [FAILED] $($_.Exception.Message)"
        Write-Output "[$Dir] --- Failed ---"
    }
}

# --------------------------------------------------
# 4. Launch parallel jobs with throttle limit
# --------------------------------------------------
$Jobs = @()
foreach ($line in $Targets) {
    while ((@($Jobs | Where-Object { $_.State -eq 'Running' })).Count -ge $ThrottleLimit) {
        Start-Sleep -Milliseconds 300
    }
    $Jobs += Start-Job -ScriptBlock $DeployBlock -ArgumentList $line, $Archive, $SystemsDir
}

# Wait and stream output
$Jobs | Wait-Job | ForEach-Object {
    Receive-Job -Job $_
    Remove-Job -Job $_
}

Write-Host "=== Finished ===" -ForegroundColor Cyan
Stop-Transcript | Out-Null
Write-Host "Full log saved to $LogFile"
