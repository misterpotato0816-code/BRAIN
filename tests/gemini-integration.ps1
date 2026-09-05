[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-gemini-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$projectA = Join-Path $testRoot 'ProjectA'
$projectB = Join-Path $testRoot 'ProjectB'
$stateRoot = Join-Path $testRoot 'state'
$sandboxDir = Join-Path $testRoot 'sandbox-home'
$geminiHooksPath = Join-Path $sandboxDir 'gemini-cli.hooks.json'
$setupScript = Join-Path $sourceRoot 'integrations\brain-setup.ps1'
$hookScript = Join-Path $sourceRoot 'integrations\brain-hook.ps1'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$realProjectsHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash
$realGeminiDir = Join-Path $env:USERPROFILE '.gemini'

function Get-RealGeminiTraces {
    # Unary comma: callers must receive a real (possibly empty) array, never
    # $null, or Compare-Object binding fails when nothing exists.
    return ,@((Get-ChildItem -LiteralPath $realGeminiDir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'brain*' -or $_.Name -like '*.brain-backup-*' } | ForEach-Object { [string]$_.FullName } | Sort-Object))
}

# Live installs are legitimate: pin pre-test traces and require zero growth.
$realGeminiTracesBefore = Get-RealGeminiTraces

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

    # Pinned to the documented envelope: hookSpecificOutput.additionalContext
    # (repo hooks reference). A flat field would pass vacuously otherwise.
    if ([string]::IsNullOrWhiteSpace($JsonText)) { return '' }
    $parsed = $JsonText | ConvertFrom-Json -Depth 30
    if ($null -eq $parsed) { return '' }
    $specific = Get-OptionalProp -Object $parsed -Name 'hookSpecificOutput'
    if ($null -eq $specific) { return '' }
    return [string](Get-OptionalProp -Object $specific -Name 'additionalContext')
}

function Invoke-GeminiSetup {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Integration = 'gemini-cli'
    )

    $output = & $setupScript -Action $Action -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -SandboxDir $sandboxDir -Integration $Integration
    return ($output | ConvertFrom-Json -Depth 30)
}

function Invoke-GeminiBridge {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Payload,
        [string]$Provider = 'GeminiCli'
    )

    $json = ConvertTo-Json -InputObject $Payload -Depth 20 -Compress
    $output = $json | & $pwshPath -NoProfile -NonInteractive -File $hookScript -Provider $Provider -BrainRoot $testBrainRoot -StateRoot $stateRoot 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'Gemini bridge must fail open with exit code 0.'
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

