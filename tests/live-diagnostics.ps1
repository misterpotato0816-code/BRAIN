[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

# Opt-in live diagnostics (BRAIN_LIVE_DIAGNOSTICS=1): lifecycle facts only,
# off by default. This test proves the gate (no file without opt-in) and the
# privacy contract (no prompt/context/code/secret content ever recorded).

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-livediag-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$projectRoot = Join-Path $testRoot 'project'
$stateRoot = Join-Path $testRoot 'state'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$hookPath = Join-Path $sourceRoot 'integrations\brain-hook.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-Bridge {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][hashtable]$Payload
    )

    $json = ConvertTo-Json -InputObject $Payload -Depth 20 -Compress
    $output = $json | & $pwshPath -NoProfile -NonInteractive -File $hookPath -Provider $Provider -BrainRoot $testBrainRoot -StateRoot $stateRoot 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "$Provider bridge must fail open with exit code 0."
    return (@($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function New-RecordText {
    param([Parameter(Mandatory = $true)][string]$TaskId)

    return @"
---
brain_record_version: "0.1"
project_id: "livediag-proj"
task_id: "$TaskId"
completed_at: "2026-08-30T20:00:00.0000000+09:00"
---

# Task Summary

- [Observed] Seeded diagnostics marker DIAG-SEED-UNIQUE-STRING.

# Approach

- [Observed] Exercised the diagnostics path.

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

function Get-DiagLines {
    $diagPath = Join-Path $stateRoot 'brain-live-diagnostics.jsonl'
    if (-not (Test-Path -LiteralPath $diagPath -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $diagPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$savedGate = $env:BRAIN_LIVE_DIAGNOSTICS
try {
    New-Item -ItemType Directory -Path $testBrainRoot, $projectRoot, $stateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'), (Join-Path $testBrainRoot 'templates'), (Join-Path $testBrainRoot 'store\raw'), (Join-Path $testBrainRoot 'integrations') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination (Join-Path $testBrainRoot 'brain.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Destination (Join-Path $testBrainRoot 'templates\work-record.md')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\trusted-roots.json'), '{"format_version":"0.1","trusted_roots":[]}', [Text.UTF8Encoding]::new($false))

    $brainScript = Join-Path $testBrainRoot 'brain.ps1'
    & $brainScript register -ProjectPath $projectRoot -ProjectId 'livediag-proj' | Out-Null
    & $brainScript init -ProjectPath $projectRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $projectRoot '.brain\outbox\seed.md'), (New-RecordText -TaskId 'seed'), [Text.UTF8Encoding]::new($false))
    & $brainScript sync -ProjectPath $projectRoot | Out-Null

    $sessionId = 'livediag-session-001'
    $secretSentinel = 'sk-livediag-SECRET-9f8e7d6c5b4a'
    $codeSentinel = 'DIAG-SOURCE-CODE-SENTINEL-const x = 42'

    # === 1. Gate off (default): no diagnostics file may appear ===
    $env:BRAIN_LIVE_DIAGNOSTICS = $null
    $null = Invoke-Bridge -Provider Cursor -Payload @{
        session_id = $sessionId
        cwd = $projectRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    $null = Invoke-Bridge -Provider Cursor -Payload @{
        session_id = $sessionId
        cwd = $projectRoot
        hook_event_name = 'PostToolUse'
        tool_name = 'Write'
        tool_input = @{ file_path = 'a.txt'; content = $codeSentinel; api_key = $secretSentinel }
    }
    Assert-True -Condition (@(Get-DiagLines).Count -eq 0) -Message '1. Diagnostics must stay off by default (no file without opt-in).'

    # === 2. Gate on: full flow is recorded as facts ===
    $env:BRAIN_LIVE_DIAGNOSTICS = '1'
    $null = Invoke-Bridge -Provider Cursor -Payload @{
        session_id = $sessionId
        cwd = $projectRoot
        hook_event_name = 'SessionStart'
        source = 'startup'
    }
    $null = Invoke-Bridge -Provider Cursor -Payload @{
        session_id = $sessionId
        cwd = $projectRoot
        hook_event_name = 'PostToolUse'
        tool_name = 'Write'
        tool_input = @{ file_path = 'a.txt'; content = $codeSentinel; api_key = $secretSentinel }
    }
    $stopOut = Invoke-Bridge -Provider Cursor -Payload @{
        session_id = $sessionId
        cwd = $projectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'Done.'
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($stopOut)) -Message '2. Stop must request the record.'

    $lines = @(Get-DiagLines)
    Assert-True -Condition ($lines.Count -ge 3) -Message '2. Entry, dirty-mark, and stop phases must be recorded.'
    $phases = @($lines | ForEach-Object { ($_ | ConvertFrom-Json -Depth 10).phase })
    Assert-True -Condition ($phases -contains 'entry') -Message '2. Entry phase must be recorded.'
    Assert-True -Condition ($phases -contains 'dirty-mark') -Message '2. Dirty-mark phase must be recorded.'
    Assert-True -Condition ($phases -contains 'stop') -Message '2. Stop phase must be recorded.'
    $raw = @($lines) -join "`n"
    foreach ($entry in $lines) {
        $parsed = $entry | ConvertFrom-Json -Depth 10
        Assert-True -Condition ([string]$parsed.provider -eq 'Cursor') -Message '2. Every line must carry the provider.'
        Assert-True -Condition ([string]$parsed.project_id -eq 'livediag-proj') -Message '2. Every line must carry the project id.'
        Assert-True -Condition ([string]$parsed.session_ref -match '^[0-9a-f]{16}$') -Message '2. Session must be a 16-hex hash, never the raw id.'
        # The raw session id may survive ONLY inside expected_record paths
        # (operational: which outbox file was expected; same sensitivity as
        # project_id). Everywhere else it must be the hash.
        foreach ($prop in @($parsed.PSObject.Properties)) {
            if ([string]$prop.Name -eq 'expected_record') { continue }
            Assert-True -Condition ([string]$prop.Value -notmatch [regex]::Escape($sessionId)) -Message ("2. Raw session id must not leak via field " + [string]$prop.Name + ".")
        }
    }
    Assert-True -Condition ($raw -notmatch 'DIAG-SEED-UNIQUE-STRING') -Message '2. Record/context content must never appear.'
    Assert-True -Condition ($raw -notmatch [regex]::Escape($codeSentinel)) -Message '2. Tool content must never appear.'
    Assert-True -Condition ($raw -notmatch [regex]::Escape($secretSentinel)) -Message '2. Secret-like tool values must never appear.'

    [pscustomobject][ordered]@{
        result = 'PASS'
        gate_off_by_default = $true
        phases_recorded = $true
        session_hashed = $true
        no_prompt_no_context_no_code_no_secret = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    $env:BRAIN_LIVE_DIAGNOSTICS = $savedGate
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-livediag-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe diagnostics test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
