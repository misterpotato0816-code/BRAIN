[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Update', 'Repair', 'Uninstall', 'Status', 'Backup', 'Restore', 'Integrations', 'Enable', 'Disable')]
    [string]$Action,

    [string]$BrainRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))),
    [string]$BrainHookPath = (Join-Path $PSScriptRoot 'brain-hook.ps1'),
    [string]$CodexHooksPath = '',
    [string]$ClaudeSettingsPath = '',
    [string]$CodexBackupPath,
    [string]$ClaudeBackupPath,
    [string]$Integration = '',
    [string]$ConfigPath = '',
    [string]$PluginPath = '',
    [string]$SandboxDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$brainLibrary = Join-Path $BrainRoot 'lib\brain-common.ps1'
if (-not (Test-Path -LiteralPath $brainLibrary -PathType Leaf)) {
    throw "BRAIN library is missing: $brainLibrary"
}
. $brainLibrary

# An explicit -SandboxDir becomes the gate for this invocation, so the
# pre-write guard below enforces the same sandbox the resolution layer used.
if (-not [string]::IsNullOrWhiteSpace($SandboxDir)) {
    $env:BRAIN_TEST_SANDBOX = $SandboxDir
}

# The integration registry ships with the setup script itself (Phase 2), not
# with the BrainRoot under management: existing test sandboxes copy only
# brain-common.ps1 into their BrainRoot, so resolve the registry next to this
# script first and fall back to embedded defaults when it is absent.
$BrainSetupRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$brainIntegrationsLibrary = Join-Path $BrainSetupRoot 'lib\brain-integrations.ps1'
if (Test-Path -LiteralPath $brainIntegrationsLibrary -PathType Leaf) {
    . $brainIntegrationsLibrary
    $BrainIntegrations = @(Get-BrainIntegrationDefinitions -SetupRoot $BrainSetupRoot)
}
else {
    $BrainIntegrations = @(
        @{ Id = 'codex'; Name = 'Codex'; DisplayName = 'Codex'; ConfigRelativePath = '.codex\hooks.json'; HandlerStyle = 'CodexCommandString'; HookIdPrefix = 'brain.codex.'; StatusPrefix = 'BRAIN Codex '; StopStyle = 'DecisionBlock'; Capabilities = @{ Install = $true; Repair = $true; Uninstall = $true }; Events = @(
            @{ EventName = 'SessionStart'; Matcher = 'startup|resume|clear|compact'; Timeout = 15 },
            @{ EventName = 'PostToolUse'; Matcher = 'apply_patch|Edit|Write'; Timeout = 10 },
            @{ EventName = 'Stop'; Matcher = ''; Timeout = 30 },
            @{ EventName = 'SessionEnd'; Matcher = 'other'; Timeout = 3 }
        ) },
        @{ Id = 'claude'; Name = 'Claude'; DisplayName = 'Claude'; ConfigRelativePath = '.claude\settings.json'; HandlerStyle = 'ClaudeArgsArray'; HookIdPrefix = 'brain.claude.'; StatusPrefix = 'BRAIN Claude '; StopStyle = 'HookSpecific'; Capabilities = @{ Install = $true; Repair = $true; Uninstall = $true }; Events = @(
            @{ EventName = 'SessionStart'; Matcher = 'startup|resume|clear|compact'; Timeout = 15 },
            @{ EventName = 'PostToolUse'; Matcher = 'Edit|Write|NotebookEdit'; Timeout = 10 },
            @{ EventName = 'Stop'; Matcher = ''; Timeout = 30 },
            @{ EventName = 'SessionEnd'; Matcher = 'clear|resume|logout|prompt_input_exit|other'; Timeout = 10 }
        ) }
    )
}

function Get-BrainSetupIntegration {
    param([Parameter(Mandatory = $true)][string]$Id)

    foreach ($definition in $BrainIntegrations) {
        if ([string]::Equals(([string]$definition.Id).Trim().ToLowerInvariant(), $Id.Trim().ToLowerInvariant(), [StringComparison]::Ordinal) -or
            [string]::Equals(([string]$definition.Name).Trim().ToLowerInvariant(), $Id.Trim().ToLowerInvariant(), [StringComparison]::Ordinal)) {
            return $definition
        }
    }
    return $null
}

function Get-BrainSetupArtifactKind {
    param([Parameter(Mandatory = $true)][object]$Definition)

    if (Get-Command Get-BrainIntegrationArtifactKind -ErrorAction SilentlyContinue) {
        return (Get-BrainIntegrationArtifactKind -Definition $Definition)
    }
    try {
        $kind = ([string]$Definition.ArtifactKind).Trim()
    }
    catch {
        $kind = ''
    }
    if ([string]::IsNullOrWhiteSpace($kind)) { return 'HookJson' }
    return $kind
}

function Get-BrainSetupConfigPath {
    param([Parameter(Mandatory = $true)][object]$Definition)

    $resolved = Resolve-BrainSetupTargetPath -Definition $Definition
    return $resolved.Path
}

