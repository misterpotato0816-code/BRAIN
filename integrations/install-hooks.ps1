# Retained for backwards compatibility. brain-setup.ps1 is the full-featured
# entry point (Install/Update/Repair/Uninstall/Status/Backup/Restore); this
# script is a thin wrapper that keeps the original -Action Install contract
# and JSON output shape that earlier tooling and tests expect.
[CmdletBinding()]
param(
    [string]$BrainHookPath = (Join-Path $PSScriptRoot 'brain-hook.ps1'),
    [string]$CodexHooksPath = (Join-Path $env:USERPROFILE '.codex\hooks.json'),
    [string]$ClaudeSettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$Integration = '',
    [string]$ConfigPath = '',
    [string]$PluginPath = '',
    [string]$SandboxDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$setupScript = Join-Path $PSScriptRoot 'brain-setup.ps1'
if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) {
    throw "BRAIN setup script is missing: $setupScript"
}

$invokeParams = @{
    Action = 'Install'
    BrainHookPath = $BrainHookPath
    CodexHooksPath = $CodexHooksPath
    ClaudeSettingsPath = $ClaudeSettingsPath
}
if (-not [string]::IsNullOrWhiteSpace($Integration)) { $invokeParams['Integration'] = $Integration }
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $invokeParams['ConfigPath'] = $ConfigPath }
if (-not [string]::IsNullOrWhiteSpace($PluginPath)) { $invokeParams['PluginPath'] = $PluginPath }
if (-not [string]::IsNullOrWhiteSpace($SandboxDir)) { $invokeParams['SandboxDir'] = $SandboxDir }
$result = & $setupScript @invokeParams | ConvertFrom-Json -Depth 20

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
