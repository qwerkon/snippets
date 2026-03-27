<#
.SYNOPSIS
  Shrinks WSL ext4.vhdx files and prints before/after sizes.

.DESCRIPTION
  - Stops WSL/Docker related processes
  - Searches for ext4.vhdx files in common locations
  - Uses cache to avoid slow full scans on every run
  - Scans current user paths first, then optionally all user profiles
  - Detects sparse files and can try to remove sparse flag
  - Retries Optimize-VHD when file is in use

.PARAMETER ForceRescan
  Ignores cache and performs a fresh scan.

.PARAMETER CacheTtlMinutes
  Cache validity time in minutes.

.PARAMETER RetryCount
  Number of retries for file-in-use errors.

.PARAMETER RetryDelaySeconds
  Delay between retries.

.NOTES
  Run in an elevated PowerShell (Administrator).
#>

[CmdletBinding()]
param(
  [switch]$ForceRescan,
  [int]$CacheTtlMinutes = 30,
  [int]$RetryCount = 1,
  [int]$RetryDelaySeconds = 5
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
  $wid = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $prp = New-Object System.Security.Principal.WindowsPrincipal($wid)

  if (-not $prp.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Please run PowerShell as Administrator."
  }
}

function SizeGB([long]$bytes) {
  return [math]::Round($bytes / 1GB, 2)
}

function Get-CacheFilePath {
  $base = Join-Path $env:LOCALAPPDATA "WSL-Disk-Optimizer"
  if (-not (Test-Path $base)) {
    New-Item -ItemType Directory -Path $base -Force | Out-Null
  }

  return (Join-Path $base "ext4vhdx-cache.json")
}

function TryImport-HyperV {
  try {
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
      Write-Host "Trying to import Hyper-V module..." -ForegroundColor Yellow
    }

    Import-Module Hyper-V -ErrorAction Stop
    return $true
  }
  catch {
    Write-Warning "Cannot load Hyper-V module (Optimize-VHD is unavailable)."
    Write-Host "Enable Hyper-V with:" -ForegroundColor Yellow
    Write-Host "  dism.exe /Online /Enable-Feature /All /FeatureName:Microsoft-Hyper-V"
    Write-Host "Reboot and run this script again."
    return $false
  }
}

function Stop-WSLRelatedProcesses {
  Write-Host "Stopping WSL/Docker related processes..." -ForegroundColor Cyan

  try {
    wsl --shutdown 2>$null
  }
  catch {
    # ignore
  }

  Start-Sleep -Seconds 2

  $processNames = @(
    "Docker Desktop",
    "com.docker.backend",
    "com.docker.proxy",
    "wsl",
    "wslhost",
    "wslservice",
    "wsl-gvproxy",
    "wslrelay",
    "Vmmem",
    "VmmemWSL"
  )

  foreach ($name in $processNames) {
    try {
      Stop-Process -Name $name -Force -ErrorAction SilentlyContinue
    }
    catch {
      # ignore
    }
  }

  try {
    Stop-Service LxssManager -Force -ErrorAction SilentlyContinue
  }
  catch {
    # ignore
  }

  Start-Sleep -Seconds 2
}

function Get-CurrentUserCandidateRoots {
  $roots = @()

  $userProfile = $env:USERPROFILE
  $localAppData = $env:LOCALAPPDATA

  $roots += @(
    (Join-Path $userProfile "WSL"),
    (Join-Path $userProfile "WSL\Ubuntu"),
    (Join-Path $localAppData "Packages"),
    (Join-Path $localAppData "Docker\wsl\data")
  )

  return $roots | Where-Object { Test-Path $_ } | Sort-Object -Unique
}

function Get-AllUsersCandidateRoots {
  $roots = @()

  $userDirs = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -notmatch '^(Public|Default|Default User|All Users|defaultuser0|WDAGUtilityAccount)$'
    }

  foreach ($userDir in $userDirs) {
    $profileRoot = $userDir.FullName

    $roots += @(
      (Join-Path $profileRoot "WSL"),
      (Join-Path $profileRoot "WSL\Ubuntu"),
      (Join-Path $profileRoot "AppData\Local\Packages"),
      (Join-Path $profileRoot "AppData\Local\Docker\wsl\data")
    )
  }

  return $roots | Where-Object { Test-Path $_ } | Sort-Object -Unique
}