# Provenance matters for the test sandbox: 'explicit' paths were handed in
# via CLI overrides (caller's responsibility); anything else is resolved from
# integration data or product defaults and must stay inside the test sandbox
# while BRAIN_TEST_SANDBOX is set.
function Resolve-BrainSetupTargetPath {
    param([Parameter(Mandatory = $true)][object]$Definition)

    $id = ([string]$Definition.Id).Trim().ToLowerInvariant()
    if ($id -eq 'codex' -and -not [string]::IsNullOrWhiteSpace($CodexHooksPath)) {
        return [pscustomobject]@{ Path = $CodexHooksPath; Provenance = 'explicit' }
    }
    if ($id -eq 'claude' -and -not [string]::IsNullOrWhiteSpace($ClaudeSettingsPath)) {
        return [pscustomobject]@{ Path = $ClaudeSettingsPath; Provenance = 'explicit' }
    }
    $kind = Get-BrainSetupArtifactKind -Definition $Definition
    if ($kind -eq 'PluginFile' -and -not [string]::IsNullOrWhiteSpace($PluginPath)) {
        return [pscustomobject]@{ Path = $PluginPath; Provenance = 'explicit' }
    }
    if ($kind -ne 'PluginFile' -and -not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return [pscustomobject]@{ Path = $ConfigPath; Provenance = 'explicit' }
    }
    $sandboxDir = $SandboxDir
    if ([string]::IsNullOrWhiteSpace($sandboxDir) -and (Get-Command Get-BrainTestSandboxDir -ErrorAction SilentlyContinue)) {
        # Test gate: no per-test argument can be forgotten; the environment
        # forces every resolved target below the sandbox.
        $sandboxDir = Get-BrainTestSandboxDir
    }
    if (-not [string]::IsNullOrWhiteSpace($sandboxDir)) {
        # Isolation support (tests, dry runs): every non-explicitly-overridden
        # target lands under one sandbox directory, deterministically derived
        # from the integration id / plugin file name. Provider-independent.
        if ($kind -eq 'PluginFile') {
            $fileName = 'brain.js'
            if (Get-Command Get-BrainIntegrationPluginFileName -ErrorAction SilentlyContinue) {
                $fileName = Get-BrainIntegrationPluginFileName -Definition $Definition
            }
            return [pscustomobject]@{ Path = (Join-Path $sandboxDir $fileName); Provenance = 'resolved' }
        }
        return [pscustomobject]@{ Path = (Join-Path $sandboxDir ($id + '.hooks.json')); Provenance = 'resolved' }
    }
    $hasRoots = $false
    try {
        $hasRoots = (@($Definition.ConfigRoots)).Count -gt 0
    }
    catch {
        $hasRoots = $false
    }
    if ($hasRoots -and (Get-Command Resolve-BrainIntegrationRoot -ErrorAction SilentlyContinue)) {
        $root = Resolve-BrainIntegrationRoot -Definition $Definition
        if ($kind -eq 'PluginFile') {
            $fileName = 'brain.js'
            if (Get-Command Get-BrainIntegrationPluginFileName -ErrorAction SilentlyContinue) {
                $fileName = Get-BrainIntegrationPluginFileName -Definition $Definition
            }
            return [pscustomobject]@{ Path = (Join-Path (Join-Path $root 'plugins') $fileName); Provenance = 'resolved' }
        }
        $configFileName = ''
        if (Get-Command Get-BrainIntegrationConfigFileName -ErrorAction SilentlyContinue) {
            $configFileName = Get-BrainIntegrationConfigFileName -Definition $Definition
        }
        if (-not [string]::IsNullOrWhiteSpace($configFileName)) {
            return [pscustomobject]@{ Path = (Join-Path $root $configFileName); Provenance = 'resolved' }
        }
        return [pscustomobject]@{ Path = $root; Provenance = 'resolved' }
    }
    $base = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [IO.Path]::GetTempPath() }
    return [pscustomobject]@{ Path = (Join-Path $base ([string]$Definition.ConfigRelativePath)); Provenance = 'resolved' }
}

# Provider-independent root-resolution detail for Status/diagnostics: which
# candidate roots were considered, which one won, and why.
function Get-BrainSetupRootDetail {
    param([Parameter(Mandatory = $true)][object]$Definition)

    $entries = @()
    try {
        $rawRoots = @($Definition.ConfigRoots)
    }
    catch {
        $rawRoots = @()
    }
    $selected = Get-BrainSetupConfigPath -Definition $Definition
    $envRoot = ''
    if (Get-Command Get-BrainIntegrationEnvRoot -ErrorAction SilentlyContinue) {
        $envRoot = Get-BrainIntegrationEnvRoot -Definition $Definition
    }
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        $entries += [pscustomobject]@{ path = $envRoot; exists = (Test-Path -LiteralPath $envRoot); env = $true }
    }
    if ($rawRoots.Count -eq 0) {
        return [pscustomobject]@{
            candidates = @()
            selected = $selected
            reason = 'single-path'
        }
    }
    foreach ($entry in $rawRoots) {
        $text = ([string]$entry).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $expanded = $text
        if ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\') -or $expanded -eq '~') {
            $homeBase = $env:USERPROFILE
            if ([string]::IsNullOrWhiteSpace($homeBase)) { $homeBase = [IO.Path]::GetTempPath() }
            $expanded = $homeBase + $expanded.Substring(1)
        }
        $expanded = [Environment]::ExpandEnvironmentVariables($expanded)
        try {
            $full = [IO.Path]::GetFullPath($expanded)
        }
        catch {
            continue
        }
        $entries += [pscustomobject]@{ path = $full; exists = (Test-Path -LiteralPath $full); env = $false }
    }
    $reason = 'default-first'
    foreach ($candidate in $entries) {
        if ($candidate.exists -and $selected.StartsWith($candidate.path, [StringComparison]::OrdinalIgnoreCase)) {
            $reason = 'first-existing'
            break
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($envRoot) -and $selected.StartsWith($envRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $reason = 'env-override'
    }
    return [pscustomobject]@{
        candidates = @($entries)
        selected = $selected
        reason = $reason
    }
}

function Get-BrainSetupEnabledIds {
    if (Get-Command Get-BrainEnabledIntegrationIds -ErrorAction SilentlyContinue) {
        return @(Get-BrainEnabledIntegrationIds -BrainRoot $BrainRoot -Definitions $BrainIntegrations)
    }
    return @($BrainIntegrations | ForEach-Object { ([string]$_.Id).Trim().ToLowerInvariant() })
}

function Get-BrainSetupTargets {
    param([string]$OnlyId = '')

    $enabledIds = @(Get-BrainSetupEnabledIds)
    $targets = @()
    foreach ($definition in $BrainIntegrations) {
        $id = ([string]$definition.Id).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($OnlyId)) {
            if ($id -ne $OnlyId.Trim().ToLowerInvariant()) { continue }
        }
        $resolved = Resolve-BrainSetupTargetPath -Definition $definition
        $targets += [pscustomobject]@{
            Definition = $definition
            Id = $id
            Path = [string]$resolved.Path
            Provenance = [string]$resolved.Provenance
            Enabled = ($enabledIds -contains $id)
        }
    }
    return @($targets)
}

function Assert-BrainSetupWriteAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Provenance = 'resolved'
    )

    if (Get-Command Assert-BrainSandboxWriteAllowed -ErrorAction SilentlyContinue) {
        Assert-BrainSandboxWriteAllowed -Path $Path -Provenance $Provenance
    }
}

