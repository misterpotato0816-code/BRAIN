# BRAIN

## What BRAIN is

BRAIN is a local store of short, curated work records for your coding projects. When you finish a piece of work with a supported AI coding assistant (Claude, Codex, OpenCode, Cursor, GitHub Copilot CLI, or Gemini CLI — see "Integrations"), a hook can ask the assistant to write a short summary in a fixed format. BRAIN keeps those summaries per project and, at the start of a later session, hands the most recent ones back to the assistant as background reading.

## What BRAIN is not

BRAIN is not an LLM and has no intelligence of its own. It does not run continuously and does not call any cloud service. The historical records it stores and injects are reference data only — they are explicitly marked as non-authoritative and are never treated as instructions, current facts, or commands by the assistant.

## Requirements

- Windows
- PowerShell 7 (`pwsh`)

## Install

Copy or clone this folder anywhere on disk, then decide which AI tools you
use. To see everything BRAIN knows about, run the read-only listing first:

```powershell
.\integrations\brain-setup.ps1 -Action Integrations
```

Each entry reports its verification status. Provider-level status stays
`Spec-validated` (spec + sandboxed simulation); capabilities proven live are
listed per integration below — no adapter claims a full live loop.

Install one integration at a time (recommended), or all enabled ones:

```powershell
.\integrations\brain-setup.ps1 -Action Install -Integration claude
.\integrations\brain-setup.ps1 -Action Install -Integration cursor
```

```powershell
.\integrations\brain-setup.ps1 -Action Install
```

Bare `Install` (no `-Integration`) converges **all enabled integrations** at
once — Codex, Claude, OpenCode, Cursor, Copilot CLI, and Gemini CLI unless
disabled (see "Provider selection" below). Each one changes only its own
artifact, always after a timestamped backup (see "Backup and restore"):

- Codex: `%USERPROFILE%\.codex\hooks.json`
- Claude: `%USERPROFILE%\.claude\settings.json`
- OpenCode: `%USERPROFILE%\.config\opencode\plugins\brain.js` (your
  `opencode.jsonc` is never edited)
- Cursor: `%USERPROFILE%\.cursor\hooks.json` (user-level only; project
  `.cursor/` and Rules are never touched)
- Copilot CLI: `%USERPROFILE%\.copilot\hooks\brain.json` (honors
  `COPILOT_HOME`; repository files are never touched)
- Gemini CLI: `%USERPROFILE%\.gemini\settings.json` (`GEMINI.md`,
  instructions, skills, and MCP config are never touched)

It adds BRAIN's hook entries to each file without touching your other
settings or hooks. If a file did not exist yet, it is created (a backup
marker records that it was absent, so `Restore` removes it again).

## First run / verify

```powershell
.\brain.ps1 version
.\integrations\brain-setup.ps1 -Action Status
```

`version` prints the BRAIN product version and the work-record format version. `Status` reports whether `pwsh` is available and how many BRAIN-managed hook entries exist for each provider and event, without changing anything.

## Registering a project

```powershell
.\brain.ps1 register -ProjectPath 'C:\Projects\Example'
```

`register` is the only command that adds a project to `config/projects.json`. Every other command (`init`, `collect`, `context`, `sync`) rejects unregistered projects. Once a project directory is registered, you can run BRAIN commands from that directory or from any subdirectory inside it — BRAIN always resolves back to the registered project root.

You may **not** register:

- a directory that is inside an already-registered project's directory
  (a subdirectory),
- a directory that contains an already-registered project (an ancestor of
  one),
