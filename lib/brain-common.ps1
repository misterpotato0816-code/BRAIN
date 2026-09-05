function Get-BrainVersion {
    param([Parameter(Mandatory = $true)][string]$BrainRoot)

    try {
        $versionFile = Join-Path $BrainRoot 'VERSION'
        if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
            return '0.0.0-unknown'
        }
        foreach ($line in (Get-Content -LiteralPath $versionFile -Encoding UTF8)) {
            $trimmed = $line.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                return $trimmed
            }
        }
        return '0.0.0-unknown'
    }
    catch {
        return '0.0.0-unknown'
    }
}

function Get-BrainCanonicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root) -or $full.Length -le $root.Length) {
        return $full
    }
    return $full.TrimEnd('\', '/')
}

function Get-BrainCanonicalDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Path is not a directory: $Path"
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse-point project directories are not supported: $Path"
    }
    return Get-BrainCanonicalPath -Path $item.FullName
}

function Test-BrainPathEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [string]::Equals(
        (Get-BrainCanonicalPath -Path $Left),
        (Get-BrainCanonicalPath -Path $Right),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Test-BrainPathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $canonicalPath = Get-BrainCanonicalPath -Path $Path
    $canonicalRoot = Get-BrainCanonicalPath -Path $Root
    if ([string]::Equals($canonicalPath, $canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($canonicalRoot.EndsWith('\') -or $canonicalRoot.EndsWith('/')) {
        $prefix = $canonicalRoot
    }
    else {
        $prefix = $canonicalRoot + [IO.Path]::DirectorySeparatorChar
    }
    return $canonicalPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-BrainPathRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root)) { return $false }
    return [string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)
}

function Read-BrainProjectRegistry {
    param([Parameter(Mandatory = $true)][string]$ProjectsFile)

    if (-not (Test-Path -LiteralPath $ProjectsFile -PathType Leaf)) {
        throw "BRAIN registry is missing: $ProjectsFile"
    }
    $raw = Get-Content -LiteralPath $ProjectsFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "BRAIN registry is empty: $ProjectsFile"
    }
    try {
        return @($raw | ConvertFrom-Json -Depth 20)
    }
    catch {
        throw "BRAIN registry is invalid JSON: $ProjectsFile"
    }
}

function Resolve-BrainProject {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Projects,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $canonicalPath = Get-BrainCanonicalPath -Path $Path
    $candidates = @()
    foreach ($entry in $Projects) {
        try {
            $entryPath = [string]$entry.path
        }
        catch {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($entryPath)) { continue }
        try {
            if (Test-BrainPathWithin -Path $canonicalPath -Root $entryPath) {
                $candidates += [pscustomobject]@{
                    Entry = $entry
                    CanonicalEntryPath = (Get-BrainCanonicalPath -Path $entryPath)
                }
            }
        }
        catch {
            continue
        }
    }
    if ($candidates.Count -eq 0) { return $null }

    $selected = @($candidates | Sort-Object { $_.CanonicalEntryPath.Length } -Descending)[0]
    return [pscustomobject]@{
        id = [string]$selected.Entry.id
        path = $selected.CanonicalEntryPath
    }
}

function Get-BrainTrustedRoots {
    param(
        [Parameter(Mandatory = $true)][string]$BrainRoot,
        [scriptblock]$LogAction = $null
    )

    $configPath = Join-Path $BrainRoot 'config\trusted-roots.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return @() }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    }
    catch {
        return @()
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    try {
        $parsed = $raw | ConvertFrom-Json -Depth 10
    }
    catch {
        if ($null -ne $LogAction) {
            & $LogAction ("Trusted roots config is invalid JSON, auto-registration stays disabled: " + $_.Exception.Message)
        }
        return @()
    }

    $roots = @()
    $entries = @()
    $property = $parsed.PSObject.Properties['trusted_roots']
    if ($null -ne $property) { $entries = @($property.Value) }
    foreach ($entry in $entries) {
        $value = [string]$entry
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if (-not [IO.Path]::IsPathRooted($value)) {
            if ($null -ne $LogAction) {
                & $LogAction ("Ignored relative trusted root: " + $value)
            }
            continue
        }
        $roots += (Get-BrainCanonicalPath -Path $value)
    }
    return @($roots)
}

function Test-BrainProjectRegistrable {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Projects,
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$BrainRoot,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$TrustedRoots = @()
    )

    $canonical = Get-BrainCanonicalPath -Path $CandidatePath

    if (Test-BrainPathWithin -Path $canonical -Root $BrainRoot) {
        return [pscustomobject]@{
            Allowed = $false
            Reason = 'The BRAIN root cannot be registered as a project.'
        }
    }

    if (Test-BrainPathRoot -Path $canonical) {
        return [pscustomobject]@{
            Allowed = $false
            Reason = "A drive or volume root cannot be registered as a project: $canonical"
        }
    }

    foreach ($root in $TrustedRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (Test-BrainPathEqual -Left $canonical -Right $root) {
            return [pscustomobject]@{
                Allowed = $false
                Reason = "A trusted root cannot be registered as a project: $canonical"
            }
        }
    }

    foreach ($entry in $Projects) {
        try {
            $entryPath = [string]$entry.path
        }
        catch {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($entryPath)) { continue }
        if (Test-BrainPathEqual -Left $entryPath -Right $canonical) { continue }
        try {
            if (Test-BrainPathWithin -Path $entryPath -Root $canonical) {
                return [pscustomobject]@{
                    Allowed = $false
                    Reason = "A parent directory of registered project '$([string]$entry.id)' cannot be registered as a project: $canonical"
                }
            }
        }
        catch {
            continue
        }
        try {
            if (Test-BrainPathWithin -Path $canonical -Root $entryPath) {
                return [pscustomobject]@{
                    Allowed = $false
                    Reason = "A subdirectory of registered project '$([string]$entry.id)' cannot be registered as a project: $canonical"
                }
            }
        }
        catch {
            continue
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Reason = ''
    }
}