# Fail-closed test guard: with the test gate set, a forgotten -BrainRoot
# would resolve to the shipped repository itself. Only Enable/Disable write
# below the BrainRoot (integrations.json); every other mutating action writes
# solely to per-target paths covered by the write guard, so only those two
# are refused here. Reads stay allowed.
function Assert-BrainSetupBrainRoot {
    param([Parameter(Mandatory = $true)][string]$Action)

    if ($Action -notin @('Enable', 'Disable')) { return }
    $sandbox = ''
    if (Get-Command Get-BrainTestSandboxDir -ErrorAction SilentlyContinue) {
        $sandbox = Get-BrainTestSandboxDir
    }
    else {
        $sandbox = ([string]$env:BRAIN_TEST_SANDBOX).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($sandbox)) { return }
    try {
        $rootFull = [IO.Path]::GetFullPath($BrainRoot)
        $shippedFull = [IO.Path]::GetFullPath($BrainSetupRoot)
    }
    catch {
        return
    }
    if ([string]::Equals($rootFull, $shippedFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "TEST SAFETY VIOLATION: mutating action '$Action' must not run against the shipped BRAIN root in test mode."
    }
}

function ConvertTo-BrainArray {
    param([object]$Value)

    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Test-BrainManagedHandler {
    param([Parameter(Mandatory = $true)][object]$Handler)

    if ($Handler -isnot [Collections.IDictionary]) { return $false }

    if ($Handler.Contains('brain_hook_id')) { return $true }
    if ($Handler.Contains('managed_by') -and [string]::Equals([string]$Handler['managed_by'], 'brain', [StringComparison]::Ordinal)) {
        return $true
    }
    if ($Handler.Contains('statusMessage')) {
        $status = [string]$Handler['statusMessage']
        if ($status -match '^BRAIN(\s+v[0-9][0-9.]*)?\s+(Codex|Claude)\s+\w+$') { return $true }
    }
    # Human-readable identity used by dialects without managed_by/brain_hook_id
    # (e.g. a documented `name` key). Third-party entries never carry it.
    if ($Handler.Contains('name')) {
        $hookName = ([string]$Handler['name']).Trim()
        if ($hookName.StartsWith('BRAIN ', [StringComparison]::Ordinal)) { return $true }
    }
    if ($Handler.Contains('command')) {
        $command = $Handler['command']
        if ($command -is [string] -and $command.IndexOf('brain-hook.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    # Per-OS command keys used by other tools' hook dialects (e.g. Copilot
    # CLI `powershell`/`bash`, direct `exec` paths). Same substring rule,
    # no provider knowledge.
    foreach ($commandKey in @('powershell', 'bash', 'exec')) {
        if ($Handler.Contains($commandKey)) {
            $commandValue = $Handler[$commandKey]
            if ($commandValue -is [string] -and $commandValue.IndexOf('brain-hook.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    }
    if ($Handler.Contains('args')) {
        foreach ($argValue in (ConvertTo-BrainArray -Value $Handler['args'])) {
            if ($argValue -is [string] -and $argValue.IndexOf('brain-hook.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    }
    return $false
}

function Read-BrainJsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{}
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }
    return ($raw | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Test-BrainJsonParseable {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
    try {
        $null = $raw | ConvertFrom-Json -AsHashtable -Depth 100
        return $true
    }
    catch {
        return $false
    }
}

function Remove-BrainHandlers {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Configuration)

    # Dialect-agnostic: handles Claude/Codex nested groups
    # ({matcher?, hooks:[handler...]}) as well as flat per-event command
    # entries ({command, timeout, matcher?}) used by other tools.
    $removed = 0
    if (-not $Configuration.Contains('hooks') -or $Configuration['hooks'] -isnot [Collections.IDictionary]) {
        return $removed
    }
    $hooks = $Configuration['hooks']
    $eventNames = @($hooks.Keys)
    foreach ($eventName in $eventNames) {
        $entries = ConvertTo-BrainArray -Value $hooks[$eventName]
        $keptEntries = @()
        foreach ($entry in $entries) {
            if ($entry -is [Collections.IDictionary] -and $entry.Contains('hooks')) {
                $handlers = ConvertTo-BrainArray -Value $entry['hooks']
                $keptHandlers = @()
                foreach ($handler in $handlers) {
                    if (Test-BrainManagedHandler -Handler $handler) {
                        $removed++
                    }
                    else {
                        $keptHandlers += $handler
                    }
                }
                if ($keptHandlers.Count -gt 0) {
                    $entry['hooks'] = @($keptHandlers)
                    $keptEntries += $entry
                }
            }
            elseif (Test-BrainManagedHandler -Handler $entry) {
                $removed++
            }
            else {
                $keptEntries += $entry
            }
        }
        if ($keptEntries.Count -gt 0) {
            $hooks[$eventName] = @($keptEntries)
        }
        else {
            $hooks.Remove($eventName)
        }
    }
    if ($hooks.Count -eq 0) {
        $Configuration.Remove('hooks')
    }
    return $removed
}

function New-BrainIntegrationHandler {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    # Byte-compatible with Phase 1 handler shapes: Codex uses a single command
    # string (command/commandWindows), Claude uses command + args array.
    # Plugin-bridge integrations never reach this function (their artifact is
    # a file, not hook JSON); an unknown style fails loudly instead of
    # silently emitting a wrong shape.
    if ([string]$Definition.HandlerStyle -eq 'CodexCommandString') {
        $command = '"' + $PowerShellPath + '" -NoProfile -NonInteractive -File "' + $BrainHookPath + '" -Provider ' + [string]$Definition.Name
        $handler = [ordered]@{
            type = 'command'
            command = $command
            commandWindows = $command
            timeout = $Timeout
            statusMessage = ([string]$Definition.StatusPrefix + $EventName)
            brain_hook_id = ([string]$Definition.HookIdPrefix + $EventName)
            managed_by = 'brain'
        }
        if ($EventName -eq 'SessionStart') {
            $handler['additionalContextLimit'] = 12000
        }
        return $handler
    }

    if ([string]$Definition.HandlerStyle -eq 'ClaudeArgsArray') {
        return [ordered]@{
            type = 'command'
            command = $PowerShellPath
            args = @('-NoProfile', '-NonInteractive', '-File', $BrainHookPath, '-Provider', [string]$Definition.Name)
            timeout = $Timeout
            statusMessage = ([string]$Definition.StatusPrefix + $EventName)
            brain_hook_id = ([string]$Definition.HookIdPrefix + $EventName)
            managed_by = 'brain'
        }
    }

    if ([string]$Definition.HandlerStyle -eq 'FlatCommand') {
        # Flat per-event command entries (flat hooks.json dialect): only
        # documented keys, so unknown-key tolerance is never required.
        # Detection relies on the brain-hook.ps1 command substring, which
        # Test-BrainManagedHandler already treats as managed.
        $handler = [ordered]@{
            command = '"' + $PowerShellPath + '" -NoProfile -NonInteractive -File "' + $BrainHookPath + '" -Provider ' + [string]$Definition.Name
            timeout = $Timeout
        }
        if ($EventName -eq 'stop' -and $null -ne $Definition.StopLoopLimit) {
            $handler['loop_limit'] = [int]$Definition.StopLoopLimit
        }
        return $handler
    }
    if ([string]$Definition.HandlerStyle -eq 'CopilotCommand') {
        # Command entries for the Copilot CLI hooks dialect: per-OS command
        # keys with a `timeoutSec` deadline. Only documented keys are emitted;
        # detection relies on the brain-hook.ps1 command substring.
        # PowerShell needs the call operator to execute a quoted executable.
        $handler = [ordered]@{
            type = 'command'
            powershell = '& "' + $PowerShellPath + '" -NoProfile -NonInteractive -File "' + $BrainHookPath + '" -Provider ' + [string]$Definition.Name
            timeoutSec = $Timeout
        }
        return $handler
    }

    if ([string]$Definition.HandlerStyle -eq 'GeminiCommand') {
        # Command entries for the Gemini CLI hooks dialect: a single
        # `command` string with a millisecond `timeout`, inside the shared
        # nested {matcher?, hooks:[...]} groups. Only documented keys are
        # emitted (`name` doubles as the human-readable identity);
        # detection relies on the brain-hook.ps1 command substring.
        #
        # The leading `& ` is load-bearing, not style: Gemini CLI on Windows
        # evaluates the entry as a PowerShell command line (verified live: a
        # bare `"exe" args...` string dies with "Unexpected token
        # '-NoProfile' in expression or statement", while the call-operator
        # form runs and returns hook JSON). Native-spawn dialects must NOT
        # copy this prefix.
        $handler = [ordered]@{
            type = 'command'
            command = '& "' + $PowerShellPath + '" -NoProfile -NonInteractive -File "' + $BrainHookPath + '" -Provider ' + [string]$Definition.Name
            name = ([string]$Definition.StatusPrefix + $EventName).Trim()
            timeout = ($Timeout * 1000)
        }
        return $handler
    }

    throw "Unknown HandlerStyle for integration '$([string]$Definition.Id)': $([string]$Definition.HandlerStyle)."
}

function Get-BrainSetupHookSchema {
    param([Parameter(Mandatory = $true)][object]$Definition)

    if (Get-Command Get-BrainIntegrationHookSchema -ErrorAction SilentlyContinue) {
        return (Get-BrainIntegrationHookSchema -Definition $Definition)
    }
    try {
        $schema = ([string]$Definition.HookSchema).Trim()
    }
    catch {
        $schema = ''
    }
    if ([string]::IsNullOrWhiteSpace($schema)) { return 'ClaudeNested' }
    return $schema
}

function Add-BrainHandlers {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Configuration,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$PowerShellPath
    )

    if (-not $Configuration.Contains('hooks') -or $Configuration['hooks'] -isnot [Collections.IDictionary]) {
        $Configuration['hooks'] = [ordered]@{}
    }
    $hooks = $Configuration['hooks']

    if ((Get-BrainSetupHookSchema -Definition $Definition) -in @('CursorFlat', 'CopilotCli')) {
        if (-not $Configuration.Contains('version')) {
            $Configuration['version'] = 1
        }
        foreach ($spec in $Definition.Events) {
            $handler = New-BrainIntegrationHandler -Definition $Definition -PowerShellPath $PowerShellPath -EventName ([string]$spec.EventName) -Timeout ([int]$spec.Timeout)
            if (-not [string]::IsNullOrWhiteSpace([string]$spec.Matcher)) {
                $handler['matcher'] = [string]$spec.Matcher
            }
            $entries = @()
            if ($hooks.Contains([string]$spec.EventName)) {
                $entries = ConvertTo-BrainArray -Value $hooks[[string]$spec.EventName]
            }
            $hooks[[string]$spec.EventName] = @($entries) + @($handler)
        }
        return
    }

    foreach ($spec in $Definition.Events) {
        $handler = New-BrainIntegrationHandler -Definition $Definition -PowerShellPath $PowerShellPath -EventName ([string]$spec.EventName) -Timeout ([int]$spec.Timeout)

        $groups = @()
        if ($hooks.Contains([string]$spec.EventName)) {
            $groups = ConvertTo-BrainArray -Value $hooks[[string]$spec.EventName]
        }
        $group = [ordered]@{}
        if (-not [string]::IsNullOrWhiteSpace([string]$spec.Matcher)) {
            $group['matcher'] = [string]$spec.Matcher
        }
        $group['hooks'] = @($handler)
        $hooks[[string]$spec.EventName] = @($groups) + @($group)
    }
}

function Backup-BrainOriginal {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = $Path + '.brain-backup-' + $Timestamp
        Copy-Item -LiteralPath $Path -Destination $backup
        return $backup
    }

    $backup = $Path + '.brain-backup-' + $Timestamp + '.absent'
    [IO.File]::WriteAllText($backup, "ABSENT`n", [Text.UTF8Encoding]::new($false))
    return $backup
}

function Write-BrainJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = Join-Path $parent ('.brain-setup-tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 100
        [IO.File]::WriteAllText($temporary, ($json + "`n"), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-BrainPwshPath {
    $command = Get-Command pwsh.exe -ErrorAction Stop
    return [IO.Path]::GetFullPath($command.Source)
}

function ConvertTo-BrainOrderInsensitiveForm {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

    # Read-BrainJsonObject uses ConvertFrom-Json -AsHashtable, and .NET Hashtable enumeration
    # order is not guaranteed. Remove-BrainHandlers/Add-BrainHandlers can churn a dictionary's
    # key order (remove + re-add) without changing its actual content, so a raw ConvertTo-Json
    # string comparison can report spurious changes. This helper normalizes dictionaries by
    # sorting their keys (ordinal) before comparison. Arrays keep their original element order
    # because order is semantically meaningful there (hook group order, BRAIN group appended last).
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object { [string]$_ } -Culture ([Globalization.CultureInfo]::InvariantCulture))) {
            $ordered[[string]$key] = ConvertTo-BrainOrderInsensitiveForm -Value $Value[$key]
        }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $list = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $list.Add((ConvertTo-BrainOrderInsensitiveForm -Value $item))
        }
        return , @($list.ToArray())
    }
    return $Value
}

function Get-BrainPluginTemplateContent {
    param([Parameter(Mandatory = $true)][object]$Definition)

    $fileName = ''
    try {
        $fileName = ([string]$Definition.PluginTemplateFile).Trim()
    }
    catch {
        $fileName = ''
    }
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw "Integration '$([string]$Definition.Id)' declares a PluginFile artifact but no PluginTemplateFile."
    }
    $templatePath = Join-Path (Join-Path $BrainSetupRoot 'integrations\providers') $fileName
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Plugin template is missing for integration '$([string]$Definition.Id)': $templatePath"
    }
    return Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
}

function ConvertTo-BrainJsStringLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    # ConvertTo-Json quotes and backslash-escapes exactly the way a JS
    # double-quoted string literal needs (JSON strings are valid JS).
    return (ConvertTo-Json -InputObject $Value)
}

function Sync-BrainPluginFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [string]$Provenance = 'resolved'
    )

    Assert-BrainSetupWriteAllowed -Path $Path -Provenance $Provenance

    $template = Get-BrainPluginTemplateContent -Definition $Definition
    $rendered = $template.Replace('"__BRAIN_ROOT__"', (ConvertTo-BrainJsStringLiteral -Value ([IO.Path]::GetFullPath($BrainRoot))))
    $rendered = $rendered.Replace('"__BRAIN_HOOK_PATH__"', (ConvertTo-BrainJsStringLiteral -Value ([IO.Path]::GetFullPath($BrainHookPath))))
    $rendered = $rendered.Replace('"__BRAIN_PWSH_PATH__"', (ConvertTo-BrainJsStringLiteral -Value ([IO.Path]::GetFullPath($PowerShellPath))))

    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        # A directory (or other non-file) owns this name. Never touch it.
        return [pscustomobject]@{
            changed = $false
            backup = $null
            path = [IO.Path]::GetFullPath($Path)
            skipped = $true
            reason = 'conflict'
        }
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $isManaged = $false
        if (Get-Command Test-BrainPluginFileManaged -ErrorAction SilentlyContinue) {
            $isManaged = Test-BrainPluginFileManaged -Path $Path -Definition $Definition
        }
        else {
            try {
                $firstLine = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
                $isManaged = (([string]$firstLine).Trim().StartsWith(([string]$Definition.PluginManagedMarker).Trim(), [StringComparison]::Ordinal))
            }
            catch {
                $isManaged = $false
            }
        }
        if (-not $isManaged) {
            # A foreign file owns this name. Never overwrite third-party
            # content; surface the conflict instead.
            return [pscustomobject]@{
                changed = $false
                backup = $null
                path = [IO.Path]::GetFullPath($Path)
                skipped = $true
                reason = 'conflict'
            }
        }
        $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::Equals($existing, $rendered, [StringComparison]::Ordinal)) {
            return [pscustomobject]@{
                changed = $false
                backup = $null
                path = [IO.Path]::GetFullPath($Path)
            }
        }
    }

    $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')
    $backup = Backup-BrainOriginal -Path $Path -Timestamp $timestamp
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = Join-Path $parent ('.brain-plugin-tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, $rendered, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    return [pscustomobject]@{
        changed = $true
        backup = $backup
        path = [IO.Path]::GetFullPath($Path)
    }
}

function Remove-BrainPluginFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Definition,
        [string]$Provenance = 'resolved'
    )

    Assert-BrainSetupWriteAllowed -Path $Path -Provenance $Provenance

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ changed = $false; backup = $null; removed = 0; path = [IO.Path]::GetFullPath($Path) }
    }
    $isManaged = $false
    if (Get-Command Test-BrainPluginFileManaged -ErrorAction SilentlyContinue) {
        $isManaged = Test-BrainPluginFileManaged -Path $Path -Definition $Definition
    }
    if (-not $isManaged) {
        return [pscustomobject]@{ changed = $false; backup = $null; removed = 0; path = [IO.Path]::GetFullPath($Path); skipped = $true; reason = 'conflict' }
    }
    $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')
    $backup = Backup-BrainOriginal -Path $Path -Timestamp $timestamp
    Remove-Item -LiteralPath $Path -Force
    return [pscustomobject]@{ changed = $true; backup = $backup; removed = 1; path = [IO.Path]::GetFullPath($Path) }
}

