#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installs Windows on another PC over Ethernet (PXE), unattended.
.DESCRIPTION
  Temporarily turns this PC into a PXE server for Windows installer media at -Source.
  All changes are reverted when it stops: install finished, error, or Ctrl+C.
  WARNING: the target PC's disk -DiskId is wiped.
#>
param(
    [string]$Source      = 'E:\',
    [string]$Adapter     = 'Ethernet',
    [string]$ServerIP    = '192.168.50.1',
    [string]$Edition     = 'Windows 10 Pro',
    [string]$Locale      = 'en-GB',
    [string]$InputLocale = '0809:00000809',
    [int]   $DiskId      = 0,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$root  = $PSScriptRoot
$www   = Join-Path $root 'www'
$bin   = Join-Path $root 'bin'
$logs  = Join-Path $root 'logs'
$share = 'win10install'
$user  = 'pxeinstall'
$fwGrp = 'PXE Win10 Install'
$net   = (($ServerIP -split '\.')[0..2] -join '.')
New-Item -ItemType Directory -Force $logs | Out-Null
$log = Join-Path $logs 'server.log'
Start-Transcript -LiteralPath (Join-Path $logs ('setup-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))) | Out-Null
function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }

Step "Checking $Source"
foreach ($f in 'sources\install.wim', 'sources\boot.wim', 'setup.exe', 'bootmgr', 'boot\bcd', 'boot\boot.sdi', 'efi\boot\bootx64.efi', 'efi\microsoft\boot\bcd') {
    if (-not (Test-Path (Join-Path $Source $f))) { throw "Missing $(Join-Path $Source $f)" }
}
foreach ($f in 'wimboot', 'ipxe.pxe', 'ipxe.efi') {
    if (-not (Test-Path (Join-Path $bin $f))) { throw "Missing bin\$f - run Get-BootFiles.ps1 first" }
}
$names = (Get-WindowsImage -ImagePath (Join-Path $Source 'sources\install.wim')).ImageName
if ($names -notcontains $Edition) { throw "'$Edition' not in install.wim. Available: $($names -join ', ')" }

Step "Checking ports 67/69/80"
$busy = @(Get-NetUDPEndpoint -LocalPort 67, 69 -ErrorAction SilentlyContinue) + @(Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue)
if ($busy.Count) { throw "Ports 67/69/80 in use (e.g. Internet Connection Sharing)." }
if ((Get-NetAdapter -Name $Adapter).Status -ne 'Up') { throw "$Adapter is not connected." }

if (-not $Force) {
    Write-Host ""
    Write-Host "The PC that network-boots from this one will have disk $DiskId WIPED." -ForegroundColor Red
    if ((Read-Host "Type WIPE to continue") -ne 'WIPE') { Write-Host "Cancelled."; return }
}

try {
    Step "Setting $Adapter to $ServerIP/24"
    $have = Get-NetIPAddress -InterfaceAlias $Adapter -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not ($have | Where-Object IPAddress -eq $ServerIP)) {
        Set-NetIPInterface -InterfaceAlias $Adapter -AddressFamily IPv4 -Dhcp Disabled
        $have | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceAlias $Adapter -IPAddress $ServerIP -PrefixLength 24 | Out-Null
    }
    for ($i = 0; $i -lt 20 -and -not (Get-NetIPAddress -InterfaceAlias $Adapter -IPAddress $ServerIP -ErrorAction SilentlyContinue | Where-Object AddressState -eq 'Preferred'); $i++) { Start-Sleep 1 }

    Step "Creating temporary user and read-only share"
    $pw  = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    $sec = ConvertTo-SecureString $pw -AsPlainText -Force
    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) { Set-LocalUser -Name $user -Password $sec }
    else { New-LocalUser -Name $user -Password $sec -PasswordNeverExpires -AccountNeverExpires -Description 'Temp: PXE install' | Out-Null }
    Get-SmbShare -Name $share -ErrorAction SilentlyContinue | Remove-SmbShare -Force
    New-SmbShare -Name $share -Path $Source -ReadAccess "$env:COMPUTERNAME\$user" | Out-Null

    Step "Adding firewall rules ($Adapter only)"
    Get-NetFirewallRule -Group $fwGrp -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $lan = "$net.0/24"
    $rule = @{ Group = $fwGrp; Direction = 'Inbound'; InterfaceAlias = $Adapter; Action = 'Allow' }
    New-NetFirewallRule @rule -DisplayName 'PXE DHCP' -Protocol UDP -LocalPort 67 | Out-Null
    New-NetFirewallRule @rule -DisplayName 'PXE TFTP' -Protocol UDP -RemoteAddress $lan | Out-Null
    New-NetFirewallRule @rule -DisplayName 'PXE HTTP' -Protocol TCP -LocalPort 80 -RemoteAddress $lan | Out-Null
    New-NetFirewallRule @rule -DisplayName 'PXE SMB'  -Protocol TCP -LocalPort 445 -RemoteAddress $lan | Out-Null

    Step "Writing install scripts"
    $cmd = (Get-Content (Join-Path $root 'pxeinstall.cmd.template') -Raw).
        Replace('__SERVER__', $ServerIP).Replace('__SHARE__', $share).
        Replace('__DOMAIN__', $env:COMPUTERNAME).Replace('__USER__', $user).Replace('__PASS__', $pw)
    [IO.File]::WriteAllText((Join-Path $www 'pxeinstall.cmd'), ($cmd -replace "`r?`n", "`r`n"), [Text.Encoding]::ASCII)
    & (Join-Path $root 'New-Unattend.ps1') -Edition $Edition -Locale $Locale -InputLocale $InputLocale -DiskId $DiskId

    $files = @{
        'boot.ipxe'         = Join-Path $www 'boot.ipxe'
        'winpeshl.ini'      = Join-Path $www 'winpeshl.ini'
        'pxeinstall.cmd'    = Join-Path $www 'pxeinstall.cmd'
        'unattend-uefi.xml' = Join-Path $www 'unattend-uefi.xml'
        'unattend-bios.xml' = Join-Path $www 'unattend-bios.xml'
        'wimboot'           = Join-Path $bin 'wimboot'
        'bootmgr'           = Join-Path $Source 'bootmgr'
        'bootx64.efi'       = Join-Path $Source 'efi\boot\bootx64.efi'
        'BCD-bios'          = Join-Path $Source 'boot\bcd'
        'BCD-efi'           = Join-Path $Source 'efi\microsoft\boot\bcd'
        'boot.sdi'          = Join-Path $Source 'boot\boot.sdi'
        'boot.wim'          = Join-Path $Source 'sources\boot.wim'
    }

    Step "Starting server (Ctrl+C to stop)"
    # Shared across hot reloads so the server remembers which PC it already booted.
    $leases = [hashtable]::Synchronized(@{})
    $done   = [hashtable]::Synchronized(@{})
    $flag   = Join-Path $root 'restart.flag'
    do {
        Remove-Item $flag -ErrorAction SilentlyContinue
        & (Join-Path $root 'pxe-server.ps1') -ServerIP $ServerIP -TftpRoot $bin -HttpFiles $files `
            -Leases $leases -Done $done -LogFile $log -SharePath $Source -AutoStop
    } while (Test-Path $flag)
} catch {
    $msg = "{0:HH:mm:ss} [ERROR] {1} (line {2})" -f (Get-Date), $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber
    Write-Host $msg -ForegroundColor Red
    try { [IO.File]::AppendAllText($log, "$msg`r`n") } catch { }
} finally {
    Step "Cleaning up"
    & (Join-Path $root 'Stop-PxeInstall.ps1') -Adapter $Adapter
    try { [IO.File]::AppendAllText($log, ("{0:HH:mm:ss} [AUTO] cleanup done`r`n" -f (Get-Date))) } catch { }
    Stop-Transcript | Out-Null
}
