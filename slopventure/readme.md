Run a script:
```
powershell.exe -ExecutionPolicy Bypass -File .\harden.ps1
```

Check something:
```
(Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4
```

Run Watchdawg: 
```
.\Watchdawg.ps1 C:\wd_backup .\watchdawg-sources.txt
```

View dropped packets:
```
Get-Content C:\Windows\System32\LogFiles\Firewall\pfirewall.log -Wait | Select-String "DROP"
```

Run Harden (the first arg is the password for `bluey`):
```
.\Harden.ps1 "YourStrongP@ssword!"
```
