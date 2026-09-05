[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-copilot-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$projectA = Join-Path $testRoot 'ProjectA'
$projectB = Join-Path $testRoot 'ProjectB'
$stateRoot = Join-Path $testRoot 'state'
$sandboxDir = Join-Path $testRoot 'sandbox-home'
$copilotHooksPath = Join-Path $sandboxDir 'copilot.hooks.json'
$setupScript = Join-Path $sourceRoot 'integrations\brain-setup.ps1'
$hookScript = Join-Path $sourceRoot 'integrations\brain-hook.ps1'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$realProjectsHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash
$realCopilotDir = Join-Path $env:USERPROFILE '.copilot'

function Get-RealCopilotTraces {
    # Unary comma: callers must receive a real (possibly empty) array, never
    # $null, or Compare-Object binding fails when nothing exists.
    return ,@((Get-ChildItem -LiteralPath $realCopilotDir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'brain*' -or $_.Name -like '*.brain-backup-*' } | ForEach-Object { [string]$_.FullName } | Sort-Object))
}

# Live installs are legitimate: pin pre-test traces and require zero growth.
$realCopilotTracesBefore = Get-RealCopilotTraces

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
    if ($null -eq $parsed) { return '' }
    return [string](Get-OptionalProp -Object $parsed -Name 'additionalContext')
}

function Invoke-CopilotSetup {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Integration = 'copilot'
    )

    $output = & $setupScript -Action $Action -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -SandboxDir $sandboxDir -Integration $Integration
    return ($output | ConvertFrom-Json -Depth 30)
}

function Invoke-CopilotBridge {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Payload,
        [string]$Provider = 'Copilot'
    )

    $json = ConvertTo-Json -InputObject $Payload -Depth 20 -Compress
    $output = $json | & $pwshPath -NoProfile -NonInteractive -File $hookScript -Provider $Provider -BrainRoot $testBrainRoot -StateRoot $stateRoot 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'Copilot bridge must fail open with exit code 0.'
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

