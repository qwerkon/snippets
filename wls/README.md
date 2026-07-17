

## Określenie rozmiarów i lokalizacji dystrybucji WSL

Do uruchomienia w PowerShell

```
$LxssPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
Get-ChildItem $LxssPath | ForEach-Object {
    $Distro = Get-ItemProperty $_.PSPath

    $VhdFileName = if ($Distro.VhdFileName) {
        $Distro.VhdFileName
    } else {
        "ext4.vhdx"
    }

    $VhdPath = Join-Path $Distro.BasePath $VhdFileName

    if (Test-Path $VhdPath) {
        $File = Get-Item $VhdPath

        [PSCustomObject]@{
            Distribution = $Distro.DistributionName
            State        = $Distro.State
            Path         = $VhdPath
            SizeGB       = [math]::Round($File.Length / 1GB, 2)
        }
    }
} | Format-Table -AutoSize
```

## Optymalizacja WSL 

Do uruchomienia w PowerShell

```
wsl -- sudo fstrim -av
wsl --shutdown
wsl --export Ubuntu D:\_backups\WSL\ubuntu-$(Get-Date -Format "yyyyMMdd").tar
wsl --export wsl-vpnkit D:\_backups\wsl\wsl-vpnkit-$(Get-Date -Format "yyyyMMdd").tar
wsl --manage Ubuntu --compact
Optimize-VHD -Path "C:\Users\*\AppData\Local\wsl\*\ext4.vhdx" -Mode Full

wsl --import Ubuntu D:\_backups\WSL\ubuntu-$(Get-Date -Format "yyyyMMdd").tar --version 2
```
