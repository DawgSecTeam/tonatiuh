Our Benefactors have recommended [winPEASx64](https://github.com/peass-ng/PEASS-ng/releases)

Also, please download this [Microsoft Sysmon](https://learn.microsoft.com/en-us/sysinternals/downloads/sysmon)

put a test VM in `minzero\hostfile`


Enable WinRM on the test VM (run once in an elevated PowerShell on the VM):
```
Enable-PSRemoting -Force
```

Run: 
```
.\minzero\Deploy.ps1 -TrustAllHosts
```
