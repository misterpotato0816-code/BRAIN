[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')

$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$testFiles = @(
    Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1' |
        Where-Object { -not [string]::Equals($_.FullName, $PSCommandPath, [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object Name
)

# Phase 7 gate: every test must dot-source the shared sandbox helper. The
# match requires the actual dot-source call, not a mere mention in a comment.
foreach ($file in $testFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    if ($text -notmatch '\.\s*\(Join-Path\s+\$PSScriptRoot\s+''helpers\\brain-test-common\.ps1''\)') {
        Write-Output "FAIL: $($file.Name) does not dot-source tests/helpers/brain-test-common.ps1"
        exit 1
    }
}

$runCanaryBefore = New-BrainTestCanary
$runCanaryFailed = $false

$results = [Collections.Generic.List[pscustomobject]]::new()
foreach ($file in $testFiles) {
    Write-Output "=== Running $($file.Name) ==="
    # Phase 4.5: every test file gets a FRESH sandbox gate. The gate forces
    # all resolved integration targets below this directory, so a new
    # integration can never leak into the real user profile even if a test
    # forgets every path override.
    $env:BRAIN_TEST_SANDBOX = Join-Path ([IO.Path]::GetTempPath()) ('brain-run-sandbox-' + $file.BaseName + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $env:BRAIN_TEST_SANDBOX -Force | Out-Null
    $fileCanaryBefore = New-BrainTestCanary
    $output = & $pwshPath -NoProfile -File $file.FullName 2>&1
    $exitCode = $LASTEXITCODE
    $passed = ($exitCode -eq 0)
    if ($passed) {
        $canaryViolations = @(Test-BrainTestCanary -Before $fileCanaryBefore)
        if ($canaryViolations.Count -gt 0) {
            $passed = $false
            $exitCode = 99
            $output = @($output) + @('CANARY VIOLATIONS:') + @($canaryViolations | ForEach-Object { 'CANARY: ' + $_ })
        }
    }
    if (Test-Path -LiteralPath $env:BRAIN_TEST_SANDBOX) {
        $sandboxLeaf = Split-Path -Leaf ([IO.Path]::GetFullPath($env:BRAIN_TEST_SANDBOX))
        $sandboxTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $sandboxFull = [IO.Path]::GetFullPath($env:BRAIN_TEST_SANDBOX)
        if (($sandboxLeaf -match '^brain-run-sandbox-[a-z0-9-]+-[0-9a-f]{32}$') -and $sandboxFull.StartsWith($sandboxTemp, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $sandboxFull -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Output "FAIL: refusing to clean unsafe sandbox path: $sandboxFull"
            exit 1
        }
    }
    $results.Add([pscustomobject]@{
        Name = $file.Name
        Passed = $passed
        ExitCode = $exitCode
    })
    if ($passed) {
        Write-Output "PASS: $($file.Name)"
    }
    else {
        Write-Output "FAIL: $($file.Name) (exit code $exitCode)"
        $output | ForEach-Object { Write-Output "    $_" }
    }
}

Write-Output ''
Write-Output '=== Canary (whole run) ==='
$runViolations = @(Test-BrainTestCanary -Before $runCanaryBefore)
if ($runViolations.Count -eq 0) {
    Write-Output 'PASS: real user config and BRAIN data unchanged.'
}
else {
    $runCanaryFailed = $true
    foreach ($violation in $runViolations) {
        Write-Output ("CANARY: $violation")
    }
}
$env:BRAIN_TEST_SANDBOX = $null

Write-Output ''
Write-Output '=== Summary ==='
foreach ($result in $results) {
    $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
    Write-Output ("{0,-6} {1}" -f $status, $result.Name)
}

$failedCount = @($results | Where-Object { -not $_.Passed }).Count
Write-Output ''
Write-Output "Total: $($results.Count), Passed: $($results.Count - $failedCount), Failed: $failedCount"

if ($failedCount -gt 0 -or $runCanaryFailed) {
    exit 1
}
exit 0
