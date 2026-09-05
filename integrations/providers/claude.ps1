# Claude integration definition (Phase 2 adapter).
# Handler JSON shape must stay byte-compatible with Phase 1:
# command = pwsh path + args array, statusMessage "BRAIN Claude <Event>",
# brain_hook_id "brain.claude.<Event>".
@{
    Id = 'claude'
    Name = 'Claude'
    DisplayName = 'Claude'
    ConfigRelativePath = '.claude\settings.json'
    HandlerStyle = 'ClaudeArgsArray'
    HookIdPrefix = 'brain.claude.'
    StatusPrefix = 'BRAIN Claude '
    StopStyle = 'HookSpecific'
    Capabilities = @{ Install = $true; Repair = $true; Uninstall = $true; VerificationStatus = 'Spec-validated'; Evidence = 'docs + simulation (no live run in repo)' }
    Events = @(
        @{ EventName = 'SessionStart'; Matcher = 'startup|resume|clear|compact'; Timeout = 15 },
        @{ EventName = 'PostToolUse'; Matcher = 'Edit|Write|NotebookEdit'; Timeout = 10 },
        @{ EventName = 'Stop'; Matcher = ''; Timeout = 30 },
        @{ EventName = 'SessionEnd'; Matcher = 'clear|resume|logout|prompt_input_exit|other'; Timeout = 10 }
    )
}
