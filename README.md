# Win10 Network Install

Install Windows on another PC over an Ethernet cable, unattended. It's a PXE server in plain PowerShell: no WDS, no third-party server.

> **Warning:** the PC that network-boots from this server has its disk wiped without asking.

## Requirements

- Windows 10/11 server PC with admin rights and an Ethernet port
- Windows installer USB (Media Creation Tool or Rufus)
- Target PC linked by cable or switch; UEFI targets need **Secure Boot off**

## Usage

1. Download the boot files once:
   ```powershell
   .\Get-BootFiles.ps1
   ```
2. Double-click `Start.cmd`, accept the admin prompt and type `WIPE`.
3. Network-boot the target PC (boot menu, e.g. F12, then *Onboard NIC / PXE*).

Setup runs on its own. When the install files are copied, the server stops and reverts every change. Run `Cleanup.cmd` only if the server was killed.

The target ends up with local admin **User** and no password. Set one afterwards.

### Options

```powershell
.\Start-PxeInstall.ps1 -Source F:\ -Adapter 'Ethernet 2' -Edition 'Windows 10 Home' -Locale en-US -InputLocale 0409:00000409
```

| Parameter | Default | |
|---|---|---|
| `-Source` | `E:\` | Installer drive |
| `-Adapter` | `Ethernet` | Network adapter to the target |
| `-ServerIP` | `192.168.50.1` | Uses the /24 around it |
| `-Edition` | `Windows 10 Pro` | Image name in `install.wim` |
| `-Locale` / `-InputLocale` | `en-GB` / `0809:00000809` | Language and keyboard |
| `-DiskId` | `0` | Target disk to wipe |
| `-Force` | | Skip the `WIPE` prompt |

## How it works

```
target PC                         this PC (192.168.50.1)
---------                         ----------------------
PXE ROM   --DHCP/TFTP-->  ipxe.pxe / ipxe.efi
iPXE      --HTTP------->  boot.ipxe, wimboot, boot.wim (+ injected files)
WinPE     --SMB-------->  \\server\win10install  (read-only share of the USB)
Setup     installs with unattend-*.xml, reboots from its own disk
```

- DHCP, TFTP and HTTP bind only to `-ServerIP`, so nothing answers on Wi-Fi or other networks.
- `wimboot` injects `winpeshl.ini`, `pxeinstall.cmd` and the answer files into WinPE.
- Changes on the server, all reverted by `Stop-PxeInstall.ps1`: a static IP on the adapter, a temporary local user and share, and firewall rules for that adapter only.
- Edits to `pxe-server.ps1` hot-reload while it runs. Create `stop.flag` to stop it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No requests in the log | Check the cable; enable network boot in firmware |
| Secure Boot violation | Turn Secure Boot off |
| `boot.wim` stalls on BIOS PCs | Use `ipxe.pxe`, not `undionly.kpxe` (the default here) |
| "Waiting for share" forever | WinPE lacks a driver for that NIC; install from USB instead |

Logs are in `logs\`.

## Credits

[iPXE](https://ipxe.org) and [wimboot](https://ipxe.org/wimboot) (GPL), downloaded by `Get-BootFiles.ps1`.