function Sync-BrainConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [string]$Provenance = 'resolved'
    )

    if ((Get-BrainSetupArtifactKind -Definition $Definition) -eq 'PluginFile') {
        return (Sync-BrainPluginFile -Path $Path -Definition $Definition -PowerShellPath $PowerShellPath -Provenance $Provenance)
    }

    Assert-BrainSetupWriteAllowed -Path $Path -Provenance $Provenance

    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        # A directory (or other non-file) owns this name. Never touch it.
        return [pscustomobject]@{
            changed = $false
            backup = $null
            path = [IO.Path]::GetFullPath($Path)
            skipped = $true
            reason = 'conflict'
        }
    }

    $config = Read-BrainJsonObject -Path $Path
    $originalComparableJson = ConvertTo-Json -InputObject (ConvertTo-BrainOrderInsensitiveForm -Value $config) -Depth 100

    $null = Remove-BrainHandlers -Configuration $config
    Add-BrainHandlers -Configuration $config -Definition $Definition -PowerShellPath $PowerShellPath

    $resultComparableJson = ConvertTo-Json -InputObject (ConvertTo-BrainOrderInsensitiveForm -Value $config) -Depth 100
    if ([string]::Equals($originalComparableJson, $resultComparableJson, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{
            changed = $false
            backup = $null
            path = [IO.Path]::GetFullPath($Path)
        }
    }

    $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')
    $backup = Backup-BrainOriginal -Path $Path -Timestamp $timestamp
    Write-BrainJsonAtomic -Path $Path -Value $config
    return [pscustomobject]@{
        changed = $true
        backup = $backup
        path = [IO.Path]::GetFullPath($Path)
    }
}

