// managed by BRAIN (brain.opencode.plugin) - do not edit by hand.
// Safe to delete via: integrations\brain-setup.ps1 -Action Uninstall -Integration opencode
//
// BRAIN memory bridge for OpenCode (Desktop and CLI share this mechanism:
// both run the same opencode server, which auto-loads local plugin files from
// the global plugins directory - no config-file edit is required).
//
// How it works:
// - session.created  -> runs brain-hook.ps1 SessionStart, caches the returned
//                       historical context, and appends it once to the next
//                       user message via the chat.message hook.
// - chat.message     -> lazy SessionStart for sessions the plugin never saw
//                       created (e.g. --continue/--session resume fires no bus
//                       event), then appends cached context exactly once.
// - tool.execute.after -> fire-and-forget PostToolUse (marks session dirty).
// - session.idle     -> runs brain-hook.ps1 Stop. When the hook requests a
//                       work record, the request text is pre-filled into the
//                       TUI prompt (appendPrompt) with a toast nudge. Nothing
//                       is submitted automatically, so this can never loop.
// - session.deleted  -> runs brain-hook.ps1 SessionEnd (syncs a pending
//                       record if the agent already wrote it) and drops state.
//
// Every failure is fail-open: a BRAIN problem never blocks the session.

import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";

const BRAIN_ROOT = "__BRAIN_ROOT__";
const BRAIN_HOOK = "__BRAIN_HOOK_PATH__";
const BRAIN_PWSH = "__BRAIN_PWSH_PATH__";

function defaultRunBridge(eventName, sessionID, cwd) {
  const payload = JSON.stringify({
    hook_event_name: eventName,
    session_id: sessionID,
    cwd: cwd,
  });
  const result = spawnSync(
    BRAIN_PWSH,
    ["-NoProfile", "-NonInteractive", "-File", BRAIN_HOOK, "-Provider", "opencode", "-BrainRoot", BRAIN_ROOT],
    { input: payload, encoding: "utf8", timeout: 30000 }
  );
  const stdout = result && result.stdout ? result.stdout.toString() : "";
  return stdout.trim();
}

// Accepts the hook's HookSpecific output shape
// ({hookSpecificOutput:{additionalContext}}) as well as the DecisionBlock
// shape ({reason}) so record requests are never silently dropped because of
// an output-shape mismatch. Returns the request text or "".
function parseRecordRequest(stdout) {
  if (!stdout) return "";
  let parsed = null;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return "";
  }
  if (!parsed || typeof parsed !== "object") return "";
  const specific = parsed.hookSpecificOutput;
  if (specific && typeof specific.additionalContext === "string" && specific.additionalContext.indexOf("BRAIN work record") >= 0) {
    return specific.additionalContext;
  }
  if (typeof parsed.reason === "string" && parsed.reason.indexOf("BRAIN work record") >= 0) {
    return parsed.reason;
  }
  return "";
}

function parseSessionContext(stdout) {
  if (!stdout) return "";
  let parsed = null;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return "";
  }
  if (!parsed || typeof parsed !== "object") return "";
  const specific = parsed.hookSpecificOutput;
  if (specific && typeof specific.additionalContext === "string" && specific.additionalContext.length > 0) {
    return specific.additionalContext;
  }
  return "";
}

