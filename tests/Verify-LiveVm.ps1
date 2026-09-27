[CmdletBinding()]
param(
    [string]$VMName = 'Codex-App-Isolated'
)

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
. (Join-Path $PSScriptRoot '..\lib\VhdChain.ps1')

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($null -eq $vm) { throw ('VM not found: {0}' -f $VMName) }

$memory = Get-VMMemory -VMName $VMName -ErrorAction Stop
$processor = Get-VMProcessor -VMName $VMName -ErrorAction Stop
$firmware = Get-VMFirmware -VMName $VMName -ErrorAction Stop
$security = Get-VMSecurity -VMName $VMName -ErrorAction Stop
$hostSettings = Get-VMHost -ErrorAction Stop
$networkAdapters = @(Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop)
$hardDrives = @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop)
$attachedDiskChain = @()
if ($hardDrives.Count -eq 1) {
    $attachedDiskChain = @(Get-VhdPathChain -Path $hardDrives[0].Path)
}
$integrationServices = @(Get-VMIntegrationService -VMName $VMName -ErrorAction Stop)
$expectedVhd = 'C:\Hyper-V\Codex-App-Isolated\Codex-App-Isolated.vhdx'
$failures = @()

if ($vm.Generation -ne 2) { $failures += 'Generation is not 2' }
if (-not $memory.DynamicMemoryEnabled -or $memory.Startup -ne 4GB -or $memory.Minimum -ne 2GB -or $memory.Maximum -ne 6GB -or $memory.Buffer -ne 20 -or $memory.Priority -ne 50) { $failures += 'Dynamic memory settings do not match' }
if ($processor.Count -ne 4 -or $processor.Maximum -ne 50 -or $processor.Reserve -ne 0 -or $processor.RelativeWeight -ne 100) { $failures += 'Processor settings do not match' }
if ($firmware.SecureBoot -ne 'On' -or $firmware.SecureBootTemplate -ne 'MicrosoftWindows') { $failures += 'Secure Boot is not enabled with the Microsoft Windows template' }
if (-not $security.TpmEnabled) { $failures += 'Virtual TPM is disabled' }
if ($vm.AutomaticStartAction -ne 'Nothing' -or $vm.AutomaticStopAction -ne 'Save') { $failures += 'Automatic start/stop settings do not match' }
if ($vm.EnhancedSessionTransportType -ne 'HvSocket') { $failures += 'VM Enhanced Session transport is not HvSocket' }
if (-not $hostSettings.EnableEnhancedSessionMode) { $failures += 'Host Enhanced Session Mode is disabled' }
if ($networkAdapters.Count -ne 1 -or [string]::IsNullOrWhiteSpace($networkAdapters[0].SwitchName)) { $failures += 'VM is not attached to exactly one switch' }
if ($hardDrives.Count -ne 1 -or $attachedDiskChain.Count -eq 0 -or -not [string]::Equals($attachedDiskChain[-1].Path, $expectedVhd, [StringComparison]::OrdinalIgnoreCase)) { $failures += 'VM VHD backing path does not match' }

$disk = Get-VHD -Path $expectedVhd -ErrorAction Stop
if ($disk.VhdFormat -ne 'VHDX' -or $disk.VhdType -ne 'Dynamic' -or $disk.Size -ne 64GB) { $failures += 'VHD format/type/capacity do not match' }

$expectedServices = @('Guest Service Interface', 'Heartbeat', 'Key-Value Pair Exchange', 'Shutdown', 'Time Synchronization', 'VSS')
foreach ($serviceName in $expectedServices) {
    $service = $integrationServices | Where-Object { $_.Name -eq $serviceName } | Select-Object -First 1
    if ($null -eq $service -or -not $service.Enabled) { $failures += ('Integration service is missing or disabled: {0}' -f $serviceName) }
}

$result = [pscustomobject]@{
    VmName = $vm.Name
    State = [string]$vm.State
    Generation = $vm.Generation
    VhdPath = $expectedVhd
    AttachedVhdPath = if ($hardDrives.Count -eq 1) { $hardDrives[0].Path } else { $null }
    VhdPathChain = @($attachedDiskChain | ForEach-Object { $_.Path })
    VhdFormat = [string]$disk.VhdFormat
    VhdType = [string]$disk.VhdType
    VhdSizeBytes = $disk.Size
    DynamicMemory = $memory.DynamicMemoryEnabled
    StartupMemoryBytes = $memory.Startup
    MinimumMemoryBytes = $memory.Minimum
    MaximumMemoryBytes = $memory.Maximum
    CpuCount = $processor.Count
    CpuMaximumPercent = $processor.Maximum
    SecureBoot = [string]$firmware.SecureBoot
    SecureBootTemplate = [string]$firmware.SecureBootTemplate
    VirtualTpmEnabled = [bool]$security.TpmEnabled
    NetworkSwitch = @($networkAdapters | Select-Object -ExpandProperty SwitchName -Unique)
    HostEnhancedSessionMode = [bool]$hostSettings.EnableEnhancedSessionMode
    EnhancedSessionTransport = [string]$vm.EnhancedSessionTransportType
    IntegrationServices = @($integrationServices | Where-Object { $_.Name -in $expectedServices } | Select-Object Name,Enabled)
    GuestOSInstallationPerformedBySetup = $false
    Failures = $failures
}

$result | ConvertTo-Json -Depth 5
if ($failures.Count -gt 0) { exit 1 }
