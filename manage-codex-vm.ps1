[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Pause', 'Resume', 'Stop', 'Save', 'Connect', 'Status', 'Restart')]
    [string]$Action,

    [string]$VMName = 'Codex-App-Isolated'
)

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($null -eq $vm) {
    throw ('Hyper-V VM not found: {0}. Run setup.ps1 first.' -f $VMName)
}

function Open-VMConnect {
    param([Parameter(Mandatory = $true)][string]$Name)

    $vmConnectPath = Join-Path $env:WINDIR 'System32\vmconnect.exe'
    if (-not (Test-Path -LiteralPath $vmConnectPath -PathType Leaf)) {
        $vmConnectCommand = Get-Command 'vmconnect.exe' -ErrorAction SilentlyContinue
        if ($null -eq $vmConnectCommand) { throw 'vmconnect.exe was not found.' }
        $vmConnectPath = $vmConnectCommand.Source
    }
    Start-Process -FilePath $vmConnectPath -ArgumentList @('localhost', $Name) -ErrorAction Stop | Out-Null
}

function Start-OrResumeVM {
    param([Parameter(Mandatory = $true)][Microsoft.HyperV.PowerShell.VirtualMachine]$Machine)

    switch ([string]$Machine.State) {
        'Off' { Start-VM -Name $Machine.Name -ErrorAction Stop | Out-Null }
        'Saved' { Start-VM -Name $Machine.Name -ErrorAction Stop | Out-Null }
        'Paused' { Resume-VM -Name $Machine.Name -ErrorAction Stop | Out-Null }
        'Running' { }
        default { throw ('Cannot start/resume VM from state {0}.' -f $Machine.State) }
    }
    Open-VMConnect -Name $Machine.Name
}

switch ($Action) {
    'Start' {
        Start-OrResumeVM -Machine $vm
    }
    'Resume' {
        Start-OrResumeVM -Machine $vm
    }
    'Pause' {
        if ([string]$vm.State -in @('Running', 'Paused')) {
            Save-VM -Name $VMName -Confirm:$false -ErrorAction Stop
        }
    }
    'Save' {
        if ([string]$vm.State -in @('Running', 'Paused')) {
            Save-VM -Name $VMName -Confirm:$false -ErrorAction Stop
        }
    }
    'Stop' {
        if ([string]$vm.State -in @('Running', 'Paused')) {
            Stop-VM -Name $VMName -Save -Confirm:$false -ErrorAction Stop
        }
    }
    'Connect' {
        if ([string]$vm.State -in @('Off', 'Saved')) {
            throw 'Start the VM before opening its connection window.'
        }
        Open-VMConnect -Name $VMName
    }
    'Status' {
        $memory = Get-VMMemory -VMName $VMName -ErrorAction Stop
        $processor = Get-VMProcessor -VMName $VMName -ErrorAction Stop
        $adapters = @(Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop)
        [pscustomobject]@{
            Name = $vm.Name
            State = [string]$vm.State
            CpuUsagePercent = $vm.CPUUsage
            ProcessorCount = $processor.Count
            ProcessorMaximumPercent = $processor.Maximum
            AssignedMemoryBytes = $vm.MemoryAssigned
            AssignedMemoryMB = [Math]::Round($vm.MemoryAssigned / 1MB, 0)
            MinimumMemoryBytes = $memory.Minimum
            MaximumMemoryBytes = $memory.Maximum
            OperationalStatus = [string]$vm.Status
            Uptime = [string]$vm.Uptime
            NetworkSwitches = @($adapters | Select-Object -ExpandProperty SwitchName -Unique)
        } | ConvertTo-Json -Depth 4
    }
    'Restart' {
        if ([string]$vm.State -eq 'Running') {
            Restart-VM -Name $VMName -Confirm:$false -ErrorAction Stop | Out-Null
            Open-VMConnect -Name $VMName
        }
        elseif ([string]$vm.State -eq 'Paused') {
            Resume-VM -Name $VMName -ErrorAction Stop | Out-Null
            Restart-VM -Name $VMName -Confirm:$false -ErrorAction Stop | Out-Null
            Open-VMConnect -Name $VMName
        }
        else {
            Start-OrResumeVM -Machine $vm
        }
    }
}
