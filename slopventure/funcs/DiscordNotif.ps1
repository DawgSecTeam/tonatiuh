function Send-DiscordAlert {
    param(
        [Parameter(Mandatory)][string]$WebhookUrl,
        [Parameter(Mandatory)][string]$Message
    )
    $payload = @{ content = "[$env:COMPUTERNAME] $Message" } | ConvertTo-Json
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body $payload | Out-Null
}
