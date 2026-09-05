# BRAIN Integration Registry (Phase 2).
#
# BRAIN Core must not carry per-AI knowledge (event names, matchers, timeouts,
# hook JSON shapes, config paths, Stop output shapes). That knowledge lives in
# small per-integration definitions under integrations/providers/*.ps1, and this
# file only discovers them, tracks enable/disable state, and resolves unknown
# ids safely.
#
# Design notes:
# - Definitions are plain hashtables so a new provider is one file + tests.
# - config/integrations.json is optional. When it is missing or invalid, every
#   known integration is treated as enabled (Phase 1 backward compatibility).
# - Unknown ids never crash: lookups return $null and callers fail open with a
#   clear error. Unknown entries inside integrations.json are ignored.

function Get-BrainDefaultIntegrationDefinitions {
    return @(
        @{
            Id = 'codex'
            Name = 'Codex'
            DisplayName = 'Codex'
            ConfigRelativePath = '.codex\hooks.json'
            HandlerStyle = 'CodexCommandString'
            HookIdPrefix = 'brain.codex.'
            StatusPrefix = 'BRAIN Codex '
            StopStyle = 'DecisionBlock'
            Capabilities = @{ Install = $true; Repair = $true; Uninstall = $true }
            Events = @(
                @{ EventName = 'SessionStart'; Matcher = 'startup|resume|clear|compact'; Timeout = 15 },
                @{ EventName = 'PostToolUse'; Matcher = 'apply_patch|Edit|Write'; Timeout = 10 },
                @{ EventName = 'Stop'; Matcher = ''; Timeout = 30 },
                @{ EventName = 'SessionEnd'; Matcher = 'other'; Timeout = 3 }
            )
        },
        @{
            Id = 'claude'
            Name = 'Claude'
            DisplayName = 'Claude'
            ConfigRelativePath = '.claude\settings.json'
            HandlerStyle = 'ClaudeArgsArray'
            HookIdPrefix = 'brain.claude.'
            StatusPrefix = 'BRAIN Claude '
            StopStyle = 'HookSpecific'
            Capabilities = @{ Install = $true; Repair = $true; Uninstall = $true }
            Events = @(
                @{ EventName = 'SessionStart'; Matcher = 'startup|resume|clear|compact'; Timeout = 15 },
                @{ EventName = 'PostToolUse'; Matcher = 'Edit|Write|NotebookEdit'; Timeout = 10 },
                @{ EventName = 'Stop'; Matcher = ''; Timeout = 30 },
                @{ EventName = 'SessionEnd'; Matcher = 'clear|resume|logout|prompt_input_exit|other'; Timeout = 10 }
            )
        }
    )
}

function Get-BrainIntegrationDefinitions {
    param([string]$SetupRoot = '')

    $definitions = @()
    $providersDir = $null
    if (-not [string]::IsNullOrWhiteSpace($SetupRoot)) {
        $providersDir = Join-Path $SetupRoot 'integrations\providers'
    }
    if ($null -ne $providersDir -and (Test-Path -LiteralPath $providersDir -PathType Container)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $providersDir -File -Filter '*.ps1' | Sort-Object Name)) {
            try {
                $definition = & $file.FullName
                if ($null -eq $definition) { continue }
                if ($definition -is [System.Collections.IEnumerable] -and $definition -isnot [Collections.IDictionary]) {
                    foreach ($item in $definition) {
                        if ($null -ne $item) { $definitions += $item }
                    }
                }
                else {
                    $definitions += $definition
                }
            }
            catch {
                # A broken provider file must not take down the whole registry.
                continue
            }
        }
    }
    if ($definitions.Count -eq 0) {
        $definitions = @(Get-BrainDefaultIntegrationDefinitions)
    }
    return @($definitions | Sort-Object { [string]$_.Id })
}

function Get-BrainIntegration {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Definitions,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $normalized = ([string]$Id).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }
    foreach ($definition in $Definitions) {
        try {
            $candidate = ([string]$definition.Id).Trim().ToLowerInvariant()
        }
        catch {
            continue
        }
        if ($candidate -eq $normalized) { return $definition }
        try {
            $candidateName = ([string]$definition.Name).Trim().ToLowerInvariant()
        }
        catch {
            $candidateName = ''
        }
        if ($candidateName -eq $normalized) { return $definition }
    }
    return $null
}

