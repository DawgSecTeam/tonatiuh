$ScanDir = "scans"
New-Item -ItemType Directory -Path $ScanDir -Force | Out-Null

function Get-SocketSnapshot {
    $tcp = Get-NetTCPConnection -State Established, SynSent, SynReceived -ErrorAction SilentlyContinue |
        ForEach-Object {
            $pName = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            "TCP $($_.LocalAddress):$($_.LocalPort) -> $($_.RemoteAddress):$($_.RemotePort) [$($_.State)] PID=$($_.OwningProcess) ($pName)"
        }
    $udp = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        ForEach-Object {
            $pName = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            "UDP $($_.LocalAddress):$($_.LocalPort) PID=$($_.OwningProcess) ($pName)"
        }
    return (@($tcp) + @($udp)) | Sort-Object -Unique
}

$lastScan = Get-SocketSnapshot
Write-Host "[*] C2Scanner started. Baseline: $($lastScan.Count) sockets." -ForegroundColor Cyan

while ($true) {
    Start-Sleep -Milliseconds 500
    $currentScan = Get-SocketSnapshot
    $diff = Compare-Object -ReferenceObject $lastScan -DifferenceObject $currentScan

    if ($diff) {
        $ts = Get-Date -Format "yyyyMMdd-HHmmss"
        $currentScan | Set-Content (Join-Path $ScanDir "$ts.txt")

        Write-Host "====== NEW STUFF HAPPENING ======" -ForegroundColor Yellow
        Write-Host "event at $(Get-Date)"
        $diff | ForEach-Object {
            if ($_.SideIndicator -eq "=>") { Write-Host "+ $($_.InputObject)" -ForegroundColor Red }
            else { Write-Host "- $($_.InputObject)" -ForegroundColor DarkGray }
        }
    }
    $lastScan = $currentScan
}