- [Observed] Exercised the Copilot bridge path.

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
    & $brainScript register -ProjectPath $projectA -ProjectId 'copilot-a' | Out-Null
    & $brainScript init -ProjectPath $projectA | Out-Null
    & $brainScript register -ProjectPath $projectB -ProjectId 'copilot-b' | Out-Null
    & $brainScript init -ProjectPath $projectB | Out-Null
    [IO.File]::WriteAllText((Join-Path $projectA '.brain\outbox\seed-a.md'), (New-RecordText -ProjectId 'copilot-a' -TaskId 'seed-a' -Summary 'Alpha Copilot seed marker.'), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $projectB '.brain\outbox\seed-b.md'), (New-RecordText -ProjectId 'copilot-b' -TaskId 'seed-b' -Summary 'Beta Copilot seed marker.'), [Text.UTF8Encoding]::new($false))
    & $brainScript sync -ProjectPath $projectA | Out-Null
    & $brainScript sync -ProjectPath $projectB | Out-Null

    # === 1. Registry listing ===
    $listOutput = & $setupScript -Action Integrations -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -SandboxDir $sandboxDir | ConvertFrom-Json -Depth 30
    $ids = @($listOutput.integrations | ForEach-Object { [string]$_.id })
    foreach ($expected in @('copilot', 'codex', 'claude', 'opencode', 'cursor')) {
        Assert-True -Condition ($ids -contains $expected) -Message "1. Registry must list $expected."
    }

    # === 2. Adapter schema ===
    $definition = & (Join-Path $sourceRoot 'integrations\providers\copilot.ps1')
    foreach ($key in @('Id', 'Name', 'DisplayName', 'ArtifactKind', 'HookSchema', 'ConfigRoots', 'ConfigRootEnv', 'ConfigFileName', 'HandlerStyle', 'StopStyle', 'SessionIdFields', 'CwdFields', 'Capabilities', 'Events')) {
        $hasKey = ($definition -is [Collections.IDictionary]) -and $definition.Contains($key)
        Assert-True -Condition $hasKey -Message "2. copilot definition must declare $key."
    }
    Assert-True -Condition ([string]$definition.Id -eq 'copilot') -Message '2. Id must be copilot.'
    Assert-True -Condition ([string]$definition.DisplayName -eq 'GitHub Copilot (CLI)') -Message '2. DisplayName must scope to CLI.'
    Assert-True -Condition ([string]$definition.HookSchema -eq 'CopilotCli') -Message '2. HookSchema must be CopilotCli.'
    Assert-True -Condition ((@($definition.Events) | ForEach-Object { [string]$_.EventName }) -join ',' -eq 'SessionStart,PostToolUse,Stop,SessionEnd') -Message '2. Events must be the registered lifecycle set.'
    Assert-True -Condition ((@($definition.Events | Where-Object { [string]$_.EventName -eq 'preToolUse' })).Count -eq 0) -Message '2. preToolUse must not be registered (fail-closed risk).'

    # === 3/4. enable / disable ===
    Assert-True -Condition ([bool](Invoke-CopilotSetup -Action Disable).enabled -eq $false) -Message '3. Disable copilot must report enabled=false.'
    Assert-True -Condition ([bool](Invoke-CopilotSetup -Action Enable).enabled -eq $true) -Message '4. Enable copilot must report enabled=true.'

    # === 5. Install product conforms to the documented CLI format ===
    $thirdPartyConfig = [ordered]@{
        version = 1
        hooks = [ordered]@{
            preToolUse = @(@{ type = 'command'; powershell = 'third-party-guard'; timeoutSec = 10 })
            Stop = @(@{ type = 'command'; powershell = 'third-party-stop'; timeoutSec = 5 })
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($copilotHooksPath, ($thirdPartyConfig + "`n"), [Text.UTF8Encoding]::new($false))
    $install = Invoke-CopilotSetup -Action Install
    Assert-True -Condition ([bool]$install.integrations.copilot.changed) -Message '5. First Install must report changed=true.'
    $installed = Get-Content -LiteralPath $copilotHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-True -Condition ([int]$installed['version'] -eq 1) -Message '5. Config must carry version 1.'
    foreach ($eventName in @('SessionStart', 'PostToolUse', 'Stop', 'SessionEnd')) {
        Assert-True -Condition ($installed['hooks'].Contains($eventName)) -Message "5. hooks.json must contain $eventName."
    }
    $allowedKeys = @('type', 'powershell', 'timeoutSec', 'matcher')
    foreach ($eventName in @($installed['hooks'].Keys)) {
        foreach ($entry in @($installed['hooks'][$eventName])) {
            Assert-True -Condition ($entry -is [Collections.IDictionary]) -Message "5. Every hook entry must be an object ($eventName)."
            foreach ($key in @($entry.Keys)) {
                Assert-True -Condition ($allowedKeys -contains [string]$key) -Message "5. Only documented CLI keys allowed, found: $key."
            }
            if ([string]$entry['powershell'] -match 'brain-hook\.ps1') {
                Assert-True -Condition ([string]$entry['powershell'] -match '-Provider Copilot') -Message '5. BRAIN command must target the Copilot provider.'
            }
        }
    }
    $brainStops = @(@($installed['hooks']['Stop']) | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_.powershell -match 'brain-hook\.ps1' })
    Assert-True -Condition ($brainStops.Count -eq 1) -Message '5. Exactly one BRAIN Stop entry must exist.'
    Assert-True -Condition ([int]$brainStops[0]['timeoutSec'] -eq 30) -Message '5. Stop timeoutSec must be 30.'
    $brainPosts = @(@($installed['hooks']['PostToolUse']) | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_.powershell -match 'brain-hook\.ps1' })
    Assert-True -Condition ([string]$brainPosts[0]['matcher'] -eq 'create|edit') -Message '5. PostToolUse matcher must be create|edit.'
    $thirdPartySurvived = $false
    foreach ($entry in @($installed['hooks']['Stop'])) {
        if ($entry -is [Collections.IDictionary] -and [string]$entry['powershell'] -eq 'third-party-stop') { $thirdPartySurvived = $true }
    }
    Assert-True -Condition $thirdPartySurvived -Message '5/9. Third-party Stop entry must survive Install.'
    Assert-True -Condition ($installed['hooks'].Contains('preToolUse')) -Message '5/9. Unrelated hook categories must survive Install.'

    # === 6/7. Update + Repair idempotency ===
    $hashAfterInstall = (Get-FileHash -LiteralPath $copilotHooksPath -Algorithm SHA256).Hash
    $backupCount = @(Get-ChildItem -LiteralPath $sandboxDir -File | Where-Object Name -Like '*.brain-backup-*').Count
    for ($i = 0; $i -lt 2; $i++) {
        $update = Invoke-CopilotSetup -Action Update
        Assert-True -Condition (-not [bool]$update.integrations.copilot.changed) -Message "6. Repeated Update run $i must report changed=false."
    }
    Assert-True -Condition ((Get-FileHash -LiteralPath $copilotHooksPath -Algorithm SHA256).Hash -eq $hashAfterInstall) -Message '6. Idempotent Update must preserve bytes.'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $sandboxDir -File | Where-Object Name -Like '*.brain-backup-*').Count -eq $backupCount) -Message '6. Idempotent Update must not create backups.'
    [IO.File]::WriteAllText($copilotHooksPath, "{`n  `"version`": 1,`n  `"hooks`": {}`n}`n", [Text.UTF8Encoding]::new($false))
    $repairPruned = Invoke-CopilotSetup -Action Repair
    Assert-True -Condition ([bool]$repairPruned.integrations.copilot.changed) -Message '7. Repair must restore pruned BRAIN entries.'

    # === 8. Uninstall removes only BRAIN entries ===
    $foreignConfig = [ordered]@{
        version = 1
        hooks = [ordered]@{
            Stop = @(
                @{ type = 'command'; powershell = 'third-party-stop'; timeoutSec = 5 },
                @{ type = 'command'; powershell = 'pwsh -File C:\x\brain-hook.ps1 -Provider Copilot'; timeoutSec = 30 }
            )
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($copilotHooksPath, ($foreignConfig + "`n"), [Text.UTF8Encoding]::new($false))
    $uninstall = Invoke-CopilotSetup -Action Uninstall
    Assert-True -Condition ([bool]$uninstall.user_data_preserved) -Message '8. Uninstall must preserve user data.'
    $afterUninstall = Get-Content -LiteralPath $copilotHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $remaining = @($afterUninstall['hooks']['Stop'])
    Assert-True -Condition ($remaining.Count -eq 1 -and [string]$remaining[0]['powershell'] -eq 'third-party-stop') -Message '8/9. Only the third-party entry must remain.'
    $null = Invoke-CopilotSetup -Action Install

    # === 10/11. malformed + conflict + unknown ===
    $malformedPath = Join-Path $sandboxDir 'malformed.hooks.json'
    [IO.File]::WriteAllText($malformedPath, "{not-json", [Text.UTF8Encoding]::new($false))
    $malformedHash = (Get-FileHash -LiteralPath $malformedPath -Algorithm SHA256).Hash
    $installThrew = $false
    try {
        $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -ConfigPath $malformedPath -Integration copilot | ConvertFrom-Json -Depth 30
    }
    catch {
        $installThrew = $true
    }
    Assert-True -Condition $installThrew -Message '10. Install on malformed JSON must throw instead of corrupting.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $malformedPath -Algorithm SHA256).Hash -eq $malformedHash) -Message '10. Malformed file bytes must be untouched.'
    $repairMalformed = & $setupScript -Action Repair -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -ConfigPath $malformedPath -Integration copilot | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([bool]$repairMalformed.integrations.copilot.skipped -eq $true) -Message '10. Repair must skip malformed JSON safely.'
    $dirShield = Join-Path $sandboxDir 'dir-shield'
    New-Item -ItemType Directory -Path $dirShield -Force | Out-Null
    $dirConflict = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -ConfigPath $dirShield -Integration copilot | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([string]$dirConflict.integrations.copilot.reason -eq 'conflict') -Message '11. A directory at the target path must be left alone.'
    Remove-Item -LiteralPath $dirShield -Force
    $unknownFailed = $false
    try {
        $null = Invoke-CopilotSetup -Action Enable -Integration 'copilot-future-xyz'
    }
    catch {
        $unknownFailed = ([string]$_.Exception.Message -match 'Unknown integration')
    }
    Assert-True -Condition $unknownFailed -Message '11. Unknown integration must fail with a clear error.'

    # === 12. Project A/B isolation with documented CLI payloads ===
    $startA = Invoke-CopilotBridge -Payload @{
        hook_event_name = 'SessionStart'
        session_id = 'copilot-session-001'
        cwd = $projectA
    }
    $startAText = Get-NativeContext -JsonText $startA
    Assert-True -Condition ($startAText -match 'Alpha Copilot seed marker') -Message '12. Project A must inject project A records.'
    Assert-True -Condition ($startAText -notmatch 'Beta Copilot seed marker') -Message '12. Project A must not leak project B records.'
    Assert-True -Condition ($startAText -match 'not instructions') -Message '13. Injected context must stay explicitly non-authoritative.'
    $startCamel = Invoke-CopilotBridge -Payload @{
        hook_event_name = 'SessionStart'
        sessionId = 'copilot-session-camel'
        cwd = $projectB
    } -Provider 'copilot'
    Assert-True -Condition ((Get-NativeContext -JsonText $startCamel) -match 'Beta Copilot seed marker') -Message '12. camelCase sessionId alias and lowercase provider must resolve.'
    $startB = Invoke-CopilotBridge -Payload @{
        hook_event_name = 'SessionStart'
        session_id = 'copilot-session-001'
        cwd = $projectB
    }
    Assert-True -Condition ((Get-NativeContext -JsonText $startB) -match 'Beta Copilot seed marker') -Message '12. Project B must inject project B records.'
    Assert-True -Condition ((Get-NativeContext -JsonText $startB) -notmatch 'Alpha Copilot seed marker') -Message '12. Project B must not leak project A records.'
    $postTool = Invoke-CopilotBridge -Payload @{
        hook_event_name = 'PostToolUse'
        session_id = 'copilot-session-001'
        cwd = $projectA
        tool_name = 'edit'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($postTool)) -Message '12. postToolUse must only mark dirty state.'
    $stopA = Invoke-CopilotBridge -Payload @{
        hook_event_name = 'Stop'
        session_id = 'copilot-session-001'
        cwd = $projectA
        stop_hook_active = $false
    }
    $stopJson = $stopA | ConvertFrom-Json -Depth 30
    $decision = [string](Get-OptionalProp -Object $stopJson -Name 'decision')
    $reason = [string](Get-OptionalProp -Object $stopJson -Name 'reason')
    Assert-True -Condition ($decision -eq 'block' -and $reason -match 'BRAIN work record') -Message '12. Stop must return the native decision-block record request.'
    Assert-True -Condition ($null -eq (Get-OptionalProp -Object $stopJson -Name 'hookSpecificOutput')) -Message '12. Copilot output must be native (no Claude envelope).'
    Assert-True -Condition ($null -eq (Get-OptionalProp -Object $stopJson -Name 'followup_message')) -Message '12. Copilot output must not use the Cursor shape.'
    $sessionKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('copilot|copilot-session-001|copilot-a'))).ToLowerInvariant()
    $stateFilePath = Join-Path $stateRoot ($sessionKey + '.json')
    Assert-True -Condition (Test-Path -LiteralPath $stateFilePath -PathType Leaf) -Message '12. Copilot state file must exist.'
    $state = Get-Content -LiteralPath $stateFilePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    [IO.File]::WriteAllText([string]$state.expected_record_path, (New-RecordText -ProjectId 'copilot-a' -TaskId ([string]$state.task_id) -Summary 'Recorded via Copilot agentStop.'), [Text.UTF8Encoding]::new($false))
    $stopSynced = Invoke-CopilotBridge -Payload @{
        hook_event_name = 'Stop'
        session_id = 'copilot-session-001'
        cwd = $projectA
        stop_hook_active = $false
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($stopSynced)) -Message '12. Stop after the record exists must sync silently.'
    $rawCount = @(Get-ChildItem -LiteralPath (Join-Path $testBrainRoot 'store\raw\copilot-a') -File -Filter '*.md').Count
    Assert-True -Condition ($rawCount -eq 2) -Message '12. Synced record must land in project A raw store.'
    $sessionEnd = Invoke-CopilotBridge -Payload @{
        hook_event_name = 'SessionEnd'
        session_id = 'copilot-session-001'
        cwd = $projectA
        reason = 'complete'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($sessionEnd)) -Message '12. sessionEnd must be a silent no-output hook.'

    # === 14. Capability honesty: exact definition values, not substrings ===
    $copilotDef = & (Join-Path $sourceRoot 'integrations\providers\copilot.ps1')
    $caps = $copilotDef.Capabilities
    Assert-True -Condition ([string]$copilotDef.StopStyle -eq 'CopilotNative') -Message '14. StopStyle must be CopilotNative.'
    Assert-True -Condition ([string]$copilotDef.HandlerStyle -eq 'CopilotCommand') -Message '14. HandlerStyle must be CopilotCommand.'
    Assert-True -Condition ([string]$caps.Stop -eq 'agentStop decision-block (Stop entry)') -Message '14. Stop capability must name the exact mechanism.'
    Assert-True -Condition ([bool]$caps.AutoSync -eq $true) -Message '14. AutoSync must be true (verified by the stop-sync flow above).'
    Assert-True -Condition ([string]$caps.ContextInjection -eq 'sessionStart additionalContext') -Message '14. ContextInjection must name the exact channel.'

    # === 15-18. Other providers untouched ===
    $cxPath = Join-Path $testRoot 'cx.json'
    $clPath = Join-Path $testRoot 'cl.json'
    $ocPath = Join-Path $testRoot 'oc-plugin.js'
    $cuPath = Join-Path $testRoot 'cu-hooks.json'
    [IO.File]::WriteAllText($cxPath, "{}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($clPath, "{}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($ocPath, "// managed by BRAIN (brain.opencode.plugin)`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($cuPath, "{`n  `"version`": 1,`n  `"hooks`": {}`n}`n", [Text.UTF8Encoding]::new($false))
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration codex | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration claude | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -PluginPath $ocPath -Integration opencode | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -ConfigPath $cuPath -Integration cursor | ConvertFrom-Json -Depth 30
    $hashes = @{}
    foreach ($p in @($cxPath, $clPath, $ocPath, $cuPath)) {
        $hashes[$p] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
    }
    $null = Invoke-CopilotSetup -Action Install
    $null = Invoke-CopilotSetup -Action Update
    Assert-True -Condition ((Get-FileHash -LiteralPath $cxPath -Algorithm SHA256).Hash -eq $hashes[$cxPath]) -Message '15. Copilot lifecycle must not rewrite Codex config.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $clPath -Algorithm SHA256).Hash -eq $hashes[$clPath]) -Message '16. Copilot lifecycle must not rewrite Claude config.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $ocPath -Algorithm SHA256).Hash -eq $hashes[$ocPath]) -Message '17. Copilot lifecycle must not rewrite the OpenCode plugin.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $cuPath -Algorithm SHA256).Hash -eq $hashes[$cuPath]) -Message '18. Copilot lifecycle must not rewrite Cursor hooks.'

    # === 19. Disable isolation ===
    $null = Invoke-CopilotSetup -Action Disable
    $codexWhileDisabled = & $setupScript -Action Update -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -PluginPath $ocPath -Integration codex | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($null -eq (Get-OptionalProp -Object $codexWhileDisabled.codex -Name 'skipped')) -Message '19. Disabling copilot must not disable Codex.'
    $copilotHashBefore = (Get-FileHash -LiteralPath $copilotHooksPath -Algorithm SHA256).Hash
    $unfiltered = & $setupScript -Action Update -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -PluginPath $ocPath | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([bool]$unfiltered.integrations.copilot.skipped -eq $true) -Message '19. Unfiltered Update must skip disabled copilot.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $copilotHooksPath -Algorithm SHA256).Hash -eq $copilotHashBefore) -Message '19. Disabled copilot hooks must not be rewritten.'
    $null = Invoke-CopilotSetup -Action Enable

    # === 20. Sandbox Hard Guard is armed for this suite ===
    Assert-BrainTestSandboxActive
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($env:BRAIN_TEST_SANDBOX)) -Message '20. Sandbox gate must be active.'

    # === 21/22. Canary handled by run-all; ConfigRoot determinism here ===
    $statusOut = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration copilot | ConvertFrom-Json -Depth 30
    $cursor = $statusOut.integrations.copilot
    Assert-True -Condition ($null -ne (Get-OptionalProp -Object $cursor -Name 'selection_reason')) -Message '22. Status must expose the root selection reason.'
    Assert-True -Condition ((@($cursor.candidate_roots) | ForEach-Object { [string]$_.path }) -join '|' -match [regex]::Escape('.copilot')) -Message '22. Candidates must include the documented user root.'
    Assert-True -Condition ([string]$cursor.selected_root -eq [IO.Path]::GetFullPath($copilotHooksPath)) -Message '22. Selected root must equal the sandbox target (positive check, not just determinism).'
    $statusAgain = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration copilot | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([string]$statusAgain.integrations.copilot.selected_root -eq [string]$cursor.selected_root) -Message '22. Root selection must be deterministic.'
    # COPILOT_HOME override (read-only Status, gate lifted temporarily).
    # Exact full-path match: a doubled hooks segment (hooks\hooks\brain.json)
    # must fail here, not slip through a StartsWith check.
    $savedGate = $env:BRAIN_TEST_SANDBOX
    $fakeCopilotHome = Join-Path $testRoot 'copilot-home'
    New-Item -ItemType Directory -Path $fakeCopilotHome -Force | Out-Null
    try {
        $env:BRAIN_TEST_SANDBOX = ''
        $env:COPILOT_HOME = $fakeCopilotHome
        $envStatus = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -Integration copilot | ConvertFrom-Json -Depth 30
        $envSelected = [string]$envStatus.integrations.copilot.selected_root
        $envExpected = [IO.Path]::GetFullPath((Join-Path (Join-Path $fakeCopilotHome 'hooks') 'brain.json'))
        Assert-True -Condition ($envSelected -eq $envExpected) -Message '22. COPILOT_HOME target must equal <home>\hooks\brain.json exactly.'
        Assert-True -Condition ($envSelected -notmatch 'hooks[\\/]hooks') -Message '22. Doubled hooks segments are rejected.'
        Assert-True -Condition ([string]$envStatus.integrations.copilot.selection_reason -eq 'env-override') -Message '22. Selection reason must report env-override.'
        $env:COPILOT_HOME = $null
        $defaultStatus = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -Integration copilot | ConvertFrom-Json -Depth 30
        $defaultSelected = [string]$defaultStatus.integrations.copilot.selected_root
        $defaultExpected = [IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $env:USERPROFILE '.copilot') 'hooks') 'brain.json'))
        Assert-True -Condition ($defaultSelected -eq $defaultExpected) -Message '22. Default target must equal ~/.copilot/hooks/brain.json exactly.'
        Assert-True -Condition ($defaultSelected -notmatch 'hooks[\\/]hooks') -Message '22. Doubled hooks segments are rejected on the default path.'
    }
    finally {
        $env:BRAIN_TEST_SANDBOX = $savedGate
        $env:COPILOT_HOME = $null
    }

    # === 23. Real user data untouched ===
    # NOTE: ~/.copilot itself is pre-existing on this machine (user's own CLI
    # usage); the assertion is that BRAIN adds nothing to it.
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash -eq $realProjectsHash) -Message '23. Real config/projects.json must be untouched.'
    $realCopilotTracesAfter = Get-RealCopilotTraces
    $newTraces = @(Compare-Object -ReferenceObject $realCopilotTracesBefore -DifferenceObject $realCopilotTracesAfter | Where-Object { $_.SideIndicator -eq '=>' })
    Assert-True -Condition ($newTraces.Count -eq 0) -Message '23. No new BRAIN artifacts may be added to the real Copilot config during tests.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'config\integrations.json'))) -Message '23. No integrations.json may be created in the real BRAIN root.'

    [pscustomobject][ordered]@{
        result = 'PASS'
        registry_lists_copilot = $true
        adapter_schema_ok = $true
        enable_disable_ok = $true
        install_conforms_to_spec = $true
        update_repair_idempotent = $true
        uninstall_only_managed = $true
        third_party_preserved = $true
        conflict_malformed_safe = $true
        project_isolation_ok = $true
        non_authoritative_ok = $true
        capability_honest = $true
        providers_untouched = $true
        disable_isolation_ok = $true
        sandbox_guard_ok = $true
        configroot_deterministic = $true
        real_user_data_untouched = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-copilot-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe copilot test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