function Get-BrainIntegrationsStatePath {
    param([Parameter(Mandatory = $true)][string]$BrainRoot)

    return (Join-Path $BrainRoot 'config\integrations.json')
}

function Get-BrainEnabledIntegrationIds {
    param(
        [Parameter(Mandatory = $true)][string]$BrainRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Definitions
    )

    $knownIds = @($Definitions | ForEach-Object { ([string]$_.Id).Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $statePath = Get-BrainIntegrationsStatePath -BrainRoot $BrainRoot
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return @($knownIds)
    }
    try {
        $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @($knownIds) }
        $parsed = $raw | ConvertFrom-Json -Depth 10
    }
    catch {
        return @($knownIds)
    }
    $enabledProperty = $parsed.PSObject.Properties['enabled']
    if ($null -eq $enabledProperty -or $null -eq $enabledProperty.Value) {
        return @($knownIds)
    }
    $enabledValue = $enabledProperty.Value
    # NOTE: ConvertFrom-Json yields PSCustomObject (not IDictionary) unless
    # -AsHashtable is used. Handle both shapes here.
    if ($enabledValue -is [Collections.IDictionary]) {
        $result = [Collections.Generic.List[string]]::new()
        foreach ($id in $knownIds) {
            if ($enabledValue.Contains($id)) {
                if ([bool]$enabledValue[$id]) { $result.Add($id) }
            }
            else {
                # Integrations not mentioned stay enabled (backward compatible).
                $result.Add($id)
            }
        }
        return @($result.ToArray())
    }
    if ($enabledValue -is [psobject] -and $null -ne $enabledValue.PSObject.Properties) {
        $propertyNames = @($enabledValue.PSObject.Properties | ForEach-Object { [string]$_.Name })
        $result = [Collections.Generic.List[string]]::new()
        foreach ($id in $knownIds) {
            if ($propertyNames -contains $id) {
                if ([bool]$enabledValue.PSObject.Properties[$id].Value) { $result.Add($id) }
            }
            else {
                $result.Add($id)
            }
        }
        return @($result.ToArray())
    }
    if ($enabledValue -is [System.Collections.IEnumerable] -and $enabledValue -isnot [string]) {
        $allowed = @{}
        foreach ($entry in $enabledValue) {
            $key = ([string]$entry).Trim().ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($key)) { $allowed[$key] = $true }
        }
        return @($knownIds | Where-Object { $allowed.ContainsKey($_) })
    }
    return @($knownIds)
}

