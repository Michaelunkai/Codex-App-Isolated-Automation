[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$requiredPaths = @(
    'setup.ps1',
    'manage-codex-vm.ps1',
    'launch-codex-vm.ps1',
    'launch-codex-vm.bat',
    'pause-codex-vm.ps1',
    'pause-codex-vm.bat',
    'GuestTools\unrestricted-drives-setup.ps1',
    'tests\Verify-LiveVm.ps1'
)

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

foreach ($relativePath in $requiredPaths) {
    $filePath = Join-Path $projectRoot $relativePath
    Assert-Condition (Test-Path -LiteralPath $filePath -PathType Leaf) "Missing required artifact: $relativePath"
}

$powerShellFiles = Get-ChildItem -LiteralPath $projectRoot -Filter '*.ps1' -File -Recurse
foreach ($file in $powerShellFiles) {
    $parseTokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$parseTokens,
        [ref]$parseErrors
    )
    Assert-Condition ($parseErrors.Count -eq 0) ("PowerShell syntax errors in {0}: {1}" -f $file.FullName, ($parseErrors -join '; '))
}

$setupText = Get-Content -LiteralPath (Join-Path $projectRoot 'setup.ps1') -Raw
Assert-Condition ([regex]::IsMatch($setupText, '-Maximum\s+50')) 'Setup must cap the VM processor at 50 percent.'
Assert-Condition ([regex]::IsMatch($setupText, '-Reserve\s+0')) 'Setup must set the processor reserve to zero.'
Assert-Condition ([regex]::IsMatch($setupText, '-RelativeWeight\s+100')) 'Setup must set processor relative weight to 100.'
Assert-Condition (-not [regex]::IsMatch($setupText, '-ProcessorMaximum| -ProcessorReserve| -ProcessorWeight')) 'Setup uses unsupported processor parameter spellings.'
Assert-Condition ([regex]::IsMatch($setupText, '-MaximumBytes\s+6GB')) 'Setup must cap dynamic memory at 6 GB.'
Assert-Condition ([regex]::IsMatch($setupText, '-MinimumBytes\s+2GB')) 'Setup must set minimum dynamic memory to 2 GB.'
Assert-Condition ([regex]::IsMatch($setupText, '-StartupBytes\s+4GB')) 'Setup must set startup memory to 4 GB.'
Assert-Condition ([regex]::IsMatch($setupText, '-SizeBytes\s+64GB')) 'Setup must create a 64 GB virtual disk.'
Assert-Condition ($setupText.Contains('Existing VM/VHDX reused; guest OS or app installation was not inspected.')) 'Setup must not claim an existing VM disk is blank without inspecting its guest.'
Assert-Condition ([regex]::IsMatch($setupText, 'if\s*\(\$existingVm\)[\s\S]*?Add-VMHardDiskDrive')) 'Setup must attach the managed VHDX when reconciling an existing VM with no disk.'
Assert-Condition ([regex]::IsMatch($setupText, '-EnhancedSessionTransportType\s+HvSocket')) 'Setup must set the VM Enhanced Session transport to HvSocket.'
Assert-Condition ($setupText.Contains('System32\WindowsPowerShell\v1.0\powershell.exe')) 'Setup self-elevation must target Windows PowerShell 5.1.'
foreach ($serviceName in @('Guest Service Interface', 'Heartbeat', 'Key-Value Pair Exchange', 'Shutdown', 'Time Synchronization', 'VSS')) {
    Assert-Condition ($setupText.Contains($serviceName)) "Setup must enable integration service: $serviceName"
}

$managerText = Get-Content -LiteralPath (Join-Path $projectRoot 'manage-codex-vm.ps1') -Raw
foreach ($action in @('Start', 'Pause', 'Resume', 'Stop', 'Save', 'Connect', 'Status', 'Restart')) {
    Assert-Condition ($managerText.Contains($action)) "Lifecycle manager is missing action: $action"
}
Assert-Condition ([regex]::IsMatch($managerText, 'Pause[\s\S]*?Save-VM')) 'Pause must save the VM state to release active host RAM.'
Assert-Condition ([regex]::IsMatch($managerText, 'Save-VM\s+-Name\s+\$VMName\s+-Confirm:\$false')) 'Saving the VM must run without an interactive confirmation prompt.'

$guestText = Get-Content -LiteralPath (Join-Path $projectRoot 'GuestTools\unrestricted-drives-setup.ps1') -Raw
Assert-Condition ($guestText.Contains('tsclient')) 'Guest drive setup must detect Enhanced Session redirected drives.'
Assert-Condition ([regex]::IsMatch($guestText, 'ValidateRange\s*\(\s*72\s*,\s*90\s*\)')) 'Guest drive allocation must accept only valid drive-letter character codes.'
Assert-Condition (-not [regex]::IsMatch($setupText, 'New-SmbShare|Grant-SmbShareAccess|Set-SmbShare')) 'Setup must preserve existing host SMB share permissions.'
$readmeText = Get-Content -LiteralPath (Join-Path $projectRoot 'README.md') -Raw
Assert-Condition ($readmeText.Contains('per-virtual-processor limit')) 'README must state the actual scope of the Hyper-V processor cap.'
Assert-Condition ($readmeText.Contains('does not implement a 50 percent host-wide CPU-group cap')) 'README must distinguish the VM processor cap from a host-wide cap.'

$launchBat = Get-Content -LiteralPath (Join-Path $projectRoot 'launch-codex-vm.bat') -Raw
$pauseBat = Get-Content -LiteralPath (Join-Path $projectRoot 'pause-codex-vm.bat') -Raw
Assert-Condition ($launchBat.Contains('launch-codex-vm.ps1')) 'Launch batch file must invoke the PowerShell launcher.'
Assert-Condition ($pauseBat.Contains('pause-codex-vm.ps1')) 'Pause batch file must invoke the PowerShell pause wrapper.'

Write-Output ("PASS: {0} PowerShell files parsed; lifecycle and hardware requirements checked." -f $powerShellFiles.Count)
