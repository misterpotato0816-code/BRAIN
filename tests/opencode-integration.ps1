[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-opencode-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$projectA = Join-Path $testRoot 'ProjectA'
$projectB = Join-Path $testRoot 'ProjectB'
$stateRoot = Join-Path $testRoot 'state'
$fakeHome = Join-Path $testRoot 'fakehome'
$fakeConfigDir = Join-Path $fakeHome '.config\opencode'
$fakePluginDir = Join-Path $fakeConfigDir 'plugins'
$pluginPath = Join-Path $fakePluginDir 'brain.js'
$setupScript = Join-Path $sourceRoot 'integrations\brain-setup.ps1'
$hookScript = Join-Path $sourceRoot 'integrations\brain-hook.ps1'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$realProjectsHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash
$realPluginPath = Join-Path $env:USERPROFILE '.config\opencode\plugins\brain.js'
# Live installs are legitimate: pin the pre-test state (absent or hash) and
# require it unchanged at the end instead of asserting absence.
$realPluginBefore = if (Test-Path -LiteralPath $realPluginPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $realPluginPath -Algorithm SHA256).Hash
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

function Get-OptionalResultProperty {
    param([Parameter(Mandatory = $true)][object]$Object, [Parameter(Mandatory = $true)][string]$Name)

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-OpenCodeSetup {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Integration = 'opencode'
    )

    $output = & $setupScript -Action $Action -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -SandboxDir $fakePluginDir -Integration $Integration
    return ($output | ConvertFrom-Json -Depth 30)
}

function Invoke-Bridge {
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Cwd
    )

    $json = ConvertTo-Json -InputObject @{ hook_event_name = $EventName; session_id = $SessionId; cwd = $Cwd } -Depth 10 -Compress
    $output = $json | & $pwshPath -NoProfile -NonInteractive -File $hookScript -Provider opencode -BrainRoot $testBrainRoot -StateRoot $stateRoot 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "opencode bridge ($EventName) must fail open with exit 0."
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

- [Observed] Exercised the OpenCode bridge path.

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
    New-Item -ItemType Directory -Path $testBrainRoot, $projectA, $projectB, $stateRoot, $fakePluginDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'), (Join-Path $testBrainRoot 'templates'), (Join-Path $testBrainRoot 'store\raw'), (Join-Path $testBrainRoot 'integrations') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination (Join-Path $testBrainRoot 'brain.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Destination (Join-Path $testBrainRoot 'templates\work-record.md')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))
    $trustedConfig = [ordered]@{ format_version = '0.1'; trusted_roots = @() } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\trusted-roots.json'), ($trustedConfig + "`n"), [Text.UTF8Encoding]::new($false))

    # Fake OpenCode global home: user config + a third-party plugin sibling.
    $fakeUserConfig = "{`n  `"`$schema`": `"https://opencode.ai/config.json`",`n  `"model`": `"third-party-model`"`n}`n"
    [IO.File]::WriteAllText((Join-Path $fakeConfigDir 'opencode.jsonc'), $fakeUserConfig, [Text.UTF8Encoding]::new($false))
    $thirdPartyPlugin = "// third-party plugin`nexport const ThirdParty = async () => ({})`n"
    [IO.File]::WriteAllText((Join-Path $fakePluginDir 'third-party.js'), $thirdPartyPlugin, [Text.UTF8Encoding]::new($false))
    $thirdPartyHash = (Get-FileHash -LiteralPath (Join-Path $fakePluginDir 'third-party.js') -Algorithm SHA256).Hash
    $fakeConfigHash = (Get-FileHash -LiteralPath (Join-Path $fakeConfigDir 'opencode.jsonc') -Algorithm SHA256).Hash

    $brainScript = Join-Path $testBrainRoot 'brain.ps1'
    & $brainScript register -ProjectPath $projectA -ProjectId 'opencode-a' | Out-Null
    & $brainScript init -ProjectPath $projectA | Out-Null
    & $brainScript register -ProjectPath $projectB -ProjectId 'opencode-b' | Out-Null
    & $brainScript init -ProjectPath $projectB | Out-Null
    [IO.File]::WriteAllText((Join-Path $projectA '.brain\outbox\seed-a.md'), (New-RecordText -ProjectId 'opencode-a' -TaskId 'seed-a' -Summary 'Alpha OpenCode seed marker.'), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $projectB '.brain\outbox\seed-b.md'), (New-RecordText -ProjectId 'opencode-b' -TaskId 'seed-b' -Summary 'Beta OpenCode seed marker.'), [Text.UTF8Encoding]::new($false))
    & $brainScript sync -ProjectPath $projectA | Out-Null
    & $brainScript sync -ProjectPath $projectB | Out-Null

    # === 1. Registry lists opencode ===
    $listOutput = & $setupScript -Action Integrations -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -SandboxDir $fakePluginDir | ConvertFrom-Json -Depth 30
    $ids = @($listOutput.integrations | ForEach-Object { [string]$_.id })
    Assert-True -Condition ($ids -contains 'opencode') -Message '1. Registry must list opencode.'
    Assert-True -Condition ($ids -contains 'codex' -and $ids -contains 'claude') -Message '1. Registry must still list codex/claude.'

    # === 2. Adapter definition schema ===
    $definition = & (Join-Path $sourceRoot 'integrations\providers\opencode.ps1')
    foreach ($key in @('Id', 'Name', 'DisplayName', 'ArtifactKind', 'PluginFileName', 'PluginTemplateFile', 'PluginManagedMarker', 'ConfigRoots', 'StopStyle', 'Capabilities', 'Events')) {
        $hasKey = $false
        if ($definition -is [Collections.IDictionary]) { $hasKey = $definition.Contains($key) }
        Assert-True -Condition $hasKey -Message "2. opencode definition must declare $key."
    }
    Assert-True -Condition ([string]$definition.Id -eq 'opencode') -Message '2. Id must be opencode.'
    Assert-True -Condition ([string]$definition.DisplayName -eq 'OpenCode') -Message '2. DisplayName must be OpenCode.'
    Assert-True -Condition ((@($definition.Events) | ForEach-Object { [string]$_.EventName }) -contains 'session.created') -Message '2. Events must include session.created.'
    Assert-True -Condition ([bool]$definition.Capabilities.Install -and [bool]$definition.Capabilities.Repair -and [bool]$definition.Capabilities.Uninstall) -Message '2. Capabilities must cover Install/Repair/Uninstall.'

    # === 3. enable / disable ===
    $disable = Invoke-OpenCodeSetup -Action Disable
    Assert-True -Condition ([bool]$disable.enabled -eq $false) -Message '3. Disable opencode must report enabled=false.'
    $enable = Invoke-OpenCodeSetup -Action Enable
    Assert-True -Condition ([bool]$enable.enabled -eq $true) -Message '3. Enable opencode must report enabled=true.'

    # === 4. Install product conforms to the real OpenCode spec ===
    $install = Invoke-OpenCodeSetup -Action Install
    Assert-True -Condition ([bool]$install.integrations.opencode.changed -or (Test-Path -LiteralPath $pluginPath -PathType Leaf)) -Message '4. Install must produce the bridge plugin file.'
    Assert-True -Condition (Test-Path -LiteralPath $pluginPath -PathType Leaf) -Message '4. Plugin file must live in the global plugins directory.'
    $pluginText = Get-Content -LiteralPath $pluginPath -Raw -Encoding UTF8
    Assert-True -Condition ($pluginText.StartsWith('// managed by BRAIN (brain.opencode.plugin)')) -Message '4. Plugin file must carry the BRAIN managed marker.'
    Assert-True -Condition ($pluginText -notmatch '__BRAIN_(ROOT|HOOK_PATH|PWSH_PATH)__') -Message '4. No template placeholder may survive rendering.'
    Assert-True -Condition ($pluginText -match 'session\.created' -and $pluginText -match 'chat\.message' -and $pluginText -match 'tool\.execute\.after' -and $pluginText -match 'session\.idle' -and $pluginText -match 'session\.deleted') -Message '4. Plugin must subscribe to the documented OpenCode events.'
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $fakeConfigDir 'opencode.jsonc') -Algorithm SHA256).Hash -eq $fakeConfigHash) -Message '4. Install must not touch the user opencode.jsonc (configs are merged by OpenCode).'
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $fakePluginDir 'third-party.js') -Algorithm SHA256).Hash -eq $thirdPartyHash) -Message '4. Install must not touch sibling plugins.'

    # === 5/6. Update + Repair converge without duplication ===
    for ($i = 0; $i -lt 2; $i++) {
        $update = Invoke-OpenCodeSetup -Action Update
        Assert-True -Condition (-not [bool]$update.integrations.opencode.changed) -Message "5. Repeated Update run $i must report changed=false."
    }
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $fakePluginDir -File -Filter 'brain.js').Count -eq 1) -Message '5. Update must not duplicate the plugin file.'
    $repair = Invoke-OpenCodeSetup -Action Repair
    Assert-True -Condition ((@(Get-ChildItem -LiteralPath $fakePluginDir -File -Filter 'brain.js')).Count -eq 1) -Message '6. Repair must not duplicate the plugin file.'
    Assert-True -Condition (@($repair.findings) -notcontains 'missing-plugin:opencode') -Message '6. Repair findings must not report a missing plugin after Install.'

    # Corrupt the plugin file and verify Repair restores exactly one copy.
    [IO.File]::WriteAllText($pluginPath, "// managed by BRAIN (brain.opencode.plugin)`n// corrupted`n", [Text.UTF8Encoding]::new($false))
    $repairAfterCorrupt = Invoke-OpenCodeSetup -Action Repair
    Assert-True -Condition ([bool]$repairAfterCorrupt.integrations.opencode.changed) -Message '6. Repair must restore a corrupted plugin file.'
    Assert-True -Condition ((Get-Content -LiteralPath $pluginPath -Raw -Encoding UTF8) -match 'session\.created') -Message '6. Repaired plugin must be the full bridge again.'

    # Plugin Backup/Restore round-trip (Restore used to reject non-JSON).
    $goodPluginHash = (Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash
    $pluginBackup = Invoke-OpenCodeSetup -Action Backup
    [IO.File]::WriteAllText($pluginPath, "// managed by BRAIN (brain.opencode.plugin)`n// mangled`n", [Text.UTF8Encoding]::new($false))
    $pluginRestore = Invoke-OpenCodeSetup -Action Restore
    Assert-True -Condition ([bool]$pluginRestore.integrations.opencode.restored) -Message '6. Restore must restore the plugin file.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash -eq $goodPluginHash) -Message '6. Restored plugin must match the backup hash.'

    # === 7/8. Uninstall removes only the managed file ===
    $uninstall = Invoke-OpenCodeSetup -Action Uninstall
    Assert-True -Condition (-not (Test-Path -LiteralPath $pluginPath)) -Message '7. Uninstall must delete the managed plugin file.'
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $fakePluginDir 'third-party.js') -Algorithm SHA256).Hash -eq $thirdPartyHash) -Message '8. Uninstall must preserve third-party plugins.'
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $fakeConfigDir 'opencode.jsonc') -Algorithm SHA256).Hash -eq $fakeConfigHash) -Message '8. Uninstall must preserve user config.'
    $null = Invoke-OpenCodeSetup -Action Install

    # === 9. Unknown / malformed / conflict safety ===
    $unknownFailed = $false
    try {
        $null = Invoke-OpenCodeSetup -Action Enable -Integration 'opencode-future-xyz'
    }
    catch {
        $unknownFailed = ([string]$_.Exception.Message -match 'Unknown integration')
    }
    Assert-True -Condition $unknownFailed -Message '9. Unknown integration must fail with a clear error.'
    Remove-Item -LiteralPath $pluginPath -Force
    [IO.File]::WriteAllText($pluginPath, "// someone else's plugin`nexport const Mine = async () => ({})`n", [Text.UTF8Encoding]::new($false))
    $conflict = Invoke-OpenCodeSetup -Action Install
    Assert-True -Condition ([string]$conflict.integrations.opencode.skipped -eq 'True' -and [string]$conflict.integrations.opencode.reason -eq 'conflict') -Message '9. Install must skip (not overwrite) a foreign brain.js.'
    Assert-True -Condition ((Get-Content -LiteralPath $pluginPath -Raw -Encoding UTF8) -match "someone else") -Message '9. Foreign plugin content must survive.'
    $repairConflict = Invoke-OpenCodeSetup -Action Repair
    Assert-True -Condition (@($repairConflict.findings) -contains 'conflict-plugin:opencode') -Message '9. Repair findings must report the conflict.'
    Remove-Item -LiteralPath $pluginPath -Force
    $null = Invoke-OpenCodeSetup -Action Install
    New-Item -ItemType Directory -Path (Join-Path $fakePluginDir 'dir-shield') -Force | Out-Null
    $dirConflict = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath (Join-Path $testRoot 'cx.json') -ClaudeSettingsPath (Join-Path $testRoot 'cl.json') -PluginPath (Join-Path $fakePluginDir 'dir-shield') -Integration opencode | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([string]$dirConflict.integrations.opencode.reason -eq 'conflict') -Message '9. A directory at the target path must be left alone.'
    Remove-Item -LiteralPath (Join-Path $fakePluginDir 'dir-shield') -Force

    # === 10. Project A/B isolation through the real bridge ===
    $startA = Invoke-Bridge -EventName SessionStart -SessionId 'opencode-session-001' -Cwd $projectA
    Assert-True -Condition ($startA -match 'Alpha OpenCode seed marker') -Message '10. Project A bridge must inject project A records.'
    Assert-True -Condition ($startA -notmatch 'Beta OpenCode seed marker') -Message '10. Project A bridge must not leak project B records.'
    $startB = Invoke-Bridge -EventName SessionStart -SessionId 'opencode-session-001' -Cwd $projectB
    Assert-True -Condition ($startB -match 'Beta OpenCode seed marker') -Message '10. Project B bridge must inject project B records.'
    Assert-True -Condition ($startB -notmatch 'Alpha OpenCode seed marker') -Message '10. Project B bridge must not leak project A records.'
    $null = Invoke-Bridge -EventName PostToolUse -SessionId 'opencode-session-001' -Cwd $projectA
    $stopA = Invoke-Bridge -EventName Stop -SessionId 'opencode-session-001' -Cwd $projectA
    $stopJson = $stopA | ConvertFrom-Json -Depth 30
    $stopText = ''
    $specificProp = $stopJson.PSObject.Properties['hookSpecificOutput']
    if ($null -ne $specificProp -and $null -ne $specificProp.Value.PSObject.Properties['additionalContext']) {
        $stopText = [string]$specificProp.Value.additionalContext
    }
    Assert-True -Condition ($stopText -match 'BRAIN work record') -Message '10. Stop bridge must return a HookSpecific record request the plugin can parse.'

    # === 11/12. Claude/Codex untouched by the opencode addition ===
    $cxPath = Join-Path $testRoot 'cx.json'
    $clPath = Join-Path $testRoot 'cl.json'
    [IO.File]::WriteAllText($cxPath, "{}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($clPath, "{}`n", [Text.UTF8Encoding]::new($false))
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $fakePluginDir -Integration codex | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $fakePluginDir -Integration claude | ConvertFrom-Json -Depth 30
    $cxHash = (Get-FileHash -LiteralPath $cxPath -Algorithm SHA256).Hash
    $clHash = (Get-FileHash -LiteralPath $clPath -Algorithm SHA256).Hash
    $null = Invoke-OpenCodeSetup -Action Install
    $null = Invoke-OpenCodeSetup -Action Update
    Assert-True -Condition ((Get-FileHash -LiteralPath $cxPath -Algorithm SHA256).Hash -eq $cxHash) -Message '11. OpenCode lifecycle must not rewrite Codex config.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $clPath -Algorithm SHA256).Hash -eq $clHash) -Message '11. OpenCode lifecycle must not rewrite Claude config.'
    $null = Invoke-OpenCodeSetup -Action Disable
    $disabledUpdate = & $setupScript -Action Update -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $fakePluginDir -Integration codex | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($null -eq (Get-OptionalResultProperty -Object $disabledUpdate.codex -Name 'skipped')) -Message '12. Disabling opencode must not disable Codex.'
    $pluginHashBefore = (Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash
    $unfiltered = & $setupScript -Action Update -BrainRoot $testBrainRoot -BrainHookPath $hookScript -CodexHooksPath $cxPath -ClaudeSettingsPath $clPath -SandboxDir $fakePluginDir | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($null -eq (Get-OptionalResultProperty -Object $unfiltered.codex -Name 'skipped') -and $null -eq (Get-OptionalResultProperty -Object $unfiltered.claude -Name 'skipped')) -Message '12. Unfiltered Update must still process Codex/Claude.'
    Assert-True -Condition ([bool]$unfiltered.integrations.opencode.skipped -eq $true) -Message '12. Unfiltered Update must skip disabled opencode.'
    Assert-True -Condition ((Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash -eq $pluginHashBefore) -Message '12. Disabled opencode plugin file must not be rewritten.'
    $null = Invoke-OpenCodeSetup -Action Enable

    # === Node harness: rendered plugin logic with the REAL pwsh bridge ===
    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $nodeCommand) {
        Write-Output 'SKIP: node.exe not available; plugin harness skipped.'
    }
    else {
        $harnessPath = Join-Path $testRoot 'harness.mjs'
        $renderedCopy = Join-Path $testRoot 'brain.plugin.mjs'
        Copy-Item -LiteralPath $pluginPath -Destination $renderedCopy
        $harness = @'
import { BrainPlugin } from "__PLUGIN__";
const projectA = "__PROJA__";
const calls = { prompts: [], toasts: [], logs: [] };
const client = {
  app: { log: async (entry) => { calls.logs.push(entry); } },
  tui: {
    appendPrompt: async (arg) => { calls.prompts.push(arg && arg.body ? arg.body.text : ""); },
    showToast: async (arg) => { calls.toasts.push(arg && arg.body ? arg.body.message : ""); },
  },
};
const plugin = await BrainPlugin({ client, directory: projectA });
const session = "node-harness-001";
// session.created caches context; chat.message appends it exactly once.
await plugin.event({ event: { type: "session.created", properties: { sessionID: session } } });
const out1 = { message: { id: "msg_first" }, parts: [] };
await plugin["chat.message"]({ sessionID: session }, out1);
if (out1.parts.length !== 1 || !String(out1.parts[0].text).includes("Alpha OpenCode seed marker")) {
  console.error("FAIL: first chat.message must carry project A context");
  console.error("DEBUG logs=" + JSON.stringify(calls.logs).slice(0, 1500));
  console.error("DEBUG parts=" + out1.parts.length);
  process.exit(1);
}
const part1 = out1.parts[0];
if (!/^prt_[0-9a-f]{32}$/.test(part1.id) || part1.sessionID !== session || part1.messageID !== out1.message.id || part1.synthetic !== true) {
  throw new Error("Injected context must be a complete synthetic TextPart belonging to this message/session.");
}
const out2 = { message: { id: "msg_second" }, parts: [] };
await plugin["chat.message"]({ sessionID: session }, out2);
if (out2.parts.length !== 0) {
  console.error("FAIL: context must be appended exactly once");
  process.exit(1);
}
// Resumed session (no session.created): lazy start must still inject.
const out3 = { message: { id: "msg_resume" }, parts: [] };
await plugin["chat.message"]({ sessionID: "node-harness-resume" }, out3);
if (out3.parts.length !== 1 || !String(out3.parts[0].text).includes("Alpha OpenCode seed marker")) {
  console.error("FAIL: resumed session must get context via lazy start");
  process.exit(1);
}
const part3 = out3.parts[0];
if (part3.id === part1.id || !/^prt_[0-9a-f]{32}$/.test(part3.id) || part3.sessionID !== "node-harness-resume" || part3.messageID !== out3.message.id) {
  throw new Error("Resumed sessions must receive distinct IDs with the correct message/session ownership.");
}
// Missing message metadata must fail open without consuming the pending context.
const incomplete = { parts: [] };
await plugin["chat.message"]({ sessionID: "node-harness-missing-message" }, incomplete);
if (incomplete.parts.length !== 0) throw new Error("Do not append an invalid TextPart without a message ID.");
const retry = { message: { id: "msg_retry" }, parts: [] };
await plugin["chat.message"]({ sessionID: "node-harness-missing-message" }, retry);
if (retry.parts.length !== 1 || retry.parts[0].messageID !== "msg_retry") {
  throw new Error("A failed append must preserve pending context for the next valid message.");
}
// Dirty work then idle: record request pre-filled, never submitted.
await plugin["tool.execute.after"]({ sessionID: session, tool: "edit", callID: "c1", args: {} });
await plugin.event({ event: { type: "session.idle", properties: { sessionID: session } } });
if (calls.prompts.length !== 1 || !calls.prompts[0].includes("BRAIN work record")) {
  console.error("FAIL: idle must pre-fill the record request, got: " + JSON.stringify(calls.prompts));
  process.exit(1);
}
if (calls.toasts.length !== 1) {
  console.error("FAIL: idle must show exactly one toast");
  process.exit(1);
}
// Second idle with the same pending request: no duplicate pre-fill.
await plugin.event({ event: { type: "session.idle", properties: { sessionID: session } } });
if (calls.prompts.length !== 1) {
  console.error("FAIL: duplicate idle must not re-fill the prompt");
  process.exit(1);
}
// session.deleted cleans up without throwing.
await plugin.event({ event: { type: "session.deleted", properties: { sessionID: session } } });
console.log("HARNESS_PASS");
'@
        $harness = $harness.Replace('__PLUGIN__', 'file:///' + ($renderedCopy -replace '\\', '/'))
        $harness = $harness.Replace('__PROJA__', ($projectA -replace '\\', '/'))
        [IO.File]::WriteAllText($harnessPath, $harness, [Text.UTF8Encoding]::new($false))
        $savedLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = (Join-Path $testRoot 'localappdata')
            $nodeOutput = & $nodeCommand.Source $harnessPath 2>&1
            Assert-True -Condition ($LASTEXITCODE -eq 0) -Message ("Node harness must pass: " + (@($nodeOutput) -join "`n"))
            Assert-True -Condition ((@($nodeOutput) -join "`n") -match 'HARNESS_PASS') -Message 'Node harness must print HARNESS_PASS.'
        }
        finally {
            $env:LOCALAPPDATA = $savedLocalAppData
        }
    }

    # === 13. Real user data untouched ===
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash -eq $realProjectsHash) -Message '13. Real config/projects.json must be untouched.'
    if ($null -eq $realPluginBefore) {
        Assert-True -Condition (-not (Test-Path -LiteralPath $realPluginPath)) -Message '13. No plugin file may be created in the real OpenCode config.'
    }
    else {
        Assert-True -Condition ((Get-FileHash -LiteralPath $realPluginPath -Algorithm SHA256).Hash -eq $realPluginBefore) -Message '13. Real OpenCode plugin file must be untouched.'
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'config\integrations.json'))) -Message '13. No integrations.json may be created in the real BRAIN root.'

    [pscustomobject][ordered]@{
        result = 'PASS'
        registry_lists_opencode = $true
        adapter_schema_ok = $true
        enable_disable_ok = $true
        install_conforms_to_spec = $true
        update_repair_idempotent = $true
        uninstall_only_managed = $true
        third_party_preserved = $true
        conflict_safe = $true
        project_isolation_ok = $true
        codex_claude_untouched = $true
        disable_isolation_ok = $true
        node_harness_ok = ($null -ne $nodeCommand)
        real_user_data_untouched = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-opencode-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe opencode test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
