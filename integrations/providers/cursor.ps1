# Cursor integration definition (Phase 4 adapter).
#
# Cursor exposes native command hooks via hooks.json (user level:
# ~/.cursor/hooks.json). The JSON dialect is a flat per-event command list,
# unlike the nested Claude/Codex shape, and is declared via HookSchema.
# Input fields also differ (conversation_id, workspace_roots[]), declared via
# the alias lists and resolved by generic Core code. Output shapes follow the
# official Cursor contract: {additional_context} on sessionStart,
# {followup_message} on stop (auto-submitted as the next user message,
# bounded by BRAIN's own MaxRecordRequests and Cursor's loop_limit).
#
# Evidence: https://cursor.com/docs/agent/hooks (events, matchers, timeouts,
# exit codes, config locations) + .../reference/third-party-hooks (response
# compatibility). Payload shapes mirror the documented examples; live runs
# 2026-09-04 covered Install/Status/Uninstall/Restore, SessionStart, context
# injection, PostToolUse dirty-mark, and SessionEnd (Stop/record loop stays
# simulated).
#
# Deliberately NOT managed: project-level .cursor/hooks.json (lives in user
# repos under version control) and Cursor Rules (instruction surface; BRAIN
# historical records must stay non-authoritative reference data per
# PROJECT_PURPOSE.md and must never be installed as rules/commands).
@{
    Id = 'cursor'
    Name = 'Cursor'
    DisplayName = 'Cursor'
    ArtifactKind = 'HookJson'
    HookSchema = 'CursorFlat'
    ConfigRoots = @('~/.cursor')
    ConfigFileName = 'hooks.json'
    HandlerStyle = 'FlatCommand'
    HookIdPrefix = 'brain.cursor.'
    StatusPrefix = 'BRAIN Cursor '
    StopStyle = 'CursorNative'
    StopLoopLimit = 5
    SessionIdFields = @('session_id', 'conversation_id')
    CwdFields = @('cwd', 'workspace_roots')
    Capabilities = @{
        Install = $true
        Repair = $true
        Uninstall = $true
        ContextInjection = 'sessionStart additional_context'
        SessionStart = 'sessionStart'
        SessionEnd = 'sessionEnd'
        Stop = 'stop followup_message'
        AutoSync = $true
        PostToolUse = 'postToolUse dirty-mark'
        VerificationStatus = 'Spec-validated'
        Evidence = 'docs + simulation; live Install/Status/Uninstall/Restore; live cursor-agent -p 2026-09-04: SessionStart+context injection, PostToolUse Write dirty-mark, SessionEnd observed (Stop not invoked by runner in -p mode)'
    }
    Events = @(
        @{ EventName = 'sessionStart'; Matcher = ''; Timeout = 15 },
        @{ EventName = 'postToolUse'; Matcher = 'Write|Delete'; Timeout = 10 },
        @{ EventName = 'stop'; Matcher = ''; Timeout = 30 },
        @{ EventName = 'sessionEnd'; Matcher = ''; Timeout = 10 }
    )
}