function Get-GlobalCandidateRoots {
  $roots = @(
    (Join-Path $env:ProgramData "DockerDesktop\vm-data"),
    "C:\WSL",
    "D:\WSL",
    "E:\WSL"
  )

  return $roots | Where-Object { Test-Path $_ } | Sort-Object -Unique
}

function Save-ScanCache([array]$paths) {
  $cacheFile = Get-CacheFilePath

  $payload = [pscustomobject]@{
    CreatedAt = (Get-Date).ToString("o")
    Paths     = @($paths)
  }

  $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cacheFile -Encoding UTF8
}

function Load-ScanCache([int]$ttlMinutes) {
  $cacheFile = Get-CacheFilePath

  if (-not (Test-Path $cacheFile)) {
    return $null
  }

  try {
    $raw = Get-Content -LiteralPath $cacheFile -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return $null
    }

    $data = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $data.CreatedAt -or -not $data.Paths) {
      return $null
    }

    $createdAt = [datetime]::Parse($data.CreatedAt)
    $ageMinutes = ((Get-Date) - $createdAt).TotalMinutes

    if ($ageMinutes -gt $ttlMinutes) {
      return $null
    }

    $validPaths = @($data.Paths | Where-Object { $_ -and (Test-Path $_) })

    return [pscustomobject]@{
      CreatedAt = $createdAt
      Paths     = $validPaths
    }
  }
  catch {
    return $null
  }
}

function Get-SparseFlag([string]$path) {
  try {
    $output = fsutil sparse queryflag $path 2>&1 | Out-String
    if ($output -match 'NOT set as sparse') {
      return $false
    }
    elseif ($output -match 'set as sparse') {
      return $true
    }
    else {
      return $null
    }
  }
  catch {
    return $null
  }
}

function Try-RemoveSparseFlag([string]$path) {
  $result = [pscustomobject]@{
    Attempted = $false
    Success   = $false
    Message   = ""
  }

  $isSparse = Get-SparseFlag -path $path
  if ($isSparse -ne $true) {
    $result.Message = "File is not sparse."
    return $result
  }

  $result.Attempted = $true

  try {
    Write-Host "Trying to remove sparse flag: $path" -ForegroundColor Yellow
    fsutil sparse setflag $path 0 | Out-Null
    Start-Sleep -Seconds 1

    $after = Get-SparseFlag -path $path
    if ($after -eq $false) {
      $result.Success = $true
      $result.Message = "Sparse flag removed successfully."
    }
    else {
      $result.Message = "Sparse flag removal did not succeed."
    }
  }
  catch {
    $result.Message = $_.Exception.Message
  }

  return $result
}

function Test-IsFileInUseError([string]$message) {
  if ([string]::IsNullOrWhiteSpace($message)) {
    return $false
  }

  return (
    $message -match '0x80070020' -or
    $message -match 'used by another process' -or
    $message -match 'is being used by another process' -or
    $message -match 'Proces nie może uzyskać dostępu do pliku' -or
    $message -match 'ponieważ jest on używany przez inny proces'
  )
}

function Scan-RootsForExt4Vhdx([string[]]$roots, [string]$phaseName) {
  $foundPaths = New-Object System.Collections.Generic.List[string]

  if (-not $roots -or $roots.Count -eq 0) {
    return @()
  }

  $total = $roots.Count
  $index = 0

  foreach ($root in $roots) {
    $index++

    $percent = [math]::Round(($index / $total) * 100, 0)
    Write-Progress -Id 1 -Activity "Searching for ext4.vhdx" -Status "$phaseName ($index/$total): $root" -PercentComplete $percent

    try {
      $items = Get-ChildItem -LiteralPath $root -Recurse -Filter "ext4.vhdx" -File -ErrorAction SilentlyContinue
      foreach ($item in $items) {
        if ($item -and $item.FullName) {
          $foundPaths.Add($item.FullName)
        }
      }
    }
    catch {
      # ignore permission/IO errors
    }
  }

  Write-Progress -Id 1 -Activity "Searching for ext4.vhdx" -Completed

  return $foundPaths | Sort-Object -Unique
}