- a trusted root (see below),
- a drive or volume root (e.g. `E:\`),
- the BRAIN root or anything inside it.

Re-registering the exact same path under the same id is harmless and just
reports `REGISTERED_ALREADY`; the same path under a different id, or the
same id for a different path, is rejected. The nesting bans are intentional:
merging two project trees into one memory (in either direction) defeats the
point of keeping each project's records separate.

## Automatic project registration

With the Codex/Claude hooks installed, a session whose working directory is inside a trusted root is registered and initialized automatically; manual `register`/`init` runs are not required. Trusted roots are configured in `config/trusted-roots.json`:

```json
{
  "format_version": "0.1",
  "trusted_roots": [
    "C:\\Projects"
  ]
}
```

Auto-registration applies only to unregistered directories under a trusted root. It never applies to the BRAIN root or anything inside it, to a trusted root itself, to paths outside every trusted root, or to any directory containing a reparse point (junction or symlink) between the trusted root and the working directory. Explicitly registered projects keep working regardless of trusted roots. A missing or invalid `config/trusted-roots.json` disables auto-registration. Hook failures always fail open — a BRAIN problem never blocks or breaks your AI session.

## Normal use

| Command | What it does |
|---|---|
| `register -ProjectPath <path> [-ProjectId <id>]` | Adds a project directory to the registry (optional custom id, lowercase letters/digits/`._-`). |
| `init -ProjectPath <path>` | Creates `.brain/` in the registered project if missing. |
| `collect -ProjectPath <path>` | Validates and copies new records from `.brain/outbox` into `store/raw`. |
| `context -ProjectPath <path> [-MaxRecords N] [-MaxContextBytes N]` | Regenerates `.brain/context.md` from the stored records (defaults: newest 10, 32 KiB). |
| `sync -ProjectPath <path>` | Runs `init`, `collect`, and `context` together. |
| `version` (or `-Version`) | Prints the BRAIN version, the record format version, and the BRAIN root. |

BRAIN writes only these paths inside a registered project:

```text
.brain/
  project.json
  outbox/
  context.md
```

Place work records based on `templates/work-record.md` directly in `.brain/outbox/`. Each record needs the required front matter and eight sections; each section needs one or more single-line bullets labeled `[Observed]`, `[Suspected]`, or `[Verified]`.

Collection behavior:

- Records are validated before collection.
- Raw records are stored byte-for-byte under `store/raw/<project-id>/<sha256>.md`.
- An existing raw record is never overwritten or deleted.
- Duplicate content is a no-op after its SHA-256 is verified.
- Outbox records are never moved or deleted.
- `context.md` is generated deterministically from recent validated raw records.
- A local single-writer lock prevents concurrent registry, raw, and context updates.
- Markdown content is never executed.
- Records containing private-key blocks, bearer authorization headers, or obvious secret assignments are rejected. Do not place credentials, tokens, cookies, private keys, or personal data in work records.

Context limits default to the newest 10 records and 32 KiB. Override them only when needed:

```powershell
.\brain.ps1 context -ProjectPath 'C:\Projects\Example' -MaxRecords 20 -MaxContextBytes 65536
```

## Update

```powershell
.\integrations\brain-setup.ps1 -Action Update
```

`Update` replaces BRAIN's hook entries in place. It recognizes BRAIN-managed handlers (including older `BRAIN v0.1 ...` handlers from a previous install) and replaces them, so repeated runs always converge to exactly one BRAIN handler per integration and event — it never creates duplicates. Everything else in your configuration files is left untouched. If nothing needs to change, `Update` reports `changed=false` and does not write or back up anything. Add `-Integration <id>` to update a single integration.

## Repair

```powershell
.\integrations\brain-setup.ps1 -Action Repair
```

`Repair` checks for common problems — missing `pwsh`, missing BRAIN files, an unreadable `projects.json` or `trusted-roots.json`, unreadable hook config files, legacy hook entries, duplicate BRAIN handlers, missing BRAIN handlers, and conflicting third-party files (e.g. a foreign `brain.js`) — and reports what it found. For anything it can safely fix (entries in a file it can parse and owns), it re-syncs that integration the same way `Update` does. Files it cannot parse are reported and skipped, never rewritten.

## Uninstall

```powershell
.\integrations\brain-setup.ps1 -Action Uninstall
```

This removes **only** BRAIN's own hook entries — from Codex/Claude hook configs
as well as the managed OpenCode plugin file (`plugins/brain.js`, only if it
starts with the BRAIN managed marker). It leaves every other setting and
every non-BRAIN hook entry exactly as it was. Add `-Integration <id>` to
uninstall a single integration.

It does **not** delete your memory data. The following are left in place:

- `config/projects.json` (your project registrations)
- `config/trusted-roots.json` (your trusted roots)
- `config/integrations.json` (your provider enable/disable choices)
- `store/raw` (all stored work records)
- each registered project's `.brain` directory

If you actually want to delete your memory data, remove these yourself — for example, delete `store/raw`, `config/projects.json`, and the `.brain` folder inside each project.

## Backup and restore

```powershell
.\integrations\brain-setup.ps1 -Action Backup
.\integrations\brain-setup.ps1 -Action Restore
```

`Install`, `Update`, `Repair`, and `Uninstall` all take a backup of a config file before changing it, named `<original file>.brain-backup-<yyyyMMdd-HHmmssfff>`. `Restore` finds the newest matching backup (or accepts an explicit `-CodexBackupPath`/`-ClaudeBackupPath` for those two integrations) and copies it back over the live file, taking a fresh safety backup of the current file first. If the backup records that the file did not exist, `Restore` removes the live file again.

These are **configuration backups only** — they back up your hook settings, not your BRAIN memory data. To back up your memory data, copy `store/raw` and `config/projects.json` yourself.

## Version

```powershell
.\brain.ps1 version
```

The BRAIN product version (in the `VERSION` file) and the work-record format version are tracked separately. The record format is still `0.1` — upgrading BRAIN does not change the shape of existing work records or require migrating anything in `store/raw`.

## Integrations (Codex / Claude / future providers)

BRAIN Core keeps no per-AI knowledge. Each AI development agent is described by
a small adapter definition in `integrations/providers/` (one file per
integration, e.g. `codex.ps1`, `claude.ps1`), discovered through the registry
in `lib/brain-integrations.ps1`. Adding a future agent (Kilo, Z Code, custom)
means adding one definition file plus its tests — Core files stay untouched.

```powershell
.\integrations\brain-setup.ps1 -Action Integrations
.\integrations\brain-setup.ps1 -Action Disable -Integration codex
.\integrations\brain-setup.ps1 -Action Enable -Integration claude
.\integrations\brain-setup.ps1 -Action Install -Integration claude
```

`Integrations` lists every known integration with its enabled flag, config
path, events, and verification status. Provider-level status stays
`Spec-validated`; capabilities proven live are listed per integration below
— no adapter claims a full live loop. `Enable`/`Disable` persist to `config/integrations.json`
(missing file means every known integration is enabled, so existing
installations keep working). `Install`, `Update`, and `Repair` skip disabled
integrations without touching their config files; `Uninstall`, `Backup`, and
`Restore` intentionally still process disabled integrations (removing BRAIN's
own entries and backing up configs is safe cleanup, never new wiring).
`Status` reports the enabled flag per integration. Unknown integration ids
are rejected with a clear
`Unknown integration: <id>. Known integrations: ...` error and never affect
other providers. The legacy `integrations/install-hooks.ps1` wrapper only
supports Codex/Claude Install and reports only those two — use
`brain-setup.ps1` for everything else.

## OpenCode (Desktop / CLI)

OpenCode is a file-based integration: both the Desktop app and the CLI run the
same opencode server, which auto-loads local plugin files from the global
plugins directory (`~/.config/opencode/plugins/`), so one integration covers
both flavours and your `opencode.jsonc` is never edited (OpenCode merges
configs instead of replacing them).

```powershell
.\integrations\brain-setup.ps1 -Action Install -Integration opencode
.\integrations\brain-setup.ps1 -Action Status -Integration opencode
.\integrations\brain-setup.ps1 -Action Uninstall -Integration opencode
```

Install copies a small bridge plugin (`brain.js`, marked as BRAIN-managed) into
the global plugins directory. At runtime the bridge calls back into
`brain-hook.ps1 -Provider opencode` and reuses the existing Core flows:

- `session.created` (+ lazy start on the first message, which also covers
  `--continue`/`--session` resume where OpenCode fires no event) resolves the
  project and appends `.brain/context.md` once to the next user message.
- `tool.execute.after` marks the session dirty.
- `session.idle` asks for a work record by pre-filling the TUI prompt
  (`appendPrompt`) with a toast nudge — nothing is ever submitted
  automatically, so the loop is impossible.
- `session.deleted` syncs a pending record if the agent already wrote it.

Only files starting with the BRAIN managed marker are ever overwritten or
deleted; sibling plugins and your own `brain.js` are left alone (reported as
`conflict-plugin:opencode`). Known limitation: OpenCode has no blocking
turn-end hook, so record requests are pre-filled rather than enforced, and a
resumed session only regains context on its next message.

Verification: spec-validated (sandboxed simulation against the installed
plugin API types; no live Desktop/CLI run in this repo).

## Cursor

Cursor is a hook-type integration using its native `hooks.json` format (flat
per-event command list). BRAIN manages the **user-level** file
(`~/.cursor/hooks.json`) only — project-level `.cursor/hooks.json` lives in
your repositories under version control and Cursor Rules are an instruction
surface, so BRAIN never touches either (historical records stay
non-authoritative reference data, never rules).

```powershell
.\integrations\brain-setup.ps1 -Action Install -Integration cursor
.\integrations\brain-setup.ps1 -Action Status -Integration cursor
.\integrations\brain-setup.ps1 -Action Uninstall -Integration cursor
```

Runtime behavior through the existing `brain-hook.ps1` flows:

- `sessionStart` resolves the project (via `workspace_roots`) and returns
  `additional_context` with the current `.brain/context.md`.
- `postToolUse` marks the session dirty (Write/Delete tools).
- `stop` returns `followup_message` with the work-record request, which Cursor
  submits as the next user message (bounded by BRAIN's own request limit and
  Cursor's `loop_limit`); once the agent writes the record, the next `stop`
  syncs silently.
- `sessionEnd` syncs a pending record if the agent already wrote it.

Known limitations: `stop` auto-submits the request as the next user message
(bounded by BRAIN's request cap and Cursor's `loop_limit` of 5); shell-driven
or subagent-mediated edits never dirty-mark (only Write/Delete tools do).

Verification: spec-validated overall; Install/Status/Uninstall/Restore,
`SessionStart`/context injection, `PostToolUse` dirty-mark, and `SessionEnd`
additionally live-verified 2026-09-04 (Desktop session + CLI `-p` runs).
`Stop`/record round-trip remains spec-validated only.

`Status` additionally reports `candidate_roots`, `selected_root`, and
`selection_reason` per integration so multi-candidate root resolution stays
inspectable. Tests and dry runs can redirect every file artifact with
`-SandboxDir <dir>` (precise overrides: `-ConfigPath` for hook JSON,
`-PluginPath` for plugin files).

## GitHub Copilot (CLI)

Copilot is a hook-type integration using the native Copilot CLI hooks format
(flat per-event entries with `powershell` + `timeoutSec`). BRAIN manages a
single user-level file (`~/.copilot/hooks/brain.json`; honored
`COPILOT_HOME` redirect included) — repository files, custom instructions,
skills, and MCP config are never touched (historical records stay
non-authoritative reference data, never standing instructions).

```powershell
.\integrations\brain-setup.ps1 -Action Install -Integration copilot
.\integrations\brain-setup.ps1 -Action Status -Integration copilot
.\integrations\brain-setup.ps1 -Action Uninstall -Integration copilot
```

Runtime behavior through the existing `brain-hook.ps1` flows:

- `SessionStart` resolves the project and returns `additionalContext` with
  the current `.brain/context.md`.
- `PostToolUse` marks the session dirty (create/edit tools).
- `Stop` (agentStop) returns `decision: block` with the work-record request,
  which the CLI submits as the next turn (bounded by BRAIN's own request
  limit and the CLI runaway guard); once the agent writes the record, the
  next stop syncs silently.
- `SessionEnd` syncs a pending record if the agent already wrote it.

Deliberately not registered: `preToolUse`/`permissionRequest` (command hooks
there are fail-closed — a hook crash would deny the tool — and BRAIN must
never break the session), prompt hooks, VS Code Chat hooks (separate Preview
system), JetBrains hooks (no official reference), and cloud-agent hooks
(repo-committed, Linux-only sandbox).

Known limitations: shell-driven or subagent-mediated edits never dirty-mark
(only create/edit tools do); the CLI must be installed for hooks to run.

Verification: spec-validated overall; Install/Status/Uninstall/Restore
additionally live-verified 2026-09-04 (CLI 1.0.82). Model lifecycle stays
spec-validated: the live CLI path is POLICY BLOCKED by the org, so no live
model session exists in this repo.

## Audit notes for Phase 7 (behavior intentionally unchanged)

- Bare `brain-setup.ps1 -Action Install` (no `-Integration`) converges **all
  enabled integrations** at once; there is no per-provider default scoping.
  This is the documented contract (see "Install" above), kept for backward
  compatibility: changing the default would silently strand existing users'
  other integrations. `Status`/`Integrations` always enumerate every known
  integration. If a future release wants Install to default to a subset
  (detected tools, explicit selection, first-run wizard), that is a deliberate
  behavior change with its own migration story — not an accident to fix here.

## Gemini CLI

Gemini CLI is a hook-type integration using its native hooks format (nested
per-event groups with millisecond `timeout`). BRAIN manages the user-level
`~/.gemini/settings.json` hooks only — project files, `GEMINI.md`,
instructions, skills, and MCP config are never touched (historical records
stay non-authoritative reference data, never standing instructions).

```powershell
.\integrations\brain-setup.ps1 -Action Install -Integration gemini-cli
.\integrations\brain-setup.ps1 -Action Status -Integration gemini-cli
.\integrations\brain-setup.ps1 -Action Uninstall -Integration gemini-cli
```

Runtime behavior through the existing `brain-hook.ps1` flows:

- `SessionStart` resolves the project and returns
  `hookSpecificOutput.additionalContext` with the current `.brain/context.md`.
- `AfterTool` marks the session dirty.
- `AfterAgent` returns `decision: deny` with the work-record request, which
  forces a retry turn carrying the request (bounded by BRAIN's own request
  limit and `stop_hook_active`); once the agent writes the record, the next
  turn syncs silently.
- `SessionEnd` syncs a pending record if the agent already wrote it
  (best-effort by CLI design).

Known limitations: `AfterTool` has no tool matcher (every tool dirties the
session; record requests stay bounded regardless), and `BeforeTool` is
deliberately unregistered (its deny output would block tools). Live run
2026-09-04 (CLI 0.58.0, API-key auth): `SessionStart` and `AfterTool` fire
with context injection and dirty-marking; `AfterAgent`/`SessionEnd` were not
invoked by the CLI in non-interactive (`-p`) runs, so the record loop there
relies on interactive sessions.

Verification: spec-validated overall; `SessionStart`/`AfterTool`/Install/
Status/Uninstall/Restore additionally live-verified 2026-09-04 (CLI 0.58.0).
`AfterAgent`/`SessionEnd`/record round-trip remain spec-validated only.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Hooks not firing | Run `-Action Status`; confirm `pwsh` is on `PATH` and the reported handler counts are 1 per event. |
| `Project is not registered` | Register the project directory (or a directory it lives under) with `brain.ps1 register`. |
| `... cannot be registered as a project` | You are trying to register an ancestor or a subdirectory of an existing project, a trusted root, a drive root, or the BRAIN root (or anything inside it) — see "Registering a project" above. |
| Context not appearing at session start | Check that `.brain/context.md` exists in the project; run `brain.ps1 sync -ProjectPath <path>` manually. |
| Stale or duplicate hook entries | Run `-Action Repair`. |
| `conflict-*` finding or skipped install | A third-party file owns the target name (e.g. your own `brain.js`). BRAIN never overwrites it — rename or remove it yourself if you want BRAIN to manage that slot. |
| `invalid-json` / unparseable config | `Repair`/`Uninstall` skip files they cannot parse instead of rewriting them. Fix or restore the file yourself, then re-run. |
| Unknown integration id | The error lists the known ids. Check spelling, or run `-Action Integrations` to enumerate. |
| Hook runs but nothing happens for a new tool | An unknown `-Provider` value is logged to the hook log and ignored (fail-open). Check `%LOCALAPPDATA%\BRAIN-v0.1\hook-state\brain-hook.log`. |
| Where is the hook log? | `%LOCALAPPDATA%\BRAIN-v0.1\hook-state\brain-hook.log` |

Hooks always fail open: if something goes wrong inside BRAIN, the hook exits successfully and your AI session continues unaffected.

## Privacy

BRAIN stores its records on your machine only and does not send anything anywhere by itself. However, when the hook injects historical context into Claude, Codex, or any other AI service at the start of a session, that context is sent to that service along with the rest of your prompt, just like anything else you type.

The work-record validator rejects records containing obvious private-key blocks, bearer tokens, and key-like assignments, but this is a simple pattern check, not a guarantee — it will not catch every possible secret. Do not put credentials, tokens, or personal data in work records.

## License

License: Proprietary / Source Available
Free to use, source available, redistribution prohibited.

BRAIN is published as Source Available / Proprietary software by Mostly Works. It is not Open Source Software. Use and source inspection are free; unauthorized redistribution, resale, and distribution of modified versions are prohibited. See `LICENSE` (English reference translation) and `LICENSE.ja.md` (the authoritative Japanese original). Contact: brainbucket000@gmail.com.

## Tests

```powershell
pwsh -NoProfile -File .\tests\run-all.ps1
```

Every test runs sandboxed: `run-all` assigns each test file a fresh
`BRAIN_TEST_SANDBOX` directory, and `brain-setup`/`brain-hook` force all
resolved integration targets below it while the gate is set — a new
integration can never leak into the real user profile even if a test forgets
every path override. Any write that would escape the sandbox fails closed with
`TEST SAFETY VIOLATION` before touching disk. `run-all` additionally snapshots
canaries (`~/.claude`, `~/.codex`, `~/.config/opencode`, `~/.cursor`, BRAIN
`config` and `store/raw`, read-only) before/after each test and fails the run
on any difference. Precise per-target overrides remain available:
`-SandboxDir` (whole run), `-ConfigPath` (hook JSON), `-PluginPath`
(plugin files).
