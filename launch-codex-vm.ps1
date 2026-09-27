[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$manager = Join-Path $PSScriptRoot 'manage-codex-vm.ps1'
& $manager -Action Start
