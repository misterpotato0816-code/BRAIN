[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

# Regression test for the Claude Desktop stdin decoding failure:
# hook payloads are UTF-8 bytes, but [Console]::In decodes them with the
# console code page (CP932 on Japanese Windows). Multi-byte UTF-8 sequences
# then mis-pair and consume ASCII quotes/backslashes that follow them, which
# corrupts the JSON exactly like the production brain-hook.log showed
# (Unterminated string at session_title, unexpected \ / b / ( inside
# tool_input.old_string / new_string, tool_response.originalFile, ...).
#
# The test pipes realistic Claude Desktop payloads as UTF-8 bytes through a
# console forced to CP932 and requires the hook to parse them and act (dirty
# flag, Stop record request) instead of failing open.

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-stdin-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'BRAIN 日本語'
$projectRoot = Join-Path $testRoot 'プロジェクト 日本語'
$stateRoot = Join-Path $testRoot 'state'
$cmdScript = Join-Path $testRoot 'run-hook-cp932.cmd'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-FailOpenCount {
    $logPath = Join-Path $stateRoot 'brain-hook.log'
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { return 0 }
    return @(Select-String -LiteralPath $logPath -Pattern 'Fail-open hook error' -SimpleMatch).Count
}

function Invoke-HookWithPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Payload,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    $payloadPath = Join-Path $testRoot ("payload-" + [guid]::NewGuid().ToString('N') + ".json")
    [IO.File]::WriteAllText($payloadPath, $Payload, [Text.UTF8Encoding]::new($false))
    $before = Get-FailOpenCount

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "$env:ComSpec"
    $psi.Arguments = '/d /c {0} "{1}" "{2}" "{3}" {4} "{5}"' -f $cmdScript, $pwshPath, $hookPath, $testBrainRoot, $Provider, $stateRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($psi)
    $bytes = [IO.File]::ReadAllBytes($payloadPath)
    $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $process.StandardInput.BaseStream.Flush()
    $process.StandardInput.Close()
    $exited = $process.WaitForExit(60000)
    if (-not $exited) { $process.Kill($true) }
    Remove-Item -LiteralPath $payloadPath -Force
    Assert-True -Condition $exited -Message 'Hook process must terminate within 60 seconds.'
    Assert-True -Condition ($process.ExitCode -eq 0) -Message "Hook must fail open with exit code 0 ($Provider)."
    $stdout = $process.StandardOutput.ReadToEnd()
    $after = Get-FailOpenCount
    return [pscustomobject]@{
        Stdout = $stdout.Trim()
        NewFailOpenErrors = ($after - $before)
    }
}

function New-PostToolUsePayload {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][int]$LargeMultiplier,
        [switch]$Pretty
    )

    $oldString = @'
    if (path == "C:\Users\テスト\設定ファイル 日本語.txt") {
        Console.WriteLine("行1: バックスラッシュ \ と引用符 " と '一重' と正規表現 \bword\d+ の混在");
    } /* コメント "quoted" \path\to\file C:\temp */
'@
    $newString = @'
    if (path == "X:\Synthetic-Projects\プロジェクト 日本語\新しい "名前" \ディレクトリ") {
        Console.WriteLine("置換後: 'single' \"escaped\" \\double\\ \b\t\n literal");
    }
'@
    $originalFile = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt (60 * $LargeMultiplier); $i++) {
        $null = $originalFile.AppendLine(('// 行 {0}: 日本語コメント \"quote\" ''single'' C:\path\file{1}.cs 正規表現 \bword\d+' -f $i, $i))
        $null = $originalFile.AppendLine(('var data = new Dictionary<string, int> {{ ["キー{0}"] = {1} }};' -f $i, $i))
    }
    $toolInput = [ordered]@{
        file_path = 'X:\Synthetic-Projects\プロジェクト 日本語\src\ファイル 日本語.cs'
        old_string = $oldString
        new_string = $newString
    }
    $toolResponse = [ordered]@{
        originalFile = $originalFile.ToString()
        structuredPatch = @(
            [ordered]@{
                oldStart = 1
                newStart = 1
                oldLines = @('古い行 "quoted" \path \bword', '// 日本語の行 "です"')
                newLines = @('新しい行 "quoted" \path \bword', '// 変更後の日本語 "行"')
            }
        )
    }
    $payload = [ordered]@{
        hook_event_name = 'PostToolUse'
        session_id = $SessionId
        cwd = $projectRoot
        tool_name = 'Edit'
        tool_input = $toolInput
        tool_response = $toolResponse
    }
    if ($Pretty) {
        return ConvertTo-Json -InputObject $payload -Depth 30
    }
    return ConvertTo-Json -InputObject $payload -Depth 30 -Compress
}

function New-StopPayload {
    param([Parameter(Mandatory = $true)][string]$SessionId)

    $message = @'
作業が完了しました。`X:\Synthetic-Projects\プロジェクト 日本語` の "設定ファイル" を更新しました。
正規表現 \bword\d+ とパス C:\temp\"新しい フォルダ" を確認済みです。
'@
    return ConvertTo-Json -InputObject ([ordered]@{
        hook_event_name = 'Stop'
        session_id = $SessionId
        cwd = $projectRoot
        stop_hook_active = $false
        last_assistant_message = $message
    }) -Depth 30 -Compress
}

