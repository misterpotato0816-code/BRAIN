# BRAIN shared test helper (Phase 4.5). Dot-source from test files:
#
#   . (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
#   Assert-BrainTestSandboxActive
#
# This file is intentionally NOT executed as a test: tests/run-all.ps1 only
# runs top-level *.ps1 files, and this helper lives in tests/helpers/.
# It performs no writes outside its own sandbox directory; the canary
# functions are strictly read-only.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:BRAIN_TEST_SANDBOX)) {
    $env:BRAIN_TEST_SANDBOX = Join-Path ([IO.Path]::GetTempPath()) ('brain-test-sandbox-' + [guid]::NewGuid().ToString('N'))
}
if (-not (Test-Path -LiteralPath $env:BRAIN_TEST_SANDBOX -PathType Container)) {
    New-Item -ItemType Directory -Path $env:BRAIN_TEST_SANDBOX -Force | Out-Null
}

function Assert-BrainTestSandboxActive {
    if ([string]::IsNullOrWhiteSpace($env:BRAIN_TEST_SANDBOX)) {
        throw 'TEST SAFETY VIOLATION: BRAIN_TEST_SANDBOX is not set.'
    }
    if (-not (Test-Path -LiteralPath $env:BRAIN_TEST_SANDBOX -PathType Container)) {
        throw "TEST SAFETY VIOLATION: sandbox directory is missing: $env:BRAIN_TEST_SANDBOX"
    }
}

function Get-BrainTestCanaryRoots {
    # This helper lives in tests/helpers/, i.e. TWO levels below the BRAIN
    # root, so go up twice. (A single '..' would land in tests/ and silently
    # watch tests/config + tests/store/raw, which do not exist.)
    $brainRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') '..'))
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($static in @(
        (Join-Path $env:USERPROFILE '.claude'),
        (Join-Path $env:USERPROFILE '.codex'),
        (Join-Path $env:USERPROFILE '.config\opencode'),
        (Join-Path $env:USERPROFILE '.cursor'),
        (Join-Path $env:USERPROFILE '.copilot'),
        (Join-Path $env:USERPROFILE '.gemini'),
        (Join-Path $brainRoot 'config'),
        (Join-Path $brainRoot 'store\raw')
    )) {
        if (-not ($roots -contains $static)) {
            $roots.Add($static)
        }
    }
    # Derive additional roots from the integration registry so provider N+1
    # is watched without editing this list. Read-only expansion only.
    try {
        $libPath = Join-Path $brainRoot 'lib\brain-integrations.ps1'
        if (Test-Path -LiteralPath $libPath -PathType Leaf) {
            . $libPath
            $definitions = @(Get-BrainIntegrationDefinitions -SetupRoot $brainRoot)
            foreach ($definition in $definitions) {
                try {
                    $declaredRoots = @($definition.ConfigRoots)
                }
                catch {
                    $declaredRoots = @()
                }
                foreach ($entry in $declaredRoots) {
                    $text = ([string]$entry).Trim()
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }
                    if ($text.StartsWith('~/') -or $text.StartsWith('~\') -or $text -eq '~') {
                        $text = $env:USERPROFILE + $text.Substring(1)
                    }
                    $text = [Environment]::ExpandEnvironmentVariables($text)
                    try {
                        $full = [IO.Path]::GetFullPath($text)
                    }
                    catch {
                        continue
                    }
                    if (-not ($roots -contains $full)) {
                        $roots.Add($full)
                    }
                }
                try {
                    $relative = ([string]$definition.ConfigRelativePath).Trim()
                }
                catch {
                    $relative = ''
                }
                if (-not [string]::IsNullOrWhiteSpace($relative)) {
                    $parent = Split-Path -Parent (Join-Path $env:USERPROFILE $relative)
                    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not ($roots -contains $parent)) {
                        $roots.Add($parent)
                    }
                }
            }
        }
    }
    catch {
    }
    return @($roots.ToArray())
}

# Third-party runtime churn written continuously by live AI tools (session
# transcripts, metrics, shell history, cache, Claude's own .claude.json
# backups). BRAIN's own backups use the distinct *.brain-backup-* pattern,
# which stays watched.
$script:BrainCanarySkippedDirNames = @(
    'node_modules', 'sessions', 'session-data', 'metrics', 'history',
    'logs', 'cache', 'local storage', 'session storage', 'sharedstorage',
    'blob_storage', 'gpucache', 'dawncache', 'crashpad', 'conversations',
    'ai-tracking', 'skills-cursor'
)
$script:BrainCanarySkippedFilePatterns = @('*.tmp', '*.log', '*.jsonl', '*.key', '*.wal', '*.shm', '*.sock', 'LOCK', 'LOG*', '.claude.json.backup.*')

