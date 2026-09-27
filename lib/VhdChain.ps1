function Get-VhdPathChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $currentPath = [IO.Path]::GetFullPath($Path)
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $chain = @()

    for ($depth = 0; $depth -lt 128; $depth++) {
        if (-not $visited.Add($currentPath)) {
            throw ('The VHD parent chain contains a cycle at {0}.' -f $currentPath)
        }

        $disk = Get-VHD -Path $currentPath -ErrorAction Stop
        $chain += $disk
        if ([string]::IsNullOrWhiteSpace($disk.ParentPath)) {
            return $chain
        }

        $currentPath = [IO.Path]::GetFullPath($disk.ParentPath)
    }

    throw ('The VHD parent chain exceeds the safety limit for {0}.' -f $Path)
}
