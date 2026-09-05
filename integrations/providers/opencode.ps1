# OpenCode integration definition (Phase 3 adapter).
#
# OpenCode (Desktop and CLI) is driven by a local JS bridge plugin, NOT by
# hook JSON. Both flavours run the same opencode server, which auto-loads
# plugin files from the global plugins directory, so one integration covers
# both. The bridge shells out to brain-hook.ps1 -Provider opencode and reuses
# the existing Core state machine; no OpenCode-specific memory format exists.
#
# Evidence: opencode 1.18.27 CLI help + https://opencode.ai/docs/plugins/ +
# https://opencode.ai/docs/config/ + installed @opencode-ai/plugin@1.18.27
# type definitions (ground truth for hook/event names and SDK shapes).
@{
    Id = 'opencode'
    Name = 'OpenCode'
    DisplayName = 'OpenCode'
    ArtifactKind = 'PluginFile'
    PluginFileName = 'brain.js'
    PluginTemplateFile = 'opencode.brain-plugin.js'
    PluginManagedMarker = '// managed by BRAIN (brain.opencode.plugin)'
    ConfigRoots = @('~/.config/opencode')
    HandlerStyle = 'PluginBridge'
    HookIdPrefix = 'brain.opencode.'
    StatusPrefix = 'BRAIN OpenCode '
    StopStyle = 'HookSpecific'
    Capabilities = @{
        Install = $true
        Repair = $true
        Uninstall = $true
        ContextInjection = 'chat.message parts'
        SessionStart = 'session.created'
        SessionEnd = 'session.deleted'
        Stop = 'session.idle + appendPrompt'
        AutoSync = $true
        VerificationStatus = 'Spec-validated'
        Evidence = 'installed types + node harness + pwsh bridge (no live server run)'
    }
    Events = @(
        @{ EventName = 'session.created'; Matcher = ''; Timeout = 30 },
        @{ EventName = 'chat.message'; Matcher = ''; Timeout = 30 },
        @{ EventName = 'tool.execute.after'; Matcher = ''; Timeout = 10 },
        @{ EventName = 'session.idle'; Matcher = ''; Timeout = 30 },
        @{ EventName = 'session.deleted'; Matcher = ''; Timeout = 10 }
    )
}
