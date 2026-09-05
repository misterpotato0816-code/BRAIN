[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-setup-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$projectRoot = Join-Path $testRoot 'project'
$userConfigRoot = Join-Path $testRoot 'user-config'
$codexHooksPath = Join-Path $userConfigRoot '.codex\hooks.json'
$claudeSettingsPath = Join-Path $userConfigRoot '.claude\settings.json'
# Isolation for file-based integrations (e.g. the OpenCode bridge plugin or
# Cursor hooks): -SandboxDir redirects every non-explicitly-overridden target
# under one temp directory, so unfiltered lifecycle actions can never resolve
# to the real user profile.
$setupScript = Join-Path $sourceRoot 'integrations\brain-setup.ps1'
$brainHookPath = Join-Path $testBrainRoot 'integrations\brain-hook.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-Setup {
    param([Parameter(Mandatory = $true)][string]$Action)

    $output = & $setupScript -Action $Action -BrainRoot $testBrainRoot -BrainHookPath $brainHookPath -CodexHooksPath $codexHooksPath -ClaudeSettingsPath $claudeSettingsPath -SandboxDir $userConfigRoot
    return ($output | ConvertFrom-Json -Depth 30)
}

function Get-Hash {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-ManagedHandlerCount {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$EventName
    )

    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    if (-not $config.Contains('hooks') -or -not $config['hooks'].Contains($EventName)) { return 0 }
    $count = 0
    foreach ($group in @($config['hooks'][$EventName])) {
        if ($group -isnot [Collections.IDictionary] -or -not $group.Contains('hooks')) { continue }
        foreach ($handler in @($group['hooks'])) {
            if ($handler -isnot [Collections.IDictionary]) { continue }
            $isManaged = $false
            if ($handler.Contains('brain_hook_id')) { $isManaged = $true }
            elseif ($handler.Contains('managed_by') -and [string]$handler['managed_by'] -eq 'brain') { $isManaged = $true }
            elseif ($handler.Contains('statusMessage') -and [string]$handler['statusMessage'] -match '^BRAIN(\s+v[0-9][0-9.]*)?\s+(Codex|Claude)\s+\w+$') { $isManaged = $true }
            elseif ($handler.Contains('command') -and $handler['command'] -is [string] -and ([string]$handler['command']).IndexOf('brain-hook.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $isManaged = $true }
            if ($isManaged) { $count++ }
        }
    }
    return $count
}

try {
    New-Item -ItemType Directory -Path $testBrainRoot, $projectRoot, $userConfigRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'), (Join-Path $testBrainRoot 'templates'), (Join-Path $testBrainRoot 'store\raw'), (Join-Path $testBrainRoot 'integrations') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination (Join-Path $testBrainRoot 'brain.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Destination (Join-Path $testBrainRoot 'templates\work-record.md')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'integrations\brain-hook.ps1') -Destination $brainHookPath
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))
    $trustedConfig = [ordered]@{ format_version = '0.1'; trusted_roots = @() } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\trusted-roots.json'), ($trustedConfig + "`n"), [Text.UTF8Encoding]::new($false))

    $brainScript = Join-Path $testBrainRoot 'brain.ps1'
    & $brainScript register -ProjectPath $projectRoot -ProjectId 'setup-project' | Out-Null
    & $brainScript init -ProjectPath $projectRoot | Out-Null

    New-Item -ItemType Directory -Path (Split-Path -Parent $codexHooksPath), (Split-Path -Parent $claudeSettingsPath) -Force | Out-Null
    $existingCodex = [ordered]@{
        description = 'existing-codex-settings'
        hooks = [ordered]@{
            SessionStart = @(@{ matcher = 'startup'; hooks = @(@{ type = 'command'; command = 'existing-codex'; statusMessage = 'existing' }) })
        }
    } | ConvertTo-Json -Depth 20
    $existingClaude = [ordered]@{
        alwaysThinkingEnabled = $true
        hooks = [ordered]@{
            Stop = @(@{ hooks = @(@{ type = 'command'; command = 'existing-claude'; statusMessage = 'existing' }) })
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($codexHooksPath, ($existingCodex + "`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($claudeSettingsPath, ($existingClaude + "`n"), [Text.UTF8Encoding]::new($false))

    # === 1. VERSION ===
    $versionOutput1 = & $brainScript version
    $versionFileText = (Get-Content -LiteralPath (Join-Path $testBrainRoot 'VERSION') -Raw).Trim()
    Assert-True -Condition ($versionOutput1 -match [regex]::Escape($versionFileText)) -Message '1. brain.ps1 version must print the VERSION file contents.'
    $versionOutput2 = & $brainScript -Version
    Assert-True -Condition ($versionOutput2 -match [regex]::Escape($versionFileText)) -Message '1. brain.ps1 -Version must print the VERSION file contents.'

    $projectsFilePath = Join-Path $testBrainRoot 'config\projects.json'
    $projectsBackup = Get-Content -LiteralPath $projectsFilePath -Raw -Encoding UTF8
    Remove-Item -LiteralPath $projectsFilePath -Force
    $versionOutput3 = & $brainScript version
    Assert-True -Condition ($versionOutput3 -match [regex]::Escape($versionFileText)) -Message '1. brain.ps1 version output must still contain the version with no registry present.'
    [IO.File]::WriteAllText($projectsFilePath, $projectsBackup, [Text.UTF8Encoding]::new($false))

    # === 2. Legacy migration ===
    $legacyClaude = [ordered]@{
        alwaysThinkingEnabled = $true
        hooks = [ordered]@{
            Stop = @(
                @{ hooks = @(@{ type = 'command'; command = 'existing-claude'; statusMessage = 'existing' }) },
                @{ hooks = @(@{ type = 'command'; command = 'pwsh'; args = @('-File', 'C:\old\brain-hook.ps1'); statusMessage = 'BRAIN v0.1 Claude Stop' }) }
            )
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($claudeSettingsPath, ($legacyClaude + "`n"), [Text.UTF8Encoding]::new($false))

    $updateResult = Invoke-Setup -Action Update
    Assert-True -Condition ([bool]$updateResult.claude.changed) -Message '2. Update must rewrite the Claude config to replace the legacy handler.'
    $stopCount = Get-ManagedHandlerCount -Path $claudeSettingsPath -Provider 'Claude' -EventName 'Stop'
    Assert-True -Condition ($stopCount -eq 1) -Message '2. Exactly one managed BRAIN handler must remain for Claude Stop after migration.'
    $claudeAfterMigration = Get-Content -LiteralPath $claudeSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $stopGroups = @($claudeAfterMigration['hooks']['Stop'])
    $unrelatedFound = $false
    foreach ($group in $stopGroups) {
        foreach ($handler in @($group['hooks'])) {
            if ($handler -is [Collections.IDictionary] -and [string]$handler['command'] -eq 'existing-claude') { $unrelatedFound = $true }
        }
    }
    Assert-True -Condition $unrelatedFound -Message '2. The unrelated pre-existing Stop handler must survive migration.'

    # === 3. No duplicates across repeated Update runs ===
    $backupCountBefore = @(Get-ChildItem -LiteralPath $userConfigRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object Name -Like '*.brain-backup-*').Count
    for ($i = 0; $i -lt 3; $i++) {
        $rerun = Invoke-Setup -Action Update
        foreach ($provider in @('Codex', 'Claude')) {
            $path = if ($provider -eq 'Codex') { $codexHooksPath } else { $claudeSettingsPath }
            foreach ($eventName in @('SessionStart', 'PostToolUse', 'Stop', 'SessionEnd')) {
                $count = Get-ManagedHandlerCount -Path $path -Provider $provider -EventName $eventName
                Assert-True -Condition ($count -eq 1) -Message "3. $provider $eventName must have exactly one managed handler on repeated Update (run $i)."
            }
        }
        if ($i -ge 1) {
            Assert-True -Condition (-not [bool]$rerun.codex.changed) -Message "3. Repeated Update run $i must report codex changed=false."
            Assert-True -Condition (-not [bool]$rerun.claude.changed) -Message "3. Repeated Update run $i must report claude changed=false."
        }
    }
    $backupCountAfter = @(Get-ChildItem -LiteralPath $userConfigRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object Name -Like '*.brain-backup-*').Count
    Assert-True -Condition ($backupCountAfter -eq $backupCountBefore) -Message '3. Idempotent Update runs must not create additional backups.'

    # === 4. Repair ===
    $claudeConfig = Get-Content -LiteralPath $claudeSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $sessionStartGroups = @($claudeConfig['hooks']['SessionStart'])
    $prunedGroups = @()
    foreach ($group in $sessionStartGroups) {
        $handlers = @($group['hooks']) | Where-Object {
            -not ($_ -is [Collections.IDictionary] -and ($_.Contains('brain_hook_id') -or ($_.Contains('managed_by') -and [string]$_['managed_by'] -eq 'brain')))
        }
        if (@($handlers).Count -gt 0) {
            $group['hooks'] = @($handlers)
            $prunedGroups += $group
        }
    }
    if (@($prunedGroups).Count -gt 0) {
        $claudeConfig['hooks']['SessionStart'] = @($prunedGroups)
    }
    else {
        $claudeConfig['hooks'].Remove('SessionStart')
    }
    $prunedJson = ConvertTo-Json -InputObject $claudeConfig -Depth 100
    [IO.File]::WriteAllText($claudeSettingsPath, ($prunedJson + "`n"), [Text.UTF8Encoding]::new($false))
    Assert-True -Condition ((Get-ManagedHandlerCount -Path $claudeSettingsPath -Provider 'Claude' -EventName 'SessionStart') -eq 0) -Message '4. Setup corruption for Repair test must remove the managed SessionStart handler.'

    $repairResult = Invoke-Setup -Action Repair
    Assert-True -Condition (@($repairResult.findings) -contains 'missing-hook:claude:SessionStart') -Message '4. Repair findings must report the missing Claude SessionStart handler.'
    Assert-True -Condition ((Get-ManagedHandlerCount -Path $claudeSettingsPath -Provider 'Claude' -EventName 'SessionStart') -eq 1) -Message '4. Repair must restore exactly one managed Claude SessionStart handler.'

    # Duplicate-handler repair case.
    $claudeConfigDup = Get-Content -LiteralPath $claudeSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    $existingSessionStartGroup = @($claudeConfigDup['hooks']['SessionStart'])[0]
    $duplicateHandler = @($existingSessionStartGroup['hooks'])[0]
    $existingSessionStartGroup['hooks'] = @($existingSessionStartGroup['hooks']) + @($duplicateHandler)
    $dupJson = ConvertTo-Json -InputObject $claudeConfigDup -Depth 100
    [IO.File]::WriteAllText($claudeSettingsPath, ($dupJson + "`n"), [Text.UTF8Encoding]::new($false))
    Assert-True -Condition ((Get-ManagedHandlerCount -Path $claudeSettingsPath -Provider 'Claude' -EventName 'SessionStart') -eq 2) -Message '4. Setup for duplicate-handler Repair test must produce two managed handlers.'

    $repairResultDup = Invoke-Setup -Action Repair
    Assert-True -Condition (@($repairResultDup.findings) -contains 'duplicate-hook:claude:SessionStart') -Message '4. Repair findings must report the duplicate Claude SessionStart handler.'
    Assert-True -Condition ((Get-ManagedHandlerCount -Path $claudeSettingsPath -Provider 'Claude' -EventName 'SessionStart') -eq 1) -Message '4. Repair must converge duplicate handlers back to exactly one.'

    # === 5. Uninstall safety ===
    $projectsHashBefore = Get-Hash -Path $projectsFilePath
    $rawDirBefore = Join-Path $testBrainRoot 'store\raw'
    $templatesHashBefore = Get-Hash -Path (Join-Path $testBrainRoot 'templates\work-record.md')
    $projectBrainFileBefore = Join-Path $projectRoot '.brain\project.json'
    $projectBrainHashBefore = Get-Hash -Path $projectBrainFileBefore
    $codexDescriptionBefore = (Get-Content -LiteralPath $codexHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50).description
    $claudeAlwaysThinkingBefore = (Get-Content -LiteralPath $claudeSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50).alwaysThinkingEnabled

    $uninstallResult = Invoke-Setup -Action Uninstall
    Assert-True -Condition ([bool]$uninstallResult.user_data_preserved) -Message '5. Uninstall must report user_data_preserved=true.'
    foreach ($provider in @('Codex', 'Claude')) {
        $path = if ($provider -eq 'Codex') { $codexHooksPath } else { $claudeSettingsPath }
        foreach ($eventName in @('SessionStart', 'PostToolUse', 'Stop', 'SessionEnd')) {
            $count = Get-ManagedHandlerCount -Path $path -Provider $provider -EventName $eventName
            Assert-True -Condition ($count -eq 0) -Message "5a. $provider $eventName must have zero managed handlers after Uninstall."
        }
    }
    $codexDescriptionAfter = (Get-Content -LiteralPath $codexHooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50).description
    $claudeAlwaysThinkingAfter = (Get-Content -LiteralPath $claudeSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50).alwaysThinkingEnabled
    Assert-True -Condition ($codexDescriptionAfter -eq $codexDescriptionBefore) -Message '5b. Unrelated Codex top-level key must survive Uninstall.'
    Assert-True -Condition ($claudeAlwaysThinkingAfter -eq $claudeAlwaysThinkingBefore) -Message '5b. Unrelated Claude top-level key must survive Uninstall.'
    $claudeStopHandlersAfter = @((Get-Content -LiteralPath $claudeSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100)['hooks']['Stop'])
    $stillHasExisting = $false
    foreach ($group in $claudeStopHandlersAfter) {
        foreach ($handler in @($group['hooks'])) {
            if ($handler -is [Collections.IDictionary] -and [string]$handler['command'] -eq 'existing-claude') { $stillHasExisting = $true }
        }
    }
    Assert-True -Condition $stillHasExisting -Message '5b. The unrelated Claude Stop hook group must survive Uninstall.'

    Assert-True -Condition ((Get-Hash -Path $projectsFilePath) -eq $projectsHashBefore) -Message '5c. config/projects.json must be untouched by Uninstall.'
    Assert-True -Condition (Test-Path -LiteralPath $rawDirBefore -PathType Container) -Message '5c. store/raw must still exist after Uninstall.'
    Assert-True -Condition ((Get-Hash -Path (Join-Path $testBrainRoot 'templates\work-record.md')) -eq $templatesHashBefore) -Message '5c. templates must be untouched by Uninstall.'
    Assert-True -Condition ((Get-Hash -Path $projectBrainFileBefore) -eq $projectBrainHashBefore) -Message '5c. The registered project''s .brain directory must be untouched by Uninstall.'

    # === 6. Backup / Restore ===
    $claudeHashAtBackup = Get-Hash -Path $claudeSettingsPath
    $backupResult = Invoke-Setup -Action Backup
    Assert-True -Condition (Test-Path -LiteralPath ([string]$backupResult.claude.backup) -PathType Leaf) -Message '6. Backup must create a Claude backup file.'

    $mangled = [ordered]@{ mangled = $true; value = 12345 } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($claudeSettingsPath, ($mangled + "`n"), [Text.UTF8Encoding]::new($false))
    Assert-True -Condition ((Get-Hash -Path $claudeSettingsPath) -ne $claudeHashAtBackup) -Message '6. Mangling the Claude settings file must actually change its hash.'

    $restoreResult = Invoke-Setup -Action Restore
    Assert-True -Condition ([bool]$restoreResult.claude.restored) -Message '6. Restore must report claude.restored=true.'
    Assert-True -Condition ((Get-Hash -Path $claudeSettingsPath) -eq $claudeHashAtBackup) -Message '6. Restored Claude settings must match the SHA-256 at backup time.'

    # '.absent' path.
    $absentConfigPath = Join-Path $userConfigRoot '.claude-absent\settings.json'
    $absentBackupResult = & $setupScript -Action Backup -BrainRoot $testBrainRoot -BrainHookPath $brainHookPath -CodexHooksPath $codexHooksPath -ClaudeSettingsPath $absentConfigPath -SandboxDir $userConfigRoot | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($absentBackupResult.claude.backup -match '\.absent$') -Message '6. Backing up a non-existent Claude settings path must create an .absent marker.'

    $absentInstallResult = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $brainHookPath -CodexHooksPath $codexHooksPath -ClaudeSettingsPath $absentConfigPath -SandboxDir $userConfigRoot | ConvertFrom-Json -Depth 30
    Assert-True -Condition (Test-Path -LiteralPath $absentConfigPath -PathType Leaf) -Message '6. Install must create the previously-absent Claude settings file.'

    $absentRestoreResult = & $setupScript -Action Restore -BrainRoot $testBrainRoot -BrainHookPath $brainHookPath -CodexHooksPath $codexHooksPath -ClaudeSettingsPath $absentConfigPath -SandboxDir $userConfigRoot | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([bool]$absentRestoreResult.claude.restored) -Message '6. Restoring the .absent marker must report restored=true.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $absentConfigPath)) -Message '6. Restoring the .absent marker must delete the live config file again.'

    # === 7. Status ===
    $codexHashBeforeStatus = Get-Hash -Path $codexHooksPath
    $claudeHashBeforeStatus = Get-Hash -Path $claudeSettingsPath
    $statusResult = Invoke-Setup -Action Status
    Assert-True -Condition ((Get-Hash -Path $codexHooksPath) -eq $codexHashBeforeStatus) -Message '7. Status must not modify the Codex config.'
    Assert-True -Condition ((Get-Hash -Path $claudeSettingsPath) -eq $claudeHashBeforeStatus) -Message '7. Status must not modify the Claude config.'
    Assert-True -Condition ($null -ne $statusResult.codex.handler_counts) -Message '7. Status must report Codex managed handler counts.'
    Assert-True -Condition ($null -ne $statusResult.claude.handler_counts) -Message '7. Status must report Claude managed handler counts.'

    [pscustomobject]@{
        result = 'PASS'
        version_command_ok = $true
        legacy_migration_ok = $true
        no_duplicates_across_reruns = $true
        repair_ok = $true
        uninstall_safety_ok = $true
        backup_restore_ok = $true
        absent_marker_ok = $true
        status_readonly_ok = $true
    } | ConvertTo-Json -Depth 6
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-setup-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe setup-lifecycle test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
