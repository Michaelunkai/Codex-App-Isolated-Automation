[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [string]$GuestIsoPath
)

$ErrorActionPreference = 'Stop'
$vmName = 'Codex-App-Isolated'
$vmRoot = 'C:\Hyper-V\Codex-App-Isolated'
$vhdPath = Join-Path $vmRoot 'Codex-App-Isolated.vhdx'
$automationRoot = 'C:\Codex-VM-Automation'
$markerName = '.codex-vm-automation-managed'
$managedFiles = @(
    'setup.ps1',
    'manage-codex-vm.ps1',
    'launch-codex-vm.ps1',
    'launch-codex-vm.bat',
    'pause-codex-vm.ps1',
    'pause-codex-vm.bat',
    'GuestTools\unrestricted-drives-setup.ps1'
)
$requiredIntegrationServices = @(
    'Guest Service Interface',
    'Heartbeat',
    'Key-Value Pair Exchange',
    'Shutdown',
    'Time Synchronization',
    'VSS'
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IPv4AddressInPrefix {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    $prefixParts = $Prefix.Split('/')
    if ($prefixParts.Count -ne 2) { return $false }
    $prefixLength = 0
    if (-not [int]::TryParse($prefixParts[1], [ref]$prefixLength) -or $prefixLength -lt 0 -or $prefixLength -gt 32) {
        return $false
    }

    try {
        $addressBytes = ([Net.IPAddress]::Parse($Address)).GetAddressBytes()
        $networkBytes = ([Net.IPAddress]::Parse($prefixParts[0])).GetAddressBytes()
    }
    catch {
        return $false
    }
    if ($addressBytes.Count -ne 4 -or $networkBytes.Count -ne 4) { return $false }

    for ($index = 0; $index -lt 4; $index++) {
        $bitsInByte = [Math]::Min(8, [Math]::Max(0, $prefixLength - ($index * 8)))
        if ($bitsInByte -eq 0) { continue }
        $mask = (0xFF -shl (8 - $bitsInByte)) -band 0xFF
        if (($addressBytes[$index] -band $mask) -ne ($networkBytes[$index] -band $mask)) {
            return $false
        }
    }
    return $true
}

function Resolve-ExistingNatSwitch {
    $defaultSwitch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if ($null -ne $defaultSwitch) { return $defaultSwitch }

    $activeNats = @(Get-NetNat -ErrorAction Stop | Where-Object { $_.Active -eq 1 })
    if ($activeNats.Count -eq 0) {
        throw 'No existing Default Switch or active NAT network was found. No switch was created or changed.'
    }

    $matches = @()
    foreach ($switch in @(Get-VMSwitch -ErrorAction Stop)) {
        $interfaceAlias = 'vEthernet ({0})' -f $switch.Name
        $addresses = @(Get-NetIPAddress -InterfaceAlias $interfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        foreach ($address in $addresses) {
            foreach ($nat in $activeNats) {
                if (Test-IPv4AddressInPrefix -Address $address.IPAddress -Prefix $nat.InternalIPInterfaceAddressPrefix) {
                    $matches += $switch
                    break
                }
            }
        }
    }

    $matches = @($matches | Sort-Object -Property Name -Unique)
    if ($matches.Count -ne 1) {
        throw ('Expected one existing Hyper-V switch with an active NAT prefix; found {0}. No host networking changes were made.' -f $matches.Count)
    }
    return $matches[0]
}

function Get-HostAdapterSnapshot {
    return @(
        Get-NetAdapter -ErrorAction Stop |
            Sort-Object -Property Name |
            ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.Status, $_.MacAddress }
    )
}

function Assert-AutomationDirectoryIsManaged {
    if (-not (Test-Path -LiteralPath $automationRoot -PathType Container)) { return }
    $markerPath = Join-Path $automationRoot $markerName
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        $markerContent = (Get-Content -LiteralPath $markerPath -Raw).Trim()
        if ($markerContent -ne 'Codex-App-Isolated-Automation-v1') {
            throw ('Refusing to use {0}; its ownership marker is invalid.' -f $automationRoot)
        }
        return
    }

    $allowedNames = @($managedFiles | ForEach-Object { [IO.Path]::GetFileName($_) }) + @('GuestTools', $markerName)
    $unexpected = @(Get-ChildItem -LiteralPath $automationRoot -Force | Where-Object { $allowedNames -notcontains $_.Name })
    if ($unexpected.Count -gt 0) {
        throw ('Refusing to overwrite unrelated content in {0}: {1}' -f $automationRoot, (($unexpected | Select-Object -ExpandProperty Name) -join ', '))
    }
}