function Get-BrainManagedHandlerCounts {
    param([Parameter(Mandatory = $true)][string]$Path)

    $counts = [ordered]@{}
    $legacy = $false
    if (-not (Test-BrainJsonParseable -Path $Path)) {
        return [pscustomobject]@{ Counts = $counts; Legacy = $false; Parseable = $false }
    }
    $config = Read-BrainJsonObject -Path $Path
    if ($config.Contains('hooks') -and $config['hooks'] -is [Collections.IDictionary]) {
        foreach ($eventName in @($config['hooks'].Keys)) {
            $count = 0
            foreach ($entry in (ConvertTo-BrainArray -Value $config['hooks'][$eventName])) {
                if ($entry -is [Collections.IDictionary] -and $entry.Contains('hooks')) {
                    foreach ($handler in (ConvertTo-BrainArray -Value $entry['hooks'])) {
                        if (Test-BrainManagedHandler -Handler $handler) {
                            $count++
                            if ($handler -is [Collections.IDictionary] -and $handler.Contains('statusMessage')) {
                                if ([string]$handler['statusMessage'] -match '^BRAIN\s+v[0-9]') { $legacy = $true }
                            }
                        }
                    }
                }
                elseif (Test-BrainManagedHandler -Handler $entry) {
                    $count++
                }
            }
            $counts[$eventName] = $count
        }
    }
    return [pscustomobject]@{ Counts = $counts; Legacy = $legacy; Parseable = $true }
}

