#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Reverts everything Start-PxeInstall.ps1 changed. Safe to run more than once.
#>
param([string]$Adapter = 'Ethernet')
$ErrorActionPreference = 'Continue'
Get-SmbShare -Name 'win10install' -ErrorAction SilentlyContinue | Remove-SmbShare -Force
Remove-LocalUser -Name 'pxeinstall' -ErrorAction SilentlyContinue
Get-NetFirewallRule -Group 'PXE Win10 Install' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetIPAddress -InterfaceAlias $Adapter -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Set-NetIPInterface -InterfaceAlias $Adapter -AddressFamily IPv4 -Dhcp Enabled
Remove-Item (Join-Path $PSScriptRoot 'www\pxeinstall.cmd') -ErrorAction SilentlyContinue   # holds the share password
Write-Host "Cleanup done." -ForegroundColor Green
