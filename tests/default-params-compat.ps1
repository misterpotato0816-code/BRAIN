[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-compat-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$setupScript = Join-Path $sourceRoot 'integrations\brain-setup.ps1'
$hookScript = Join-Path $sourceRoot 'integrations\brain-hook.ps1'
$realProjectsHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash
$realCursorHooksPath = Join-Path $env:USERPROFILE '.cursor\hooks.json'
$realCursorHooksBefore = if (Test-Path -LiteralPath $realCursorHooksPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $realCursorHooksPath -Algorithm SHA256).Hash
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

# Live-verification regression: real users invoke brain-setup WITHOUT the
# -CodexHooksPath/-ClaudeSettingsPath overrides that every older test passes
# explicitly. With empty defaults, the compat codex/claude summaries must
# still resolve through the normal declaration-driven resolver instead of
# crashing on GetFullPath('').

try {
    New-Item -ItemType Directory -Path $testBrainRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'lib') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')

    # Reference paths from the unfiltered (fully explicit-by-default) Status.
    $reference = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript | ConvertFrom-Json -Depth 30
    $referenceCodexPath = [string]$reference.codex.path
    $referenceClaudePath = [string]$reference.claude.path
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($referenceCodexPath)) -Message 'Reference codex path must not be empty.'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($referenceClaudePath)) -Message 'Reference claude path must not be empty.'

    foreach ($id in @('cursor', 'copilot', 'gemini-cli', 'opencode')) {
        $status = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript -Integration $id | ConvertFrom-Json -Depth 30
        Assert-True -Condition ([string]$status.result -eq 'OK') -Message "Status -Integration $id must succeed without explicit hook paths."
        Assert-True -Condition ([string]$status.codex.path -eq $referenceCodexPath) -Message "Compat codex path for -Integration $id must equal the resolver path."
        Assert-True -Condition ([string]$status.claude.path -eq $referenceClaudePath) -Message "Compat claude path for -Integration $id must equal the resolver path."
    }

    # Backup with defaults must also survive (sandbox gate forces all
    # resolved targets below the temp sandbox; Status/Backup never write
    # outside it). Only the selected integration gets a backup artifact.
    $backup = & $setupScript -Action Backup -BrainRoot $testBrainRoot -BrainHookPath $hookScript -Integration cursor | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([string]$backup.result -eq 'OK') -Message 'Backup -Integration cursor must succeed without explicit hook paths.'
    Assert-True -Condition ([string]$backup.codex.path -eq $referenceCodexPath) -Message 'Backup compat codex path must equal the resolver path.'
    $cursorBackupPath = [string]$backup.integrations.cursor
    Assert-True -Condition (Test-Path -LiteralPath $cursorBackupPath -PathType Leaf) -Message 'Backup must record a real backup file for the selected integration.'
    Assert-True -Condition ($cursorBackupPath.StartsWith($env:BRAIN_TEST_SANDBOX, [StringComparison]::OrdinalIgnoreCase)) -Message 'Backup artifact must stay inside the sandbox.'

    # Unfiltered Status keeps working (non-regression).
    $unfiltered = & $setupScript -Action Status -BrainRoot $testBrainRoot -BrainHookPath $hookScript | ConvertFrom-Json -Depth 30
    Assert-True -Condition ([string]$unfiltered.result -eq 'OK') -Message 'Unfiltered Status must succeed.'

    # Real user data untouched (Status/Backup under gate are read-only or
    # sandbox-confined by construction; assert it anyway).
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash -eq $realProjectsHash) -Message 'Real config/projects.json must be untouched.'
    if ($null -eq $realCursorHooksBefore) {
        Assert-True -Condition (-not (Test-Path -LiteralPath $realCursorHooksPath)) -Message 'No real Cursor hooks may exist.'
    }
    else {
        Assert-True -Condition ((Get-FileHash -LiteralPath $realCursorHooksPath -Algorithm SHA256).Hash -eq $realCursorHooksBefore) -Message 'Real Cursor hooks.json must be untouched.'
    }

    [pscustomobject][ordered]@{
        result = 'PASS'
        default_param_status_ok = $true
        compat_path_matches_resolver = $true
        default_param_backup_ok = $true
        unfiltered_status_ok = $true
        real_user_data_untouched = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-compat-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe compat test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
