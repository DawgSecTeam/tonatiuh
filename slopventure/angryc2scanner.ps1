#Requires -RunAsAdministrator
param(
    # Processes that must NEVER be killed (prevents BSOD & self-lockout)
    [string[]]$ProtectedProcesses = @(
        "Idle", "System", "Registry", "smss", "csrss", "wininit",
        "services", "lsass", "winlogon", "svchost", "explorer",
        "MsMpEng", "wsmprovhost", "sshd", "Splunkd"
    )
)

$ScanDir = "scans"
New-Item -ItemType Directory -Path $ScanDir -Force | Out-Null

function Get-TcpSnapshot {
    Get-NetTCPConnection -State Established, SynSent -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0)' } |
        ForEach-Object {
            $pName = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            [PSCustomObject]@{
                Key = "TCP $($_.LocalAddress):$($_.LocalPort) -> $($_.RemoteAddress):$($_.RemotePort) PID=$($_.OwningProcess) ($pName)"
                PID = $_.OwningProcess
            }
        }
}

function Stop-ProcessTree([int]$TargetPid) {
    $currentPid = $TargetPid
    $visited = @()

    while ($currentPid -gt 4 -and $currentPid -ne $PID -and $currentPid -notin $visited) {
        $visited += $currentPid
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $currentPid" -ErrorAction SilentlyContinue
        if (-not $proc) { break }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($proc.Name)
        if ($baseName -in $ProtectedProcesses) {
            Write-Host "    [SAFE] Skipping protected process $baseName (PID $currentPid)" -ForegroundColor DarkYellow
            break
        }

        $parentPid = $proc.ParentProcessId
        Stop-Process -Id $currentPid -Force -ErrorAction SilentlyContinue
        Write-Host "    [X] done murdering $baseName (PID $currentPid)" -ForegroundColor Red
        $currentPid = $parentPid
    }
}

$lastKeys = @(Get-TcpSnapshot | Select-Object -ExpandProperty Key)
Write-Host "[*] AngryC2Scanner armed. Baseline: $($lastKeys.Count) TCP connections." -ForegroundColor Red

while ($true) {
    Start-Sleep -Milliseconds 500
    $current = @(Get-TcpSnapshot)
    $currentKeys = @($current | Select-Object -ExpandProperty Key)

    $newConns = Compare-Object -ReferenceObject $lastKeys -DifferenceObject $currentKeys |
        Where-Object { $_.SideIndicator -eq "=>" }

    if ($newConns) {
        Write-Host "====== NEW STUFF HAPPENING ======" -ForegroundColor Yellow
        Write-Host "event at $(Get-Date)"
        $newConns | ForEach-Object { Write-Host "+ $($_.InputObject)" -ForegroundColor Red }

        Write-Host "====== COMMITTING MURDER ======" -ForegroundColor Red
        $hitPids = $current | Where-Object { $_.Key -in $newConns.InputObject } |
            Select-Object -ExpandProperty PID -Unique

        foreach ($p in $hitPids) {
            Stop-ProcessTree -TargetPid $p
        }
    }

    $lastKeys = $currentKeys
}
