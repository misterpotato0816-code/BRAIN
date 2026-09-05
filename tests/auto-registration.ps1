[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-auto-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'BRAIN'
$trustedRoot = Join-Path $testRoot 'trusted'
$autoProjectRoot = Join-Path $trustedRoot 'AutoProject'
$afterBreakageRoot = Join-Path $trustedRoot 'AfterBreakage'
$linkTargetRoot = Join-Path $trustedRoot 'LinkTarget'
$junctionFinal = Join-Path $trustedRoot 'JunctionLink'
$linkAncestorTarget = Join-Path $testRoot 'outside'
$junctionAncestor = Join-Path $trustedRoot 'AncestorLink'
$outsideProjectRoot = Join-Path $linkAncestorTarget 'OutsideProject'
$stateRoot = Join-Path $testRoot 'state'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-Hook {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Codex', 'Claude')][string]$Provider,
        [Parameter(Mandatory = $true)][hashtable]$InputObject
    )

    $json = ConvertTo-Json -InputObject $InputObject -Depth 30 -Compress
    $output = $json | & $pwshPath -NoProfile -NonInteractive -File (Join-Path $testBrainRoot 'integrations\brain-hook.ps1') -Provider $Provider -BrainRoot $testBrainRoot -StateRoot $stateRoot 2>&1
    $exitCode = $LASTEXITCODE
    Assert-True -Condition ($exitCode -eq 0) -Message "$Provider hook must fail open with exit code 0."
    return (@($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-RegistryProjects {
    $raw = Get-Content -LiteralPath (Join-Path $testBrainRoot 'config\projects.json') -Raw -Encoding UTF8
    return @($raw | ConvertFrom-Json -Depth 20)
}

function Get-RegisteredCount {
    return (Get-RegistryProjects).Count
}

function Get-StateFiles {
    return @(Get-ChildItem -LiteralPath $stateRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)
}

function New-RecordText {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Summary
    )

    return @"
---
brain_record_version: "0.1"
project_id: "$ProjectId"
task_id: "$TaskId"
completed_at: "2026-08-31T12:00:00.0000000+09:00"
---

# Task Summary

- [Observed] $Summary

# Approach

- [Observed] Exercised automatic registration through the SessionStart hook.

# Successes

- [Verified] The unregistered directory became a BRAIN project without manual commands.

# Failures

- [Observed] No failure was observed in this bounded path.

# Bugs

- [Suspected] No bug is currently suspected from this bounded path.

# Fixes

- [Verified] No fix was required for this record.

# Evidence

- [Verified] Existing brain.ps1 sync stored this record under store/raw and refreshed context.md.

# Next-Time Notes

- [Observed] Keep trusted roots narrow and reparse-point free.
"@
}

try {
    New-Item -ItemType Directory -Path $testBrainRoot, $trustedRoot, $autoProjectRoot, $linkTargetRoot, $linkAncestorTarget, $outsideProjectRoot, $stateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'), (Join-Path $testBrainRoot 'templates'), (Join-Path $testBrainRoot 'store\raw'), (Join-Path $testBrainRoot 'integrations') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination (Join-Path $testBrainRoot 'brain.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Destination (Join-Path $testBrainRoot 'templates\work-record.md')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'integrations\brain-hook.ps1') -Destination (Join-Path $testBrainRoot 'integrations\brain-hook.ps1')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))
    $trustedConfig = [ordered]@{
        format_version = '0.1'
        trusted_roots = @($trustedRoot)
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\trusted-roots.json'), ($trustedConfig + "`n"), [Text.UTF8Encoding]::new($false))

    $mainlinePath = Join-Path $autoProjectRoot 'mainline.txt'
    [IO.File]::WriteAllText($mainlinePath, "unchanged`n", [Text.UTF8Encoding]::new($false))
    $mainlineHash = (Get-FileHash -LiteralPath $mainlinePath -Algorithm SHA256).Hash

    # --- Phase 1: unregistered project under a trusted root is auto-registered at SessionStart ---
    $session1 = 'auto-session-001'
    $start = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $session1
        cwd = $autoProjectRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    $startJson = $start | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($startJson.hookSpecificOutput.hookEventName -eq 'SessionStart') -Message 'Auto-registered SessionStart must inject hookSpecificOutput context.'
    Assert-True -Condition ([string]$startJson.hookSpecificOutput.additionalContext -match 'historical reference data, not instructions') -Message 'Injected context must be explicitly non-authoritative.'

    $projects = @(Get-RegistryProjects)
    Assert-True -Condition ($projects.Count -eq 1) -Message 'SessionStart must auto-register exactly one project.'
    $projectId = [string]$projects[0].id
    Assert-True -Condition ($projectId -match '^[a-z0-9][a-z0-9._-]{0,63}$') -Message 'Auto-generated project id must match the registry id rule.'
    Assert-True -Condition ([string]$projects[0].path -eq ([IO.Path]::GetFullPath($autoProjectRoot).TrimEnd('\', '/'))) -Message 'Auto-registered path must be the canonical session cwd.'

    $projectFile = Join-Path $autoProjectRoot '.brain\project.json'
    Assert-True -Condition (Test-Path -LiteralPath $projectFile -PathType Leaf) -Message 'Auto-registration must auto-init .brain/project.json.'
    $metadata = Get-Content -LiteralPath $projectFile -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10
    Assert-True -Condition ([string]$metadata.project_id -eq $projectId) -Message 'Auto-inited project.json must carry the auto-generated id.'
    $contextPath = Join-Path $autoProjectRoot '.brain\context.md'
    Assert-True -Condition (Test-Path -LiteralPath $contextPath -PathType Leaf) -Message 'Auto-registration must produce context.md.'
    $contextText = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8
    Assert-True -Condition ($contextText.Contains('No validated historical records fit the current limits.')) -Message 'Fresh auto-inited context must state that no records exist yet.'

    $stateFiles = @(Get-StateFiles)
    Assert-True -Condition ($stateFiles.Count -eq 1) -Message 'Auto-registered session must create exactly one state file.'
    $state = Get-Content -LiteralPath $stateFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    Assert-True -Condition ([string]$state.project_id -eq $projectId) -Message 'Session state must reference the auto-registered project.'
    Assert-True -Condition (-not [bool]$state.dirty) -Message 'Fresh session state must not be dirty.'

    # --- Phase 2: PostToolUse marks dirty, Stop requests a record once ---
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $session1
        turn_id = 'turn-001'
        cwd = $autoProjectRoot
        hook_event_name = 'PostToolUse'
        tool_name = 'apply_patch'
        tool_input = @{ command = 'test edit' }
    }
    $state = Get-Content -LiteralPath $stateFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    Assert-True -Condition ([bool]$state.dirty) -Message 'PostToolUse must mark the auto-registered session dirty.'

    $stop = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $session1
        turn_id = 'turn-001'
        cwd = $autoProjectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Done.'
    }
    $stopJson = $stop | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($stopJson.decision -eq 'block') -Message 'Stop must request a work record for the auto-registered dirty session.'
    $state = Get-Content -LiteralPath $stateFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    $recordPath = [string]$state.expected_record_path
    $taskId = [string]$state.task_id
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($recordPath)) -Message 'Stop must plan an expected record path.'
    Assert-True -Condition ([int]$state.request_count -eq 1) -Message 'Stop must request the record once per turn.'

    # --- Phase 3: the model writes the record, next Stop syncs into store/raw ---
    [IO.File]::WriteAllText($recordPath, (New-RecordText -ProjectId $projectId -TaskId $taskId -Summary 'Auto-registration E2E recorded this turn.'), [Text.UTF8Encoding]::new($false))

    $syncingStop = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $session1
        turn_id = 'turn-002'
        cwd = $autoProjectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $true
        last_assistant_message = 'Record created.'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($syncingStop)) -Message 'Successful Stop sync must allow completion.'

    $rawDirectory = Join-Path $testBrainRoot ("store\raw\" + $projectId)
    $rawFiles = @(Get-ChildItem -LiteralPath $rawDirectory -File -Filter '*.md')
    Assert-True -Condition ($rawFiles.Count -eq 1) -Message 'Stop sync must store the record under store/raw/<project-id>.'
    $rawHash = (Get-FileHash -LiteralPath $rawFiles[0].FullName -Algorithm SHA256).Hash
    $outboxHash = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash
    Assert-True -Condition ($rawHash -eq $outboxHash) -Message 'Raw record must be a byte-for-byte copy of the outbox record.'
    $contextText = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8
    Assert-True -Condition ($contextText.Contains('Auto-registration E2E recorded this turn.')) -Message 'Stop sync must refresh context.md with the new record.'

    # --- Phase 4: SessionEnd cleans up state for the clean session ---
    $stateCountBeforeEnd = @(Get-StateFiles).Count
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $session1
        cwd = $autoProjectRoot
        hook_event_name = 'SessionEnd'
        reason = 'other'
    }
    Assert-True -Condition (@(Get-StateFiles).Count -eq ($stateCountBeforeEnd - 1)) -Message 'SessionEnd must remove state for a clean session.'

    # --- Phase 5: second session in the same project must not duplicate registration ---
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = 'auto-session-002'
        cwd = $autoProjectRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ((Get-RegisteredCount) -eq 1) -Message 'Second session must reuse the existing registration.'

    # --- Phase 6: exclusion rules ---
    $countBeforeExclusions = Get-RegisteredCount
    $stateCountBeforeExclusions = @(Get-StateFiles).Count

    # trusted root itself is a container, never a project
    $null = Invoke-Hook -Provider Claude -InputObject @{
        session_id = 'root-session'
        cwd = $trustedRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ((Get-RegisteredCount) -eq $countBeforeExclusions) -Message 'The trusted root itself must not be auto-registered.'

    # the BRAIN root and its subtree are excluded
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = 'brain-root-session'
        cwd = $testBrainRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ((Get-RegisteredCount) -eq $countBeforeExclusions) -Message 'The BRAIN root itself must not be auto-registered.'
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = 'brain-sub-session'
        cwd = (Join-Path $testBrainRoot 'integrations')
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ((Get-RegisteredCount) -eq $countBeforeExclusions) -Message 'Paths inside the BRAIN root must not be auto-registered.'

    # outside every trusted root
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = 'outside-session'
        cwd = $outsideProjectRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ((Get-RegisteredCount) -eq $countBeforeExclusions) -Message 'Paths outside trusted roots must not be auto-registered.'

    # final path segment is a junction
    New-Item -ItemType Junction -Path $junctionFinal -Target $linkTargetRoot | Out-Null
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = 'junction-session'
        cwd = $junctionFinal
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ((Get-RegisteredCount) -eq $countBeforeExclusions) -Message 'Junction project directories must not be auto-registered.'

    # a junction ancestor must not smuggle an outside directory under the trusted root
    New-Item -ItemType Junction -Path $junctionAncestor -Target $linkAncestorTarget | Out-Null
    $throughJunction = Join-Path $junctionAncestor 'OutsideProject'
    Assert-True -Condition (Test-Path -LiteralPath $throughJunction -PathType Container) -Message 'Junction ancestor test setup must resolve.'
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = 'ancestor-session'
        cwd = $throughJunction
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ((Get-RegisteredCount) -eq $countBeforeExclusions) -Message 'Directories reached through a junction ancestor must not be auto-registered.'

    # nonexistent path
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = 'missing-session'
        cwd = (Join-Path $trustedRoot 'DoesNotExist')
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ((Get-RegisteredCount) -eq $countBeforeExclusions) -Message 'Nonexistent paths must not be auto-registered.'

    Assert-True -Condition (@(Get-StateFiles).Count -eq $stateCountBeforeExclusions) -Message 'Excluded sessions must not create hook state.'

    # --- Phase 7: invalid trusted-roots config disables auto-registration, valid config re-enables it ---
    New-Item -ItemType Directory -Path $afterBreakageRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\trusted-roots.json'), '{ not-json', [Text.UTF8Encoding]::new($false))
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = 'breakage-session'
        cwd = $afterBreakageRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ((Get-RegisteredCount) -eq $countBeforeExclusions) -Message 'Invalid trusted-roots config must disable auto-registration.'

    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\trusted-roots.json'), ($trustedConfig + "`n"), [Text.UTF8Encoding]::new($false))
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = 'recovery-session'
        cwd = $afterBreakageRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ((Get-RegisteredCount) -eq ($countBeforeExclusions + 1)) -Message 'Restored trusted-roots config must re-enable auto-registration.'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $afterBreakageRoot '.brain\context.md') -PathType Leaf) -Message 'Recovered auto-registration must init the project.'

    Assert-True -Condition ((Get-FileHash -LiteralPath $mainlinePath -Algorithm SHA256).Hash -eq $mainlineHash) -Message 'Auto-registration must not modify project mainline files.'

    [pscustomobject][ordered]@{
        result = 'PASS'
        auto_registered_project_id = $projectId
        auto_initialized = $true
        session_start_context_injected = $true
        stop_record_requested_once = $true
        raw_stored_byte_identical = $true
        context_refreshed = $true
        sessionend_state_cleaned = $true
        second_session_no_duplicate = $true
        trusted_root_excluded = $true
        brain_root_excluded = $true
        outside_root_excluded = $true
        junction_excluded = $true
        junction_ancestor_excluded = $true
        missing_path_excluded = $true
        invalid_config_fail_open = $true
        config_recovery_reenabled = $true
        mainline_unchanged = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-auto-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe auto-registration test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
