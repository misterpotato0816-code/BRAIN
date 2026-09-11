[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$setupScript = Join-Path $sourceRoot 'integrations\brain-setup.ps1'
$wrapperScript = Join-Path $sourceRoot 'integrations\install-hooks.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-setup-audit-' + [guid]::NewGuid().ToString('N'))
$originalProfile = $env:USERPROFILE
$originalSandbox = $env:BRAIN_TEST_SANDBOX

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-InstalledFiles {
    param([string]$Directory)
    return @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force |
        Where-Object Name -NotLike '*.brain-backup-*' | Sort-Object Name | Select-Object -ExpandProperty Name)
}

try {
    # Even a regression of the sandbox resolver can write only to this fake
    # profile, which is outside each scenario's sandbox and therefore watched.
    $env:USERPROFILE = Join-Path $testRoot 'fake-profile'
    New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null
    $profileCanary = Join-Path $env:USERPROFILE 'canary.txt'
    [IO.File]::WriteAllText($profileCanary, 'unchanged')
    $profileHash = (Get-FileHash -LiteralPath $profileCanary).Hash

    # F2: parse the command returned by the shipped handler function, with
    # Windows paths containing spaces, without running any AI product.
    $tokens = $null
    $parseErrors = $null
    $setupAst = [Management.Automation.Language.Parser]::ParseFile($setupScript, [ref]$tokens, [ref]$parseErrors)
    Assert-True (@($parseErrors).Count -eq 0) 'The setup script must parse.'
    $handlerFunction = $setupAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-BrainIntegrationHandler'
    }, $true)
    Assert-True ($null -ne $handlerFunction) 'The public handler function must exist.'
    . ([scriptblock]::Create($handlerFunction.Extent.Text))
    $definition = & (Join-Path $sourceRoot 'integrations\providers\copilot.ps1')
    $BrainHookPath = 'C:\Users\Example User\BRAIN\integrations\brain-hook.ps1'
    $windowsPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    foreach ($event in @($definition.Events)) {
        $handler = New-BrainIntegrationHandler -Definition $definition -PowerShellPath $windowsPwsh -EventName $event.EventName -Timeout $event.Timeout
        $commandAst = [Management.Automation.Language.Parser]::ParseInput([string]$handler.powershell, [ref]$tokens, [ref]$parseErrors)
        Assert-True (@($parseErrors).Count -eq 0) "Copilot $($event.EventName) command must be valid PowerShell."
        $invocation = $commandAst.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
        Assert-True ($null -ne $invocation -and [string]$invocation.InvocationOperator -eq 'Ampersand') 'A quoted executable must be invoked with the call operator.'
        Assert-True ($invocation.CommandElements[0].Value -eq $windowsPwsh) 'The executable path must remain intact.'
        Assert-True ($invocation.CommandElements[4].Value -eq $BrainHookPath) 'The hook path must remain a single argument.'
    }

    # F3/F7: the default legacy install writes exactly two reported targets.
    # Neither hook path is supplied, which exercises the formerly leaking path.
    $sandbox = Join-Path $testRoot 'wrapper-sandbox'
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $codexPath = Join-Path $sandbox 'codex.hooks.json'
    $claudePath = Join-Path $sandbox 'claude.hooks.json'
    $codexSeed = '{"description":"keep-codex","hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party-codex"}]}]}}'
    $claudeSeed = '{"alwaysThinkingEnabled":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party-claude"}]}]}}'
    [IO.File]::WriteAllText($codexPath, $codexSeed)
    [IO.File]::WriteAllText($claudePath, $claudeSeed)
    $first = & $wrapperScript -SandboxDir $sandbox | ConvertFrom-Json -Depth 30
    Assert-True ($first.result -eq 'OK' -and $first.codex_changed -and $first.claude_changed) 'Initial legacy install must report both writes.'
    $legacyFields = @('result', 'codex_changed', 'codex_path', 'codex_backup', 'claude_changed', 'claude_path', 'claude_backup', 'brain_hook', 'powershell')
    Assert-True (($first.PSObject.Properties.Name -join ',') -eq ($legacyFields -join ',')) 'Legacy JSON output shape must remain unchanged.'
    Assert-True ($first.codex_path -eq $codexPath -and $first.claude_path -eq $claudePath) 'Legacy output paths must use the sandbox resolver.'
    Assert-True (((Get-InstalledFiles $sandbox) -join ',') -eq 'claude.hooks.json,codex.hooks.json') 'Legacy default install must create no unreported provider artifacts.'
    Assert-True ([IO.File]::ReadAllText($first.codex_backup) -eq $codexSeed) 'Codex backup must preserve the original bytes.'
    Assert-True ([IO.File]::ReadAllText($first.claude_backup) -eq $claudeSeed) 'Claude backup must preserve the original bytes.'
    $codex = Get-Content -LiteralPath $codexPath -Raw | ConvertFrom-Json -Depth 30
    $claude = Get-Content -LiteralPath $claudePath -Raw | ConvertFrom-Json -Depth 30
    Assert-True ($codex.description -eq 'keep-codex' -and $claude.alwaysThinkingEnabled) 'Unrelated settings must survive legacy install.'
    Assert-True (@($codex.hooks.Stop.hooks.command) -contains 'third-party-codex') 'Existing Codex hooks must survive.'
    Assert-True (@($claude.hooks.Stop.hooks.command) -contains 'third-party-claude') 'Existing Claude hooks must survive.'
    $beforeHashes = @((Get-FileHash -LiteralPath $codexPath).Hash, (Get-FileHash -LiteralPath $claudePath).Hash)
    $backupsBefore = @(Get-ChildItem -LiteralPath $sandbox -File -Filter '*.brain-backup-*').Count
    $second = & $wrapperScript -SandboxDir $sandbox | ConvertFrom-Json -Depth 30
    Assert-True (-not $second.codex_changed -and -not $second.claude_changed) 'Repeated legacy install must report no changes.'
    Assert-True ((Get-FileHash -LiteralPath $codexPath).Hash -eq $beforeHashes[0] -and (Get-FileHash -LiteralPath $claudePath).Hash -eq $beforeHashes[1]) 'Repeated install must preserve bytes.'
    Assert-True (@(Get-ChildItem -LiteralPath $sandbox -File -Filter '*.brain-backup-*').Count -eq $backupsBefore) 'Repeated install must create no redundant backups.'

    # The environment-only sandbox is effective when every path is omitted.
    $environmentSandbox = Join-Path $testRoot 'environment-sandbox'
    New-Item -ItemType Directory -Path $environmentSandbox -Force | Out-Null
    $env:BRAIN_TEST_SANDBOX = $environmentSandbox
    $environmentInstall = & $wrapperScript | ConvertFrom-Json -Depth 30
    Assert-True ($environmentInstall.codex_path -eq (Join-Path $environmentSandbox 'codex.hooks.json')) 'Environment sandbox must apply to omitted Codex path.'
    Assert-True ($environmentInstall.claude_path -eq (Join-Path $environmentSandbox 'claude.hooks.json')) 'Environment sandbox must apply to omitted Claude path.'
    Assert-True (((Get-InstalledFiles $environmentSandbox) -join ',') -eq 'claude.hooks.json,codex.hooks.json') 'Environment-only install must remain limited to two providers.'

    # Explicit targets remain honored; selecting one provider must not install
    # the other. The explicit path stays inside the disposable test root.
    $explicitPath = Join-Path $testRoot 'explicit-codex.json'
    $explicit = & $wrapperScript -Integration ' Codex ' -CodexHooksPath $explicitPath -SandboxDir (Join-Path $testRoot 'single') | ConvertFrom-Json -Depth 30
    Assert-True ($explicit.codex_changed -and -not $explicit.claude_changed -and $explicit.codex_path -eq $explicitPath) 'Explicit Codex path and provider selection must remain supported.'
    Assert-True (-not (Test-Path -LiteralPath $explicit.claude_path)) 'Unselected Claude must not be installed.'
    $configPath = Join-Path $testRoot 'explicit-claude.json'
    $configInstall = & $wrapperScript -Integration claude -ConfigPath $configPath -SandboxDir (Join-Path $testRoot 'config') | ConvertFrom-Json -Depth 30
    Assert-True ($configInstall.claude_changed -and -not $configInstall.codex_changed -and $configInstall.claude_path -eq $configPath) 'A selected Claude ConfigPath must remain supported.'

    # Unsupported legacy targets are rejected before settings are touched.
    $rejectedSandbox = Join-Path $testRoot 'rejected'
    foreach ($provider in @('opencode', 'cursor', 'copilot', 'gemini-cli', 'unknown')) {
        $message = ''
        try { & $wrapperScript -Integration $provider -SandboxDir $rejectedSandbox | Out-Null }
        catch { $message = $_.Exception.Message }
        Assert-True ($message -match 'brain-setup.ps1') "Unsupported provider $provider must explain the full setup entry point."
    }
    $message = ''
    try { & $wrapperScript -ConfigPath (Join-Path $rejectedSandbox 'shared.json') -SandboxDir $rejectedSandbox | Out-Null }
    catch { $message = $_.Exception.Message }
    Assert-True ($message -match '-ConfigPath requires -Integration') 'A shared config override must require one selected provider.'
    Assert-True (-not (Test-Path -LiteralPath $rejectedSandbox)) 'Rejected requests must not write any settings.'

    Assert-True (@(Get-ChildItem -LiteralPath $env:USERPROFILE -Recurse -Force).Count -eq 1) 'No resolved config may leak into the fake profile.'
    Assert-True ((Get-FileHash -LiteralPath $profileCanary).Hash -eq $profileHash) 'The fake profile canary must remain unchanged.'
    [pscustomobject][ordered]@{
        result = 'PASS'
        copilot_windows_command_syntax = $true
        legacy_sandbox_isolation = $true
        legacy_two_provider_scope = $true
        legacy_json_compatibility = $true
        idempotence_and_unrelated_settings = $true
        explicit_targets_and_rejections = $true
    } | ConvertTo-Json
}
finally {
    $env:USERPROFILE = $originalProfile
    $env:BRAIN_TEST_SANDBOX = $originalSandbox
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ((Split-Path -Leaf $resolved) -notmatch '^brain-setup-audit-[0-9a-f]{32}$' -or -not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean unsafe setup audit test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