function Get-BrainDiagnostics {
    $findings = [Collections.Generic.List[string]]::new()

    try { $null = Get-Command pwsh.exe -ErrorAction Stop } catch { $findings.Add('missing:pwsh') }
    if (-not (Test-Path -LiteralPath $BrainHookPath -PathType Leaf)) { $findings.Add('missing:hook-script') }
    if (-not (Test-Path -LiteralPath (Join-Path $BrainRoot 'lib\brain-common.ps1') -PathType Leaf)) { $findings.Add('missing:library') }
    if (-not (Test-Path -LiteralPath (Join-Path $BrainRoot 'VERSION') -PathType Leaf)) { $findings.Add('missing:version-file') }
    if (-not (Test-Path -LiteralPath (Join-Path $BrainRoot 'brain.ps1') -PathType Leaf)) { $findings.Add('missing:brain-script') }

    $projectsFile = Join-Path $BrainRoot 'config\projects.json'
    if (Test-Path -LiteralPath $projectsFile -PathType Leaf) {
        if (-not (Test-BrainJsonParseable -Path $projectsFile)) { $findings.Add('invalid:projects-registry') }
    }
    else {
        $findings.Add('missing:projects-registry')
    }

    $trustedRootsFile = Join-Path $BrainRoot 'config\trusted-roots.json'
    if ((Test-Path -LiteralPath $trustedRootsFile -PathType Leaf) -and -not (Test-BrainJsonParseable -Path $trustedRootsFile)) {
        $findings.Add('invalid:trusted-roots')
    }

    $parseableById = @{}
    $pluginManagedById = @{}
    foreach ($definition in $BrainIntegrations) {
        $id = ([string]$definition.Id).Trim().ToLowerInvariant()
        $path = Get-BrainSetupConfigPath -Definition $definition
        if ((Get-BrainSetupArtifactKind -Definition $definition) -eq 'PluginFile') {
            $managed = $false
            if ((Test-Path -LiteralPath $path -PathType Leaf)) {
                if (Get-Command Test-BrainPluginFileManaged -ErrorAction SilentlyContinue) {
                    $managed = Test-BrainPluginFileManaged -Path $path -Definition $definition
                }
                if ($managed) {
                    $parseableById[$id] = $true
                    $pluginManagedById[$id] = $true
                }
                else {
                    # A foreign file owns this name: valid state for the host tool,
                    # but BRAIN must not touch it.
                    $parseableById[$id] = $true
                    $pluginManagedById[$id] = $false
                    $findings.Add(('conflict-plugin:{0}' -f $id))
                }
            }
            else {
                $parseableById[$id] = $true
                $pluginManagedById[$id] = $false
                $findings.Add(('missing-plugin:{0}' -f $id))
            }
            continue
        }
        $isParseable = Test-BrainJsonParseable -Path $path
        $parseableById[$id] = $isParseable
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not $isParseable) {
            $findings.Add(('invalid:{0}-config' -f $id))
        }
    }

    foreach ($definition in $BrainIntegrations) {
        $id = ([string]$definition.Id).Trim().ToLowerInvariant()
        if ((Get-BrainSetupArtifactKind -Definition $definition) -eq 'PluginFile') { continue }
        if (-not $parseableById[$id]) { continue }
        $path = Get-BrainSetupConfigPath -Definition $definition
        $info = Get-BrainManagedHandlerCounts -Path $path
        if ($info.Legacy) { $findings.Add(('legacy-hook:{0}' -f $id)) }
        foreach ($spec in $definition.Events) {
            $count = if ($info.Counts.Contains([string]$spec.EventName)) { $info.Counts[[string]$spec.EventName] } else { 0 }
            if ($count -eq 0) { $findings.Add(('missing-hook:{0}:{1}' -f $id, [string]$spec.EventName)) }
            elseif ($count -gt 1) { $findings.Add(('duplicate-hook:{0}:{1}' -f $id, [string]$spec.EventName)) }
        }
    }

    return @($findings), $parseableById
}

function Get-BrainNewestBackup {
    param([Parameter(Mandatory = $true)][string]$Path)

    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return $null }
    $candidates = @(Get-ChildItem -LiteralPath $parent -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith($leaf + '.brain-backup-', [StringComparison]::Ordinal) } | Sort-Object Name -Descending)
    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0].FullName
}

