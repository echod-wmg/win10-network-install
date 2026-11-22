<#
.SYNOPSIS
  Writes www\unattend-uefi.xml and www\unattend-bios.xml.
.DESCRIPTION
  Wipes the target disk, installs the given edition, creates local admin "User" with no password
  and skips the first-start questions.
#>
param(
    [string]$Edition     = 'Windows 10 Pro',
    [string]$Locale      = 'en-GB',
    [string]$InputLocale = '0809:00000809',
    [int]   $DiskId      = 0
)
$ErrorActionPreference = 'Stop'
$www = Join-Path $PSScriptRoot 'www'

# Microsoft's public generic install keys: select the edition, do not activate.
$keys = @{
    'Windows 10 Home'      = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
    'Windows 10 Pro'       = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
    'Windows 10 Education' = 'YNMGQ-8RYV3-4PGQ3-C8XTP-7CFBY'
}
$keyXml = if ($keys[$Edition]) { "<ProductKey><Key>$($keys[$Edition])</Key><WillShowUI>OnError</WillShowUI></ProductKey>" } else { '' }

$arch = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
$layouts = @{
    uefi = @{
        Win  = 3
        Part = @'
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
'@
    }
    bios = @{
        Win  = 2
        Part = @'
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>500</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>System Reserved</Label><Active>true</Active></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
'@
    }
}

$intl = @"
      <InputLocale>$InputLocale</InputLocale>
      <SystemLocale>$Locale</SystemLocale>
      <UILanguage>$Locale</UILanguage>
      <UserLocale>$Locale</UserLocale>
"@

foreach ($fw in 'uefi', 'bios') {
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" $arch>
      <SetupUILanguage><UILanguage>$Locale</UILanguage></SetupUILanguage>
$intl    </component>
    <component name="Microsoft-Windows-Setup" $arch>
      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>
        <Disk wcm:action="add">
          <DiskID>$DiskId</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
$($layouts[$fw].Part)        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>$Edition</Value></MetaData>
          </InstallFrom>
          <InstallTo><DiskID>$DiskId</DiskID><PartitionID>$($layouts[$fw].Win)</PartitionID></InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        $keyXml
      </UserData>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $arch>
$intl    </component>
    <component name="Microsoft-Windows-Shell-Setup" $arch>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>User</Name>
            <Group>Administrators</Group>
            <Password><Value></Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
    $out = Join-Path $www "unattend-$fw.xml"
    [IO.File]::WriteAllText($out, $xml, (New-Object Text.UTF8Encoding($false)))
    [xml](Get-Content $out -Raw) | Out-Null   # fail early if malformed
}
