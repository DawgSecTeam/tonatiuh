#Requires -RunAsAdministrator
param(
    [Parameter(Position = 0)]
    [string]$SusIP = "10.67.2.26"
)

$LogFile = "beaconfinder.log"
Write-Host "[*] Watching for Established connections to $SusIP (polling every 200ms)..." -ForegroundColor Cyan

while ($true) {
    $hits = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteAddress -eq $SusIP }

    if ($hits) {
        foreach ($hit in $hits) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($hit.OwningProcess)" -ErrorAction SilentlyContinue
            $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($hit.LocalAddress):$($hit.LocalPort) -> $($hit.RemoteAddress):$($hit.RemotePort) | PID=$($hit.OwningProcess) | Name=$($proc.Name) | Cmd=$($proc.CommandLine)"
            Write-Host $entry -ForegroundColor Red
            Add-Content -LiteralPath $LogFile -Value $entry
        }
        break
    }

    Start-Sleep -Milliseconds 200
}
