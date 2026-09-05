# Gemini CLI integration definition (Phase 6 adapter).
#
# Scope: Gemini CLI user-level hooks ONLY (DisplayName says so). Gemini Code
# Assist IDE extensions expose no hooks/lifecycle surface, JetBrains hooks
# are Preview without an official reference, and cloud/API agents run in a
# remote sandbox unreachable from this machine. MCP/skills are model-invoked
# (non-deterministic) and GEMINI.md/instructions would promote historical
# reference data to standing orders, which PROJECT_PURPOSE.md forbids.
#
# The CLI hooks contract (geminicli.com/docs/hooks + hooks/reference, fetched
# 2026) uses PascalCase event names with snake_case payloads including
# hook_event_name/session_id/cwd, a nested {matcher?, hooks:[...]} shape with
# millisecond `timeout`, additive merge across sources, and fail-open
# timeouts. BeforeTool is DELIBERATELY not registered: its deny/block output
# prevents tool execution, and BRAIN must never break the session. AfterTool
# dirty-marking covers the record loop. There is no synchronous Stop hook;
# AfterAgent (decision deny + reason forces a retry turn, bounded by BRAIN's
# own request limit and stop_hook_active) is the documented turn-end channel.
#
# Evidence: official Gemini CLI docs above; payload shapes mirror the
# documented examples. Live runs 2026-09-04 covered Install/Status/Uninstall/
# Restore plus SessionStart, context injection, and AfterTool dirty-marking
# against CLI 0.58.0 (AfterAgent/SessionEnd/record loop stays simulated).
# AfterTool carries no matcher: the exact runtime tool-name vocabulary is not
# verifiable without a live CLI, and dirty-marking is cheap (record requests
# stay bounded by MaxRecordRequests). A wrong narrow matcher would silently
# drop material turns, which is worse than extra dirty marks.
@{
    Id = 'gemini-cli'
    Name = 'GeminiCli'
    DisplayName = 'Gemini CLI'
    ArtifactKind = 'HookJson'
    HookSchema = 'ClaudeNested'
    ConfigRoots = @('~/.gemini')
    ConfigFileName = 'settings.json'
    HandlerStyle = 'GeminiCommand'
    HookIdPrefix = 'brain.gemini-cli.'
    StatusPrefix = 'BRAIN Gemini CLI '
    StopStyle = 'GeminiNative'
    SessionIdFields = @('session_id', 'sessionId')
    CwdFields = @('cwd')
    Capabilities = @{
        Install = $true
        Repair = $true
        Uninstall = $true
        ContextInjection = 'SessionStart additionalContext'
        SessionStart = 'SessionStart'
        SessionEnd = 'SessionEnd'
        Stop = 'AfterAgent deny-retry'
        PostToolUse = 'AfterTool dirty-mark'
        AutoSync = $true
        VerificationStatus = 'Spec-validated'
        Evidence = 'docs + simulation; live Install/Status/Uninstall/Restore 2026-09-04; live CLI 0.58.0 via API key 2026-09-04: SessionStart+AfterTool fired, context injected, write_file/read_file dirty-marked; AfterAgent/SessionEnd NOT invoked by CLI in -p mode (upstream); individual OAuth unsupported (browser auth ok, CLI rejected twice)'
        LiveVerified = @('Install', 'Status', 'Uninstall', 'Restore', 'SessionStart', 'ContextInjection', 'AfterTool')
    }
    Events = @(
        @{ EventName = 'SessionStart'; Matcher = ''; Timeout = 15 },
        @{ EventName = 'AfterTool'; Matcher = ''; Timeout = 10 },
        @{ EventName = 'AfterAgent'; Matcher = ''; Timeout = 30 },
        @{ EventName = 'SessionEnd'; Matcher = ''; Timeout = 10 }
    )
}
