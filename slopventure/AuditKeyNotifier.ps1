#Requires -RunAsAdministrator
param(
    [string]$WebhookUrl = "",
    [string[]]$AlertKeys = @("recon", "susp_activity"),
    [int]$PollIntervalSeconds = 2
)

# Fallback: read webhook URL from minzero\discordkey if not passed as a parameter
if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
    $keyPaths = @(
        (Join-Path $PSScriptRoot "minzero\discordkey"),
        (Join-Path $PSScriptRoot "discordkey")
    )
    foreach ($kp in $keyPaths) {
        if (Test-Path -LiteralPath $kp) {
            $WebhookUrl = (Get-Content -LiteralPath $kp -First 1).Trim()
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
    Write-Error "[x] No Discord webhook URL provided. Pass -WebhookUrl or populate minzero\discordkey."
    exit 1
}

$LogName = "Microsoft-Windows-Sysmon/Operational"
if (-not (Get-WinEvent -ListLog $LogName -ErrorAction SilentlyContinue)) {
    Write-Error "[x] Sysmon event log '$LogName' not found. Install Sysmon64 first."
    exit 1
}

# Start from the latest existing RecordId so we only alert on new events
$latest = Get-WinEvent -LogName $LogName -MaxEvents 1 -ErrorAction SilentlyContinue
$lastRecordId = if ($latest) { $latest.RecordId } else { 0 }

Write-Host "[*] Starting Sysmon Alert Listener (Keys: $($AlertKeys -join ', '))..." -ForegroundColor Cyan

while ($true) {
    Start-Sleep -Seconds $PollIntervalSeconds

    $xpath = "*[System[(EventRecordID > $lastRecordId)]]"
    $events = Get-WinEvent -LogName $LogName -FilterXPath $xpath -Oldest -ErrorAction SilentlyContinue

    foreach ($evt in $events) {
        $lastRecordId = $evt.RecordId
        $xml = [xml]$evt.ToXml()

        $data = @{}
        foreach ($node in $xml.Event.EventData.Data) {
            $data[$node.Name] = $node.'#text'
        }

        $ruleName = $data["RuleName"]
        if ([string]::IsNullOrWhiteSpace($ruleName)) { continue }

        foreach ($key in $AlertKeys) {
            if ($ruleName -like "*$key*") {
                $comm = if ($data["Image"]) { Split-Path -Leaf $data["Image"] } else { "unknown" }
                $procId  = if ($data["ProcessId"]) { $data["ProcessId"] } else { "N/A" }
                $ppid    = if ($data["ParentProcessId"]) { $data["ParentProcessId"] } else { "N/A" }
                $user    = if ($data["User"]) { $data["User"] } else { "N/A" }
                $cmdLine = if ($data["CommandLine"]) { $data["CommandLine"] } else { "N/A" }

                Write-Host "--- ALERT TRIGGERED [$key] on $env:COMPUTERNAME ---" -ForegroundColor Red
                Write-Host "    COMM=$comm PID=$procId PPID=$ppid USER=$user"

                $payload = @{
                    embeds = @(
                        @{
                            title  = "[$env:COMPUTERNAME] $key"
                            color  = if ($key -eq "susp_activity") { 15158332 } else { 15844367 }
                            fields = @(
                                @{ name = "COMM"; value = $comm; inline = $true }
                                @{ name = "PID";  value = $procId; inline = $true }
                                @{ name = "PPID"; value = $ppid; inline = $true }
                                @{ name = "USER"; value = $user; inline = $false }
                                @{ name = "CMD";  value = "``$($cmdLine.Substring(0, [Math]::Min($cmdLine.Length, 900)))``"; inline = $false }
                            )
                        }
                    )
                } | ConvertTo-Json -Depth 5

                try {
                    Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType "application/json" -Body $payload | Out-Null
                } catch {
                    Write-Warning "Failed to send Discord webhook: $_"
                }
            }
        }
    }
}