function Find-Ext4Vhdx([switch]$ForceRescan, [int]$CacheTtlMinutes) {
  if (-not $ForceRescan) {
    $cache = Load-ScanCache -ttlMinutes $CacheTtlMinutes
    if ($null -ne $cache -and $cache.Paths.Count -gt 0) {
      Write-Host ("Using cached scan results from {0}" -f $cache.CreatedAt) -ForegroundColor DarkGray
      return [pscustomobject]@{
        FromCache = $true
        Paths     = @($cache.Paths)
      }
    }
  }

  $allFound = New-Object System.Collections.Generic.List[string]

  Write-Host "Scanning current user paths..." -ForegroundColor Cyan
  $currentUserRoots = Get-CurrentUserCandidateRoots
  $currentResults = Scan-RootsForExt4Vhdx -roots $currentUserRoots -phaseName "Current user"
  foreach ($p in $currentResults) { $allFound.Add($p) }

  Write-Host "Scanning global paths..." -ForegroundColor Cyan
  $globalRoots = Get-GlobalCandidateRoots
  $globalResults = Scan-RootsForExt4Vhdx -roots $globalRoots -phaseName "Global locations"
  foreach ($p in $globalResults) { $allFound.Add($p) }

  Write-Host "Scanning all user profiles..." -ForegroundColor Cyan
  $allUsersRoots = Get-AllUsersCandidateRoots
  $allUsersResults = Scan-RootsForExt4Vhdx -roots $allUsersRoots -phaseName "All users"
  foreach ($p in $allUsersResults) { $allFound.Add($p) }

  $unique = $allFound | Sort-Object -Unique

  Save-ScanCache -paths $unique

  return [pscustomobject]@{
    FromCache = $false
    Paths     = @($unique)
  }
}

function Invoke-OptimizeVhdWithRetry([string]$fullPath, [int]$RetryCount, [int]$RetryDelaySeconds) {
  $attempt = 0
  $lastErrorMessage = ""

  while ($attempt -le $RetryCount) {
    try {
      $attempt++
      Optimize-VHD -Path $fullPath -Mode Full -ErrorAction Stop

      return [pscustomobject]@{
        Success      = $true
        AttemptCount = $attempt
        Message      = if ($attempt -gt 1) { "Succeeded after retry." } else { "" }
      }
    }
    catch {
      $lastErrorMessage = $_.Exception.Message

      if ($attempt -le $RetryCount -and (Test-IsFileInUseError -message $lastErrorMessage)) {
        Write-Host "Optimize-VHD failed because file is in use. Retrying..." -ForegroundColor Yellow
        Stop-WSLRelatedProcesses
        Start-Sleep -Seconds $RetryDelaySeconds
        continue
      }

      return [pscustomobject]@{
        Success      = $false
        AttemptCount = $attempt
        Message      = $lastErrorMessage
      }
    }
  }

  return [pscustomobject]@{
    Success      = $false
    AttemptCount = $attempt
    Message      = $lastErrorMessage
  }
}

function Optimize-OneVHDX([string]$fullPath, [bool]$hasHyperV, [int]$RetryCount, [int]$RetryDelaySeconds) {
  $before = (Get-Item -LiteralPath $fullPath).Length
  $sparse = Get-SparseFlag -path $fullPath

  $result = [pscustomobject]@{
    Path            = $fullPath
    BeforeGB        = SizeGB $before
    AfterGB         = $null
    SavedGB         = $null
    Status          = "Skipped"
    Sparse          = $sparse
    SparseAction    = ""
    RetryAttempts   = 0
    FromCache       = $null
    Note            = ""
  }

  if (-not $hasHyperV) {
    $result.Status = "Skipped"
    $result.Note   = "Hyper-V not available"
    return $result
  }

  if ($sparse -eq $true) {
    $sparseRemoval = Try-RemoveSparseFlag -path $fullPath

    if ($sparseRemoval.Attempted) {
      $result.SparseAction = $sparseRemoval.Message
    }

    $sparse = Get-SparseFlag -path $fullPath
    $result.Sparse = $sparse

    if ($sparse -eq $true) {
      $result.Status = "Blocked"
      $result.Note   = if ([string]::IsNullOrWhiteSpace($sparseRemoval.Message)) {
        "File is sparse. Optimize-VHD cannot compact sparse VHDX."
      } else {
        $sparseRemoval.Message
      }
      $result.AfterGB = $result.BeforeGB
      $result.SavedGB = 0
      return $result
    }
  }

  $opt = Invoke-OptimizeVhdWithRetry -fullPath $fullPath -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds
  $result.RetryAttempts = $opt.AttemptCount

  if ($opt.Success) {
    $after = (Get-Item -LiteralPath $fullPath).Length
    $result.AfterGB = SizeGB $after
    $result.SavedGB = [math]::Round(($before - $after) / 1GB, 2)
    $result.Status  = "Optimized"
    $result.Note    = $opt.Message
  }
  else {
    $result.Status = "Failed"
    $result.Note   = $opt.Message

    try {
      $after = (Get-Item -LiteralPath $fullPath).Length
      $result.AfterGB = SizeGB $after
      $result.SavedGB = [math]::Round(($before - $after) / 1GB, 2)
    }
    catch {
      # leave AfterGB/SavedGB null
    }
  }

  return $result
}