function Install-ManagementFiles {
    Assert-AutomationDirectoryIsManaged
    if (-not (Test-Path -LiteralPath $automationRoot -PathType Container)) {
        New-Item -Path $automationRoot -ItemType Directory -ErrorAction Stop | Out-Null
    }
    $guestToolsRoot = Join-Path $automationRoot 'GuestTools'
    if (-not (Test-Path -LiteralPath $guestToolsRoot -PathType Container)) {
        New-Item -Path $guestToolsRoot -ItemType Directory -ErrorAction Stop | Out-Null
    }

    foreach ($relativePath in $managedFiles) {
        $sourcePath = Join-Path $PSScriptRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw ('Required source artifact is missing: {0}' -f $sourcePath)
        }
        $destinationPath = Join-Path $automationRoot $relativePath
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -Path $destinationParent -ItemType Directory -ErrorAction Stop | Out-Null
        }
        $sourceFullPath = [IO.Path]::GetFullPath($sourcePath)
        $destinationFullPath = [IO.Path]::GetFullPath($destinationPath)
        if (-not [string]::Equals($sourceFullPath, $destinationFullPath, [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force -ErrorAction Stop
        }
    }

    $markerPath = Join-Path $automationRoot $markerName
    Set-Content -LiteralPath $markerPath -Value 'Codex-App-Isolated-Automation-v1' -Encoding UTF8 -ErrorAction Stop
}

function Assert-VhdIsExpected {
    param([Parameter(Mandatory = $true)][string]$Path)
    $vhd = Get-VHD -Path $Path -ErrorAction Stop
    if ($vhd.VhdFormat -ne 'VHDX' -or $vhd.VhdType -ne 'Dynamic' -or $vhd.Size -ne 64GB) {
        throw ('Existing VHDX at {0} does not match the required 64 GB dynamically expanding VHDX. It was preserved.' -f $Path)
    }
    return $vhd
}

if (-not (Test-IsAdministrator)) {
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($CheckOnly) { $argumentList += '-CheckOnly' }
    if (-not [string]::IsNullOrWhiteSpace($GuestIsoPath)) {
        $argumentList += '-GuestIsoPath'
        $argumentList += ('"{0}"' -f $GuestIsoPath)
    }
    $windowsPowerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $windowsPowerShellPath -ArgumentList ($argumentList -join ' ') -Verb RunAs -ErrorAction Stop
    return
}

foreach ($relativePath in $managedFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $relativePath) -PathType Leaf)) {
        throw ('The project is incomplete; missing {0}.' -f $relativePath)
    }
}

if (-not [string]::IsNullOrWhiteSpace($GuestIsoPath)) {
    if (-not (Test-Path -LiteralPath $GuestIsoPath -PathType Leaf)) {
        throw ('Guest ISO not found: {0}' -f $GuestIsoPath)
    }
    if ([IO.Path]::GetExtension($GuestIsoPath) -ne '.iso') {
        throw 'GuestIsoPath must point to an .iso file.'
    }
    $GuestIsoPath = (Resolve-Path -LiteralPath $GuestIsoPath).Path
}

$feature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -ErrorAction Stop
if ($feature.State -ne 'Enabled') {
    if ($CheckOnly) {
        [pscustomobject]@{
            CheckOnly = $true
            HyperVFeatureState = [string]$feature.State
            RequiresFeatureEnable = $true
            VmName = $vmName
            CanProvisionNow = $false
        } | ConvertTo-Json -Depth 3
        return
    }

    if ($feature.State -ne 'Disabled') {
        throw ('Hyper-V is in feature state {0}; resolve that state before provisioning.' -f $feature.State)
    }
    $featureResult = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -All -NoRestart -ErrorAction Stop
    $feature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -ErrorAction Stop
    if ($feature.State -ne 'Enabled' -or $featureResult.RestartNeeded) {
        Write-Warning 'Hyper-V feature installation requires a host reboot. The host was not restarted; rerun setup.ps1 after the planned reboot.'
        exit 3010
    }
}

Import-Module Hyper-V -ErrorAction Stop
$requiredCommands = @('Get-VM', 'New-VM', 'New-VHD', 'Set-VM', 'Set-VMMemory', 'Set-VMProcessor', 'Get-VMFirmware', 'Set-VMFirmware', 'Get-VMSecurity', 'Get-VMKeyProtector', 'Set-VMKeyProtector', 'Enable-VMTPM', 'Get-VMIntegrationService', 'Enable-VMIntegrationService')
foreach ($commandName in $requiredCommands) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw ('Required Hyper-V command is unavailable: {0}' -f $commandName)
    }
}
if (-not (Get-Command Get-NetNat -ErrorAction SilentlyContinue)) {
    throw 'Get-NetNat is unavailable; an existing NAT switch cannot be verified safely.'
}