export const BrainPlugin = async (ctx, deps) => {
  const client = ctx.client;
  const baseDirectory = ctx.directory;
  const injected = deps && deps.runBridge ? deps.runBridge : defaultRunBridge;

  const startedSessions = new Set();
  const pendingContext = new Map();
  const recordRequested = new Set();

  async function logDebug(message) {
    try {
      await client.app.log({ body: { service: "brain", level: "debug", message: message } });
    } catch {
      // Logging must never break the session.
    }
  }

  function sessionDir(props) {
    if (props && typeof props.directory === "string" && props.directory) return props.directory;
    if (props && typeof props.cwd === "string" && props.cwd) return props.cwd;
    if (props && props.info && typeof props.info.directory === "string" && props.info.directory) return props.info.directory;
    return baseDirectory;
  }

  async function bridgeStart(sessionID, cwd) {
    let stdout = "";
    try {
      stdout = await injected("SessionStart", sessionID, cwd);
    } catch (err) {
      await logDebug("SessionStart bridge failed: " + (err && err.message ? err.message : String(err)));
      return;
    }
    const contextText = parseSessionContext(stdout);
    if (contextText) pendingContext.set(sessionID, contextText);
  }

  return {
    event: async ({ event }) => {
      try {
        if (!event || typeof event.type !== "string") return;
        const props = event.properties || {};
        const sessionID =
          (typeof props.sessionID === "string" && props.sessionID) ||
          (props.info && typeof props.info.id === "string" && props.info.id) ||
          (typeof props.sessionId === "string" && props.sessionId) ||
          "";
        if (!sessionID) return;

        if (event.type === "session.created") {
          // The factory can evaluate more than once per process, so guard
          // against double SessionStart side effects.
          if (startedSessions.has(sessionID)) return;
          startedSessions.add(sessionID);
          await bridgeStart(sessionID, sessionDir(props));
        } else if (
          event.type === "session.idle" ||
          (event.type === "session.status" && props.status && props.status.type === "idle")
        ) {
          let stdout = "";
          try {
            stdout = await injected("Stop", sessionID, sessionDir(props));
          } catch (err) {
            await logDebug("Stop bridge failed: " + (err && err.message ? err.message : String(err)));
            return;
          }
          const request = parseRecordRequest(stdout);
          if (!request) {
            // Synced (or nothing pending): a future dirty cycle may ask again.
            recordRequested.delete(sessionID);
          } else if (!recordRequested.has(sessionID)) {
            recordRequested.add(sessionID);
            try {
              await client.tui.appendPrompt({ body: { text: request } });
            } catch (err) {
              await logDebug("appendPrompt failed: " + (err && err.message ? err.message : String(err)));
            }
            try {
              await client.tui.showToast({
                body: { title: "BRAIN", message: "Work record requested - prompt pre-filled.", variant: "info" },
              });
            } catch {
              // Headless/serve mode has no TUI; the pre-filled prompt is
              // best-effort and must not fail the session.
            }
          }
        } else if (event.type === "session.deleted") {
          try {
            await injected("SessionEnd", sessionID, sessionDir(props));
          } catch (err) {
            await logDebug("SessionEnd bridge failed: " + (err && err.message ? err.message : String(err)));
          }
          startedSessions.delete(sessionID);
          pendingContext.delete(sessionID);
          recordRequested.delete(sessionID);
        }
      } catch {
        // Fail open.
      }
    },

    "chat.message": async (input, output) => {
      try {
        const sessionID = input && input.sessionID;
        if (!sessionID) return;
        // Covers resumed sessions (no session.created fires on resume) and
        // whichever of session.created/chat.message arrives first.
        if (!startedSessions.has(sessionID)) {
          startedSessions.add(sessionID);
          await bridgeStart(sessionID, baseDirectory);
        }
        const contextText = pendingContext.get(sessionID);
        if (contextText) {
          // chat.message receives fully identified TextParts. OpenCode saves
          // newly appended parts without assigning these fields afterwards.
          const messageID = output && output.message && output.message.id;
          if (typeof messageID !== "string" || !messageID || !Array.isArray(output.parts)) return;
          output.parts.push({
            id: "prt_" + randomUUID().replace(/-/g, ""),
            sessionID,
            messageID,
            type: "text",
            text: contextText,
            synthetic: true,
          });
          pendingContext.delete(sessionID);
        }
      } catch {
        // Fail open: never block message admission.
      }
    },

    "tool.execute.after": async (input) => {
      try {
        if (input && input.sessionID) {
          await injected("PostToolUse", input.sessionID, baseDirectory);
        }
      } catch {
        // Fail open.
      }
    },
  };
};
