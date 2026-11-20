#Requires -RunAsAdministrator
param(
    [Alias("h")]
    [switch]$Help,

    [Alias("c")]
    [switch]$Clear,

    [Alias("d")]
    [switch]$Download,

    [string]$PortSourcesFile = "C:\ProgramData\port-sources"
)

$ErrorActionPreference = "Stop"
$RuleGroup = "Quetzalcoatl-AutoFirewall"
$VerticalSubnet = "192.168.111.0/24"

if ($Help) {
    @"
[*] Displaying the help menu
Valid flags:
  -Help     (-h)    Displays this help menu
  -Clear    (-c)    Clears the firewall of all rules and sets default allow
  -Download (-d)    Unlocks outbound ports 53 (UDP), 80 (TCP), and 443 (TCP)
                    regardless of port-sources to allow package managers/downloads.
"@
    exit 0
}

# Ensure Windows Defender Firewall service is running
$fwService = Get-Service -Name "MpsSvc"
if ($fwService.Status -ne "Running") {
    Start-Service -Name "MpsSvc"
}

# Precaution: set default allow while flushing rules so we don't drop our own session
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True -DefaultInboundAction Allow -DefaultOutboundAction Allow

# Remove previous Quetzalcoatl rules and disable all pre-existing rules (iptables -F equivalent)
Remove-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue
Get-NetFirewallRule -Enabled True | Disable-NetFirewallRule

if ($Clear) {
    Write-Host "[*] Nuking firewall"
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True -DefaultInboundAction Allow -DefaultOutboundAction Allow
    Write-Host "[+] Firewall is no longer (Default Allow, all rules cleared)" -ForegroundColor Yellow
    exit 0
}

Write-Host "[*] Applying hardened firewall rules..." -ForegroundColor Cyan

# Read port-sources (Line 1 = space-separated IN ports, Line 2 = space-separated OUT ports)
$InPorts = @()
$OutPorts = @()
if (Test-Path -LiteralPath $PortSourcesFile) {
    $lines = Get-Content -LiteralPath $PortSourcesFile
    if ($lines.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace($lines[0])) {
        $InPorts = $lines[0].Trim() -split '\s+'
    }
    if ($lines.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($lines[-1])) {
        $OutPorts = $lines[-1].Trim() -split '\s+'
    }
} else {
    Write-Warning "Port sources file '$PortSourcesFile' not found. Continuing with empty IN/OUT lists."
}

# Note: Windows Defender Firewall implicitly allows loopback and is stateful (ESTABLISHED/RELATED).

# --------------------------------------------------
# INBOUND ports
# --------------------------------------------------
foreach ($port in $InPorts) {
    Write-Host "[+] Allow inbound TCP port $port"
    New-NetFirewallRule -DisplayName "QZ-In-TCP-$port" -Group $RuleGroup `
        -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null

    Write-Host "[+] Allow inbound UDP port $port"
    New-NetFirewallRule -DisplayName "QZ-In-UDP-$port" -Group $RuleGroup `
        -Direction Inbound -Protocol UDP -LocalPort $port -Action Allow | Out-Null
}

# Deny outbound ICMPv4
Write-Host "[+] Deny outbound ICMP"
New-NetFirewallRule -DisplayName "QZ-Out-ICMP-Block" -Group $RuleGroup `
    -Direction Outbound -Protocol ICMPv4 -Action Block | Out-Null

# --------------------------------------------------
# OUTBOUND ports
# --------------------------------------------------
foreach ($port in $OutPorts) {
    Write-Host "[+] Allow outbound TCP port $port"
    New-NetFirewallRule -DisplayName "QZ-Out-TCP-$port" -Group $RuleGroup `
        -Direction Outbound -Protocol TCP -RemotePort $port -Action Allow | Out-Null

    Write-Host "[+] Allow outbound UDP port $port"
    New-NetFirewallRule -DisplayName "QZ-Out-UDP-$port" -Group $RuleGroup `
        -Direction Outbound -Protocol UDP -RemotePort $port -Action Allow | Out-Null
}

# Allow inbound ICMPv4
New-NetFirewallRule -DisplayName "QZ-In-ICMP-Allow" -Group $RuleGroup `
    -Direction Inbound -Protocol ICMPv4 -Action Allow | Out-Null

# --------------------------------------------------
# Download / Package Manager ports (-Download)
# --------------------------------------------------
if ($Download) {
    Write-Host "[+] Allow outbound UDP port 53 (DNS)"
    New-NetFirewallRule -DisplayName "QZ-Out-DNS-53" -Group $RuleGroup `
        -Direction Outbound -Protocol UDP -RemotePort 53 -Action Allow | Out-Null

    Write-Host "[+] Allow outbound TCP port 80"
    New-NetFirewallRule -DisplayName "QZ-Out-HTTP-80" -Group $RuleGroup `
        -Direction Outbound -Protocol TCP -RemotePort 80 -Action Allow | Out-Null

    Write-Host "[+] Allow outbound TCP port 443"
    New-NetFirewallRule -DisplayName "QZ-Out-HTTPS-443" -Group $RuleGroup `
        -Direction Outbound -Protocol TCP -RemotePort 443 -Action Allow | Out-Null
}

# --------------------------------------------------
# Allow vertical subnet (192.168.111.0/24)
# --------------------------------------------------
New-NetFirewallRule -DisplayName "QZ-In-Vertical" -Group $RuleGroup `
    -Direction Inbound -RemoteAddress $VerticalSubnet -Action Allow | Out-Null
New-NetFirewallRule -DisplayName "QZ-Out-Vertical" -Group $RuleGroup `
    -Direction Outbound -RemoteAddress $VerticalSubnet -Action Allow | Out-Null

# --------------------------------------------------
# Disable IPv6 on all network adapters
# --------------------------------------------------
Write-Host "[*] Disabling IPv6..."
Disable-NetAdapterBinding -Name "*" -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue

# --------------------------------------------------
# Default Deny + Dropped Packet Logging
# --------------------------------------------------
Set-NetFirewallProfile -Profile Domain,Public,Private `
    -Enabled True `
    -DefaultInboundAction Block `
    -DefaultOutboundAction Block `
    -LogBlocked True `
    -LogFileName "%SystemRoot%\System32\LogFiles\Firewall\pfirewall.log" `
    -LogMaxSizeKilobytes 16384

# Export backup of rules (Windows Defender Firewall persists automatically across reboots)
Write-Host "[*] Exporting firewall policy backup..."
netsh advfirewall export "C:\ProgramData\firewall.wfw" | Out-Null

Write-Host "[+] Firewall locked down successfully." -ForegroundColor Green
Write-Host "    Dropped packets are logged to: C:\Windows\System32\LogFiles\Firewall\pfirewall.log"