# --- Main ---

Assert-Admin

Set-ExecutionPolicy Bypass -Scope Process -Force

Write-Host "Shutting down WSL..." -ForegroundColor Cyan
Stop-WSLRelatedProcesses

$hasHyperV = TryImport-HyperV

Write-Host "Searching for ext4.vhdx files..." -ForegroundColor Cyan
$scan = Find-Ext4Vhdx -ForceRescan:$ForceRescan -CacheTtlMinutes $CacheTtlMinutes
$diskPaths = @($scan.Paths)

if (-not $diskPaths -or $diskPaths.Count -eq 0) {
  Write-Warning "No ext4.vhdx files found in common locations."
  Write-Host "Searched current user, global locations, and other user profiles." -ForegroundColor Yellow
  Write-Host "Use -ForceRescan to bypass cache if needed." -ForegroundColor Yellow
  return
}

Write-Host ("Found {0} VHDX file(s):" -f $diskPaths.Count) -ForegroundColor Green
$diskPaths | ForEach-Object { Write-Host " - $_" }

if ($scan.FromCache) {
  Write-Host "Source: cache" -ForegroundColor DarkGray
}
else {
  Write-Host "Source: fresh scan" -ForegroundColor DarkGray
}

Write-Host "Optimizing (this may take a while)..." -ForegroundColor Cyan
$results = @()

$totalDisks = $diskPaths.Count
$currentDisk = 0

foreach ($path in $diskPaths) {
  $currentDisk++
  $percent = [math]::Round(($currentDisk / $totalDisks) * 100, 0)

  Write-Progress -Id 2 -Activity "Optimizing VHDX files" -Status "Processing ($currentDisk/$totalDisks): $path" -PercentComplete $percent

  $result = Optimize-OneVHDX -fullPath $path -hasHyperV $hasHyperV -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds
  $result.FromCache = $scan.FromCache
  $results += $result
}

Write-Progress -Id 2 -Activity "Optimizing VHDX files" -Completed

Write-Host "`n=== SUMMARY ===" -ForegroundColor Magenta
$results |
  Sort-Object Status, SavedGB -Descending |
  Format-Table `
    @{Label="Status"; Expression={$_.Status}}, `
    @{Label="Sparse"; Expression={$_.Sparse}}, `
    @{Label="Sparse Action"; Expression={$_.SparseAction}}, `
    @{Label="Attempts"; Expression={$_.RetryAttempts}}, `
    @{Label="Before (GB)"; Expression={$_.BeforeGB}}, `
    @{Label="After (GB)"; Expression={$_.AfterGB}}, `
    @{Label="Saved (GB)"; Expression={$_.SavedGB}}, `
    @{Label="Path"; Expression={$_.Path}}, `
    @{Label="Info"; Expression={$_.Note}} -AutoSize

$totalBefore = (($results | Where-Object { $_.BeforeGB -ne $null }).BeforeGB | Measure-Object -Sum).Sum
$totalAfter  = (($results | Where-Object { $_.AfterGB  -ne $null }).AfterGB  | Measure-Object -Sum).Sum

if ($null -eq $totalBefore) { $totalBefore = 0 }
if ($null -eq $totalAfter)  { $totalAfter  = 0 }

$totalSaved = [math]::Round($totalBefore - $totalAfter, 2)

Write-Host ("`nTotal BEFORE: {0} GB" -f $totalBefore) -ForegroundColor Gray
Write-Host ("Total AFTER:  {0} GB" -f $totalAfter) -ForegroundColor Gray
Write-Host ("Saved space:  {0} GB" -f $totalSaved) -ForegroundColor Green