$networkSwitch = Resolve-ExistingNatSwitch
$existingVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
$existingDisk = Test-Path -LiteralPath $vhdPath -PathType Leaf
$volume = Get-Volume -DriveLetter C -ErrorAction Stop
if ($volume.SizeRemaining -lt 8GB) {
    throw 'C: needs at least 8 GB free for VM state and operating files.'
}
Assert-AutomationDirectoryIsManaged

if ($existingVm) {
    if ($existingVm.Generation -ne 2) {
        throw 'The existing VM is not Generation 2; it was left unchanged.'
    }
    if ([string]$existingVm.State -notin @('Off', 'Saved')) {
        throw ('The existing VM is {0}. Save it, turn it off, and rerun setup; no running session was interrupted.' -f $existingVm.State)
    }
    $existingDrives = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction Stop)
    if ($existingDrives.Count -gt 1 -or ($existingDrives.Count -eq 1 -and -not [string]::Equals($existingDrives[0].Path, $vhdPath, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'The existing VM has a different or additional virtual disk. It was left unchanged.'
    }
}

if ($CheckOnly) {
    if ($existingDisk) { [void](Assert-VhdIsExpected -Path $vhdPath) }
    [pscustomobject]@{
        CheckOnly = $true
        HyperVFeatureState = [string]$feature.State
        VmName = $vmName
        ExistingVm = [bool]$existingVm
        ExistingVhd = $existingDisk
        NetworkSwitch = $networkSwitch.Name
        GuestIsoPath = $GuestIsoPath
        CanProvisionNow = $true
        Note = 'Check-only mode made no host or VM changes.'
    } | ConvertTo-Json -Depth 3
    return
}

Install-ManagementFiles
$adapterSnapshotBefore = Get-HostAdapterSnapshot
if (-not (Test-Path -LiteralPath $vmRoot -PathType Container)) {
    New-Item -Path $vmRoot -ItemType Directory -ErrorAction Stop | Out-Null
}

if (-not $existingDisk) {
    New-VHD -Path $vhdPath -SizeBytes 64GB -Dynamic -ErrorAction Stop | Out-Null
}
else {
    [void](Assert-VhdIsExpected -Path $vhdPath)
    $diskInfo = Get-VHD -Path $vhdPath -ErrorAction Stop
    if (-not $existingVm -and $diskInfo.Attached) {
        throw 'The requested VHDX is already attached elsewhere. It was preserved.'
    }
}

if (-not $existingVm) {
    New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 4GB -VHDPath $vhdPath -Path $vmRoot -SwitchName $networkSwitch.Name -ErrorAction Stop | Out-Null
}
elseif ($existingDrives.Count -eq 0) {
    Add-VMHardDiskDrive -VMName $vmName -Path $vhdPath -ErrorAction Stop
}

$networkAdapters = @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop)
if ($networkAdapters.Count -gt 1) {
    throw 'The VM has multiple virtual network adapters; no adapters were removed.'
}
if ($networkAdapters.Count -eq 0) {
    Add-VMNetworkAdapter -VMName $vmName -SwitchName $networkSwitch.Name -ErrorAction Stop | Out-Null
}
elseif ($networkAdapters[0].SwitchName -ne $networkSwitch.Name) {
    Connect-VMNetworkAdapter -VMNetworkAdapter $networkAdapters[0] -SwitchName $networkSwitch.Name -ErrorAction Stop
}

Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -StartupBytes 4GB -MinimumBytes 2GB -MaximumBytes 6GB -Buffer 20 -Priority 50 -ErrorAction Stop
Set-VMProcessor -VMName $vmName -Count 4 -Maximum 50 -Reserve 0 -RelativeWeight 100 -ErrorAction Stop
Set-VM -Name $vmName -AutomaticStopAction Save -AutomaticStartAction Nothing -EnhancedSessionTransportType HvSocket -ErrorAction Stop
Set-VMHost -EnableEnhancedSessionMode $true -ErrorAction Stop

$firmware = Get-VMFirmware -VMName $vmName -ErrorAction Stop
if ($firmware.SecureBoot -ne 'On' -or $firmware.SecureBootTemplate -ne 'MicrosoftWindows') {
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
}

$vmSecurity = Get-VMSecurity -VMName $vmName -ErrorAction Stop
if (-not $vmSecurity.TpmEnabled) {
    $keyProtector = Get-VMKeyProtector -VMName $vmName -ErrorAction Stop
    if ($null -eq $keyProtector -or $keyProtector.Length -eq 0) {
        Set-VMKeyProtector -VMName $vmName -NewLocalKeyProtector -ErrorAction Stop
    }
    Enable-VMTPM -VMName $vmName -ErrorAction Stop
}
$vmSecurity = Get-VMSecurity -VMName $vmName -ErrorAction Stop
if (-not $vmSecurity.TpmEnabled) {
    throw 'The VM virtual TPM could not be enabled; Windows 11 provisioning cannot continue.'
}