- [Observed] Exercised the Gemini bridge path.

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
    & $brainScript register -ProjectPath $projectA -ProjectId 'gemini-a' | Out-Null
    & $brainScript init -ProjectPath $projectA | Out-Null
    & $brainScript register -ProjectPath $projectB -ProjectId 'gemini-b' | Out-Null
    & $brainScript init -ProjectPath $projectB | Out-Null
    [IO.File]::WriteAllText((Join-Path $projectA '.brain\outbox\seed-a.md'), (New-RecordText -ProjectId 'gemini-a' -TaskId 'seed-a' -Summary 'Alpha Gemini seed marker.'), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $projectB '.brain\outbox\seed-b.md'), (New-RecordText -ProjectId 'gemini-b' -TaskId 'seed-b' -Summary 'Beta Gemini seed marker.'), [Text.UTF8Encoding]::new($false))
    & $brainScript sync -ProjectPath $projectA | Out-Null
    & $brainScript sync -ProjectPath $projectB | Out-Null

    # === 1. Registry listing (product scope, not brand umbrella) ===
    $listOutput = & $setupScript -Action Integrations -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -SandboxDir $sandboxDir | ConvertFrom-Json -Depth 30
    $ids = @($listOutput.integrations | ForEach-Object { [string]$_.id })
    foreach ($expected in @('gemini-cli', 'copilot', 'codex', 'claude', 'opencode', 'cursor')) {
        Assert-True -Condition ($ids -contains $expected) -Message "1. Registry must list $expected."
    }
    Assert-True -Condition (-not ($ids -contains 'gemini')) -Message '1. No brand-umbrella gemini id may exist.'

    # === 2. Adapter schema ===
    $definition = & (Join-Path $sourceRoot 'integrations\providers\gemini-cli.ps1')
    foreach ($key in @('Id', 'Name', 'DisplayName', 'ArtifactKind', 'HookSchema', 'ConfigRoots', 'ConfigFileName', 'HandlerStyle', 'StopStyle', 'SessionIdFields', 'CwdFields', 'Capabilities', 'Events')) {
        $hasKey = ($definition -is [Collections.IDictionary]) -and $definition.Contains($key)
        Assert-True -Condition $hasKey -Message "2. gemini-cli definition must declare $key."
    }
    Assert-True -Condition ([string]$definition.Id -eq 'gemini-cli') -Message '2. Id must be gemini-cli.'
    Assert-True -Condition ([string]$definition.DisplayName -eq 'Gemini CLI') -Message '2. DisplayName must scope to CLI.'
    Assert-True -Condition ([string]$definition.HookSchema -eq 'ClaudeNested') -Message '2. HookSchema reuses the nested dialect.'
    Assert-True -Condition ((@($definition.Events) | ForEach-Object { [string]$_.EventName }) -join ',' -eq 'SessionStart,AfterTool,AfterAgent,SessionEnd') -Message '2. Events must be the registered lifecycle set.'
    Assert-True -Condition ((@($definition.Events | Where-Object { [string]$_.EventName -eq 'BeforeTool' })).Count -eq 0) -Message '2. BeforeTool must not be registered (deny risk).'
    Assert-True -Condition ((@($definition.Events | Where-Object { [string]$_.EventName -eq 'Stop' })).Count -eq 0) -Message '2. No invented Stop event may be registered.'

    # === 3/4. enable / disable ===
    Assert-True -Condition ([bool](Invoke-GeminiSetup -Action Disable).enabled -eq $false) -Message '3. Disable gemini-cli must report enabled=false.'
    Assert-True -Condition ([bool](Invoke-GeminiSetup -Action Enable).enabled -eq $true) -Message '4. Enable gemini-cli must report enabled=true.'

    # === 5. Install product conforms to the documented CLI format ===
    $thirdPartyConfig = [ordered]@{
        hooks = [ordered]@{
            AfterAgent = @(@{ type = 'command'; command = 'third-party-retry'; timeout = 5000 })
            BeforeTool = @(@{ type = 'command'; command = 'third-party-guard'; timeout = 5000 })
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($geminiHooksPath, ($thirdPartyConfig + "`n"), [Text.UTF8Encoding]::new($false))
    $install = Invoke-GeminiSetup -Action Install
    Assert-True -Condition ([bool]$install.integrations.'gemini-cli'.changed) -Message '5. First Install must report changed=true.'
    $installed = Get-Content -LiteralPath $geminiHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    foreach ($eventName in @('SessionStart', 'AfterTool', 'AfterAgent', 'SessionEnd')) {
        Assert-True -Condition ($installed['hooks'].Contains($eventName)) -Message "5. settings must contain $eventName."
    }
    $allowedKeys = @('type', 'command', 'name', 'timeout', 'matcher')
    $brainEntryCount = 0
    foreach ($eventName in @($installed['hooks'].Keys)) {
        foreach ($entry in @($installed['hooks'][$eventName])) {
            $handlers = @()
            if ($entry -is [Collections.IDictionary] -and $entry.Contains('hooks')) {
                $handlers = @($entry['hooks'])
            }
            elseif ($entry -is [Collections.IDictionary]) {
                $handlers = @($entry)
            }
            foreach ($handler in $handlers) {
                if ($handler -isnot [Collections.IDictionary]) { continue }
                foreach ($key in @($handler.Keys)) {
                    Assert-True -Condition ($allowedKeys -contains [string]$key) -Message "5. Only documented CLI keys allowed, found: $key."
                }
                if ([string]$handler['command'] -match 'brain-hook\.ps1') {
                    $brainEntryCount++
                    Assert-True -Condition ([string]$handler['command'] -match '-Provider GeminiCli') -Message '5. BRAIN command must target the Gemini provider.'
                    Assert-True -Condition ([string]$handler['command'] -match '^&\s"') -Message '5. BRAIN command must use the call-operator form (bare quoted exe dies as a PowerShell expression under the live CLI runner).'
                }
            }
        }
    }
    Assert-True -Condition ($brainEntryCount -eq 4) -Message '5. Exactly four BRAIN entries (one per event) must exist.'
    $brainAgents = @(@($installed['hooks']['AfterAgent']) | ForEach-Object { @($_['hooks']) } | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_.command -match 'brain-hook\.ps1' })
    Assert-True -Condition ($brainAgents.Count -eq 1) -Message '5. Exactly one BRAIN AfterAgent entry must exist.'
    Assert-True -Condition ([int]$brainAgents[0]['timeout'] -eq 30000) -Message '5. AfterAgent timeout must be 30000 ms.'
    Assert-True -Condition ([string]$brainAgents[0]['name'] -eq 'BRAIN Gemini CLI AfterAgent') -Message '5. Entry name must identify the integration.'
    $thirdPartySurvived = $false
    foreach ($entry in @($installed['hooks']['AfterAgent'])) {
        $handlers = @()
        if ($entry -is [Collections.IDictionary] -and $entry.Contains('hooks')) {
            $handlers = @($entry['hooks'])
        }
        elseif ($entry -is [Collections.IDictionary]) {
            $handlers = @($entry)
        }
        foreach ($handler in $handlers) {
            if ($handler -is [Collections.IDictionary] -and [string]$handler['command'] -eq 'third-party-retry') { $thirdPartySurvived = $true }
        }
    }
    Assert-True -Condition $thirdPartySurvived -Message '5/9. Third-party AfterAgent entry must survive Install.'
    Assert-True -Condition ($installed['hooks'].Contains('BeforeTool')) -Message '5/9. Unrelated hook categories must survive Install.'

    # === 6/7. Update + Repair idempotency ===
    $hashAfterInstall = (Get-FileHash -LiteralPath $geminiHooksPath -Algorithm SHA256).Hash
    $backupCount = @(Get-ChildItem -LiteralPath $sandboxDir -File | Where-Object Name -Like '*.brain-backup-*').Count
    for ($i = 0; $i -lt 2; $i++) {
        $update = Invoke-GeminiSetup -Action Update
        Assert-True -Condition (-not [bool]$update.integrations.'gemini-cli'.changed) -Message "6. Repeated Update run $i must report changed=false."
    }
    Assert-True -Condition ((Get-FileHash -LiteralPath $geminiHooksPath -Algorithm SHA256).Hash -eq $hashAfterInstall) -Message '6. Idempotent Update must preserve bytes.'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $sandboxDir -File | Where-Object Name -Like '*.brain-backup-*').Count -eq $backupCount) -Message '6. Idempotent Update must not create backups.'
    [IO.File]::WriteAllText($geminiHooksPath, "{`n  `"hooks`": {}`n}`n", [Text.UTF8Encoding]::new($false))
    $repairPruned = Invoke-GeminiSetup -Action Repair
    Assert-True -Condition ([bool]$repairPruned.integrations.'gemini-cli'.changed) -Message '7. Repair must restore pruned BRAIN entries.'

    # === 8. Uninstall removes only BRAIN entries ===
    $foreignConfig = [ordered]@{
        hooks = [ordered]@{
            AfterAgent = @(
                @{ matcher = 'other-tool'; hooks = @(@{ type = 'command'; command = 'third-party-retry'; timeout = 5000 }) },
                @{ hooks = @(@{ type = 'command'; command = 'pwsh -File C:\x\brain-hook.ps1 -Provider GeminiCli'; timeout = 30000 }) }
            )
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($geminiHooksPath, ($foreignConfig + "`n"), [Text.UTF8Encoding]::new($false))
    $uninstall = Invoke-GeminiSetup -Action Uninstall
    Assert-True -Condition ([bool]$uninstall.user_data_preserved) -Message '8. Uninstall must preserve user data.'
    $afterUninstall = Get-Content -LiteralPath $geminiHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $remainingGroups = @($afterUninstall['hooks']['AfterAgent'])
    Assert-True -Condition ($remainingGroups.Count -eq 1) -Message '8/9. Only the third-party group must remain.'
    Assert-True -Condition ([string](@($remainingGroups[0]['hooks'])[0]['command']) -eq 'third-party-retry') -Message '8/9. Third-party command must survive.'
    $null = Invoke-GeminiSetup -Action Install

    # === 10/11. malformed + conflict + unknown ===
    $malformedPath = Join-Path $sandboxDir 'malformed.hooks.json'
    [IO.File]::WriteAllText($malformedPath, "{not-json", [Text.UTF8Encoding]::new($false))
    $malformedHash = (Get-FileHash -LiteralPath $malformedPath -Algorithm SHA256).Hash
    $installThrew = $false
    try {
        $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -ConfigPath $malformedPath -Integration gemini-cli | ConvertFrom-Json -Depth 30
    }
    catch {
        $installThrew = $true
    }
    Assert-True -Condition $installThrew -Message '10. Install on malformed JSON must throw instead of corrupting.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $malformedPath -Algorithm SHA256).Hash -eq $malformedHash) -Message '10. Malformed file bytes must be untouched.'
    $repairMalformed = & $setupScript -Action Repair -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -ConfigPath $malformedPath -Integration gemini-cli | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([bool]$repairMalformed.integrations.'gemini-cli'.skipped -eq $true) -Message '10. Repair must skip malformed JSON safely.'
    $dirShield = Join-Path $sandboxDir 'dir-shield'
    New-Item -ItemType Directory -Path $dirShield -Force | Out-Null
    $dirConflict = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -ConfigPath $dirShield -Integration gemini-cli | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([string]$dirConflict.integrations.'gemini-cli'.reason -eq 'conflict') -Message '11. A directory at the target path must be left alone.'
    Remove-Item -LiteralPath $dirShield -Force
    $unknownFailed = $false
    try {
        $null = Invoke-GeminiSetup -Action Enable -Integration 'gemini-future-xyz'
    }
    catch {
        $unknownFailed = ([string]$_.Exception.Message -match 'Unknown integration')
    }
    Assert-True -Condition $unknownFailed -Message '11. Unknown integration must fail with a clear error.'

    # === 12. Project A/B isolation with documented CLI payloads ===
    $startA = Invoke-GeminiBridge -Payload @{
        hook_event_name = 'SessionStart'
        session_id = 'gemini-session-001'
        cwd = $projectA
    }
    $startAText = Get-NativeContext -JsonText $startA
    Assert-True -Condition ($startAText -match 'Alpha Gemini seed marker') -Message '12. Project A must inject project A records.'
    Assert-True -Condition ($startAText -notmatch 'Beta Gemini seed marker') -Message '12. Project A must not leak project B records.'
    Assert-True -Condition ($startAText -match 'not instructions') -Message '13. Injected context must stay explicitly non-authoritative.'
    $startAFlat = if ([string]::IsNullOrWhiteSpace($startA)) { $null } else { $startA | ConvertFrom-Json -Depth 30 }
    Assert-True -Condition (($null -eq $startAFlat) -or ($null -eq (Get-OptionalProp -Object $startAFlat -Name 'additionalContext'))) -Message '12. SessionStart must use the envelope shape, not a flat field.'
    $startCamel = Invoke-GeminiBridge -Payload @{
        hook_event_name = 'SessionStart'
        sessionId = 'gemini-session-camel'
        cwd = $projectB
    } -Provider 'geminicli'
    Assert-True -Condition ((Get-NativeContext -JsonText $startCamel) -match 'Beta Gemini seed marker') -Message '12. camelCase sessionId alias and lowercase provider must resolve.'
    $startB = Invoke-GeminiBridge -Payload @{
        hook_event_name = 'SessionStart'
        session_id = 'gemini-session-001'
        cwd = $projectB
    }
    Assert-True -Condition ((Get-NativeContext -JsonText $startB) -match 'Beta Gemini seed marker') -Message '12. Project B must inject project B records.'
    Assert-True -Condition ((Get-NativeContext -JsonText $startB) -notmatch 'Alpha Gemini seed marker') -Message '12. Project B must not leak project A records.'
    $afterTool = Invoke-GeminiBridge -Payload @{
        hook_event_name = 'AfterTool'
        session_id = 'gemini-session-001'
        cwd = $projectA
        tool_name = 'edit'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($afterTool)) -Message '12. AfterTool must only mark dirty state.'
    $afterAgent = Invoke-GeminiBridge -Payload @{
        hook_event_name = 'AfterAgent'
        session_id = 'gemini-session-001'
        cwd = $projectA
        stop_hook_active = $false
    }
    $agentJson = $afterAgent | ConvertFrom-Json -Depth 30
    $decision = [string](Get-OptionalProp -Object $agentJson -Name 'decision')
    $reason = [string](Get-OptionalProp -Object $agentJson -Name 'reason')
    Assert-True -Condition ($decision -eq 'deny' -and $reason -match 'BRAIN work record') -Message '12. AfterAgent must return the native deny-retry record request.'
    Assert-True -Condition ($null -eq (Get-OptionalProp -Object $agentJson -Name 'hookSpecificOutput')) -Message '12. Gemini output must be native (no Claude envelope).'
    Assert-True -Condition ($null -eq (Get-OptionalProp -Object $agentJson -Name 'followup_message')) -Message '12. Gemini output must not use the Cursor shape.'
    $sessionKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('geminicli|gemini-session-001|gemini-a'))).ToLowerInvariant()
    $stateFilePath = Join-Path $stateRoot ($sessionKey + '.json')
    Assert-True -Condition (Test-Path -LiteralPath $stateFilePath -PathType Leaf) -Message '12. Gemini state file must exist.'
    $state = Get-Content -LiteralPath $stateFilePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    [IO.File]::WriteAllText([string]$state.expected_record_path, (New-RecordText -ProjectId 'gemini-a' -TaskId ([string]$state.task_id) -Summary 'Recorded via Gemini AfterAgent.'), [Text.UTF8Encoding]::new($false))
    $agentSynced = Invoke-GeminiBridge -Payload @{
        hook_event_name = 'AfterAgent'
        session_id = 'gemini-session-001'
        cwd = $projectA
        stop_hook_active = $false
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($agentSynced)) -Message '12. AfterAgent after the record exists must sync silently.'
    $rawCount = @(Get-ChildItem -LiteralPath (Join-Path $testBrainRoot 'store\raw\gemini-a') -File -Filter '*.md').Count
    Assert-True -Condition ($rawCount -eq 2) -Message '12. Synced record must land in project A raw store.'
    $sessionEnd = Invoke-GeminiBridge -Payload @{
        hook_event_name = 'SessionEnd'
        session_id = 'gemini-session-001'
        cwd = $projectA
        reason = 'exit'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($sessionEnd)) -Message '12. sessionEnd must be a silent no-output hook.'
    $unknownEvent = Invoke-GeminiBridge -Payload @{
        hook_event_name = 'Stop'
        session_id = 'gemini-session-001'
        cwd = $projectA
    }
    # Clean state here (sessionEnd removed it): any output at all — deny,
    # followup, or envelope — is a mishandling of the unregistered name.
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($unknownEvent)) -Message '22. Unregistered Stop name must stay fully silent on clean state.'

    # === 14. Capability honesty: exact definition values ===
    $geminiDef = & (Join-Path $sourceRoot 'integrations\providers\gemini-cli.ps1')
    $caps = $geminiDef.Capabilities
    Assert-True -Condition ([string]$geminiDef.StopStyle -eq 'GeminiNative') -Message '14. StopStyle must be GeminiNative.'
    Assert-True -Condition ([string]$geminiDef.HandlerStyle -eq 'GeminiCommand') -Message '14. HandlerStyle must be GeminiCommand.'
    Assert-True -Condition ([string]$caps.Stop -eq 'AfterAgent deny-retry') -Message '14. Stop capability must name the exact mechanism.'
    Assert-True -Condition ([bool]$caps.AutoSync -eq $true) -Message '14. AutoSync must be true (verified by the retry-sync flow above).'
    Assert-True -Condition ([string]$caps.ContextInjection -eq 'SessionStart additionalContext') -Message '14. ContextInjection must name the exact channel.'

    # === 15. Other providers untouched ===
    $cxPath = Join-Path $testRoot 'cx.json'
    $clPath = Join-Path $testRoot 'cl.json'
    $ocPath = Join-Path $testRoot 'oc-plugin.js'
    $cuPath = Join-Path $testRoot 'cu-hooks.json'
    $cpPath = Join-Path $testRoot 'cp-hooks.json'
    [IO.File]::WriteAllText($cxPath, "{}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($clPath, "{}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($ocPath, "// managed by BRAIN (brain.opencode.plugin)`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($cuPath, "{`n  `"version`": 1,`n  `"hooks`": {}`n}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($cpPath, "{`n  `"version`": 1,`n  `"hooks`": {}`n}`n", [Text.UTF8Encoding]::new($false))
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration codex | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration claude | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -PluginPath $ocPath -Integration opencode | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -ConfigPath $cuPath -Integration cursor | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -ConfigPath $cpPath -Integration copilot | ConvertFrom-Json -Depth 30
    $hashes = @{}
    foreach ($p in @($cxPath, $clPath, $ocPath, $cuPath, $cpPath)) {
        $hashes[$p] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
    }
    $null = Invoke-GeminiSetup -Action Install
    $null = Invoke-GeminiSetup -Action Update
    Assert-True -Condition ((Get-FileHash -LiteralPath $cxPath -Algorithm SHA256).Hash -eq $hashes[$cxPath]) -Message '15. Gemini lifecycle must not rewrite Codex config.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $clPath -Algorithm SHA256).Hash -eq $hashes[$clPath]) -Message '15. Gemini lifecycle must not rewrite Claude config.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $ocPath -Algorithm SHA256).Hash -eq $hashes[$ocPath]) -Message '15. Gemini lifecycle must not rewrite the OpenCode plugin.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $cuPath -Algorithm SHA256).Hash -eq $hashes[$cuPath]) -Message '15. Gemini lifecycle must not rewrite Cursor hooks.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $cpPath -Algorithm SHA256).Hash -eq $hashes[$cpPath]) -Message '15. Gemini lifecycle must not rewrite Copilot hooks.'

    # === 16. Disable isolation ===
    $null = Invoke-GeminiSetup -Action Disable
    $codexWhileDisabled = & $setupScript -Action Update -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -PluginPath $ocPath -Integration codex | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($null -eq (Get-OptionalProp -Object $codexWhileDisabled.codex -Name 'skipped')) -Message '16. Disabling gemini-cli must not disable Codex.'
    $geminiHashBefore = (Get-FileHash -LiteralPath $geminiHooksPath -Algorithm SHA256).Hash
    $unfiltered = & $setupScript -Action Update -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -PluginPath $ocPath | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([bool]$unfiltered.integrations.'gemini-cli'.skipped -eq $true) -Message '16. Unfiltered Update must skip disabled gemini-cli.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $geminiHooksPath -Algorithm SHA256).Hash -eq $geminiHashBefore) -Message '16. Disabled gemini-cli hooks must not be rewritten.'
    $null = Invoke-GeminiSetup -Action Enable

    # === 17. Sandbox Hard Guard is armed for this suite ===
    Assert-BrainTestSandboxActive
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($env:BRAIN_TEST_SANDBOX)) -Message '17. Sandbox gate must be active.'

    # === 19. ConfigRoot determinism ===
    $statusOut = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration gemini-cli | ConvertFrom-Json -Depth 30
    $geminiStatus = $statusOut.integrations.'gemini-cli'
    Assert-True -Condition ($null -ne (Get-OptionalProp -Object $geminiStatus -Name 'selection_reason')) -Message '19. Status must expose the root selection reason.'
    Assert-True -Condition ((@($geminiStatus.candidate_roots) | ForEach-Object { [string]$_.path }) -join '|' -match [regex]::Escape('.gemini')) -Message '19. Candidates must include the documented user root.'
    Assert-True -Condition ([string]$geminiStatus.selected_root -eq [IO.Path]::GetFullPath($geminiHooksPath)) -Message '19. Selected root must equal the sandbox target.'
    $statusAgain = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $sandboxDir -Integration gemini-cli | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([string]$statusAgain.integrations.'gemini-cli'.selected_root -eq [string]$geminiStatus.selected_root) -Message '19. Root selection must be deterministic.'

    # === 20. Real user data untouched ===
    # NOTE: ~/.gemini itself is pre-existing on this machine (including an
    # Antigravity-owned `brain` directory); the assertion is that BRAIN adds
    # no hook files or backups to it.
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash -eq $realProjectsHash) -Message '20. Real config/projects.json must be untouched.'
    $realGeminiTracesAfter = Get-RealGeminiTraces
    $newGeminiTraces = @(Compare-Object -ReferenceObject $realGeminiTracesBefore -DifferenceObject $realGeminiTracesAfter | Where-Object { $_.SideIndicator -eq '=>' })
    Assert-True -Condition ($newGeminiTraces.Count -eq 0) -Message '20. No new BRAIN artifacts may be added to the real Gemini config during tests.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'config\integrations.json'))) -Message '20. No integrations.json may be created in the real BRAIN root.'

    [pscustomobject][ordered]@{
        result = 'PASS'
        registry_lists_gemini_cli = $true
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
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-gemini-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe gemini test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
