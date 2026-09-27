# Codex App Isolated VM Automation

PowerShell 5.1 tooling for creating and managing a Generation 2 Hyper-V VM named `Codex-App-Isolated` on Windows 11 Pro.

## What setup configures

- A dynamically expanding 64 GB VHDX at `C:\Hyper-V\Codex-App-Isolated\Codex-App-Isolated.vhdx`.
- Four virtual processors with a 50 percent Hyper-V processor maximum, zero reserve, and relative weight 100.
- Dynamic memory with 4 GB startup, 2 GB minimum, 6 GB maximum, 20 percent buffer, and priority 50.
- Save-on-host-shutdown, manual host startup, the six requested integration services, and HvSocket Enhanced Session transport.
- The existing Default Switch when present. Otherwise, it detects a single existing switch whose host IPv4 address belongs to an active NAT prefix. It does not create or reconfigure host switches, NATs, or adapters.
- `C:\Codex-VM-Automation\` management scripts and launch shortcuts.

`Set-VMProcessor -Maximum 50` is a per-virtual-processor limit applied uniformly to the VM's virtual processors. On the inspected 16-logical-processor host, four vCPUs at 50 percent amount to roughly two logical-processor equivalents (12.5 percent of total host capacity); this is an inference from the documented per-processor behavior. It does not implement a 50 percent host-wide CPU-group cap. Hyper-V CPU groups use a separate Host Compute Service interface, which this project does not configure. The verified 6 GB setting is the guest memory maximum; it is not a measurement or strict ceiling for the complete VM worker-process footprint.

Run a no-change preflight:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -CheckOnly
```

Provision the VM:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

An optional `-GuestIsoPath 'X:\path\to\windows.iso'` attaches a selected ISO to the VM. Setup does not install Windows or sign in to Codex. A newly created VHDX is blank; Windows installation, guest account setup, Codex installation, and Codex account sign-in remain guest-side steps.

## Lifecycle controls

```powershell
C:\Codex-VM-Automation\launch-codex-vm.bat
C:\Codex-VM-Automation\pause-codex-vm.bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Codex-VM-Automation\manage-codex-vm.ps1 -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Codex-VM-Automation\manage-codex-vm.ps1 -Action Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Codex-VM-Automation\manage-codex-vm.ps1 -Action Restart
```

`Pause` saves the VM state so guest execution stops and active VM memory is released. `Stop` also saves state to preserve open guest sessions. Use `Save` to explicitly save, `Resume` to resume/start and connect, and `Connect` to open VMConnect for an already active VM.

Lifecycle actions require the current account to be an Administrator or a member of the local Hyper-V Administrators group.

## Host file access limits

Enhanced Session drive redirection is configured in VMConnect for each connection. The first connection must select the needed host drives under **Show Options > Local Resources > More**. The guest helper `GuestTools\unrestricted-drives-setup.ps1` maps drives already redirected through `\\tsclient` and sets user-level environment variables. Mapped files are accessed with the connected host user's permissions; this does not grant guest administrator rights on the host.

Setup deliberately leaves existing SMB share permissions alone and does not grant `Everyone` write access to drive roots. A VM with administrative write access to every host drive would not isolate the host filesystem. Host-wide SMB changes would also require guest credentials and a separate access decision. Existing shares can be used only with their current ACLs.

Enhanced Session drive selection is a VMConnect setting, not a supported `Set-VM` operation that setup can force without a session choice. Clipboard and audio availability depend on the Enhanced Session guest and its effective RDP policy.

## Microsoft references

- [Set-VMProcessor](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmprocessor?view=windowsserver2025-ps)
- [Hyper-V virtual machine resource controls](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/manage-hyper-v-cpugroups)
- [Share devices with a Hyper-V virtual machine](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/enhanced-session-mode)
- [Manage Hyper-V Integration Services](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/Manage-Hyper-V-integration-services)
- [Hyper-V Dynamic Memory](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/dynamic-memory)

## Verification

Run the source checks under Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Check-Project.ps1
```

Then run `setup.ps1 -CheckOnly` before provisioning. After setup, `manage-codex-vm.ps1 -Action Status` reports live VM state, processor usage/cap, assigned memory, operational status, and uptime.
