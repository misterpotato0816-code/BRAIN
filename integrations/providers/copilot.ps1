# GitHub Copilot CLI integration definition (Phase 5 adapter).
#
# Scope: Copilot CLI user-level hooks ONLY (DisplayName says so). VS Code
# Chat hooks are a separate Preview system with different merge semantics,
# JetBrains hooks are Preview without an official reference, and cloud-agent
# hooks require repo-committed files plus a Linux sandbox with no access to
# this machine. MCP/skills are model-invoked (non-deterministic) and custom
# instructions would promote historical reference data to standing orders,
# which PROJECT_PURPOSE.md forbids.
#
# The CLI hooks contract (docs.github.com/en/copilot/reference/hooks-reference)
# uses PascalCase event names with snake_case payloads including
# hook_event_name/session_id/cwd, a flat per-event entry list with `powershell`
# + `timeoutSec` keys, additive merge across sources, and fail-open timeouts.
# preToolUse/permissionRequest are DELIBERATELY not registered: command
# preToolUse is fail-closed (a hook crash denies the tool), and BRAIN must
# never break the session. postToolUse dirty-marking covers the record loop.
#
# Evidence: official hooks reference + CLI customize guide (fetched 2026);
# payload shapes mirror the documented examples. Live runs 2026-09-04 covered
# Install/Status/Uninstall/Restore against CLI 1.0.82; the model path is
# POLICY BLOCKED by the org, so no live model session exists.
# Windows-only scope (BRAIN requires Windows): only the `powershell` command
# key is emitted. Unix hosts would need `bash`/`command` fallbacks, which are
# deliberately absent here.
#
# Dirty-marking covers file-writing tools only (create|edit). Shell-driven or
# subagent-mediated edits can miss marking, exactly like the Claude/Codex
# adapters which match Edit|Write but not shell tools; widening would trade
# precision for noise on every read-only turn.
@{
    Id = 'copilot'
    Name = 'Copilot'
    DisplayName = 'GitHub Copilot (CLI)'
    ArtifactKind = 'HookJson'
    HookSchema = 'CopilotCli'
    ConfigRoots = @('~/.copilot')
    # COPILOT_HOME is the analog of ~/.copilot (the home dir), NOT the hooks
    # dir: hooks live in $COPILOT_HOME\hooks\. Sub stays empty so the shared
    # ConfigFileName ('hooks/brain.json') resolves exactly there.
    ConfigRootEnv = @{ Var = 'COPILOT_HOME'; Sub = '' }
    ConfigFileName = 'hooks/brain.json'
    HandlerStyle = 'CopilotCommand'
    HookIdPrefix = 'brain.copilot.'
    StatusPrefix = 'BRAIN Copilot '
    StopStyle = 'CopilotNative'
    SessionIdFields = @('session_id', 'sessionId')
    CwdFields = @('cwd')
    Capabilities = @{
        Install = $true
        Repair = $true
        Uninstall = $true
        ContextInjection = 'sessionStart additionalContext'
        SessionStart = 'sessionStart'
        SessionEnd = 'sessionEnd'
        Stop = 'agentStop decision-block (Stop entry)'
        PostToolUse = 'postToolUse dirty-mark'
        AutoSync = $true
        VerificationStatus = 'Spec-validated'
        Evidence = 'docs + simulation; live Install/Status/Uninstall/Restore 2026-09-04 (CLI blocked by org policy, no live session)'
    }
    Events = @(
        @{ EventName = 'SessionStart'; Matcher = ''; Timeout = 15 },
        @{ EventName = 'PostToolUse'; Matcher = 'create|edit'; Timeout = 10 },
        @{ EventName = 'Stop'; Matcher = ''; Timeout = 30 },
        @{ EventName = 'SessionEnd'; Matcher = ''; Timeout = 10 }
    )
}
