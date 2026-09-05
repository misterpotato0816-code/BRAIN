[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-registry-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$projectA = Join-Path $testRoot 'ProjectA'
$projectB = Join-Path $testRoot 'ProjectB'
$stateRoot = Join-Path $testRoot 'state'
$userConfigRoot = Join-Path $testRoot 'user-config'
$codexHooksPath = Join-Path $userConfigRoot '.codex\hooks.json'
$claudeSettingsPath = Join-Path $userConfigRoot '.claude\settings.json'
$setupScript = Join-Path $sourceRoot 'integrations\brain-setup.ps1'
$hookScript = Join-Path $sourceRoot 'integrations\brain-hook.ps1'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$realProjectsHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-Setup {
    param([Parameter(Mandatory = $true)][string]$Action)

    $output = & $setupScript -Action $Action -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $codexHooksPath -ClaudeSettingsPath $claudeSettingsPath -SandboxDir $userConfigRoot
    return ($output | ConvertFrom-Json -Depth 30)
}

function Invoke-SetupWithArgs {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Integration = ''
    )

    if ([string]::IsNullOrWhiteSpace($Integration)) {
        $output = & $setupScript -Action $Action -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $codexHooksPath -ClaudeSettingsPath $claudeSettingsPath -SandboxDir $userConfigRoot
    }
    else {
        $output = & $setupScript -Action $Action -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $codexHooksPath -ClaudeSettingsPath $claudeSettingsPath -SandboxDir $userConfigRoot -Integration $Integration
    }
    return ($output | ConvertFrom-Json -Depth 30)
}