function Test-BrainIntegrationEnabled {
    param(
        [Parameter(Mandatory = $true)][string]$BrainRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Definitions,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $normalized = ([string]$Id).Trim().ToLowerInvariant()
    return ((Get-BrainEnabledIntegrationIds -BrainRoot $BrainRoot -Definitions $Definitions) -contains $normalized)
}

function Set-BrainIntegrationEnabled {
    param(
        [Parameter(Mandatory = $true)][string]$BrainRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Definitions,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $definition = Get-BrainIntegration -Definitions $Definitions -Id $Id
    if ($null -eq $definition) {
        throw "Unknown integration: $Id. Known integrations: $(@($Definitions | ForEach-Object { [string]$_.Id }) -join ', ')."
    }
    $normalized = ([string]$definition.Id).Trim().ToLowerInvariant()

    $statePath = Get-BrainIntegrationsStatePath -BrainRoot $BrainRoot
    $map = [ordered]@{}
    if ((Test-Path -LiteralPath $statePath -PathType Leaf)) {
        try {
            $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json -Depth 10
                $enabledProperty = $parsed.PSObject.Properties['enabled']
                if ($null -ne $enabledProperty -and $null -ne $enabledProperty.Value) {
                    $enabledValue = $enabledProperty.Value
                    if ($enabledValue -is [Collections.IDictionary]) {
                        foreach ($key in @($enabledValue.Keys)) {
                            $map[[string]$key] = [bool]$enabledValue[$key]
                        }
                    }
                    else {
                        # ConvertFrom-Json yields PSCustomObject by default.
                        foreach ($property in @($enabledValue.PSObject.Properties)) {
                            $map[[string]$property.Name] = [bool]$property.Value
                        }
                    }
                }
            }
        }
        catch {
            $map = [ordered]@{}
        }
    }
    # Preserve keys for known integrations not yet mentioned (default enabled).
    foreach ($known in $Definitions) {
        $key = ([string]$known.Id).Trim().ToLowerInvariant()
        if (-not $map.Contains($key)) { $map[$key] = $true }
    }
    $map[$normalized] = $Enabled

    $parent = Split-Path -Parent $statePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $payload = [ordered]@{
        format_version = '0.1'
        enabled = $map
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 10
    $temporary = Join-Path $parent ('.brain-integrations-tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, ($json + "`n"), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $statePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    return $normalized
}

# Phase 4.5 test-isolation primitives. When the BRAIN_TEST_SANDBOX
# environment variable points at a directory, test execution is active and
# every resolved (non-explicit) integration target must stay inside it.
# Explicit CLI path overrides remain the caller's responsibility.
# The write guard reads the environment DIRECTLY (never via a helper) so a
# single corrupted seam cannot disable both the forcing and the guard.

function Get-BrainTestSandboxDir {
    return ([string]$env:BRAIN_TEST_SANDBOX).Trim()
}

function Test-BrainSandboxPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SandboxDir
    )

    try {
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetFullPath($SandboxDir)
    }
    catch {
        return $false
    }
    if ([string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-BrainSandboxWriteAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Provenance = 'resolved'
    )

    # Independent env read (deliberately different expression text than the
    # forcing helper above): see the comment above.
    $sandbox = "$env:BRAIN_TEST_SANDBOX".Trim()
    if ([string]::IsNullOrWhiteSpace($sandbox)) { return }
    if ($Provenance -eq 'explicit') { return }
    $inside = $false
    try {
        $inside = Test-BrainSandboxPath -Path $Path -SandboxDir $sandbox
    }
    catch {
        $inside = $false
    }
    if (-not $inside) {
        throw "TEST SAFETY VIOLATION: write target escapes sandbox (target=$Path)."
    }
}

function Get-BrainIntegrationConfigPath {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$SetupRoot
    )

    # Explicit CLI overrides for the two built-in providers stay in
    # brain-setup.ps1; this is only the default location for any integration
    # (including future ones) relative to the user profile.
    $base = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [IO.Path]::GetTempPath() }
    return (Join-Path $base ([string]$Definition.ConfigRelativePath))
}

# Phase 3 generic helpers. All provider knowledge stays in the integration
# definition; these functions only interpret the declarative schema.
# No provider id or name may appear here.

function Get-BrainIntegrationArtifactKind {
    param([Parameter(Mandatory = $true)][object]$Definition)

    try {
        $kind = ([string]$Definition.ArtifactKind).Trim()
    }
    catch {
        $kind = ''
    }
    if ([string]::IsNullOrWhiteSpace($kind)) { return 'HookJson' }
    return $kind
}

# Phase 4 generic helpers. HookJson artifacts come in more than one JSON
# dialect (Claude/Codex nest groups under each event; other tools use a flat
# per-event command list). The dialect is declarative data on the definition;
# no provider id or name may appear here.

function Get-BrainIntegrationHookSchema {
    param([Parameter(Mandatory = $true)][object]$Definition)

    try {
        $schema = ([string]$Definition.HookSchema).Trim()
    }
    catch {
        $schema = ''
    }
    if ([string]::IsNullOrWhiteSpace($schema)) { return 'ClaudeNested' }
    return $schema
}

function Get-BrainIntegrationConfigFileName {
    param([Parameter(Mandatory = $true)][object]$Definition)

    try {
        $name = ([string]$Definition.ConfigFileName).Trim()
    }
    catch {
        $name = ''
    }
    return $name
}