function Test-BrainCanarySkippedFile {
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($pattern in $script:BrainCanarySkippedFilePatterns) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function New-BrainTestCanary {
    $entries = [Collections.Generic.List[pscustomobject]]::new()
    # Same two-level rule as Get-BrainTestCanaryRoots above: this helper
    # lives in tests/helpers/.
    $brainRepoRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') '..'))
    foreach ($root in (Get-BrainTestCanaryRoots)) {
        if (-not (Test-Path -LiteralPath $root)) {
            $entries.Add([pscustomobject]@{ Root = $root; Exists = $false; Relative = $null; Length = $null; Ticks = $null; Hash = $null })
            continue
        }
        # The BRAIN repo itself always gets a full scan; user-profile roots
        # skip documented runtime churn (see above). Direct children of a
        # root are always recorded, so new top-level entries can never hide.
        $fullScan = ([IO.Path]::GetFullPath($root)).StartsWith($brainRepoRoot, [StringComparison]::OrdinalIgnoreCase)
        $stack = [Collections.Generic.Stack[object]]::new()
        $stack.Push([pscustomobject]@{ Dir = $root; Depth = 0 })
        $files = [Collections.Generic.List[object]]::new()
        while ($stack.Count -gt 0) {
            $frame = $stack.Pop()
            $dir = [string]$frame.Dir
            $depth = [int]$frame.Depth
            foreach ($child in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
                if ($child.PSIsContainer) {
                    $skipSubtree = (-not $fullScan) -and (
                        [string]::Equals($child.Name, 'node_modules', [StringComparison]::OrdinalIgnoreCase) -or
                        ($script:BrainCanarySkippedDirNames -contains $child.Name.ToLowerInvariant()))
                    if ($skipSubtree -and $depth -gt 0) {
                        # Churn subtree below the top level: fully invisible.
                        continue
                    }
                    if ($skipSubtree) {
                        # Direct child: recorded as a DIR entry (never recursed).
                        $files.Add($child)
                    }
                    else {
                        $stack.Push([pscustomobject]@{ Dir = $child.FullName; Depth = ($depth + 1) })
                    }
                }
                else {
                    # Skipped runtime patterns are invisible at every depth:
                    # depth-0 recording caused constant false positives from
                    # live shell/transcript logs, while no BRAIN code path
                    # writes such files. Directories are still always
                    # recorded at depth 0, so new top-level entries can't hide.
                    if (-not $fullScan -and (Test-BrainCanarySkippedFile -Name $child.Name)) { continue }
                    $files.Add($child)
                }
            }
        }
        $files = @($files)
        if ($files.Count -eq 0) {
            $entries.Add([pscustomobject]@{ Root = $root; Exists = $true; Relative = ''; Length = 0; Ticks = 0; Hash = 'EMPTY' })
        }
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($root.Length)
            if ($file.PSIsContainer) {
                $entries.Add([pscustomobject]@{
                    Root = $root
                    Exists = $true
                    Relative = $relative
                    Length = -1
                    Ticks = $file.LastWriteTimeUtc.Ticks
                    Hash = 'DIR'
                })
                continue
            }
            $hash = $null
            # Hash small files byte-for-byte; for large ones length+mtime is
            # sufficient change evidence and keeps the canary fast.
            if ($file.Length -le 1048576) {
                try {
                    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                }
                catch {
                    $hash = 'UNREADABLE'
                }
            }
            $entries.Add([pscustomobject]@{
                Root = $root
                Exists = $true
                Relative = $relative
                Length = $file.Length
                Ticks = $file.LastWriteTimeUtc.Ticks
                Hash = $hash
            })
        }
    }
    return [pscustomobject]@{ TakenAt = [DateTimeOffset]::UtcNow; Entries = @($entries.ToArray()) }
}

function Test-BrainTestCanary {
    param([Parameter(Mandatory = $true)][object]$Before)

    $after = New-BrainTestCanary
    $violations = [Collections.Generic.List[string]]::new()
    $keyOf = { param($e) return ([string]$e.Root + "`n" + [string]$e.Relative) }
    $beforeMap = @{}
    foreach ($entry in @($Before.Entries)) { $beforeMap[(&$keyOf $entry)] = $entry }
    $afterMap = @{}
    foreach ($entry in @($after.Entries)) { $afterMap[(&$keyOf $entry)] = $entry }
    foreach ($key in @($beforeMap.Keys)) {
        if (-not $afterMap.ContainsKey($key)) {
            $violations.Add("missing after test: $key")
        }
    }
    foreach ($key in @($afterMap.Keys)) {
        if (-not $beforeMap.ContainsKey($key)) {
            $violations.Add("created during test: $key")
        }
    }
    foreach ($key in @($beforeMap.Keys)) {
        if (-not $afterMap.ContainsKey($key)) { continue }
        $b = $beforeMap[$key]
        $a = $afterMap[$key]
        if ([string]$b.Exists -ne [string]$a.Exists) {
            $violations.Add("existence changed: $key")
            continue
        }
        if ($null -eq $b.Relative) { continue }
        if ([string]$b.Length -ne [string]$a.Length -or [string]$b.Ticks -ne [string]$a.Ticks) {
            $violations.Add("modified during test: $key")
            continue
        }
        if ($null -ne $b.Hash -and $null -ne $a.Hash -and [string]$b.Hash -ne [string]$a.Hash) {
            $violations.Add("content changed during test: $key")
        }
    }
    return @($violations.ToArray())
}
