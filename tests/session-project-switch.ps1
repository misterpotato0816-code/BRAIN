[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

# Regression test for the B3 fix: a Claude/Codex session that moves between
# two registered projects (same session_id) must never have one project's
# dirty state / work-record request synced into the other project's store.

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-switch-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$projectA = Join-Path $testRoot 'ProjectA'
$projectB = Join-Path $testRoot 'ProjectB'
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
        [Parameter(Mandatory = $true)][hashtable]$InputObject
    )

    $json = ConvertTo-Json -InputObject $InputObject -Depth 30 -Compress
    $output = $json | & $pwshPath -NoProfile -NonInteractive -File (Join-Path $testBrainRoot 'integrations\brain-hook.ps1') -Provider Claude -BrainRoot $testBrainRoot -StateRoot $stateRoot 2>&1
    $exitCode = $LASTEXITCODE
    Assert-True -Condition ($exitCode -eq 0) -Message 'Hook must always fail open with exit code 0.'
    return (@($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
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

- [Observed] Exercised the session/project-switch regression path.

# Successes

- [Verified] The record only ever lands under its own project.

# Failures

- [Observed] No failure was observed in this bounded path.

# Bugs

- [Suspected] No bug is currently suspected from this bounded path.

# Fixes

- [Verified] No fix was required for this record.

# Evidence

- [Verified] store/raw for the other project stayed empty throughout.

# Next-Time Notes

- [Observed] Keep session state scoped per project.
"@
}

function Get-StateFileFor {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$ProjectId
    )

    foreach ($file in @(Get-ChildItem -LiteralPath $stateRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $state = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        }
        catch {
            continue
        }
        if ([string]$state.session_id -eq $SessionId -and [string]$state.project_id -eq $ProjectId) {
            return $file
        }
    }
    return $null
}