function Get-SessionState {
    param([Parameter(Mandatory = $true)][string]$SessionId)

    foreach ($file in @(Get-ChildItem -LiteralPath $stateRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $state = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        if ([string]$state.session_id -eq $SessionId) { return $state }
    }
    return $null
}

try {
    New-Item -ItemType Directory -Path $testBrainRoot, $projectRoot, $stateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'), (Join-Path $testBrainRoot 'templates'), (Join-Path $testBrainRoot 'store\raw'), (Join-Path $testBrainRoot 'integrations') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination (Join-Path $testBrainRoot 'brain.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Destination (Join-Path $testBrainRoot 'templates\work-record.md')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'integrations\brain-hook.ps1') -Destination (Join-Path $testBrainRoot 'integrations\brain-hook.ps1')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))

    $hookPath = Join-Path $testBrainRoot 'integrations\brain-hook.ps1'
    # Pure-ASCII cmd script: Japanese/space paths are passed as quoted arguments
    # (%1 pwsh, %2 hook, %3 brainRoot, %4 provider, %5 stateRoot) so the script
    # file itself survives any console code page.
    $cmdLines = @(
        '@echo off',
        'chcp 932 >nul',
        '%1 -NoProfile -NonInteractive -File %2 -Provider %4 -BrainRoot %3 -StateRoot %5'
    )
    [IO.File]::WriteAllLines($cmdScript, $cmdLines, [Text.UTF8Encoding]::new($false))

    & (Join-Path $testBrainRoot 'brain.ps1') register -ProjectPath $projectRoot -ProjectId 'stdin-e2e' | Out-Null
    & (Join-Path $testBrainRoot 'brain.ps1') init -ProjectPath $projectRoot | Out-Null

    # --- Case 1: compact PostToolUse payload with Japanese cwd, code, quotes, backslashes ---
    $session1 = 'stdin-session-001'
    $result = Invoke-HookWithPayload -Provider Claude -SessionId $session1 -Payload (New-PostToolUsePayload -SessionId $session1 -LargeMultiplier 1)
    Assert-True -Condition ($result.NewFailOpenErrors -eq 0) -Message 'Compact PostToolUse payload must not fail open under CP932 console.'
    $state = Get-SessionState -SessionId $session1
    Assert-True -Condition ($null -ne $state) -Message 'Parsed PostToolUse must create session state.'
    Assert-True -Condition ([bool]$state.dirty) -Message 'Parsed PostToolUse must mark the session dirty (cwd Japanese path decoded exactly).'
    Assert-True -Condition ([string]$state.project_id -eq 'stdin-e2e') -Message 'Session state must bind to the registered Japanese-named project.'

    # --- Case 2: Stop payload with nasty last_assistant_message requests a record ---
    $result = Invoke-HookWithPayload -Provider Claude -SessionId $session1 -Payload (New-StopPayload -SessionId $session1)
    Assert-True -Condition ($result.NewFailOpenErrors -eq 0) -Message 'Stop payload with Japanese last_assistant_message must not fail open.'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($result.Stdout)) -Message 'Stop must emit a record request.'
    $stopJson = $result.Stdout | ConvertFrom-Json -Depth 30
    Assert-True -Condition ($stopJson.hookSpecificOutput.hookEventName -eq 'Stop') -Message 'Claude Stop must use hookSpecificOutput.'
    Assert-True -Condition ([string]$stopJson.hookSpecificOutput.additionalContext -match 'Create a short BRAIN work record') -Message 'Stop must request a work record.'
    $state = Get-SessionState -SessionId $session1
    Assert-True -Condition ([int]$state.request_count -eq 1) -Message 'Stop must count exactly one record request.'
    Assert-True -Condition (Test-Path -LiteralPath (Split-Path -Parent ([string]$state.expected_record_path)) -PathType Container) -Message 'Expected record path must live in the existing outbox (Japanese path decoded).'

    # --- Case 3: large tool_response (~150 KiB) must parse completely ---
    $session2 = 'stdin-session-002'
    $result = Invoke-HookWithPayload -Provider Claude -SessionId $session2 -Payload (New-PostToolUsePayload -SessionId $session2 -LargeMultiplier 30)
    Assert-True -Condition ($result.NewFailOpenErrors -eq 0) -Message 'Large PostToolUse payload must not fail open.'
    $state = Get-SessionState -SessionId $session2
    Assert-True -Condition ($null -ne $state) -Message 'Large payload must still parse and create session state.'
    Assert-True -Condition ([bool]$state.dirty) -Message 'Large payload must mark the session dirty.'

    # --- Case 4: pretty-printed (multi-line) payload must parse ---
    $session3 = 'stdin-session-003'
    $result = Invoke-HookWithPayload -Provider Claude -SessionId $session3 -Payload (New-PostToolUsePayload -SessionId $session3 -LargeMultiplier 1 -Pretty)
    Assert-True -Condition ($result.NewFailOpenErrors -eq 0) -Message 'Pretty-printed payload must not fail open.'
    $state = Get-SessionState -SessionId $session3
    Assert-True -Condition ($null -ne $state -and [bool]$state.dirty) -Message 'Pretty-printed payload must mark the session dirty.'

    # --- Case 5: Codex provider shares the same stdin path ---
    $session4 = 'stdin-session-004'
    $result = Invoke-HookWithPayload -Provider Codex -SessionId $session4 -Payload (New-PostToolUsePayload -SessionId $session4 -LargeMultiplier 1)
    Assert-True -Condition ($result.NewFailOpenErrors -eq 0) -Message 'Codex PostToolUse payload must not fail open.'
    $state = Get-SessionState -SessionId $session4
    Assert-True -Condition ($null -ne $state -and [bool]$state.dirty) -Message 'Codex PostToolUse must mark the session dirty.'

    [pscustomobject][ordered]@{
        result = 'PASS'
        cp932_console_decoding = $true
        posttooluse_dirty_marked = $true
        japanese_project_bound = $true
        stop_record_requested = $true
        large_payload_parsed = $true
        pretty_payload_parsed = $true
        codex_path_unchanged = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-stdin-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe stdin test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