$availableServices = @(Get-VMIntegrationService -VMName $vmName -ErrorAction Stop)
foreach ($serviceName in $requiredIntegrationServices) {
    $service = $availableServices | Where-Object { $_.Name -eq $serviceName } | Select-Object -First 1
    if ($null -eq $service) {
        throw ('Required VM integration service is unavailable: {0}' -f $serviceName)
    }
    if (-not $service.Enabled) {
        Enable-VMIntegrationService -VMName $vmName -Name $serviceName -ErrorAction Stop
    }
}

if (-not [string]::IsNullOrWhiteSpace($GuestIsoPath)) {
    $dvdDrives = @(Get-VMDvdDrive -VMName $vmName -ErrorAction Stop)
    if ($dvdDrives.Count -eq 0) {
        Add-VMDvdDrive -VMName $vmName -ErrorAction Stop | Out-Null
        $dvdDrives = @(Get-VMDvdDrive -VMName $vmName -ErrorAction Stop)
    }
    if ($dvdDrives.Count -ne 1) {
        throw 'The VM must have exactly one DVD drive before an ISO can be attached.'
    }
    Set-VMDvdDrive -VMName $vmName -ControllerNumber $dvdDrives[0].ControllerNumber -ControllerLocation $dvdDrives[0].ControllerLocation -Path $GuestIsoPath -ErrorAction Stop
}

$adapterSnapshotAfter = Get-HostAdapterSnapshot
$adapterDifference = @(Compare-Object -ReferenceObject $adapterSnapshotBefore -DifferenceObject $adapterSnapshotAfter)
if ($adapterDifference.Count -gt 0) {
    throw ('Host network adapter state changed during provisioning: {0}' -f (($adapterDifference | ForEach-Object { $_.InputObject }) -join '; '))
}

$vm = Get-VM -Name $vmName -ErrorAction Stop
$memory = Get-VMMemory -VMName $vmName -ErrorAction Stop
$processor = Get-VMProcessor -VMName $vmName -ErrorAction Stop
$networkAdapters = @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop)
$verificationFailures = @()
if ($vm.Generation -ne 2) { $verificationFailures += 'Generation is not 2' }
if (-not $memory.DynamicMemoryEnabled -or $memory.Startup -ne 4GB -or $memory.Minimum -ne 2GB -or $memory.Maximum -ne 6GB -or $memory.Buffer -ne 20 -or $memory.Priority -ne 50) { $verificationFailures += 'Memory settings do not match' }
if ($processor.Count -ne 4 -or $processor.Maximum -ne 50 -or $processor.Reserve -ne 0 -or $processor.RelativeWeight -ne 100) { $verificationFailures += 'Processor settings do not match' }
if ($vm.AutomaticStopAction -ne 'Save' -or $vm.AutomaticStartAction -ne 'Nothing') { $verificationFailures += 'Automatic start/stop settings do not match' }
if ($vm.EnhancedSessionTransportType -ne 'HvSocket') { $verificationFailures += 'Enhanced session transport is not HvSocket' }
if ($networkAdapters.Count -ne 1 -or $networkAdapters[0].SwitchName -ne $networkSwitch.Name) { $verificationFailures += 'VM is not attached exclusively to the selected NAT switch' }
if ($verificationFailures.Count -gt 0) {
    throw ('Post-configuration verification failed: {0}' -f ($verificationFailures -join '; '))
}

$guestState = if ($GuestIsoPath) {
    'ISO attached; Windows installation and Codex sign-in still require guest setup.'
}
elseif ($existingVm) {
    'Existing VM/VHDX reused; guest OS or app installation was not inspected.'
}
elseif ($existingDisk -and -not $existingVm) {
    'Existing VHDX attached; guest operating system was not inferred.'
}
else {
    'Blank VHDX created; no guest operating system or Codex app is installed.'
}

[pscustomobject]@{
    VmName = $vm.Name
    State = [string]$vm.State
    Generation = $vm.Generation
    VhdPath = $vhdPath
    VhdCapacityBytes = 64GB
    DynamicMemory = $memory.DynamicMemoryEnabled
    StartupMemoryBytes = $memory.Startup
    MinimumMemoryBytes = $memory.Minimum
    MaximumMemoryBytes = $memory.Maximum
    CpuCount = $processor.Count
    CpuMaximumPercent = $processor.Maximum
    AutomaticStartAction = [string]$vm.AutomaticStartAction
    AutomaticStopAction = [string]$vm.AutomaticStopAction
    EnhancedSessionTransport = [string]$vm.EnhancedSessionTransportType
    NetworkSwitch = $networkAdapters[0].SwitchName
    HostNetworkAdaptersUnchanged = $true
    GuestSetup = $guestState
    AutomationPath = $automationRoot
} | ConvertTo-Json -Depth 4