function Restore-BrainConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$BackupPath,
        [object]$Definition = $null
    )

    $chosen = if (-not [string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath } else { Get-BrainNewestBackup -Path $Path }
    if ([string]::IsNullOrWhiteSpace($chosen) -or -not (Test-Path -LiteralPath $chosen -PathType Leaf)) {
        return [pscustomobject]@{ restored = $false; reason = 'no-backup'; mode = $null; source = $chosen }
    }

    $isPlugin = ($null -ne $Definition -and (Get-BrainSetupArtifactKind -Definition $Definition) -eq 'PluginFile')
    $isAbsentMarker = $chosen.EndsWith('.absent', [StringComparison]::OrdinalIgnoreCase)
    if (-not $isAbsentMarker) {
        $content = Get-Content -LiteralPath $chosen -Raw -Encoding UTF8
        if ($content.Trim() -eq 'ABSENT') { $isAbsentMarker = $true }
    }

    if ($isAbsentMarker) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            if ($isPlugin) {
                # Never delete a foreign file that appeared after the backup:
                # absent-restore only removes what BRAIN manages.
                $managed = $false
                if (Get-Command Test-BrainPluginFileManaged -ErrorAction SilentlyContinue) {
                    $managed = Test-BrainPluginFileManaged -Path $Path -Definition $Definition
                }
                else {
                    $managed = $true
                }
                if (-not $managed) {
                    return [pscustomobject]@{ restored = $false; reason = 'conflict'; mode = $null; source = $chosen }
                }
            }
            $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')
            $null = Backup-BrainOriginal -Path $Path -Timestamp $timestamp
            Remove-Item -LiteralPath $Path -Force
        }
        return [pscustomobject]@{ restored = $true; reason = ''; mode = 'absent'; source = $chosen }
    }

    if (-not $isPlugin -and -not (Test-BrainJsonParseable -Path $chosen)) {
        return [pscustomobject]@{ restored = $false; reason = 'invalid-backup'; mode = $null; source = $chosen }
    }

    $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')
    $null = Backup-BrainOriginal -Path $Path -Timestamp $timestamp
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = Join-Path $parent ('.brain-restore-tmp-' + [guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $chosen -Destination $temporary
    Move-Item -LiteralPath $temporary -Destination $Path -Force
    return [pscustomobject]@{ restored = $true; reason = ''; mode = 'file'; source = $chosen }
}

$brainVersion = Get-BrainVersion -BrainRoot $BrainRoot

Assert-BrainSetupBrainRoot -Action $Action

if (-not [string]::IsNullOrWhiteSpace($Integration)) {
    $requested = Get-BrainSetupIntegration -Id $Integration
    if ($null -eq $requested) {
        throw "Unknown integration: $Integration. Known integrations: $(@($BrainIntegrations | ForEach-Object { [string]$_.Id }) -join ', ')."
    }
}
$onlyIntegrationId = if ([string]::IsNullOrWhiteSpace($Integration)) { '' } else { ([string](Get-BrainSetupIntegration -Id $Integration).Id).Trim().ToLowerInvariant() }

function Get-BrainSetupResultForId {
    param([hashtable]$Results, [string]$Id)

    if ($Results.ContainsKey($Id)) { return $Results[$Id] }
    $definition = Get-BrainSetupIntegration -Id $Id
    $path = Get-BrainSetupConfigPath -Definition $definition
    $reason = if ([string]::IsNullOrWhiteSpace($onlyIntegrationId)) { 'disabled' } else { 'not-selected' }
    return [pscustomobject]@{ changed = $false; backup = $null; removed = 0; path = [IO.Path]::GetFullPath($path); skipped = $true; reason = $reason }
}

# Backward-compat top-level summaries/paths for the two original integrations.
# The path always comes from the normal declaration-driven resolver, so it
# can never disagree with (or crash on) empty CLI parameters.
function Get-BrainSetupCompatSummary {
    param([Parameter(Mandatory = $true)][string]$Id)

    $definition = Get-BrainSetupIntegration -Id $Id
    if ($null -eq $definition) {
        throw "Unknown integration in compat summary: $Id."
    }
    $resolved = Resolve-BrainSetupTargetPath -Definition $definition
    return [pscustomobject]@{
        path = [IO.Path]::GetFullPath([string]$resolved.Path)
        exists = $false
        parseable = $true
        enabled = $false
        handler_counts = [ordered]@{}
        legacy_handler_present = $false
    }
}

function Get-BrainSetupCompatPath {
    param([Parameter(Mandatory = $true)][string]$Id)

    return [string](Get-BrainSetupCompatSummary -Id $Id).path
}

switch ($Action) {
    'Integrations' {
        $enabledIds = @(Get-BrainSetupEnabledIds)
        $items = @()
        foreach ($definition in $BrainIntegrations) {
            $id = ([string]$definition.Id).Trim().ToLowerInvariant()
            $items += [pscustomobject][ordered]@{
                id = $id
                name = [string]$definition.Name
                display_name = [string]$definition.DisplayName
                enabled = ($enabledIds -contains $id)
                config_path = [IO.Path]::GetFullPath((Get-BrainSetupConfigPath -Definition $definition))
                events = @($definition.Events | ForEach-Object { [string]$_.EventName })
                capabilities = $definition.Capabilities
            }
        }
        [pscustomobject][ordered]@{
            action = $Action
            result = 'OK'
            brain_version = $brainVersion
            brain_root = $BrainRoot
            integrations = @($items)
        } | ConvertTo-Json -Depth 20
    }

    'Enable' {
        if ([string]::IsNullOrWhiteSpace($Integration)) { throw "-Integration <id> is required for the 'Enable' action." }
        if (Get-Command Set-BrainIntegrationEnabled -ErrorAction SilentlyContinue) {
            $null = Set-BrainIntegrationEnabled -BrainRoot $BrainRoot -Definitions $BrainIntegrations -Id $Integration -Enabled $true
        }
        else {
            throw 'Integration enablement is not supported by the loaded registry.'
        }
        $enabledIds = @(Get-BrainSetupEnabledIds)
        [pscustomobject][ordered]@{
            action = $Action
            result = 'OK'
            brain_version = $brainVersion
            brain_root = $BrainRoot
            integration = $onlyIntegrationId
            enabled = ($enabledIds -contains $onlyIntegrationId)
        } | ConvertTo-Json -Depth 20
    }

    'Disable' {
        if ([string]::IsNullOrWhiteSpace($Integration)) { throw "-Integration <id> is required for the 'Disable' action." }
        if (Get-Command Set-BrainIntegrationEnabled -ErrorAction SilentlyContinue) {
            $null = Set-BrainIntegrationEnabled -BrainRoot $BrainRoot -Definitions $BrainIntegrations -Id $Integration -Enabled $false
        }
        else {
            throw 'Integration enablement is not supported by the loaded registry.'
        }
        $enabledIds = @(Get-BrainSetupEnabledIds)
        [pscustomobject][ordered]@{
            action = $Action
            result = 'OK'
            brain_version = $brainVersion
            brain_root = $BrainRoot
            integration = $onlyIntegrationId
            enabled = ($enabledIds -contains $onlyIntegrationId)
        } | ConvertTo-Json -Depth 20
    }

    { $_ -in @('Install', 'Update') } {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            throw 'BRAIN hook installation requires PowerShell 7 or later.'
        }
        $pwshPath = Get-BrainPwshPath
        $results = @{}
        foreach ($target in (Get-BrainSetupTargets -OnlyId $onlyIntegrationId)) {
            if (-not $target.Enabled) {
                $results[$target.Id] = [pscustomobject]@{ changed = $false; backup = $null; path = [IO.Path]::GetFullPath($target.Path); skipped = $true; reason = 'disabled' }
                continue
            }
            $results[$target.Id] = Sync-BrainConfiguration -Path $target.Path -Definition $target.Definition -PowerShellPath $pwshPath -Provenance $target.Provenance
        }
        $codex = Get-BrainSetupResultForId -Results $results -Id 'codex'
        $claude = Get-BrainSetupResultForId -Results $results -Id 'claude'
        [pscustomobject][ordered]@{
            action = $Action
            result = 'OK'
            brain_version = $brainVersion
            brain_root = $BrainRoot
            brain_hook = [IO.Path]::GetFullPath($BrainHookPath)
            powershell = $pwshPath
            codex = $codex
            claude = $claude
            integrations = $results
        } | ConvertTo-Json -Depth 20
    }

    'Repair' {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            throw 'BRAIN hook installation requires PowerShell 7 or later.'
        }
        $pwshPath = Get-BrainPwshPath
        $findings, $parseableById = Get-BrainDiagnostics

        $results = @{}
        foreach ($target in (Get-BrainSetupTargets -OnlyId $onlyIntegrationId)) {
            if (-not $target.Enabled) {
                $results[$target.Id] = [pscustomobject]@{ changed = $false; backup = $null; path = [IO.Path]::GetFullPath($target.Path); skipped = $true; reason = 'disabled' }
                continue
            }
            if (-not $parseableById[$target.Id]) {
                $results[$target.Id] = [pscustomobject]@{ changed = $false; backup = $null; path = [IO.Path]::GetFullPath($target.Path); skipped = $true; reason = 'invalid-json' }
                continue
            }
            $results[$target.Id] = Sync-BrainConfiguration -Path $target.Path -Definition $target.Definition -PowerShellPath $pwshPath -Provenance $target.Provenance
        }
        $codex = Get-BrainSetupResultForId -Results $results -Id 'codex'
        $claude = Get-BrainSetupResultForId -Results $results -Id 'claude'

        [pscustomobject][ordered]@{
            action = $Action
            result = 'OK'
            brain_version = $brainVersion
            brain_root = $BrainRoot
            brain_hook = [IO.Path]::GetFullPath($BrainHookPath)
            powershell = $pwshPath
            findings = @($findings)
            codex = $codex
            claude = $claude
            integrations = $results
        } | ConvertTo-Json -Depth 20
    }

    'Uninstall' {
        $results = @{}
        foreach ($target in (Get-BrainSetupTargets -OnlyId $onlyIntegrationId)) {
            if ((Get-BrainSetupArtifactKind -Definition $target.Definition) -eq 'PluginFile') {
                $results[$target.Id] = Remove-BrainPluginFile -Path $target.Path -Definition $target.Definition -Provenance $target.Provenance
                continue
            }
            if (-not (Test-BrainJsonParseable -Path $target.Path)) {
                $results[$target.Id] = [pscustomobject]@{ changed = $false; backup = $null; removed = 0; path = [IO.Path]::GetFullPath($target.Path); skipped = $true; reason = 'invalid-json' }
                continue
            }
            Assert-BrainSetupWriteAllowed -Path $target.Path -Provenance $target.Provenance
            $targetConfig = Read-BrainJsonObject -Path $target.Path
            $removedCount = Remove-BrainHandlers -Configuration $targetConfig
            if ($removedCount -eq 0) {
                $results[$target.Id] = [pscustomobject]@{ changed = $false; backup = $null; removed = 0; path = [IO.Path]::GetFullPath($target.Path) }
            }
            else {
                $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')
                $backup = Backup-BrainOriginal -Path $target.Path -Timestamp $timestamp
                Write-BrainJsonAtomic -Path $target.Path -Value $targetConfig
                $results[$target.Id] = [pscustomobject]@{ changed = $true; backup = $backup; removed = $removedCount; path = [IO.Path]::GetFullPath($target.Path) }
            }
        }
        $codex = Get-BrainSetupResultForId -Results $results -Id 'codex'
        $claude = Get-BrainSetupResultForId -Results $results -Id 'claude'

        [pscustomobject][ordered]@{
            action = $Action
            result = 'OK'
            brain_version = $brainVersion
            brain_root = $BrainRoot
            brain_hook = [IO.Path]::GetFullPath($BrainHookPath)
            codex = $codex
            claude = $claude
            integrations = $results
            user_data_preserved = $true
            note = 'Memory data and project registrations were intentionally left in place: store/, config/projects.json, config/trusted-roots.json, and every project''s .brain directory are untouched.'
        } | ConvertTo-Json -Depth 20
    }

    'Status' {
        $pwshAvailable = $true
        try { $null = Get-Command pwsh.exe -ErrorAction Stop } catch { $pwshAvailable = $false }

        $enabledIds = @(Get-BrainSetupEnabledIds)
        $summaries = @{}
        foreach ($target in (Get-BrainSetupTargets -OnlyId $onlyIntegrationId)) {
            if ((Get-BrainSetupArtifactKind -Definition $target.Definition) -eq 'PluginFile') {
                $exists = (Test-Path -LiteralPath $target.Path -PathType Leaf)
                $managed = $false
                if ($exists -and (Get-Command Test-BrainPluginFileManaged -ErrorAction SilentlyContinue)) {
                    $managed = Test-BrainPluginFileManaged -Path $target.Path -Definition $target.Definition
                }
                $rootDetail = Get-BrainSetupRootDetail -Definition $target.Definition
                $summaries[$target.Id] = [pscustomobject]@{
                    path = [IO.Path]::GetFullPath($target.Path)
                    exists = $exists
                    parseable = $true
                    enabled = ($enabledIds -contains $target.Id)
                    managed = $managed
                    artifact_kind = 'PluginFile'
                    candidate_roots = @($rootDetail.candidates)
                    selected_root = $rootDetail.selected
                    selection_reason = $rootDetail.reason
                    handler_counts = [ordered]@{}
                    legacy_handler_present = $false
                }
                continue
            }
            $parseable = Test-BrainJsonParseable -Path $target.Path
            $info = if ($parseable) { Get-BrainManagedHandlerCounts -Path $target.Path } else { $null }
            $rootDetail = Get-BrainSetupRootDetail -Definition $target.Definition
            $summaries[$target.Id] = [pscustomobject]@{
                path = [IO.Path]::GetFullPath($target.Path)
                exists = (Test-Path -LiteralPath $target.Path -PathType Leaf)
                parseable = $parseable
                enabled = ($enabledIds -contains $target.Id)
                artifact_kind = 'HookJson'
                hook_schema = (Get-BrainSetupHookSchema -Definition $target.Definition)
                candidate_roots = @($rootDetail.candidates)
                selected_root = $rootDetail.selected
                selection_reason = $rootDetail.reason
                handler_counts = if ($null -ne $info) { $info.Counts } else { [ordered]@{} }
                legacy_handler_present = if ($null -ne $info) { $info.Legacy } else { $false }
            }
        }
        $codexSummary = if ($summaries.ContainsKey('codex')) { $summaries['codex'] } else { Get-BrainSetupCompatSummary -Id 'codex' }
        $claudeSummary = if ($summaries.ContainsKey('claude')) { $summaries['claude'] } else { Get-BrainSetupCompatSummary -Id 'claude' }

        [pscustomobject][ordered]@{
            action = $Action
            result = 'OK'
            brain_version = $brainVersion
            brain_root = $BrainRoot
            brain_hook = [IO.Path]::GetFullPath($BrainHookPath)
            pwsh_available = $pwshAvailable
            codex = $codexSummary
            claude = $claudeSummary
            integrations = $summaries
        } | ConvertTo-Json -Depth 20
    }

    'Backup' {
        $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')
        $backups = @{}
        foreach ($target in (Get-BrainSetupTargets -OnlyId $onlyIntegrationId)) {
            Assert-BrainSetupWriteAllowed -Path $target.Path -Provenance $target.Provenance
            $backups[$target.Id] = Backup-BrainOriginal -Path $target.Path -Timestamp $timestamp
        }
        $codexBackup = if ($backups.ContainsKey('codex')) { $backups['codex'] } else { $null }
        $claudeBackup = if ($backups.ContainsKey('claude')) { $backups['claude'] } else { $null }
        [pscustomobject][ordered]@{
            action = $Action
            result = 'OK'
            brain_version = $brainVersion
            brain_root = $BrainRoot
            brain_hook = [IO.Path]::GetFullPath($BrainHookPath)
            codex = [pscustomobject]@{ path = (Get-BrainSetupCompatPath -Id 'codex'); backup = $codexBackup }
            claude = [pscustomobject]@{ path = (Get-BrainSetupCompatPath -Id 'claude'); backup = $claudeBackup }
            integrations = $backups
        } | ConvertTo-Json -Depth 20
    }

    'Restore' {
        $results = @{}
        foreach ($target in (Get-BrainSetupTargets -OnlyId $onlyIntegrationId)) {
            $explicit = $null
            if ($target.Id -eq 'codex' -and -not [string]::IsNullOrWhiteSpace($CodexBackupPath)) { $explicit = $CodexBackupPath }
            if ($target.Id -eq 'claude' -and -not [string]::IsNullOrWhiteSpace($ClaudeBackupPath)) { $explicit = $ClaudeBackupPath }
            Assert-BrainSetupWriteAllowed -Path $target.Path -Provenance $target.Provenance
            $results[$target.Id] = Restore-BrainConfiguration -Path $target.Path -BackupPath $explicit -Definition $target.Definition
        }
        $codex = if ($results.ContainsKey('codex')) { $results['codex'] } else { [pscustomobject]@{ restored = $false; reason = 'disabled'; mode = $null; source = $null } }
        $claude = if ($results.ContainsKey('claude')) { $results['claude'] } else { [pscustomobject]@{ restored = $false; reason = 'disabled'; mode = $null; source = $null } }
        [pscustomobject][ordered]@{
            action = $Action
            result = 'OK'
            brain_version = $brainVersion
            brain_root = $BrainRoot
            brain_hook = [IO.Path]::GetFullPath($BrainHookPath)
            codex = $codex
            claude = $claude
            integrations = $results
        } | ConvertTo-Json -Depth 20
    }
}