# Ordered stdin field aliases used to resolve a session id / working
# directory out of a provider's hook payload. First present, non-empty value
# wins; arrays contribute their first element (e.g. workspace root lists).
function Get-BrainIntegrationSessionIdFields {
    param([Parameter(Mandatory = $true)][object]$Definition)

    try {
        $fields = @($Definition.SessionIdFields)
    }
    catch {
        $fields = @()
    }
    $names = @($fields | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($names.Count -eq 0) { return @('session_id') }
    return @($names)
}

function Get-BrainIntegrationCwdFields {
    param([Parameter(Mandatory = $true)][object]$Definition)

    try {
        $fields = @($Definition.CwdFields)
    }
    catch {
        $fields = @()
    }
    $names = @($fields | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($names.Count -eq 0) { return @('cwd') }
    return @($names)
}

# Optional environment-directed root: @{ Var = 'NAME'; Sub = 'subdir' }.
# When the variable is set, "$var\Sub" is the canonical root (generic; no
# provider names here).
function Get-BrainIntegrationEnvRoot {
    param([Parameter(Mandatory = $true)][object]$Definition)

    $spec = $null
    try {
        $spec = $Definition.ConfigRootEnv
    }
    catch {
        return ''
    }
    if ($null -eq $spec) { return '' }
    $var = ''
    $sub = ''
    if ($spec -is [Collections.IDictionary]) {
        $var = ([string]$spec['Var']).Trim()
        $sub = ([string]$spec['Sub']).Trim()
    }
    else {
        try {
            $var = ([string]$spec.Var).Trim()
            $sub = ([string]$spec.Sub).Trim()
        }
        catch {
            return ''
        }
    }
    if ([string]::IsNullOrWhiteSpace($var)) { return '' }
    $base = [Environment]::GetEnvironmentVariable($var)
    if ([string]::IsNullOrWhiteSpace($base)) { return '' }
    $full = $base
    if (-not [string]::IsNullOrWhiteSpace($sub)) {
        $full = Join-Path $base $sub
    }
    try {
        return [IO.Path]::GetFullPath($full)
    }
    catch {
        return ''
    }
}

function Resolve-BrainIntegrationRoot {
    param([Parameter(Mandatory = $true)][object]$Definition)

    # An environment-directed root (e.g. COPILOT_HOME) takes precedence when
    # set, whether or not it exists yet: the vendor defines it as canonical.
    $envRoot = Get-BrainIntegrationEnvRoot -Definition $Definition
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) { return $envRoot }

    $candidates = @()
    try {
        $roots = @($Definition.ConfigRoots)
    }
    catch {
        $roots = @()
    }
    foreach ($entry in $roots) {
        $text = ([string]$entry).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text.StartsWith('~/') -or $text.StartsWith('~\') -or $text -eq '~') {
            $homeBase = $env:USERPROFILE
            if ([string]::IsNullOrWhiteSpace($homeBase)) { $homeBase = [IO.Path]::GetTempPath() }
            $text = $homeBase + $text.Substring(1)
        }
        $text = [Environment]::ExpandEnvironmentVariables($text)
        try {
            $candidates += [IO.Path]::GetFullPath($text)
        }
        catch {
            continue
        }
    }
    if ($candidates.Count -eq 0) {
        return (Get-BrainIntegrationConfigPath -Definition $Definition -SetupRoot '')
    }
    # Ordered candidates: the first EXISTING root wins (mirrors how layered
    # tools fall back between parallel install locations); otherwise the
    # first entry is the install target.
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $candidates[0]
}

function Get-BrainIntegrationPluginFileName {
    param([Parameter(Mandatory = $true)][object]$Definition)

    try {
        $name = ([string]$Definition.PluginFileName).Trim()
    }
    catch {
        $name = ''
    }
    if ([string]::IsNullOrWhiteSpace($name)) { return 'brain.js' }
    return $name
}

function Get-BrainIntegrationPluginMarker {
    param([Parameter(Mandatory = $true)][object]$Definition)

    try {
        $marker = ([string]$Definition.PluginManagedMarker).Trim()
    }
    catch {
        $marker = ''
    }
    if ([string]::IsNullOrWhiteSpace($marker)) { return '// managed by BRAIN' }
    return $marker
}

function Test-BrainPluginFileManaged {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $firstLine = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    }
    catch {
        return $false
    }
    $marker = Get-BrainIntegrationPluginMarker -Definition $Definition
    return (([string]$firstLine).Trim().StartsWith($marker, [StringComparison]::Ordinal))
}
