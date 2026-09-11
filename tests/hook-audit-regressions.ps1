[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $env:BRAIN_TEST_SANDBOX ('brain-hook-audit-' + [guid]::NewGuid().ToString('N'))
$brainRoot = Join-Path $testRoot 'BRAIN'
$projectRoot = Join-Path $testRoot 'Project One'
$otherProjectRoot = Join-Path $testRoot 'Project Two'
$stateRoot = Join-Path $testRoot 'state'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$utf8 = [Text.UTF8Encoding]::new($false)
$sessionId = 'audit-resume-session'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-Hook {
    param([string]$Event, [string]$Project = $projectRoot, [string]$Turn = 'first', [bool]$Active = $false)

    $payload = @{
        hook_event_name = $Event
        session_id = $sessionId
        cwd = $Project
        turn_id = $Turn
        source = 'resume'
        tool_name = 'Edit'
        stop_hook_active = $Active
    } | ConvertTo-Json -Compress
    $output = $payload | & $pwshPath -NoProfile -NonInteractive -File (Join-Path $brainRoot 'integrations\brain-hook.ps1') -Provider Codex -BrainRoot $brainRoot -StateRoot $stateRoot 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'All lifecycle hooks must fail open.'
    $text = (@($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        # A rejection warning on stdout would corrupt provider JSON.
        $null = $text | ConvertFrom-Json -Depth 30
    }
    return $text
}

function Get-StateFile {
    param([string]$ProjectId = 'hook-audit')

    $matches = @(Get-ChildItem -LiteralPath $stateRoot -Filter '*.json' -File | Where-Object {
        $item = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $item.project_id -eq $ProjectId
    })
    Assert-True ($matches.Count -eq 1) "Exactly one state must remain for $ProjectId."
    return $matches[0].FullName
}

function Read-TestState {
    param([string]$ProjectId = 'hook-audit')
    return Get-Content -LiteralPath (Get-StateFile $ProjectId) -Raw -Encoding UTF8 | ConvertFrom-Json
}

function New-RecordText {
    param([string]$TaskId, [string]$Summary, [string]$ProjectId = 'hook-audit')

    $template = Get-Content -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Raw -Encoding UTF8
    return $template.Replace('replace-with-registered-project-id', $ProjectId).
        Replace('replace-with-local-task-id', $TaskId).
        Replace('Briefly describe the completed task.', $Summary)
}

function Assert-CleanState {
    $state = Read-TestState
    Assert-True (-not $state.dirty) 'Accepted pending work must become clean.'
    Assert-True ($state.request_count -eq 0) 'Accepted pending work must reset the request cap.'
    Assert-True ([string]::IsNullOrEmpty($state.expected_record_path)) 'Accepted pending work must clear its expected path.'
    Assert-True ([string]::IsNullOrEmpty($state.task_id)) 'Accepted pending work must clear its task id.'
}

try {
    New-Item -ItemType Directory -Path $brainRoot, $projectRoot, $otherProjectRoot, $stateRoot -Force | Out-Null
    foreach ($directory in @('config', 'lib', 'templates', 'integrations', 'store\raw')) {
        New-Item -ItemType Directory -Path (Join-Path $brainRoot $directory) -Force | Out-Null
    }
    foreach ($file in @('brain.ps1', 'VERSION', 'lib\brain-common.ps1', 'templates\work-record.md', 'integrations\brain-hook.ps1')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $brainRoot $file)
    }
    [IO.File]::WriteAllText((Join-Path $brainRoot 'config\projects.json'), "[]`n", $utf8)
    $brainScript = Join-Path $brainRoot 'brain.ps1'
    & $brainScript register -ProjectPath $projectRoot -ProjectId 'hook-audit' | Out-Null
    & $brainScript init -ProjectPath $projectRoot | Out-Null
    & $brainScript register -ProjectPath $otherProjectRoot -ProjectId 'hook-audit-other' | Out-Null
    & $brainScript init -ProjectPath $otherProjectRoot | Out-Null

    $null = Invoke-Hook SessionStart
    $null = Invoke-Hook PostToolUse
    $firstRequest = Invoke-Hook Stop | ConvertFrom-Json
    Assert-True ($firstRequest.reason.Contains('Create a short BRAIN work record')) 'Dirty work must request a record.'
    $pending = Read-TestState
    $firstPath = [string]$pending.expected_record_path
    [IO.File]::WriteAllText($firstPath, (New-RecordText $pending.task_id 'First work before interruption.'), $utf8)
    $unrelatedPath = Join-Path $projectRoot '.brain\outbox\000-unrelated-incomplete.md'
    [IO.File]::WriteAllText($unrelatedPath, "---`n", $utf8)

    # The process ended after writing a record but before Stop/SessionEnd.
    $resumed = Invoke-Hook SessionStart | ConvertFrom-Json
    Assert-True ($resumed.hookSpecificOutput.additionalContext.Contains('First work before interruption.')) 'Resume must collect the pending record even with unrelated incomplete outbox files.'
    Assert-CleanState
    Assert-True (Test-Path -LiteralPath $unrelatedPath) 'Unrelated rejected records must remain available for repair.'

    [IO.File]::WriteAllText((Join-Path $projectRoot 'new-work.txt'), 'Second work after resume.', $utf8)
    $null = Invoke-Hook PostToolUse -Turn second
    $secondRequest = Invoke-Hook Stop -Turn second | ConvertFrom-Json
    Assert-True ($secondRequest.reason.Contains('Create a short BRAIN work record')) 'New work after resume must request its own record.'
    $pending = Read-TestState
    Assert-True ($pending.dirty -and $pending.request_count -eq 1) 'The new task must have a fresh request budget.'
    Assert-True ($pending.expected_record_path -ne $firstPath) 'The previous record must not satisfy the new task.'

    # A valid old record plus an invalid expected one must never look complete.
    [IO.File]::WriteAllText($pending.expected_record_path, "---`n", $utf8)
    $repair = Invoke-Hook Stop -Turn second | ConvertFrom-Json
    Assert-True ($repair.reason.Contains('Repair the pending BRAIN work record')) 'Stop must ask to repair the invalid expected record.'
    Assert-True ((Read-TestState).dirty) 'Skipping an invalid expected record must retain dirty state.'
    $null = Invoke-Hook SessionEnd
    Assert-True ((Read-TestState).dirty) 'SessionEnd must retain invalid pending state.'

    $failedResume = Invoke-Hook SessionStart
    Assert-True ([string]::IsNullOrWhiteSpace($failedResume)) 'Failed required-record validation must not inject context.'
    $pending = Read-TestState
    Assert-True ($pending.dirty -and $pending.request_count -eq 2) 'Failed resume must retain pending state and its request count.'

    # Sweeping another project must also require that project's pending record.
    $null = Invoke-Hook SessionStart -Project $otherProjectRoot
    $null = Invoke-Hook SessionEnd -Project $otherProjectRoot
    Assert-True ((Read-TestState).dirty) 'A cross-project SessionEnd sweep must not discard invalid pending work.'

    # Missing expected files must remain pending even when other files are valid.
    Remove-Item -LiteralPath $pending.expected_record_path -Force
    $missingResume = Invoke-Hook SessionStart
    Assert-True ([string]::IsNullOrWhiteSpace($missingResume)) 'A missing required record must not be treated as successful sync.'
    Assert-True ((Read-TestState).dirty) 'Missing required records must preserve dirty state.'

    [IO.File]::WriteAllText($pending.expected_record_path, (New-RecordText $pending.task_id 'Second work repaired after resume.'), $utf8)
    # Already-collected duplicates are valid proof, as with an earlier manual sync.
    & $brainScript sync -ProjectPath $projectRoot 3>$null | Out-Null
    $null = Invoke-Hook SessionStart
    Assert-CleanState

    # An empty outbox does not make pre-upgrade context trustworthy. Seed raw
    # history that the old validator accepted, then ensure it is revalidated.
    Get-ChildItem -LiteralPath (Join-Path $projectRoot '.brain\outbox') -File -Filter '*.md' | Remove-Item -Force
    $contextPath = Join-Path $projectRoot '.brain\context.md'
    $dummyValue = 'DUMMY_OLD_CONTEXT_0123456789'
    $legacyRecord = New-RecordText 'legacy-invalid' ('api_key=' + $dummyValue)
    $legacyPath = Join-Path $brainRoot 'store\raw\hook-audit\legacy-invalid.md'
    [IO.File]::WriteAllText($legacyPath, $legacyRecord, $utf8)
    [IO.File]::WriteAllText($contextPath, ('api_key=' + $dummyValue), $utf8)
    $safeResume = Invoke-Hook SessionStart
    Assert-True (-not $safeResume.Contains($dummyValue)) 'SessionStart must not inject rejected legacy raw history, even with an empty outbox.'
    Assert-True ($safeResume.Contains('Second work repaired after resume.')) 'Legacy rejection must preserve valid historical context.'
    Assert-True (Test-Path -LiteralPath $legacyPath) 'Rejected legacy raw history must remain on disk.'

    # If rebuilding itself fails, fail open without sending pre-existing bytes.
    [IO.File]::WriteAllText($contextPath, $dummyValue, $utf8)
    $originalScript = [IO.File]::ReadAllBytes($brainScript)
    try {
        [IO.File]::WriteAllText($brainScript, "throw 'Simulated unavailable BRAIN store.'", $utf8)
        $unavailableResume = Invoke-Hook SessionStart
        Assert-True ([string]::IsNullOrWhiteSpace($unavailableResume)) 'A failed sync must never fall back to unvalidated existing context.'
    }
    finally {
        [IO.File]::WriteAllBytes($brainScript, $originalScript)
    }

    [pscustomobject][ordered]@{
        result = 'PASS'
        resume_clears_accepted_pending_state = $true
        new_work_gets_new_record = $true
        unrelated_invalid_does_not_block_completion = $true
        invalid_expected_stop_end_resume_sweep_preserved = $true
        missing_expected_preserved = $true
        duplicate_expected_accepted = $true
        legacy_context_revalidated = $true
        failed_sync_does_not_inject_context = $true
        warnings_do_not_corrupt_hook_json = $true
    } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $safePrefix = [IO.Path]::GetFullPath($env:BRAIN_TEST_SANDBOX).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolved.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $resolved) -notmatch '^brain-hook-audit-[0-9a-f]{32}$') {
            throw 'Refusing to clean an unsafe hook audit test path.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
