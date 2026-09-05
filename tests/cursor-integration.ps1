[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-cursor-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$projectA = Join-Path $testRoot 'ProjectA'
$projectB = Join-Path $testRoot 'ProjectB'
$stateRoot = Join-Path $testRoot 'state'
$sandboxDir = Join-Path $testRoot 'sandbox-home'
$cursorHooksPath = Join-Path $sandboxDir 'cursor.hooks.json'
$setupScript = Join-Path $sourceRoot 'integrations\brain-setup.ps1'
$hookScript = Join-Path $sourceRoot 'integrations\brain-hook.ps1'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$realProjectsHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash
$realCursorHooks = Join-Path $env:USERPROFILE '.cursor\hooks.json'
# Live installs are legitimate: pin the pre-test state (absent or hash) and
# require it unchanged at the end instead of asserting absence.
$realCursorHooksBefore = if (Test-Path -LiteralPath $realCursorHooks -PathType Leaf) {
    (Get-FileHash -LiteralPath $realCursorHooks -Algorithm SHA256).Hash
}
else {
    $null
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-OptionalProp {
    param([Parameter(Mandatory = $true)][object]$Object, [Parameter(Mandatory = $true)][string]$Name)

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-NativeContext {
    param([Parameter(Mandatory = $true)][string]$JsonText)

    if ([string]::IsNullOrWhiteSpace($JsonText)) { return '' }
    $parsed = $JsonText | ConvertFrom-Json -Depth 30
    return [string](Get-OptionalProp -Object $parsed -Name 'additional_context')
}

function Invoke-CursorSetup {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Integration = 'cursor'
    )

    $output = & $setupScript -Action $Action -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -SandboxDir $sandboxDir -Integration $Integration
    return ($output | ConvertFrom-Json -Depth 30)
}

function Invoke-CursorBridge {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Payload,
        [string]$Provider = 'Cursor'
    )

    $json = ConvertTo-Json -InputObject $Payload -Depth 20 -Compress
    $output = $json | & $pwshPath -NoProfile -NonInteractive -File $hookScript -Provider $Provider -BrainRoot $testBrainRoot -StateRoot $stateRoot 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'Cursor bridge must fail open with exit code 0.'
    return (@($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
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

- [Observed] Exercised the Cursor bridge path.

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
    New-Item -ItemType Directory -Path $testBrainRoot, $projectA, $projectB, $stateRoot, $sandboxDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'), (Join-Path $testBrainRoot 'templates'), (Join-Path $testBrainRoot 'store\raw'), (Join-Path $testBrainRoot 'integrations') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination (Join-Path $testBrainRoot 'brain.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Destination (Join-Path $testBrainRoot 'templates\work-record.md')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))
    $trustedConfig = [ordered]@{ format_version = '0.1'; trusted_roots = @() } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\trusted-roots.json'), ($trustedConfig + "`n"), [Text.UTF8Encoding]::new($false))

    $brainScript = Join-Path $testBrainRoot 'brain.ps1'
    & $brainScript register -ProjectPath $projectA -ProjectId 'cursor-a' | Out-Null
    & $brainScript init -ProjectPath $projectA | Out-Null
    & $brainScript register -ProjectPath $projectB -ProjectId 'cursor-b' | Out-Null
    & $brainScript init -ProjectPath $projectB | Out-Null
    [IO.File]::WriteAllText((Join-Path $projectA '.brain\outbox\seed-a.md'), (New-RecordText -ProjectId 'cursor-a' -TaskId 'seed-a' -Summary 'Alpha Cursor seed marker.'), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $projectB '.brain\outbox\seed-b.md'), (New-RecordText -ProjectId 'cursor-b' -TaskId 'seed-b' -Summary 'Beta Cursor seed marker.'), [Text.UTF8Encoding]::new($false))
    & $brainScript sync -ProjectPath $projectA | Out-Null
    & $brainScript sync -ProjectPath $projectB | Out-Null

    # === 1. Registry lists cursor ===
    $listOutput = & $setupScript -Action Integrations -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -SandboxDir $sandboxDir | ConvertFrom-Json -Depth 30
    $ids = @($listOutput.integrations | ForEach-Object { [string]$_.id })
    foreach ($expected in @('cursor', 'codex', 'claude', 'opencode')) {
        Assert-True -Condition ($ids -contains $expected) -Message "1. Registry must list $expected."
    }

    # === 2. Adapter definition schema ===
    $definition = & (Join-Path $sourceRoot 'integrations\providers\cursor.ps1')
    foreach ($key in @('Id', 'Name', 'DisplayName', 'ArtifactKind', 'HookSchema', 'ConfigRoots', 'ConfigFileName', 'HandlerStyle', 'StopStyle', 'SessionIdFields', 'CwdFields', 'Capabilities', 'Events')) {
        $hasKey = ($definition -is [Collections.IDictionary]) -and $definition.Contains($key)
        Assert-True -Condition $hasKey -Message "2. cursor definition must declare $key."
    }
    Assert-True -Condition ([string]$definition.Id -eq 'cursor') -Message '2. Id must be cursor.'
    Assert-True -Condition ([string]$definition.DisplayName -eq 'Cursor') -Message '2. DisplayName must be Cursor.'
    Assert-True -Condition ([string]$definition.HookSchema -eq 'CursorFlat') -Message '2. HookSchema must be CursorFlat.'
    Assert-True -Condition ((@($definition.Events) | ForEach-Object { [string]$_.EventName }) -join ',' -eq 'sessionStart,postToolUse,stop,sessionEnd') -Message '2. Events must be the documented Cursor lifecycle set.'

    # === 3. enable / disable ===
    Assert-True -Condition ([bool](Invoke-CursorSetup -Action Disable).enabled -eq $false) -Message '3. Disable cursor must report enabled=false.'
    Assert-True -Condition ([bool](Invoke-CursorSetup -Action Enable).enabled -eq $true) -Message '3. Enable cursor must report enabled=true.'

    # === 4. Install product conforms to the documented Cursor format ===
    $thirdPartyConfig = [ordered]@{
        version = 1
        hooks = [ordered]@{
            beforeShellExecution = @(@{ command = 'third-party-audit'; timeout = 10 })
            stop = @(@{ command = 'third-party-stop'; timeout = 5 })
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($cursorHooksPath, ($thirdPartyConfig + "`n"), [Text.UTF8Encoding]::new($false))
    $thirdPartyHashCheck = (Get-FileHash -LiteralPath $cursorHooksPath -Algorithm SHA256).Hash
    $install = Invoke-CursorSetup -Action Install
    Assert-True -Condition ([bool]$install.integrations.cursor.changed) -Message '4. First Install must report changed=true.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $cursorHooksPath -Algorithm SHA256).Hash -ne $thirdPartyHashCheck) -Message '4. Install must add BRAIN entries.'
    $installed = Get-Content -LiteralPath $cursorHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-True -Condition ([int]$installed['version'] -eq 1) -Message '4. Cursor config must carry version 1.'
    foreach ($eventName in @('sessionStart', 'postToolUse', 'stop', 'sessionEnd')) {
        Assert-True -Condition ($installed['hooks'].Contains($eventName)) -Message "4. hooks.json must contain $eventName."
    }
    $allowedKeys = @('command', 'timeout', 'matcher', 'loop_limit')
    foreach ($eventName in @($installed['hooks'].Keys)) {
        foreach ($entry in @($installed['hooks'][$eventName])) {
            Assert-True -Condition ($entry -is [Collections.IDictionary]) -Message "4. Every hook entry must be an object ($eventName)."
            foreach ($key in @($entry.Keys)) {
                Assert-True -Condition ($allowedKeys -contains [string]$key) -Message "4. Only documented Cursor keys allowed, found: $key."
            }
            if ([string]$entry['command'] -match 'brain-hook\.ps1') {
                Assert-True -Condition ([string]$entry['command'] -match '-Provider Cursor') -Message '4. BRAIN command must target the Cursor provider.'
            }
        }
    }
    $brainStops = @(@($installed['hooks']['stop']) | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_.command -match 'brain-hook\.ps1' })
    Assert-True -Condition ($brainStops.Count -eq 1) -Message '4. Exactly one BRAIN stop entry must exist.'
    Assert-True -Condition ([int]$brainStops[0]['timeout'] -eq 30) -Message '4. stop timeout must be 30.'
    $thirdPartySurvived = $false
    foreach ($entry in @($installed['hooks']['stop'])) {
        if ($entry -is [Collections.IDictionary] -and [string]$entry['command'] -eq 'third-party-stop') { $thirdPartySurvived = $true }
    }
    Assert-True -Condition $thirdPartySurvived -Message '4. Third-party stop entry must survive Install.'
    $shellSurvived = $false
    foreach ($entry in @($installed['hooks']['beforeShellExecution'])) {
        if ($entry -is [Collections.IDictionary] -and [string]$entry['command'] -eq 'third-party-audit') { $shellSurvived = $true }
    }
    Assert-True -Condition $shellSurvived -Message '4. Unrelated hook categories must survive Install.'
    $sessionEntry = @(@($installed['hooks']['sessionStart']) | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_.command -match 'brain-hook\.ps1' })[0]
    Assert-True -Condition ($null -ne $sessionEntry -and [int]$sessionEntry['timeout'] -eq 15) -Message '4. sessionStart entry must exist with timeout 15.'

    # === 5/6. Update + Repair idempotency ===
    $hashAfterInstall = (Get-FileHash -LiteralPath $cursorHooksPath -Algorithm SHA256).Hash
    $backupCount = @(Get-ChildItem -LiteralPath $sandboxDir -File | Where-Object Name -Like '*.brain-backup-*').Count
    for ($i = 0; $i -lt 2; $i++) {
        $update = Invoke-CursorSetup -Action Update
        Assert-True -Condition (-not [bool]$update.integrations.cursor.changed) -Message "5. Repeated Update run $i must report changed=false."
    }
    Assert-True -Condition ((Get-FileHash -LiteralPath $cursorHooksPath -Algorithm SHA256).Hash -eq $hashAfterInstall) -Message '5. Idempotent Update must preserve bytes.'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $sandboxDir -File | Where-Object Name -Like '*.brain-backup-*').Count -eq $backupCount) -Message '5. Idempotent Update must not create backups.'
    $repair = Invoke-CursorSetup -Action Repair
    Assert-True -Condition (@($repair.findings) -notcontains 'missing-hook:cursor:stop') -Message '6. Repair must not report missing hooks after Install.'
    [IO.File]::WriteAllText($cursorHooksPath, "{`n  `"version`": 1,`n  `"hooks`": {}`n}`n", [Text.UTF8Encoding]::new($false))
    $repairPruned = Invoke-CursorSetup -Action Repair
    Assert-True -Condition ([bool]$repairPruned.integrations.cursor.changed) -Message '6. Repair must restore pruned BRAIN entries.'
    $restored = Get-Content -LiteralPath $cursorHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-True -Condition ($restored['hooks'].Contains('stop')) -Message '6. Repaired config must contain stop again.'

    # === 7/8. Uninstall removes only BRAIN entries ===
    $foreignConfig = [ordered]@{
        version = 1
        hooks = [ordered]@{
            stop = @(
                @{ command = 'third-party-stop'; timeout = 5 },
                @{ command = 'pwsh -File C:\x\brain-hook.ps1 -Provider Cursor'; timeout = 30 }
            )
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($cursorHooksPath, ($foreignConfig + "`n"), [Text.UTF8Encoding]::new($false))
    $uninstall = Invoke-CursorSetup -Action Uninstall
    Assert-True -Condition ([bool]$uninstall.user_data_preserved) -Message '7. Uninstall must preserve user data.'
    $afterUninstall = Get-Content -LiteralPath $cursorHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $remaining = @($afterUninstall['hooks']['stop'])
    Assert-True -Condition ($remaining.Count -eq 1 -and [string]$remaining[0]['command'] -eq 'third-party-stop') -Message '7/8. Only the third-party entry must remain.'
    $null = Invoke-CursorSetup -Action Install

    # === 9/10. conflict + malformed safety ===
    $malformedPath = Join-Path $sandboxDir 'malformed.hooks.json'
    [IO.File]::WriteAllText($malformedPath, "{not-json", [Text.UTF8Encoding]::new($false))
    $malformedHash = (Get-FileHash -LiteralPath $malformedPath -Algorithm SHA256).Hash
    $installThrew = $false
    try {
        $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -ConfigPath $malformedPath -Integration cursor | ConvertFrom-Json -Depth 30
    }
    catch {
        $installThrew = $true
    }
    Assert-True -Condition $installThrew -Message '9. Install on malformed JSON must throw instead of corrupting.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $malformedPath -Algorithm SHA256).Hash -eq $malformedHash) -Message '9. Malformed file bytes must be untouched.'
    $repairMalformed = & $setupScript -Action Repair -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -ConfigPath $malformedPath -Integration cursor | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([bool]$repairMalformed.integrations.cursor.skipped -eq $true) -Message '10. Repair must skip malformed JSON safely.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $malformedPath -Algorithm SHA256).Hash -eq $malformedHash) -Message '10. Repair must not touch malformed bytes.'
    $unknownFailed = $false
    try {
        $null = Invoke-CursorSetup -Action Enable -Integration 'cursor-future-xyz'
    }
    catch {
        $unknownFailed = ([string]$_.Exception.Message -match 'Unknown integration')
    }
    Assert-True -Condition $unknownFailed -Message '9. Unknown integration must fail with a clear error.'

    # === 11. Project A/B isolation with documented Cursor payloads ===
    $startA = Invoke-CursorBridge -Payload @{
        hook_event_name = 'sessionStart'
        session_id = 'cursor-session-001'
        workspace_roots = @($projectA)
        cursor_version = '1.7.2'
    }
    $startAJson = if ([string]::IsNullOrWhiteSpace($startA)) { $null } else { $startA | ConvertFrom-Json -Depth 30 }
    $startAText = if ($null -eq $startAJson) { '' } else { [string](Get-OptionalProp -Object $startAJson -Name 'additional_context') }
    Assert-True -Condition ($startAText -match 'Alpha Cursor seed marker') -Message '11. Project A must inject project A records.'
    Assert-True -Condition ($startAText -notmatch 'Beta Cursor seed marker') -Message '11. Project A must not leak project B records.'
    Assert-True -Condition ($startAText -match 'not instructions') -Message '11. Injected context must stay explicitly non-authoritative.'
    Assert-True -Condition (($null -eq $startAJson) -or ($null -eq (Get-OptionalProp -Object $startAJson -Name 'hookSpecificOutput'))) -Message '11. Cursor output must be native (no Claude envelope).'
    $startAlias = Invoke-CursorBridge -Payload @{
        hook_event_name = 'sessionStart'
        conversation_id = 'cursor-session-alias'
        cwd = $projectB
    } -Provider 'cursor'
    Assert-True -Condition ((Get-NativeContext -JsonText $startAlias) -match 'Beta Cursor seed marker') -Message '11. conversation_id/cwd aliases and lowercase provider must resolve.'
    $startB = Invoke-CursorBridge -Payload @{
        hook_event_name = 'sessionStart'
        session_id = 'cursor-session-001'
        workspace_roots = @($projectB)
    }
    Assert-True -Condition ((Get-NativeContext -JsonText $startB) -match 'Beta Cursor seed marker') -Message '11. Project B must inject project B records.'
    Assert-True -Condition ((Get-NativeContext -JsonText $startB) -notmatch 'Alpha Cursor seed marker') -Message '11. Project B must not leak project A records.'
    $postTool = Invoke-CursorBridge -Payload @{
        hook_event_name = 'postToolUse'
        conversation_id = 'cursor-session-001'
        tool_name = 'Write'
        tool_input = @{ path = 'a.txt' }
        cwd = $projectA
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($postTool)) -Message '11. postToolUse must only mark dirty state.'
    $stopA = Invoke-CursorBridge -Payload @{
        hook_event_name = 'stop'
        conversation_id = 'cursor-session-001'
        workspace_roots = @($projectA)
        status = 'completed'
        loop_count = 0
    }
    $stopJson = $stopA | ConvertFrom-Json -Depth 30
    $followup = [string](Get-OptionalProp -Object $stopJson -Name 'followup_message')
    Assert-True -Condition ($followup -match 'BRAIN work record') -Message '11. stop must return a native followup_message record request.'
    Assert-True -Condition ($null -eq (Get-OptionalProp -Object $stopJson -Name 'decision')) -Message '11. Cursor stop must not use decision:block.'
    $stateFile = @(Get-ChildItem -LiteralPath $stateRoot -File -Filter '*.json') | Select-Object -First 1
    Assert-True -Condition ($null -ne $stateFile) -Message '11. Cursor state file must exist.'
    $state = Get-Content -LiteralPath $stateFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    [IO.File]::WriteAllText([string]$state.expected_record_path, (New-RecordText -ProjectId 'cursor-a' -TaskId ([string]$state.task_id) -Summary 'Recorded via Cursor stop followup.'), [Text.UTF8Encoding]::new($false))
    $stopSynced = Invoke-CursorBridge -Payload @{
        hook_event_name = 'stop'
        conversation_id = 'cursor-session-001'
        workspace_roots = @($projectA)
        status = 'completed'
        loop_count = 1
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($stopSynced)) -Message '11. stop after the record exists must sync silently.'
    $rawCount = @(Get-ChildItem -LiteralPath (Join-Path $testBrainRoot 'store\raw\cursor-a') -File -Filter '*.md').Count
    Assert-True -Condition ($rawCount -eq 2) -Message '11. Synced record must land in project A raw store.'
    $sessionEnd = Invoke-CursorBridge -Payload @{
        hook_event_name = 'sessionEnd'
        session_id = 'cursor-session-001'
        workspace_roots = @($projectA)
        reason = 'completed'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($sessionEnd)) -Message '11. sessionEnd must be a silent no-output hook.'
    $unknownEvent = Invoke-CursorBridge -Payload @{
        hook_event_name = 'workspaceHover'
        session_id = 'cursor-session-001'
        cwd = $projectA
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($unknownEvent)) -Message '11. Unknown Cursor events must be a fail-open no-op.'

    # === 12/13. Other providers untouched; disable isolation ===
    $cxPath = Join-Path $testRoot 'cx.json'
    $clPath = Join-Path $testRoot 'cl.json'
    $ocPath = Join-Path $testRoot 'oc-plugin.js'
    [IO.File]::WriteAllText($cxPath, "{}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($clPath, "{}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($ocPath, "// managed by BRAIN (brain.opencode.plugin)`n", [Text.UTF8Encoding]::new($false))
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration codex | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration claude | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -PluginPath $ocPath -Integration opencode | ConvertFrom-Json -Depth 30
    $cxHash = (Get-FileHash -LiteralPath $cxPath -Algorithm SHA256).Hash
    $clHash = (Get-FileHash -LiteralPath $clPath -Algorithm SHA256).Hash
    $ocHash = (Get-FileHash -LiteralPath $ocPath -Algorithm SHA256).Hash
    $null = Invoke-CursorSetup -Action Install
    $null = Invoke-CursorSetup -Action Update
    Assert-True -Condition ((Get-FileHash -LiteralPath $cxPath -Algorithm SHA256).Hash -eq $cxHash) -Message '12. Cursor lifecycle must not rewrite Codex config.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $clPath -Algorithm SHA256).Hash -eq $clHash) -Message '12. Cursor lifecycle must not rewrite Claude config.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $ocPath -Algorithm SHA256).Hash -eq $ocHash) -Message '12. Cursor lifecycle must not rewrite the OpenCode plugin.'
    $null = Invoke-CursorSetup -Action Disable
    $codexWhileDisabled = & $setupScript -Action Update -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration codex | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($null -eq (Get-OptionalProp -Object $codexWhileDisabled.codex -Name 'skipped')) -Message '13. Disabling cursor must not disable Codex.'
    $cursorHashBefore = (Get-FileHash -LiteralPath $cursorHooksPath -Algorithm SHA256).Hash
    $unfiltered = & $setupScript -Action Update -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -PluginPath $ocPath | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([bool]$unfiltered.integrations.cursor.skipped -eq $true) -Message '13. Unfiltered Update must skip disabled cursor.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $cursorHooksPath -Algorithm SHA256).Hash -eq $cursorHashBefore) -Message '13. Disabled cursor hooks must not be rewritten.'
    $null = Invoke-CursorSetup -Action Enable

    # === 14. Capability honesty ===
    $caps = (& (Join-Path $sourceRoot 'integrations\providers\cursor.ps1')).Capabilities
    Assert-True -Condition ([string]$caps.Stop -match 'followup') -Message '14. Stop capability must name the followup mechanism.'
    Assert-True -Condition ([bool]$caps.AutoSync -eq $true) -Message '14. AutoSync must be true (verified by the stop-sync flow above).'
    Assert-True -Condition ([string]$caps.ContextInjection -match 'additional_context') -Message '14. ContextInjection must name the real channel.'

    # === 16. ConfigRoot determinism (generic mechanism, synthetic roots) ===
    . (Join-Path $sourceRoot 'lib\brain-integrations.ps1')
    $rootA = Join-Path $testRoot 'roots\a'
    $rootB = Join-Path $testRoot 'roots\b'
    New-Item -ItemType Directory -Path $rootA, $rootB -Force | Out-Null
    $synthetic = @{ Id = 'probe'; ConfigRoots = @((Join-Path $testRoot 'roots\missing'), $rootB, $rootA) }
    Assert-True -Condition ((Resolve-BrainIntegrationRoot -Definition $synthetic) -eq $rootB) -Message '16. First existing root must win regardless of order.'
    $syntheticNone = @{ Id = 'probe'; ConfigRoots = @((Join-Path $testRoot 'roots\missing1'), (Join-Path $testRoot 'roots\missing2')) }
    Assert-True -Condition ((Resolve-BrainIntegrationRoot -Definition $syntheticNone) -eq (Join-Path $testRoot 'roots\missing1')) -Message '16. With no existing root, the first candidate must be the install target.'
    $statusOut = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration cursor | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($null -ne (Get-OptionalProp -Object $statusOut.integrations.cursor -Name 'selection_reason')) -Message '16. Status must expose the root selection reason.'
    $statusAgain = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration cursor | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([string]$statusOut.integrations.cursor.selected_root -eq [string]$statusAgain.integrations.cursor.selected_root) -Message '16. Root selection must be deterministic.'

    # === 15. Real user data untouched ===
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash -eq $realProjectsHash) -Message '15. Real config/projects.json must be untouched.'
    if ($null -eq $realCursorHooksBefore) {
        Assert-True -Condition (-not (Test-Path -LiteralPath $realCursorHooks)) -Message '15. No hooks.json may be created in the real Cursor config.'
    }
    else {
        Assert-True -Condition ((Get-FileHash -LiteralPath $realCursorHooks -Algorithm SHA256).Hash -eq $realCursorHooksBefore) -Message '15. Real Cursor hooks.json must be untouched.'
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'config\integrations.json'))) -Message '15. No integrations.json may be created in the real BRAIN root.'

    [pscustomobject][ordered]@{
        result = 'PASS'
        registry_lists_cursor = $true
        adapter_schema_ok = $true
        enable_disable_ok = $true
        install_conforms_to_spec = $true
        update_repair_idempotent = $true
        uninstall_only_managed = $true
        third_party_preserved = $true
        conflict_malformed_safe = $true
        project_isolation_ok = $true
        providers_untouched = $true
        disable_isolation_ok = $true
        capability_honest = $true
        configroot_deterministic = $true
        real_user_data_untouched = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-cursor-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe cursor test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
