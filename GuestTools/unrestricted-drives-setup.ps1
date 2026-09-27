[CmdletBinding()]
param(
    [ValidateRange(72, 90)]
    [int]$FirstDriveLetterCode = 72
)

$ErrorActionPreference = 'Stop'
$redirectedRoot = '\\tsclient'
if (-not (Test-Path -LiteralPath $redirectedRoot -PathType Container)) {
    throw 'Enhanced Session host-drive redirection is unavailable. In VMConnect, enable the required drives under Show Options > Local Resources > More, then sign out and reconnect to the guest.'
}

$hostDrives = @(Get-ChildItem -LiteralPath $redirectedRoot -Directory -ErrorAction Stop | Sort-Object -Property Name)
if ($hostDrives.Count -eq 0) {
    throw 'No host drives are redirected into this guest session.'
}

$usedLetters = @{}
foreach ($drive in @(Get-PSDrive -PSProvider FileSystem)) {
    $usedLetters[$drive.Name.ToUpperInvariant()] = $true
}

$mappings = @()
$failures = @()
$nextLetterCode = $FirstDriveLetterCode
foreach ($hostDrive in $hostDrives) {
    while ($nextLetterCode -le 90 -and $usedLetters.ContainsKey(([char]$nextLetterCode).ToString())) {
        $nextLetterCode++
    }
    if ($nextLetterCode -gt 90) {
        $failures += ('No unused drive letter remains for host drive {0}.' -f $hostDrive.Name)
        continue
    }

    $letter = ([char]$nextLetterCode).ToString()
    $target = '{0}:\' -f $letter
    try {
        New-PSDrive -Name $letter -PSProvider FileSystem -Root $hostDrive.FullName -Persist -Scope Global -ErrorAction Stop | Out-Null
        $usedLetters[$letter] = $true
        $mappings += [pscustomobject]@{
            HostDrive = $hostDrive.Name
            GuestDrive = $target
            Root = $hostDrive.FullName
        }
    }
    catch {
        $failures += ('{0} -> {1}: {2}' -f $hostDrive.FullName, $target, $_.Exception.Message)
    }
    $nextLetterCode++
}

if ($mappings.Count -eq 0) {
    throw ('No redirected host drives could be mapped. {0}' -f ($failures -join '; '))
}

$driveLetters = @($mappings | ForEach-Object { $_.GuestDrive })
$driveMap = @($mappings | ForEach-Object { '{0}={1}' -f $_.GuestDrive, $_.Root })
[Environment]::SetEnvironmentVariable('CODEX_HOST_DRIVES', ($driveLetters -join ';'), 'User')
[Environment]::SetEnvironmentVariable('CODEX_HOST_DRIVE_MAP', ($driveMap -join ';'), 'User')
$env:CODEX_HOST_DRIVES = $driveLetters -join ';'
$env:CODEX_HOST_DRIVE_MAP = $driveMap -join ';'

[pscustomobject]@{
    MappedDrives = $mappings
    Failures = $failures
    UserEnvironmentVariables = @('CODEX_HOST_DRIVES', 'CODEX_HOST_DRIVE_MAP')
    AccessNote = 'Mapped access uses the connected host user context and its file permissions.'
} | ConvertTo-Json -Depth 4