function Invoke-Hook {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][hashtable]$InputObject
    )

    $json = ConvertTo-Json -InputObject $InputObject -Depth 30 -Compress
    $output = $json | & $pwshPath -NoProfile -NonInteractive -File $hookScript -Provider $Provider -BrainRoot $testBrainRoot -StateRoot $stateRoot 2>&1
    $exitCode = $LASTEXITCODE
    Assert-True -Condition ($exitCode -eq 0) -Message "$Provider hook must fail open with exit code 0."
    return (@($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-ManagedCount {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$EventName)

    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    if (-not $config.Contains('hooks') -or -not $config['hooks'].Contains($EventName)) { return 0 }
    $count = 0
    foreach ($group in @($config['hooks'][$EventName])) {
        if ($group -isnot [Collections.IDictionary] -or -not $group.Contains('hooks')) { continue }
        foreach ($handler in @($group['hooks'])) {
            if ($handler -is [Collections.IDictionary] -and ($handler.Contains('brain_hook_id') -or ($handler.Contains('managed_by') -and [string]$handler['managed_by'] -eq 'brain'))) { $count++ }
        }
    }
    return $count
}

function New-RecordText {
    param([Parameter(Mandatory = $true)][string]$ProjectId, [Parameter(Mandatory = $true)][string]$TaskId, [Parameter(Mandatory = $true)][string]$Summary)

    return @"
---
brain_record_version: "0.1"
project_id: "$ProjectId"
task_id: "$TaskId"
completed_at: "2026-08-30T20:00:00.0000000+09:00"
---

# Task Summary

- [Observed] $Summary

# Approach

- [Observed] Exercised the adapter registry path.

# Successes

- [Verified] The expected contract was observed in the isolated test.

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
    New-Item -ItemType Directory -Path $testBrainRoot, $projectA, $projectB, $stateRoot, $userConfigRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'), (Join-Path $testBrainRoot 'templates'), (Join-Path $testBrainRoot 'store\raw'), (Join-Path $testBrainRoot 'integrations') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination (Join-Path $testBrainRoot 'brain.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Destination (Join-Path $testBrainRoot 'templates\work-record.md')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))
    $trustedConfig = [ordered]@{ format_version = '0.1'; trusted_roots = @() } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\trusted-roots.json'), ($trustedConfig + "`n"), [Text.UTF8Encoding]::new($false))

    $brainScript = Join-Path $testBrainRoot 'brain.ps1'
    & $brainScript register -ProjectPath $projectA -ProjectId 'registry-a' | Out-Null
    & $brainScript init -ProjectPath $projectA | Out-Null
    & $brainScript register -ProjectPath $projectB -ProjectId 'registry-b' | Out-Null
    & $brainScript init -ProjectPath $projectB | Out-Null
    [IO.File]::WriteAllText((Join-Path $projectA '.brain\outbox\seed-a.md'), (New-RecordText -ProjectId 'registry-a' -TaskId 'seed-a' -Summary 'Alpha project seed marker.'), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $projectB '.brain\outbox\seed-b.md'), (New-RecordText -ProjectId 'registry-b' -TaskId 'seed-b' -Summary 'Beta project seed marker.'), [Text.UTF8Encoding]::new($false))
    & $brainScript sync -ProjectPath $projectA | Out-Null
    & $brainScript sync -ProjectPath $projectB | Out-Null

    # === 1. Registry enumerates Codex/Claude ===
    $list = Invoke-Setup -Action Integrations
    $ids = @($list.integrations | ForEach-Object { [string]$_.id })
    Assert-True -Condition ($ids -contains 'codex') -Message '1. Registry must enumerate codex.'
    Assert-True -Condition ($ids -contains 'claude') -Message '1. Registry must enumerate claude.'
    Assert-True -Condition ((@($list.integrations | Where-Object { [string]$_.id -eq 'codex' })[0].enabled) -eq $true) -Message '1. Codex must be enabled by default.'
    Assert-True -Condition ((@($list.integrations | Where-Object { [string]$_.id -eq 'claude' })[0].enabled) -eq $true) -Message '1. Claude must be enabled by default.'

    # === 2/3. Adapter hook output matches the Phase 1 contract ===
    New-Item -ItemType Directory -Path (Split-Path -Parent $codexHooksPath), (Split-Path -Parent $claudeSettingsPath) -Force | Out-Null
    [IO.File]::WriteAllText($codexHooksPath, ("{}`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($claudeSettingsPath, ("{}`n"), [Text.UTF8Encoding]::new($false))
    $installResult = Invoke-Setup -Action Install
    Assert-True -Condition ([bool]$installResult.codex.changed -and [bool]$installResult.claude.changed) -Message '2. Install must add both providers.'

    $codexConfig = Get-Content -LiteralPath $codexHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $codexStartGroup = @(@($codexConfig['hooks']['SessionStart'])[-1])
    $codexHandler = @($codexStartGroup[0]['hooks'])[0]
    Assert-True -Condition ([string]$codexHandler['statusMessage'] -eq 'BRAIN Codex SessionStart') -Message '2. Codex statusMessage must match Phase 1.'
    Assert-True -Condition ([string]$codexHandler['brain_hook_id'] -eq 'brain.codex.SessionStart') -Message '2. Codex brain_hook_id must match Phase 1.'
    Assert-True -Condition ([string]$codexHandler['command'] -match 'brain-hook\.ps1' -and [string]$codexHandler['command'] -match '-Provider Codex') -Message '2. Codex single-string command must match Phase 1.'
    Assert-True -Condition ([string]$codexHandler['commandWindows'] -eq [string]$codexHandler['command']) -Message '2. Codex commandWindows must equal command.'
    Assert-True -Condition ([int]$codexHandler['timeout'] -eq 15) -Message '2. Codex SessionStart timeout must be 15.'
    Assert-True -Condition ([int]$codexHandler['additionalContextLimit'] -eq 12000) -Message '2. Codex SessionStart additionalContextLimit must be 12000.'
    Assert-True -Condition ([string]$codexStartGroup[0]['matcher'] -eq 'startup|resume|clear|compact') -Message '2. Codex SessionStart matcher must match Phase 1.'
    $codexStopGroup = @(@($codexConfig['hooks']['Stop'])[-1])
    Assert-True -Condition (-not $codexStopGroup[0].Contains('matcher')) -Message '2. Codex Stop must carry no matcher.'

    $claudeConfig = Get-Content -LiteralPath $claudeSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $claudeStopGroup = @(@($claudeConfig['hooks']['Stop'])[-1])
    $claudeHandler = @($claudeStopGroup[0]['hooks'])[0]
    Assert-True -Condition ([string]$claudeHandler['statusMessage'] -eq 'BRAIN Claude Stop') -Message '3. Claude statusMessage must match Phase 1.'
    Assert-True -Condition ([string]$claudeHandler['brain_hook_id'] -eq 'brain.claude.Stop') -Message '3. Claude brain_hook_id must match Phase 1.'
    Assert-True -Condition ((@($claudeHandler['args']) -join ' ') -match '-Provider Claude') -Message '3. Claude args array must carry -Provider Claude.'
    Assert-True -Condition ([int]$claudeHandler['timeout'] -eq 30) -Message '3. Claude Stop timeout must be 30.'
    Assert-True -Condition (-not $claudeStopGroup[0].Contains('matcher')) -Message '3. Claude Stop must carry no matcher.'
    $claudePostGroup = @(@($claudeConfig['hooks']['PostToolUse'])[-1])
    Assert-True -Condition ([string]$claudePostGroup[0]['matcher'] -eq 'Edit|Write|NotebookEdit') -Message '3. Claude PostToolUse matcher must match Phase 1.'
    $codexPostGroup = @(@($codexConfig['hooks']['PostToolUse'])[-1])
    Assert-True -Condition ([string]$codexPostGroup[0]['matcher'] -eq 'apply_patch|Edit|Write') -Message '2. Codex PostToolUse matcher must match Phase 1.'

    # === 4. enable / disable round-trip ===
    $disable = Invoke-SetupWithArgs -Action Disable -Integration codex
    Assert-True -Condition ([bool]$disable.enabled -eq $false) -Message '4. Disable codex must report enabled=false.'
    $listAfter = Invoke-Setup -Action Integrations
    Assert-True -Condition ((@($listAfter.integrations | Where-Object { [string]$_.id -eq 'codex' })[0].enabled) -eq $false) -Message '4. Codex must stay disabled in listing.'
    Assert-True -Condition ((@($listAfter.integrations | Where-Object { [string]$_.id -eq 'claude' })[0].enabled) -eq $true) -Message '4. Claude must stay enabled.'
    $reenable = Invoke-SetupWithArgs -Action Enable -Integration codex
    Assert-True -Condition ([bool]$reenable.enabled -eq $true) -Message '4. Enable codex must report enabled=true.'

    # === 5. Disabled provider gets no hooks ===
    $null = Invoke-SetupWithArgs -Action Disable -Integration codex
    $codexHashBefore = (Get-FileHash -LiteralPath $codexHooksPath -Algorithm SHA256).Hash
    $claudeHashBefore = (Get-FileHash -LiteralPath $claudeSettingsPath -Algorithm SHA256).Hash
    $updateWhileDisabled = Invoke-Setup -Action Update
    Assert-True -Condition ([bool]$updateWhileDisabled.codex.skipped -eq $true) -Message '5. Update must skip the disabled Codex provider.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $codexHooksPath -Algorithm SHA256).Hash -eq $codexHashBefore) -Message '5. Disabled Codex config must not be modified.'
    $null = Invoke-SetupWithArgs -Action Enable -Integration codex

    # === 6/7. Update + Repair converge without duplication ===
    for ($i = 0; $i -lt 2; $i++) {
        $null = Invoke-Setup -Action Update
        foreach ($eventName in @('SessionStart', 'PostToolUse', 'Stop', 'SessionEnd')) {
            Assert-True -Condition ((Get-ManagedCount -Path $codexHooksPath -EventName $eventName) -eq 1) -Message "6. Codex $eventName must have exactly one handler after Update."
            Assert-True -Condition ((Get-ManagedCount -Path $claudeSettingsPath -EventName $eventName) -eq 1) -Message "6. Claude $eventName must have exactly one handler after Update."
        }
    }
    $repairResult = Invoke-Setup -Action Repair
    foreach ($eventName in @('SessionStart', 'PostToolUse', 'Stop', 'SessionEnd')) {
        Assert-True -Condition ((Get-ManagedCount -Path $codexHooksPath -EventName $eventName) -eq 1) -Message "7. Codex $eventName must have exactly one handler after Repair."
        Assert-True -Condition ((Get-ManagedCount -Path $claudeSettingsPath -EventName $eventName) -eq 1) -Message "7. Claude $eventName must have exactly one handler after Repair."
    }

    # === 8. Uninstall removes only BRAIN-managed entries ===
    $codexBefore = Get-Content -LiteralPath $codexHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $codexBefore['hooks']['Stop'] = @(@($codexBefore['hooks']['Stop']) + @(@{ hooks = @(@{ type = 'command'; command = 'third-party-keep-me'; statusMessage = 'third-party' }) }))
    [IO.File]::WriteAllText($codexHooksPath, ((ConvertTo-Json -InputObject $codexBefore -Depth 100) + "`n"), [Text.UTF8Encoding]::new($false))
    $uninstall = Invoke-Setup -Action Uninstall
    Assert-True -Condition ([bool]$uninstall.user_data_preserved) -Message '8. Uninstall must preserve user data.'
    $codexAfter = Get-Content -LiteralPath $codexHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $thirdPartySurvived = $false
    if ($codexAfter.Contains('hooks') -and $codexAfter['hooks'].Contains('Stop')) {
        foreach ($group in @($codexAfter['hooks']['Stop'])) {
            foreach ($handler in @($group['hooks'])) {
                if ($handler -is [Collections.IDictionary] -and [string]$handler['command'] -eq 'third-party-keep-me') { $thirdPartySurvived = $true }
            }
        }
    }
    Assert-True -Condition $thirdPartySurvived -Message '8. Uninstall must keep third-party hooks.'
    foreach ($eventName in @('SessionStart', 'PostToolUse', 'Stop', 'SessionEnd')) {
        Assert-True -Condition ((Get-ManagedCount -Path $codexHooksPath -EventName $eventName) -eq 0) -Message "8. Codex $eventName must have zero managed handlers after Uninstall."
    }
    $null = Invoke-Setup -Action Install

    # === 9. Unknown provider is rejected clearly ===
    $unknownFailed = $false
    try {
        $null = Invoke-SetupWithArgs -Action Enable -Integration kilo-future-xyz
    }
    catch {
        $unknownFailed = ([string]$_.Exception.Message -match 'Unknown integration')
    }
    Assert-True -Condition $unknownFailed -Message '9. Unknown integration enable must fail with a clear error.'
    $unknownHookOutput = Invoke-Hook -Provider 'kilo-future-xyz' -InputObject @{ session_id = 's-unknown'; cwd = $projectA; hook_event_name = 'SessionStart'; source = 'startup' }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($unknownHookOutput)) -Message '9. Unknown provider hook must be a fail-open no-op.'
    Assert-True -Condition ((Get-ManagedCount -Path $codexHooksPath -EventName 'SessionStart') -eq 1) -Message '9. Unknown provider must not disturb Codex hooks.'
    Assert-True -Condition ((Get-ManagedCount -Path $claudeSettingsPath -EventName 'SessionStart') -eq 1) -Message '9. Unknown provider must not disturb Claude hooks.'

    # === 10. Integration A config change does not affect B ===
    $claudeHashPinned = (Get-FileHash -LiteralPath $claudeSettingsPath -Algorithm SHA256).Hash
    $null = Invoke-SetupWithArgs -Action Update -Integration codex
    Assert-True -Condition ((Get-FileHash -LiteralPath $claudeSettingsPath -Algorithm SHA256).Hash -eq $claudeHashPinned) -Message '10. Codex-only Update must not touch Claude config.'

    # === 11. Stop output shapes per adapter + project isolation ===
    $sessionId = 'registry-session-001'
    $null = Invoke-Hook -Provider Codex -InputObject @{ session_id = $sessionId; cwd = $projectA; hook_event_name = 'SessionStart'; source = 'startup' }
    $startA = Invoke-Hook -Provider Claude -InputObject @{ session_id = $sessionId; cwd = $projectA; hook_event_name = 'SessionStart'; source = 'startup' }
    Assert-True -Condition ($startA -match 'Alpha project seed marker') -Message '11. Project A context must inject project A records.'
    Assert-True -Condition ($startA -notmatch 'Beta project seed marker') -Message '11. Project A context must not leak project B records.'
    $startB = Invoke-Hook -Provider Claude -InputObject @{ session_id = $sessionId; cwd = $projectB; hook_event_name = 'SessionStart'; source = 'startup' }
    Assert-True -Condition ($startB -match 'Beta project seed marker') -Message '11. Project B context must inject project B records.'
    Assert-True -Condition ($startB -notmatch 'Alpha project seed marker') -Message '11. Project B context must not leak project A records.'

    $null = Invoke-Hook -Provider Codex -InputObject @{ session_id = $sessionId; cwd = $projectA; hook_event_name = 'PostToolUse'; tool_name = 'Edit'; tool_input = @{ file_path = 'a.txt' } }
    $codexStop = Invoke-Hook -Provider Codex -InputObject @{ session_id = $sessionId; cwd = $projectA; hook_event_name = 'Stop'; stop_hook_active = $false; last_assistant_message = 'Done.' }
    $codexStopJson = $codexStop | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($codexStopJson.decision -eq 'block') -Message '11. Codex Stop must use decision:block.'
    $null = Invoke-Hook -Provider Claude -InputObject @{ session_id = 'registry-session-002'; cwd = $projectB; hook_event_name = 'PostToolUse'; tool_name = 'Edit'; tool_input = @{ file_path = 'b.txt' } }
    $claudeStop = Invoke-Hook -Provider Claude -InputObject @{ session_id = 'registry-session-002'; cwd = $projectB; hook_event_name = 'Stop'; stop_hook_active = $false; last_assistant_message = 'Done.' }
    $claudeStopJson = $claudeStop | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($null -eq $claudeStopJson.PSObject.Properties['decision']) -Message '11. Claude Stop must not use decision:block.'
    Assert-True -Condition ($claudeStopJson.hookSpecificOutput.hookEventName -eq 'Stop') -Message '11. Claude Stop must use hookSpecificOutput.'

    $stateFiles = @(Get-ChildItem -LiteralPath $stateRoot -File -Filter '*.json')
    Assert-True -Condition ($stateFiles.Count -ge 2) -Message '11. Separate projects must keep separate hook state files.'

    # === 12. Real user data untouched ===
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash -eq $realProjectsHash) -Message '12. Real config/projects.json must be untouched.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'config\integrations.json'))) -Message '12. No integrations.json may be created in the real BRAIN root.'

    [pscustomobject][ordered]@{
        result = 'PASS'
        registry_lists_codex_claude = $true
        codex_handler_compatible = $true
        claude_handler_compatible = $true
        enable_disable_ok = $true
        disabled_provider_skipped = $true
        update_repair_idempotent = $true
        uninstall_only_managed = $true
        unknown_provider_rejected = $true
        cross_provider_isolation_ok = $true
        project_isolation_ok = $true
        real_user_data_untouched = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-registry-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe registry test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
