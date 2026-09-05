# Codex integration definition (Phase 2 adapter).
# Returned hashtable is consumed by lib/brain-integrations.ps1.
# Handler JSON shape below must stay byte-compatible with Phase 1:
# single-string command/commandWindows, statusMessage "BRAIN Codex <Event>",
# brain_hook_id "brain.codex.<Event>", additionalContextLimit only on SessionStart.
@{
    Id = 'codex'
    Name = 'Codex'
    DisplayName = 'Codex'
    ConfigRelativePath = '.codex\hooks.json'
    HandlerStyle = 'CodexCommandString'
    HookIdPrefix = 'brain.codex.'
    StatusPrefix = 'BRAIN Codex '
    StopStyle = 'DecisionBlock'
    Capabilities = @{ Install = $true; Repair = $true; Uninstall = $true; VerificationStatus = 'Spec-validated'; Evidence = 'docs + simulation (no live run in repo)' }
    Events = @(
        @{ EventName = 'SessionStart'; Matcher = 'startup|resume|clear|compact'; Timeout = 15 },
        @{ EventName = 'PostToolUse'; Matcher = 'apply_patch|Edit|Write'; Timeout = 10 },
        @{ EventName = 'Stop'; Matcher = ''; Timeout = 30 },
        @{ EventName = 'SessionEnd'; Matcher = 'other'; Timeout = 3 }
    )
}
