[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $env:BRAIN_TEST_SANDBOX ('core-audit-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$projectRoot = Join-Path $testRoot 'project'
$brainScript = Join-Path $testBrainRoot 'brain.ps1'
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function New-Record {
    param([string]$TaskId, [string]$Summary = 'Safe historical summary.')
    return $script:recordTemplate.Replace('replace-with-registered-project-id', 'audit-project').
        Replace('replace-with-local-task-id', $TaskId).
        Replace('Briefly describe the completed task.', $Summary)
}

function Invoke-RequiredSync {
    param([string]$Path)
    $messages = [Collections.Generic.List[string]]::new()
    $failed = $false
    try {
        & $brainScript sync -ProjectPath $projectRoot -RequiredRecordPath $Path 3>&1 |
            ForEach-Object { $messages.Add([string]$_) }
    }
    catch {
        $failed = $true
        $messages.Add($_.Exception.Message)
    }
    return [pscustomobject]@{ Failed = $failed; Messages = ($messages -join "`n") }
}

try {
    foreach ($directory in @($testBrainRoot, $projectRoot, (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination $brainScript
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", $utf8)
    $script:recordTemplate = Get-Content -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Raw -Encoding UTF8

    & $brainScript register -ProjectPath $projectRoot -ProjectId 'audit-project' | Out-Null
    & $brainScript init -ProjectPath $projectRoot | Out-Null
    $outbox = Join-Path $projectRoot '.brain\outbox'
    $raw = Join-Path $testBrainRoot 'store\raw\audit-project'
    $contextPath = Join-Path $projectRoot '.brain\context.md'
    $invalidPath = Join-Path $outbox '000-incomplete.md'
    $validPath = Join-Path $outbox '999-valid.md'
    [IO.File]::WriteAllText($invalidPath, "---`n", $utf8)
    [IO.File]::WriteAllText($validPath, (New-Record -TaskId 'valid-after-incomplete'), $utf8)
    $invalidHash = (Get-FileHash -LiteralPath $invalidPath -Algorithm SHA256).Hash

    # F5: a malformed first file cannot starve unrelated, valid work, on any run.
    $first = Invoke-RequiredSync -Path $validPath
    Assert-True (-not $first.Failed) 'A valid required record must succeed beside an incomplete record.'
    Assert-True ($first.Messages.Contains('rejected=1')) 'Collection must report the rejected file count.'
    Assert-True ((Get-Content -LiteralPath $contextPath -Raw).Contains('valid-after-incomplete')) 'Valid work must reach context.'
    $rawFiles = @(Get-ChildItem -LiteralPath $raw -File -Filter '*.md')
    Assert-True ($rawFiles.Count -eq 1) 'Only the valid record may enter raw.'
    $validRawPath = $rawFiles[0].FullName
    $validRawHash = (Get-FileHash -LiteralPath $validRawPath -Algorithm SHA256).Hash
    $contextHash = (Get-FileHash -LiteralPath $contextPath -Algorithm SHA256).Hash
    $duplicate = Invoke-RequiredSync -Path $validPath
    Assert-True (-not $duplicate.Failed -and $duplicate.Messages.Contains('duplicates=1')) 'A revalidated duplicate must satisfy RequiredRecordPath.'
    Assert-True ((Get-FileHash -LiteralPath $contextPath -Algorithm SHA256).Hash -eq $contextHash) 'Duplicate sync must remain deterministic.'
    Assert-True ((Get-FileHash -LiteralPath $invalidPath -Algorithm SHA256).Hash -eq $invalidHash) 'Rejected outbox must remain unchanged.'

    foreach ($required in @($invalidPath, (Join-Path $outbox 'missing.md'), (Join-Path $testRoot '999-valid.md'))) {
        [IO.File]::WriteAllText($contextPath, 'STALE CONTEXT', $utf8)
        $failed = Invoke-RequiredSync -Path $required
        Assert-True $failed.Failed 'An invalid, missing, or outside required record cannot mark a hook complete.'
        Assert-True ($failed.Messages.Contains('CONTEXT_WRITTEN')) 'Context must be regenerated before required-record failure.'
        Assert-True ((Get-Content -LiteralPath $contextPath -Raw).Contains('valid-after-incomplete')) 'Good context must be refreshed even when required work is rejected.'
    }

    # F1: reject secrets in the actual labeled bullet format, prose, code and JSON.
    # Only synthetic sentinels are used. Diagnostics must never repeat their values.
    $secretCases = @(
        'api_key=FAKE_DUMMY_VALUE_0123456789',
        'Before api-key: FAKE_DUMMY_VALUE_0123456789 after.',
        'Set `ACCESS_TOKEN="FAKE_DUMMY_VALUE_0123456789"` during the test.',
        '{"secret_key": "FAKE_DUMMY_VALUE_0123456789"}',
        "secret-key='FAKE_DUMMY_VALUE_0123456789'",
        'Authorization: Bearer FAKE_DUMMY_BEARER_0123456789',
        'The header was "Authorization": "Bearer FAKE_DUMMY_BEARER_0123456789".',
        '-----BEGIN PRIVATE KEY----- FAKE_DUMMY_PRIVATE_0123456789'
    )
    $caseNumber = 0
    foreach ($secretCase in $secretCases) {
        $caseNumber++
        $secretPath = Join-Path $outbox ("secret-case-$caseNumber.md")
        [IO.File]::WriteAllText($secretPath, (New-Record -TaskId "secret-case-$caseNumber" -Summary $secretCase), $utf8)
        $beforeHash = (Get-FileHash -LiteralPath $secretPath -Algorithm SHA256).Hash
        $result = Invoke-RequiredSync -Path $secretPath
        Assert-True $result.Failed 'A secret-like required record must fail acceptance.'
        Assert-True (-not $result.Messages.Contains('FAKE_DUMMY_')) 'Warnings and errors must not expose values from rejected records.'
        Assert-True (-not (Get-Content -LiteralPath $contextPath -Raw).Contains('FAKE_DUMMY_')) 'Rejected values must not appear in context.'
        Assert-True (@(Get-ChildItem -LiteralPath $raw -File -Filter '*.md').Count -eq 1) 'Rejected values must not be collected.'
        Assert-True ((Get-FileHash -LiteralPath $secretPath -Algorithm SHA256).Hash -eq $beforeHash) 'Rejected secret-like outbox files must not be rewritten.'
    }

    # Safe documentation placeholders should remain usable.
    $safePath = Join-Path $outbox 'safe-placeholder.md'
    [IO.File]::WriteAllText($safePath, (New-Record -TaskId 'safe-placeholders' -Summary 'Configure api_key=<your-key> and Authorization: Bearer <your-token>; no actual values are recorded.'), $utf8)
    $safe = Invoke-RequiredSync -Path $safePath
    Assert-True (-not $safe.Failed) 'Placeholder documentation should not be mistaken for a secret.'

    # Repairing a rejected outbox record makes it eligible on the next sync.
    [IO.File]::WriteAllText($invalidPath, (New-Record -TaskId 'repaired-incomplete'), $utf8)
    $repaired = Invoke-RequiredSync -Path $invalidPath
    Assert-True (-not $repaired.Failed) 'A repaired required record must be rechecked and accepted.'

    # Preserve original bytes while accepting Windows CRLF and an optional BOM.
    $encodedPath = Join-Path $outbox 'utf8-bom-crlf.md'
    $encodedText = (New-Record -TaskId 'utf8-bom-crlf').Replace("`r`n", "`n").Replace("`n", "`r`n")
    $bomUtf8 = [Text.UTF8Encoding]::new($true)
    $encodedBytes = [byte[]]($bomUtf8.GetPreamble() + $bomUtf8.GetBytes($encodedText))
    [IO.File]::WriteAllBytes($encodedPath, $encodedBytes)
    $encodedResult = Invoke-RequiredSync -Path $encodedPath
    Assert-True (-not $encodedResult.Failed) 'A UTF-8 BOM and CRLF must not break record validation.'
    $encodedHash = (Get-FileHash -LiteralPath $encodedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $encodedRaw = Join-Path $raw ($encodedHash + '.md')
    Assert-True ((Get-FileHash -LiteralPath $encodedRaw -Algorithm SHA256).Hash.ToLowerInvariant() -eq $encodedHash) 'Validated BOM/CRLF raw must be stored byte-for-byte.'

    # Previously accepted records are immutable; old secrets must nevertheless
    # be excluded when rebuilding context, including context-only invocation.
    $legacyText = New-Record -TaskId 'legacy-secret' -Summary 'api_key=FAKE_DUMMY_LEGACY_0123456789'
    $legacyBytes = $utf8.GetBytes($legacyText)
    $legacyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($legacyBytes)).ToLowerInvariant()
    $legacyPath = Join-Path $raw ($legacyHash + '.md')
    [IO.File]::WriteAllBytes($legacyPath, $legacyBytes)
    [IO.File]::WriteAllText($contextPath, 'FAKE_DUMMY_LEGACY_0123456789', $utf8)
    $contextOutput = (& $brainScript context -ProjectPath $projectRoot 3>&1 | Out-String)
    Assert-True ($contextOutput.Contains('RAW_RECORD_EXCLUDED')) 'Legacy rejected raw records must be reported.'
    Assert-True (-not $contextOutput.Contains('FAKE_DUMMY_')) 'Legacy raw warning must not reveal secret-like values.'
    $newContext = Get-Content -LiteralPath $contextPath -Raw
    Assert-True (-not $newContext.Contains('FAKE_DUMMY_')) 'Regenerated context must remove legacy secret-like content.'
    Assert-True ($newContext.Contains('valid-after-incomplete')) 'Other historical records must survive legacy exclusion.'
    Assert-True ((Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $legacyHash) 'Excluded legacy raw must remain byte-identical.'
    Assert-True ((Get-FileHash -LiteralPath $validRawPath -Algorithm SHA256).Hash -eq $validRawHash) 'Existing valid raw must remain byte-identical.'

    # F6: legal directory names must produce valid, stable auto IDs.
    $slugPaths = @('_demo', '.demo', '日本語', ('_' + ('a' * 100)))
    foreach ($leaf in $slugPaths) {
        $slugPath = Join-Path $testRoot $leaf
        New-Item -ItemType Directory -Path $slugPath -Force | Out-Null
        & $brainScript register -ProjectPath $slugPath | Out-Null
        & $brainScript register -ProjectPath $slugPath | Out-Null
    }
    $projects = @(Get-Content -LiteralPath (Join-Path $testBrainRoot 'config\projects.json') -Raw | ConvertFrom-Json)
    Assert-True ($projects.Count -eq 5) 'Repeated auto registration must not duplicate entries.'
    foreach ($project in $projects) {
        Assert-True ([string]$project.id -match '^[a-z0-9][a-z0-9._-]{0,63}$') 'Every generated ID must satisfy the registry contract.'
    }

    [pscustomobject]@{
        result = 'PASS'
        malformed_outbox_isolated = $true
        required_record_acceptance = $true
        labeled_secret_cases_rejected = $secretCases.Count
        legacy_raw_excluded_without_mutation = $true
        auto_id_names = $slugPaths.Count
    } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $full = [IO.Path]::GetFullPath($testRoot)
        $sandbox = [IO.Path]::GetFullPath($env:BRAIN_TEST_SANDBOX).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($sandbox, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $full) -notmatch '^core-audit-[0-9a-f]{32}$') {
            throw 'Refusing to clean an unsafe test directory.'
        }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