try {
    New-Item -ItemType Directory -Path $testBrainRoot, $projectA, $projectB, $stateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'), (Join-Path $testBrainRoot 'templates'), (Join-Path $testBrainRoot 'store\raw'), (Join-Path $testBrainRoot 'integrations') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination (Join-Path $testBrainRoot 'brain.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Destination (Join-Path $testBrainRoot 'templates\work-record.md')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'integrations\brain-hook.ps1') -Destination (Join-Path $testBrainRoot 'integrations\brain-hook.ps1')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))

    $brainScript = Join-Path $testBrainRoot 'brain.ps1'
    & $brainScript register -ProjectPath $projectA -ProjectId 'project-a' | Out-Null
    & $brainScript init -ProjectPath $projectA | Out-Null
    & $brainScript register -ProjectPath $projectB -ProjectId 'project-b' | Out-Null
    & $brainScript init -ProjectPath $projectB | Out-Null

    $rawA = Join-Path $testBrainRoot 'store\raw\project-a'
    $rawB = Join-Path $testBrainRoot 'store\raw\project-b'
    $outboxA = Join-Path $projectA '.brain\outbox'
    $outboxB = Join-Path $projectB '.brain\outbox'

    $session = 'switch-session-001'

    # 1. SessionStart in ProjectA.
    $null = Invoke-Hook -InputObject @{
        session_id = $session
        cwd = $projectA
        hook_event_name = 'SessionStart'
        source = 'startup'
    }

    # 2. PostToolUse in ProjectA marks it dirty.
    $null = Invoke-Hook -InputObject @{
        session_id = $session
        turn_id = 'turn-a-1'
        cwd = $projectA
        hook_event_name = 'PostToolUse'
        tool_name = 'Edit'
        tool_input = @{ file_path = (Join-Path $projectA 'file.txt') }
    }
    $stateFileA = Get-StateFileFor -SessionId $session -ProjectId 'project-a'
    Assert-True -Condition ($null -ne $stateFileA) -Message '2. ProjectA session state must exist after PostToolUse.'
    $stateA = Get-Content -LiteralPath $stateFileA.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    Assert-True -Condition ([bool]$stateA.dirty) -Message '2. ProjectA state must be dirty after PostToolUse.'

    # 3. Stop with cwd = ProjectB: the user moved to another project.
    $stopB = Invoke-Hook -InputObject @{
        session_id = $session
        turn_id = 'turn-b-1'
        cwd = $projectB
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Switched project.'
    }
    if (-not [string]::IsNullOrWhiteSpace($stopB)) {
        $stopBJson = $stopB | ConvertFrom-Json -Depth 30
        $stopBText = [string]$stopBJson.hookSpecificOutput.additionalContext
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($stopBText) -and $stopBText -notmatch [regex]::Escape($projectA)) -Message '3. Any Stop output for ProjectB must not reference ProjectA''s path.'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($stopB)) -Message '3. Stop on a clean ProjectB state must stay silent (no cross-project continuation).'
    $stateFileAAfter = Get-StateFileFor -SessionId $session -ProjectId 'project-a'
    Assert-True -Condition ($null -ne $stateFileAAfter) -Message '3. ProjectA dirty state must still exist after a Stop targeting ProjectB.'
    $stateAAfter = Get-Content -LiteralPath $stateFileAAfter.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    Assert-True -Condition ([bool]$stateAAfter.dirty) -Message '3. ProjectA state must remain dirty; it must not have been consumed on ProjectB''s behalf.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $rawB) -or (@(Get-ChildItem -LiteralPath $rawB -File -Filter '*.md' -ErrorAction SilentlyContinue).Count -eq 0)) -Message '3. ProjectB store/raw must receive nothing from ProjectA''s dirty state.'

    # 4. Stop with cwd = ProjectA first requests a work record (this sets
    # expected_record_path in ProjectA's own state); write the record there,
    # then Stop again so it syncs.
    $requestStopA = Invoke-Hook -InputObject @{
        session_id = $session
        turn_id = 'turn-a-2'
        cwd = $projectA
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Requesting a record.'
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($requestStopA)) -Message '4. Stop in ProjectA must request a work record.'
    $stateFileAForRecord = Get-StateFileFor -SessionId $session -ProjectId 'project-a'
    $stateAForRecord = Get-Content -LiteralPath $stateFileAForRecord.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    $recordPathA = [string]$stateAForRecord.expected_record_path
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($recordPathA)) -Message '4. ProjectA state must carry an expected record path.'
    New-Item -ItemType Directory -Path $outboxA -Force -ErrorAction SilentlyContinue | Out-Null
    [IO.File]::WriteAllText($recordPathA, (New-RecordText -ProjectId 'project-a' -TaskId ([string]$stateAForRecord.task_id) -Summary 'ProjectA work recorded.'), [Text.UTF8Encoding]::new($false))

    $stopA = Invoke-Hook -InputObject @{
        session_id = $session
        turn_id = 'turn-a-1'
        cwd = $projectA
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Record written.'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($stopA)) -Message '4. Stop in ProjectA with a valid pending record must sync silently.'
    $rawFilesA = @(Get-ChildItem -LiteralPath $rawA -File -Filter '*.md' -ErrorAction SilentlyContinue)
    Assert-True -Condition ($rawFilesA.Count -eq 1) -Message '4. Exactly one raw record must appear under store/raw/project-a.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $rawB) -or (@(Get-ChildItem -LiteralPath $rawB -File -Filter '*.md' -ErrorAction SilentlyContinue).Count -eq 0)) -Message '4. Nothing must appear under store/raw/project-b.'

    # 5. SessionEnd with cwd = ProjectB.
    $endB = Invoke-Hook -InputObject @{
        session_id = $session
        cwd = $projectB
        hook_event_name = 'SessionEnd'
        reason = 'other'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($endB)) -Message '5. SessionEnd in ProjectB must emit nothing.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $rawB) -or (@(Get-ChildItem -LiteralPath $rawB -File -Filter '*.md' -ErrorAction SilentlyContinue).Count -eq 0)) -Message '5. No ProjectA record must be written into ProjectB''s store during SessionEnd.'

    # 6. Final cross-contamination assertions.
    $rawBCount = if (Test-Path -LiteralPath $rawB) { @(Get-ChildItem -LiteralPath $rawB -File -Filter '*.md' -ErrorAction SilentlyContinue).Count } else { 0 }
    Assert-True -Condition ($rawBCount -eq 0) -Message '6. store/raw/project-b must contain zero files.'
    $outboxBCount = if (Test-Path -LiteralPath $outboxB) { @(Get-ChildItem -LiteralPath $outboxB -File -Filter '*.md' -ErrorAction SilentlyContinue).Count } else { 0 }
    Assert-True -Condition ($outboxBCount -eq 0) -Message '6. ProjectB .brain/outbox must contain zero .md files.'

    $contextA = Get-Content -LiteralPath (Join-Path $projectA '.brain\context.md') -Raw -Encoding UTF8
    Assert-True -Condition ($contextA -match 'ProjectA work recorded') -Message '6. ProjectA context.md must contain ProjectA''s record.'
    $contextBPath = Join-Path $projectB '.brain\context.md'
    if (Test-Path -LiteralPath $contextBPath -PathType Leaf) {
        $contextB = Get-Content -LiteralPath $contextBPath -Raw -Encoding UTF8
        Assert-True -Condition ($contextB -notmatch 'ProjectA work recorded') -Message '6. ProjectB context.md must never contain ProjectA''s record.'
    }
    Assert-True -Condition ($contextA -notmatch 'project-b') -Message '6. ProjectA context.md must not reference ProjectB.'

    # Direct guard test: hand-craft a state file whose project_id is
    # ProjectA's id, but stored at the state path that (Claude, session,
    # ProjectB) would use, then fire a Stop with cwd=ProjectB.
    $guardSession = 'switch-session-guard'
    $hashBytes = [Text.Encoding]::UTF8.GetBytes('claude|' + $guardSession + '|project-b')
    $sessionKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($hashBytes)).ToLowerInvariant()
    $guardStatePath = Join-Path $stateRoot ($sessionKey + '.json')
    $guardState = [ordered]@{
        provider = 'Claude'
        session_id = $guardSession
        project_id = 'project-a'
        project_path = $projectA
        dirty = $true
        request_count = 0
        expected_record_path = ''
        task_id = ''
        updated_at = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($guardStatePath, ($guardState + "`n"), [Text.UTF8Encoding]::new($false))

    $logCountBefore = 0
    $logPath = Join-Path $stateRoot 'brain-hook.log'
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $logCountBefore = @(Select-String -LiteralPath $logPath -Pattern 'project mismatch' -SimpleMatch).Count
    }

    $guardOutput = Invoke-Hook -InputObject @{
        session_id = $guardSession
        cwd = $projectB
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Guard test.'
    }
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($guardOutput)) -Message 'Guard: mismatched-project Stop must emit nothing.'
    $logCountAfter = 0
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $logCountAfter = @(Select-String -LiteralPath $logPath -Pattern 'project mismatch' -SimpleMatch).Count
    }
    Assert-True -Condition ($logCountAfter -gt $logCountBefore) -Message 'Guard: a project mismatch line must be logged.'

    [pscustomobject]@{
        result = 'PASS'
        project_a_dirty_preserved_across_switch = $true
        project_b_received_nothing = $true
        project_a_synced_correctly = $true
        no_cross_contamination = $true
        guard_mismatch_detected = $true
    } | ConvertTo-Json -Depth 6
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-switch-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe session-project-switch test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
