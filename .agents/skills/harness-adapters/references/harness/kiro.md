# Kiro CLI

Verified 2026-09-01 on Kiro CLI 2.18.0 (kiro-cli-chat build).
The router owns Kiro's task-kind boundary: crewmate and scout only.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `kiro-cli` at `~/.local/bin/kiro-cli`, symlink to `~/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli`; the actual chat engine is sibling `kiro-cli-chat` (launched via `kiro-cli chat ...`). The `kiro-cli` process name is stable and survives updates (fixed app-bundle path, unlike Cursor's versioned install). |
| Launch | `kiro-cli chat --agent <name> --model <model> --trust-all-tools --tui '<brief>'`. The positional `[INPUT]` auto-submits as the first prompt. `--tui` forces the interactive TUI. `--trust-all-tools` suppresses all tool-permission prompts after a one-time global consent dialog (accepted via "Yes, and don't ask again"). |
| Models | `--model <model>`; authoritative discovery: `kiro-cli chat --list-models --format json`. Provider `kiro` (AmazonQ/Bedrock backend). |
| Busy | Hook-driven push source (`kiro-hook`, same shape as `claude-hook`): `userPromptSubmit` opens, `stop` closes at every turn boundary. `stop` does NOT fire on interrupt (same gap as Claude). Hooks ride the workspace-local agent config at `<worktree>/.kiro/agents/<name>.json`. |
| Exit | `/quit` followed by Enter; `/exit` is a synonym. |
| Interrupt | Single Escape cancels the running turn; composer returns empty (no restored text, no Ctrl+U needed). |
| Skill | No `/skill` command. Standing instructions ride the agent config's `prompt` (`file://` URI) and `resources` (glob) fields. For no-mistakes delivery, the spawn generates a procedure file from `no-mistakes axi` help output at `.kiro/agents/fm-<id>-nm-procedure.md` and points the agent config's `prompt` at it via `file://` URI; the worker drives the pipeline through `no-mistakes axi` shell commands. When `no-mistakes` is absent from PATH the procedure file is silently skipped. |
| Tools | The agent config must include `"tools": ["*"]`. Kiro-cli 2.18.0 grants **zero** tools when the `tools` field is omitted, so the worker cannot read, write, or run shell commands without it. Verified 2026-09-01 with controlled probes: config without `tools` produced `Tool validation failed: No tool with "read" is found`; byte-identical config with `"tools": ["*"]` succeeded. |
| Resume | `--resume-id <session-id>` or `--resume` (most recent). Session IDs are UUID-4, available from hook payloads and `/session-id`. |
| Autonomy | `--trust-all-tools` suppresses all tool-permission prompts. |
| Trust | `--trust-all-tools` triggers a three-option consent dialog ("No, exit" preselected, "Yes, I accept", "Yes, and don't ask again"); globally suppressed on this machine. |
| Marker | `KIRO_SESSION_ID` (UUID, always present in tool subprocesses). Kiro does NOT clear inherited `CLAUDECODE`, `CURSOR_AGENT`, or other foreign markers, so detection tests kiro before claude in `../../../bin/fm-harness.sh` and spawn clears foreign markers at the launch boundary. |
| Composer | Bare row, no border, no prompt glyph. Idle placeholder `ask a question or describe a task` in RGB(158,158,158), luminance ~158 (above ghost threshold 128). Mid-turn `Kiro is working` text in same color. |
| Effort | `--effort <low\|medium\|high\|xhigh\|max>`, maps 1:1 with firstmate's shared vocabulary. No validation (invalid values silently accepted). |

## Workspace-local agent config

Hooks, prompt, and resources live in `<worktree>/.kiro/agents/<name>.json`.
`--agent <name>` selects the config when kiro is launched from that worktree as cwd.
No global hook installation is needed (unlike grok's guarded global hook).
No trust grant is needed for workspace-local agent hooks (unlike grok's project hook trust).
Hook commands are fire-and-forget; exit code does not block or influence the turn.

## Foreign marker inheritance

Kiro does NOT clear inherited environment variables.
`CLAUDECODE=1`, `CURSOR_AGENT=1`, `AI_AGENT`, and all CLAUDE_* variables survive into kiro tool subprocesses.
Detection in `../../../bin/fm-harness.sh` tests `KIRO_SESSION_ID` before `CLAUDECODE` (same precedence strategy as cursor before claude).
`../../../bin/fm-spawn.sh` clears `CLAUDECODE`, `CURSOR_AGENT`, `CURSOR_INVOKED_AS`, `AI_AGENT`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION`, `GROK_AGENT`, `PI_CODING_AGENT`, and `FM_PI_HARNESS` at the launch boundary.

## Maturity and primary limit

Kiro CLI 2.18.0 is verified for crewmate and scout work only.
It has no primary supervision protocol (no `asyncRewake`, no hook-driven continuation).
It has no secondmate contract (no primary turn-end integration).
It is outside the primary guard integrations in `../../../docs/turnend-guard.md`.
