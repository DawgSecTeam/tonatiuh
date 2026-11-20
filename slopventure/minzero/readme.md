# Dependencies
Only for the host system
parallel, sshpass

# Order of operations
- YOU NEED TO CREATE A `hostfile` FILE in this directory
  - must be in this format: `<system-name> <ip> <ssh-user> <current-password> <new-password-hash>`
  - one line per host
  - `<system-name>` must match a directory in `../systems/`, which gets uploaded along with its `port-sources`
  - pregenerate all password hashes with `../funcs/passwordHasher.ps1`
- execute `deploy.ps1`
  - tars up all resources (`harden.ps1` and `autofirewall.ps1` live at the repo root, alongside
    `activate.ps1`, not in `minzero/`) and scps everything to /var/tmp
  - creates /var/tmp/.log for remote logs
  - runs activate.ps1 (passed the host's hashed password), which
    - runs autofirewall.ps1 (sets iptable rules)
    - runs backup.ps1
    - installs auditd and applies the rules
    - deploys watchdawg to /etc/kernel
    - deploys busybox to /opt/busybox and replaces /bin/false
    - runs harden.ps1 (sets /bin/false shells, adds bluey, sets bluey password, locks system accounts)
- deploy logs are saved to `deploy.log` on the host
- after deploy, run the baseline scripts (`standard.ps1`, `specific.ps1`) on the target
