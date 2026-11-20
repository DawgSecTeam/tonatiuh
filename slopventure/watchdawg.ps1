#Requires -RunAsAdministrator
param(
    [Parameter(Position = 0)]
    [string]$BackupDir,

    [Parameter(Position = 1)]
    [string]$InputFile
)

Write-Host "▗▖ ▗▖ ▗▄▖▗▄▄▄▖▗▄▄▖▗▖ ▗▖▗▄▄▄  ▗▄▖ ▗▖ ▗▖ ▗▄▄▖"
Write-Host "▐▌ ▐▌▐▌ ▐▌ █ ▐▌   ▐▌ ▐▌▐▌  █▐▌ ▐▌▐▌ ▐▌▐▌   "
Write-Host "▐▌ ▐▌▐▛▀▜▌ █ ▐▌   ▐▛▀▜▌▐▌  █▐▛▀▜▌▐▌ ▐▌▐▌▝▜▌"
Write-Host "▐▙█▟▌▐▌ ▐▌ █ ▝▚▄▄▖▐▌ ▐▌▐▙▄▄▀▐▌ ▐▌▐▙█▟▌▝▚▄▞▘"
Write-Host "                    Version 1.1.2 (Windows)`n"

if ([string]::IsNullOrWhiteSpace($BackupDir) -or [string]::IsNullOrWhiteSpace($InputFile)) {
    Write-Host "no arguments.`ninput backup directory and input file"
    exit 1
}

if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    Write-Host "Input file '$InputFile' does not exist."
    exit 1
}

# Maps "C:\Windows\System32\..." -> "$BackupDir\C\Windows\System32\..."
function Get-BackupPath([string]$FilePath) {
    $fullPath = [System.IO.Path]::GetFullPath($FilePath)
    $relative = $fullPath -replace '^([A-Za-z]):\\', '$1\'
    return Join-Path $BackupDir $relative
}

function Copy-WithParents([string]$SourcePath) {
    $destPath = Get-BackupPath $SourcePath
    $destParent = Split-Path -Parent $destPath
    if (-not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }
    Copy-Item -LiteralPath $SourcePath -Destination $destPath -Force -ErrorAction SilentlyContinue
}

# Create backup & hidden log directory
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
Write-Host "Backup dir created"

$LogDir = "C:\ProgramData\.wd"
$LogFile = Join-Path $LogDir "wd.log"
if (-not (Test-Path -LiteralPath $LogDir)) {
    $dirItem = New-Item -ItemType Directory -Path $LogDir -Force
    $dirItem.Attributes = $dirItem.Attributes -bor [System.IO.FileAttributes]::Hidden
}
if (-not (Test-Path -LiteralPath $LogFile)) {
    New-Item -ItemType File -Path $LogFile -Force | Out-Null
}

# Separate watchlist alongside $InputFile so $InputFile is never mutated
$InputDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($InputFile))
$Watchlist = Join-Path $InputDir "watchlist"
$WatchPaths = [System.Collections.Generic.List[string]]::new()

# Expand directories and files into the watchlist
foreach ($rawLine in Get-Content -LiteralPath $InputFile) {
    $line = $rawLine.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }

    if (Test-Path -LiteralPath $line -PathType Container) {
        Get-ChildItem -LiteralPath $line -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $WatchPaths.Add($_.FullName)
        }
    }
    elseif (Test-Path -LiteralPath $line -PathType Leaf) {
        Write-Host "adding file to watchlist: $line"
        $WatchPaths.Add((Get-Item -LiteralPath $line -Force).FullName)
        Copy-WithParents $line
    }
    else {
        Write-Host "file or folder $line doesn't exist"
    }
}

# Deduplicate and write watchlist file
$WatchPaths = $WatchPaths | Select-Object -Unique
Set-Content -LiteralPath $Watchlist -Value $WatchPaths

# Seed backup directory with initial contents of every expanded file
foreach ($file in $WatchPaths) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
    $backupFile = Get-BackupPath $file
    if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) {
        Copy-WithParents $file
    }
}

Write-Host "[*] Watching $($WatchPaths.Count) files..." -ForegroundColor Cyan

# Main monitoring loop
while ($true) {
    foreach ($file in $WatchPaths) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $backupFile = Get-BackupPath $file
        if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) { continue }

        $liveHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        $bakHash  = (Get-FileHash -LiteralPath $backupFile -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash

        if ($liveHash -and $bakHash -and ($liveHash -ne $bakHash)) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $alertMsg = "Woof! File change detected on file $file"

            Write-Host $alertMsg -ForegroundColor Red
            Add-Content -LiteralPath $LogFile -Value "============"
            Add-Content -LiteralPath $LogFile -Value "CHANGE on file $file at $timestamp"

            # Text diff (falls back cleanly if the file is binary)
            try {
                $diff = Compare-Object `
                    -ReferenceObject (Get-Content -LiteralPath $backupFile -ErrorAction Stop) `
                    -DifferenceObject (Get-Content -LiteralPath $file -ErrorAction Stop)
                if ($diff) {
                    $diffLines = $diff | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
                    Add-Content -LiteralPath $LogFile -Value $diffLines
                }
            } catch {
                Add-Content -LiteralPath $LogFile -Value "[Binary or unreadable diff - SHA256 changed: $bakHash -> $liveHash]"
            }

            # Update baseline copy
            Copy-WithParents $file

            # Broadcast to all active RDP/console sessions (Windows equivalent of wall)
            if (Get-Command msg.exe -ErrorAction SilentlyContinue) {
                msg.exe * $alertMsg 2>$null
            }
        }
    }

    Start-Sleep -Seconds 3
}
