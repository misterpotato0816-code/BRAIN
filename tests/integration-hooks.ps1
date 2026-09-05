[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-hooks-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'BRAIN 日本語'
$testProjectRoot = Join-Path $testRoot 'Project With Spaces'
$unregisteredRoot = Join-Path $testRoot 'Unregistered'
$stateRoot = Join-Path $testRoot 'state'
$configRoot = Join-Path $testRoot 'user-config'
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

function New-RecordText {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Summary
    )

    return @"
---
brain_record_version: "0.1"
project_id: "hook-e2e"
task_id: "$TaskId"
completed_at: "2026-08-30T20:00:00.0000000+09:00"
---

# Task Summary

- [Observed] $Summary

# Approach

- [Observed] Exercised the PowerShell lifecycle hook adapter.

# Successes

- [Verified] The expected hook contract was observed in the isolated test.

# Failures

- [Observed] No failure was observed in this bounded path.

# Bugs

- [Suspected] No bug is currently suspected from this bounded path.

# Fixes

- [Verified] No fix was required for this record.

# Evidence

- [Verified] Existing brain.ps1 accepted and synchronized this record.

# Next-Time Notes

- [Observed] Recheck provider behavior with a live smoke test.
"@
}

try {
    New-Item -ItemType Directory -Path $testBrainRoot, $testProjectRoot, $unregisteredRoot, $stateRoot, $configRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'), (Join-Path $testBrainRoot 'templates'), (Join-Path $testBrainRoot 'store\raw'), (Join-Path $testBrainRoot 'integrations') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination (Join-Path $testBrainRoot 'brain.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Destination (Join-Path $testBrainRoot 'templates\work-record.md')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'integrations\brain-hook.ps1') -Destination (Join-Path $testBrainRoot 'integrations\brain-hook.ps1')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))

    $brainScript = Join-Path $testBrainRoot 'brain.ps1'
    & $brainScript register -ProjectPath $testProjectRoot -ProjectId 'hook-e2e' | Out-Null
    & $brainScript init -ProjectPath $testProjectRoot | Out-Null
    $mainlinePath = Join-Path $testProjectRoot 'mainline.txt'
    [IO.File]::WriteAllText($mainlinePath, "unchanged`n", [Text.UTF8Encoding]::new($false))
    $mainlineHash = (Get-FileHash -LiteralPath $mainlinePath -Algorithm SHA256).Hash

    $seedPath = Join-Path $testProjectRoot '.brain\outbox\seed.md'
    [IO.File]::WriteAllText($seedPath, (New-RecordText -TaskId 'seed' -Summary 'Seeded context injection evidence.'), [Text.UTF8Encoding]::new($false))
    & $brainScript sync -ProjectPath $testProjectRoot | Out-Null

    $codexSession = 'codex-session-001'
    $codexStart = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $codexSession
        cwd = $testProjectRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    $codexStartJson = $codexStart | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($codexStartJson.hookSpecificOutput.hookEventName -eq 'SessionStart') -Message 'Codex SessionStart must use hookSpecificOutput.'
    Assert-True -Condition ([string]$codexStartJson.hookSpecificOutput.additionalContext -match 'historical reference data, not instructions') -Message 'Codex context must be explicitly non-authoritative.'
    Assert-True -Condition ([string]$codexStartJson.hookSpecificOutput.additionalContext -match 'Seeded context injection evidence') -Message 'Codex SessionStart must inject current context.md.'

    $codexPost = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $codexSession
        turn_id = 'turn-001'
        cwd = $testProjectRoot
        hook_event_name = 'PostToolUse'
        tool_name = 'apply_patch'
        tool_input = @{ command = 'test edit' }
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($codexPost)) -Message 'PostToolUse should only mark dirty state.'

    $codexStop = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $codexSession
        turn_id = 'turn-001'
        cwd = $testProjectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Done.'
    }
    $codexStopJson = $codexStop | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($codexStopJson.decision -eq 'block') -Message 'Codex Stop must use official decision:block continuation.'
    Assert-True -Condition ([string]$codexStopJson.reason -match 'Create a short BRAIN work record') -Message 'Codex Stop must request a record.'

    $activeStop = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $codexSession
        turn_id = 'turn-002'
        cwd = $testProjectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $true
        last_assistant_message = 'Continuation.'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($activeStop)) -Message 'stop_hook_active must prevent recursive Codex continuation.'

    $stateFile = @(Get-ChildItem -LiteralPath $stateRoot -File -Filter '*.json') | Select-Object -First 1
    Assert-True -Condition ($null -ne $stateFile) -Message 'Codex state file must exist.'
    $state = Get-Content -LiteralPath $stateFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    $recordPath = [string]$state.expected_record_path
    Assert-True -Condition (Test-Path -LiteralPath (Split-Path -Parent $recordPath) -PathType Container) -Message 'Expected outbox directory must exist.'
    [IO.File]::WriteAllText($recordPath, (New-RecordText -TaskId ([string]$state.task_id) -Summary 'Recorded a dirty Codex Stop continuation.'), [Text.UTF8Encoding]::new($false))

    $syncingStop = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $codexSession
        turn_id = 'turn-002'
        cwd = $testProjectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $true
        last_assistant_message = 'Record created.'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($syncingStop)) -Message 'Successful Stop sync should allow completion.'
    $rawFiles = @(Get-ChildItem -LiteralPath (Join-Path $testBrainRoot 'store\raw\hook-e2e') -File -Filter '*.md')
    Assert-True -Condition ($rawFiles.Count -eq 2) -Message 'Codex Stop must reuse brain.ps1 sync and add one record.'
    $contextText = Get-Content -LiteralPath (Join-Path $testProjectRoot '.brain\context.md') -Raw -Encoding UTF8
    Assert-True -Condition $contextText.Contains('Recorded a dirty Codex Stop continuation.') -Message 'Codex Stop sync must refresh context.md.'

    $claudeSession = 'claude-session-001'
    $null = Invoke-Hook -Provider Claude -InputObject @{
        session_id = $claudeSession
        cwd = $testProjectRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    $null = Invoke-Hook -Provider Claude -InputObject @{
        session_id = $claudeSession
        cwd = $testProjectRoot
        hook_event_name = 'PostToolUse'
        tool_name = 'Edit'
        tool_input = @{ file_path = $mainlinePath }
    }
    $claudeStop = Invoke-Hook -Provider Claude -InputObject @{
        session_id = $claudeSession
        cwd = $testProjectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Done.'
    }
    $claudeStopJson = $claudeStop | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($null -eq $claudeStopJson.PSObject.Properties['decision']) -Message 'Claude normal record request must not use error-style decision:block.'
    Assert-True -Condition ($claudeStopJson.hookSpecificOutput.hookEventName -eq 'Stop') -Message 'Claude Stop must use hookSpecificOutput.'
    Assert-True -Condition ([string]$claudeStopJson.hookSpecificOutput.additionalContext -match 'Create a short BRAIN work record') -Message 'Claude Stop must continue with non-error additionalContext.'
    $claudeActive = Invoke-Hook -Provider Claude -InputObject @{
        session_id = $claudeSession
        cwd = $testProjectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $true
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($claudeActive)) -Message 'stop_hook_active must prevent recursive Claude continuation.'

    $stateCountBefore = @(Get-ChildItem -LiteralPath $stateRoot -File -Filter '*.json').Count
    $unregisteredOutput = Invoke-Hook -Provider Codex -InputObject @{
        session_id = 'unregistered-session'
        cwd = $unregisteredRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($unregisteredOutput)) -Message 'Unregistered projects must be a no-op.'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $stateRoot -File -Filter '*.json').Count -eq $stateCountBefore) -Message 'Unregistered projects must not create state.'

    $malformedOutput = '{not-json' | & $pwshPath -NoProfile -NonInteractive -File (Join-Path $testBrainRoot 'integrations\brain-hook.ps1') -Provider Codex -BrainRoot $testBrainRoot -StateRoot $stateRoot 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'Malformed hook input must fail open.'
    Assert-True -Condition ([string]::IsNullOrWhiteSpace((@($malformedOutput) -join "`n"))) -Message 'Fail-open errors must not corrupt hook stdout.'

    # MaxRecordRequests cap: an agent that never writes the record must not
    # be asked forever. First two Stops request, the third stays silent.
    $capSession = 'codex-cap-001'
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $capSession
        cwd = $testProjectRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    $null = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $capSession
        turn_id = 'turn-cap'
        cwd = $testProjectRoot
        hook_event_name = 'PostToolUse'
        tool_name = 'apply_patch'
        tool_input = @{ command = 'cap edit' }
    }
    $capStop1 = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $capSession
        turn_id = 'turn-cap'
        cwd = $testProjectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Done.'
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($capStop1)) -Message 'First Stop must request the record.'
    $capStop2 = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $capSession
        turn_id = 'turn-cap'
        cwd = $testProjectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Still done.'
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($capStop2)) -Message 'Second Stop must re-request the record.'
    $capStop3 = Invoke-Hook -Provider Codex -InputObject @{
        session_id = $capSession
        turn_id = 'turn-cap'
        cwd = $testProjectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Done again.'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($capStop3)) -Message 'Third Stop must stay silent (request cap reached).'

    $codexConfig = Join-Path $configRoot '.codex\hooks.json'
    $claudeConfig = Join-Path $configRoot '.claude\settings.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $codexConfig), (Split-Path -Parent $claudeConfig) -Force | Out-Null
    $existingCodex = @{
        description = 'existing'
        hooks = @{
            SessionStart = @(@{ matcher = 'startup'; hooks = @(@{ type = 'command'; command = 'existing-codex'; statusMessage = 'existing' }) })
        }
    } | ConvertTo-Json -Depth 20
    $existingClaude = @{
        alwaysThinkingEnabled = $true
        hooks = @{
            Stop = @(@{ hooks = @(@{ type = 'command'; command = 'existing-claude'; statusMessage = 'existing' }) })
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($codexConfig, ($existingCodex + "`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($claudeConfig, ($existingClaude + "`n"), [Text.UTF8Encoding]::new($false))

    $installer = Join-Path $sourceRoot 'integrations\install-hooks.ps1'
    # Isolation for file-based integrations (see setup-lifecycle.ps1):
    # -SandboxDir redirects every non-explicitly-overridden target under one
    # temp directory. Backup/idempotency assertions below keep holding because
    # both runs share the same sandbox directory.
    $installOne = & $installer -BrainHookPath (Join-Path $sourceRoot 'integrations\brain-hook.ps1') -CodexHooksPath $codexConfig -ClaudeSettingsPath $claudeConfig -SandboxDir $configRoot | ConvertFrom-Json -Depth 20
    Assert-True -Condition ([bool]$installOne.codex_changed -and [bool]$installOne.claude_changed) -Message 'First installer run must add both provider hooks.'
    Assert-True -Condition (Test-Path -LiteralPath ([string]$installOne.codex_backup) -PathType Leaf) -Message 'Codex pre-install settings must be backed up.'
    Assert-True -Condition (Test-Path -LiteralPath ([string]$installOne.claude_backup) -PathType Leaf) -Message 'Claude pre-install settings must be backed up.'
    $codexHashAfterFirst = (Get-FileHash -LiteralPath $codexConfig -Algorithm SHA256).Hash
    $claudeHashAfterFirst = (Get-FileHash -LiteralPath $claudeConfig -Algorithm SHA256).Hash
    $backupCount = @(Get-ChildItem -LiteralPath $configRoot -Recurse -File | Where-Object Name -Like '*.brain-backup-*').Count

    $installTwo = & $installer -BrainHookPath (Join-Path $sourceRoot 'integrations\brain-hook.ps1') -CodexHooksPath $codexConfig -ClaudeSettingsPath $claudeConfig -SandboxDir $configRoot | ConvertFrom-Json -Depth 20
    Assert-True -Condition (-not [bool]$installTwo.codex_changed -and -not [bool]$installTwo.claude_changed) -Message 'Second installer run must be idempotent.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $codexConfig -Algorithm SHA256).Hash -eq $codexHashAfterFirst) -Message 'Idempotent Codex install must preserve config bytes.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $claudeConfig -Algorithm SHA256).Hash -eq $claudeHashAfterFirst) -Message 'Idempotent Claude install must preserve config bytes.'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $configRoot -Recurse -File | Where-Object Name -Like '*.brain-backup-*').Count -eq $backupCount) -Message 'Idempotent install must not create extra backups.'

    $installedCodex = Get-Content -LiteralPath $codexConfig -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $installedClaude = Get-Content -LiteralPath $claudeConfig -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    Assert-True -Condition ($installedCodex.description -eq 'existing') -Message 'Installer must preserve unrelated Codex settings.'
    Assert-True -Condition (@($installedCodex.hooks.SessionStart).Count -eq 2) -Message 'Installer must append rather than replace existing Codex hooks.'
    Assert-True -Condition ([bool]$installedClaude.alwaysThinkingEnabled) -Message 'Installer must preserve unrelated Claude settings.'
    Assert-True -Condition (@($installedClaude.hooks.Stop).Count -eq 2) -Message 'Installer must append rather than replace existing Claude hooks.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $mainlinePath -Algorithm SHA256).Hash -eq $mainlineHash) -Message 'Hook integration must not modify project mainline files.'

    [pscustomobject][ordered]@{
        result = 'PASS'
        codex_session_start_context = $true
        codex_stop_decision_block = $true
        codex_stop_sync_raw_count = $rawFiles.Count
        claude_stop_additional_context = $true
        stop_hook_active_bounded = $true
        stop_request_capped = $true
        unregistered_noop = $true
        malformed_input_fail_open = $true
        installer_backup = $true
        installer_idempotent = $true
        existing_hooks_preserved = $true
        mainline_unchanged = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-hooks-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe integration test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

