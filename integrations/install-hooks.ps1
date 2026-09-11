# Retained for backwards compatibility. brain-setup.ps1 is the full-featured
# entry point (Install/Update/Repair/Uninstall/Status/Backup/Restore); this
# script is a thin wrapper that keeps the original -Action Install contract
# and JSON output shape that earlier tooling and tests expect.
[CmdletBinding()]
param(
    [string]$BrainHookPath = (Join-Path $PSScriptRoot 'brain-hook.ps1'),
    [string]$CodexHooksPath = '',
    [string]$ClaudeSettingsPath = '',
    [string]$Integration = '',
    [string]$ConfigPath = '',
    [string]$PluginPath = '',
    [string]$SandboxDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This legacy contract reports only Codex and Claude. Keep its writes within
# that same scope; newer integrations use the full setup entry point.
$selectedIntegrations = @('codex', 'claude')
if (-not [string]::IsNullOrWhiteSpace($Integration)) {
    $id = $Integration.Trim().ToLowerInvariant()
    if ($id -notin $selectedIntegrations) {
        throw "install-hooks.ps1 supports only codex and claude. Use brain-setup.ps1 -Action Install -Integration <id> for other integrations."
    }
    $selectedIntegrations = @($id)
}
if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and $selectedIntegrations.Count -ne 1) {
    throw '-ConfigPath requires -Integration codex or claude. Use -CodexHooksPath and -ClaudeSettingsPath to specify separate targets.'
}

$setupScript = Join-Path $PSScriptRoot 'brain-setup.ps1'
if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) {
    throw "BRAIN setup script is missing: $setupScript"
}

$invokeParams = @{
    Action = 'Install'
    BrainHookPath = $BrainHookPath
}
# Empty defaults must reach setup's resolver as defaults, not explicit user
# profile paths, so both -SandboxDir and BRAIN_TEST_SANDBOX remain effective.
if (-not [string]::IsNullOrWhiteSpace($CodexHooksPath)) { $invokeParams['CodexHooksPath'] = $CodexHooksPath }
if (-not [string]::IsNullOrWhiteSpace($ClaudeSettingsPath)) { $invokeParams['ClaudeSettingsPath'] = $ClaudeSettingsPath }
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $invokeParams['ConfigPath'] = $ConfigPath }
if (-not [string]::IsNullOrWhiteSpace($PluginPath)) { $invokeParams['PluginPath'] = $PluginPath }
if (-not [string]::IsNullOrWhiteSpace($SandboxDir)) { $invokeParams['SandboxDir'] = $SandboxDir }
$result = $null
foreach ($id in $selectedIntegrations) {
    $invokeParams['Integration'] = $id
    $current = & $setupScript @invokeParams | ConvertFrom-Json -Depth 20
    if ($null -eq $result) { $result = $current }
    $result.$id = $current.$id
}

[pscustomobject][ordered]@{
    result = $result.result
    codex_changed = [bool]$result.codex.changed
    codex_path = [string]$result.codex.path
    codex_backup = if ($null -eq $result.codex.backup) { $null } else { [string]$result.codex.backup }
    claude_changed = [bool]$result.claude.changed
    claude_path = [string]$result.claude.path
    claude_backup = if ($null -eq $result.claude.backup) { $null } else { [string]$result.claude.backup }
    brain_hook = [string]$result.brain_hook
    powershell = [string]$result.powershell
} | ConvertTo-Json -Depth 10
