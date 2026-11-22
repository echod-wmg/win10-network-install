<#
.SYNOPSIS
  Downloads the iPXE boot files into .\bin.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'

$bin = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null

$files = [ordered]@{
    'wimboot'  = 'https://github.com/ipxe/wimboot/releases/latest/download/wimboot'
    'ipxe.pxe' = 'https://boot.ipxe.org/ipxe.pxe'                 # BIOS
    'ipxe.efi' = 'https://boot.ipxe.org/x86_64-efi/ipxe.efi'      # UEFI x64
}
foreach ($name in $files.Keys) {
    $out = Join-Path $bin $name
    Invoke-WebRequest $files[$name] -OutFile $out -UseBasicParsing
    '{0,-9} {1,8:N0} bytes  SHA256 {2}' -f $name, (Get-Item $out).Length, (Get-FileHash $out).Hash
}
