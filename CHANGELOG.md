# Changelog

## 0.2.1

- Reject obvious secret assignments and bearer headers inside labeled record bullets. Revalidate stored records before context injection, preserving raw files.
- Continue collecting valid records when an outbox file is incomplete or invalid. Only clear pending hook state after the expected record itself was accepted.
- Clear successfully recovered pending records at session resume so subsequent work receives a new record request.
- Generate valid project IDs for directory names beginning with `_` or `.`.
- Correct the PowerShell invocation used by Copilot hooks.
- Limit the legacy installer to its documented Codex/Claude scope and honor sandbox-only path overrides.
- Give OpenCode context parts their required unique part, session, and message IDs.
- Add regression coverage and a Windows CI run. Provider-level live verification remains limited as described in the README; automated test results do not imply a full live model round trip.

The work-record format remains 0.1. No registry or raw-record migration is required.
