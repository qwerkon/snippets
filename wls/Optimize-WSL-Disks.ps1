<#
.SYNOPSIS
  Shrinks WSL ext4.vhdx files and prints before/after sizes.

.NOTES
  Run in an elevated PowerShell (Administrator).
#>

$ErrorActionPreference = 'Stop'

function Assert-Admin {
  $wid = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $prp = New-Object System.Security.Principal.WindowsPrincipal($wid)
  if (-not $prp.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Please run PowerShell as Administrator."
  }
}

function SizeGB([long]$bytes) {
  [math]::Round($bytes / 1GB, 2)
}

function TryImport-HyperV {
  try {
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
      Write-Host "Trying to import Hyper-V module..." -ForegroundColor Yellow
    }
    Import-Module Hyper-V -ErrorAction Stop
    return $true
  } catch {
    Write-Warning "Cannot load Hyper-V module (Optimize-VHD is unavailable)."
    Write-Host "Enable Hyper-V with:" -ForegroundColor Yellow
    Write-Host "  dism.exe /Online /Enable-Feature /All /FeatureName:Microsoft-Hyper-V"
    Write-Host "Reboot and run this script again."
    return $false
  }
}

function Find-Ext4Vhdx {
  $paths = @()

  $candidateRoots = @(
    "$env:LOCALAPPDATA\Packages",                # MS Store WSL
    "$env:LOCALAPPDATA\Docker\wsl\data",         # Docker Desktop
    "$env:ProgramData\DockerDesktop\vm-data",    # Docker alt
    "C:\WSL", "D:\WSL", "E:\WSL"                 # manual imports
  ) | Where-Object { Test-Path $_ }

  foreach ($root in $candidateRoots) {
    try {
      $found = Get-ChildItem -LiteralPath $root -Recurse -Filter "ext4.vhdx" -File -ErrorAction SilentlyContinue
      if ($found) { $paths += $found }
    } catch {
      # ignore permission/IO errors
    }
  }

  $paths | Sort-Object FullName -Unique
}

function Optimize-OneVHDX([string]$fullPath, [bool]$hasHyperV) {
  $before = (Get-Item -LiteralPath $fullPath).Length
  $result = [pscustomobject]@{
    Path     = $fullPath
    BeforeGB = SizeGB $before
    AfterGB  = $null
    SavedGB  = $null
    Status   = "Skipped"
    Note     = ""
  }

  if (-not $hasHyperV) {
    $result.Status = "Skipped"
    $result.Note   = "Hyper-V not available"
    return $result
  }

  try {
    Optimize-VHD -Path $fullPath -Mode Full -ErrorAction Stop
    $after = (Get-Item -LiteralPath $fullPath).Length
    $result.AfterGB = SizeGB $after
    $result.SavedGB = [math]::Round(($before - $after) / 1GB, 2)
    $result.Status  = "Optimized"
  } catch {
    $result.Status = "Failed"
    $result.Note   = $_.Exception.Message
    try {
      $after = (Get-Item -LiteralPath $fullPath).Length
      $result.AfterGB = SizeGB $after
      $result.SavedGB = [math]::Round(($before - $after) / 1GB, 2)
    } catch {
      # leave AfterGB/SavedGB null
    }
  }

  return $result
}

# --- Main ---

Assert-Admin

Write-Host "Shutting down WSL..." -ForegroundColor Cyan
// Set-ExecutionPolicy Bypass -Scope Process -Force
// .\Optimize-WSL-Disks.ps1

try { wsl --shutdown 2>$null } catch { }

$hasHyperV = TryImport-HyperV

Write-Host "Searching for ext4.vhdx files..." -ForegroundColor Cyan
$disks = Find-Ext4Vhdx

if (-not $disks -or $disks.Count -eq 0) {
  Write-Warning "No ext4.vhdx files found in common locations."
  Write-Host "Add your custom root to the candidateRoots array if needed." -ForegroundColor Yellow
  return
}

Write-Host ("Found {0} VHDX file(s):" -f $disks.Count) -ForegroundColor Green
$disks | ForEach-Object { Write-Host " - $($_.FullName)" }

Write-Host "Optimizing (this may take a while)..." -ForegroundColor Cyan
$results = @()
foreach ($d in $disks) {
  $results += Optimize-OneVHDX -fullPath $d.FullName -hasHyperV $hasHyperV
}

Write-Host "`n=== SUMMARY ===" -ForegroundColor Magenta
$results | Sort-Object Status, SavedGB -Descending | Format-Table `
  @{Label="Status"; Expression={$_.Status}}, `
  @{Label="Before (GB)"; Expression={$_.BeforeGB}}, `
  @{Label="After (GB)"; Expression={$_.AfterGB}}, `
  @{Label="Saved (GB)"; Expression={$_.SavedGB}}, `
  @{Label="Path"; Expression={$_.Path}}, `
  @{Label="Info"; Expression={$_.Note}} -AutoSize

$totalBefore = ( ($results | Where-Object { $_.BeforeGB -ne $null }).BeforeGB | Measure-Object -Sum ).Sum
$totalAfter  = ( ($results | Where-Object { $_.AfterGB  -ne $null }).AfterGB  | Measure-Object -Sum ).Sum

if ($null -eq $totalBefore) { $totalBefore = 0 }
if ($null -eq $totalAfter)  { $totalAfter  = 0 }
$totalSaved  = [math]::Round($totalBefore - $totalAfter, 2)

Write-Host ("`nTotal BEFORE: {0} GB" -f $totalBefore) -ForegroundColor Gray
Write-Host ("Total AFTER:  {0} GB" -f $totalAfter)  -ForegroundColor Gray
Write-Host ("Saved space:  {0} GB" -f $totalSaved)  -ForegroundColor Green
