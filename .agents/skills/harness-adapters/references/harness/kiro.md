# Kiro CLI

Verified 2026-09-02 on Kiro CLI 2.18.0 with the V3 agent engine (KAS 0.38.7), which is the engine firstmate launches.
Facts unchanged from the 2026-09-01 V2 verification are carried forward and marked where the two engines differ.
The router owns Kiro's task-kind boundary: crewmate and scout only.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `kiro-cli` at `~/.local/bin/kiro-cli`, symlink to `~/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli`; the actual chat engine is sibling `kiro-cli-chat` (launched via `kiro-cli chat ...`). The `kiro-cli` process name is stable and survives updates (fixed app-bundle path, unlike Cursor's versioned install). |
| Launch | `kiro-cli chat --agent-engine v3 --agent <name> --model <model> --trust-all-tools --tui '<brief>'`. The positional `[INPUT]` auto-submits as the first prompt. `--tui` forces the interactive TUI. `--trust-all-tools` suppresses all tool-permission prompts after a one-time global consent dialog (accepted via "Yes, and don't ask again"). `--v3` is the shorter vendor-promoted alias for the same engine selection; `../../../bin/fm-spawn.sh` owns which form the launch uses and why. `--mode <default\|spec>` is V3-only and unused. |
| Models | `--model <model>`; authoritative discovery: `kiro-cli chat --list-models --format json`. Provider `kiro` (AmazonQ/Bedrock backend). The V3 model list, ids, and rate multipliers are identical to V2's, and per-turn credit cost is equivalent. |
| Busy | Hook-driven push source (`kiro-hook`, same shape as `claude-hook`): `userPromptSubmit` opens, `stop` closes at every turn boundary. `stop` does NOT fire on interrupt (same gap as Claude) and no hook fires when the agent is killed; see "Interrupt and kill" below. Hooks ride the workspace-local agent config at `<worktree>/.kiro/agents/<name>.json`. V3 reports PascalCase event names in hook payloads (`UserPromptSubmit`, `Stop`) but accepts the camelCase config keys firstmate writes, and registering both spellings fires each hook twice. Session ids in V3 payloads carry a `sess_` prefix (`sess_<uuid4>`); V2 ids are bare UUID-4. |
| Exit | `/quit` followed by Enter; `/exit` is a synonym. `/quit` fires NO hooks (no `Stop`, no `SessionEnd`). |
| Interrupt | Single Escape cancels the running turn, and Ctrl+C cancels equivalently; composer returns empty (no restored text, no Ctrl+U needed). Under V3 the interrupt also kills the shell child and its whole subprocess tree. |
| Skill | No `/skill` command. Standing instructions ride the agent config's `prompt` (`file://` URI) and `resources` (glob) fields. For no-mistakes delivery, the spawn generates a procedure file from `no-mistakes axi` help output at `.kiro/agents/fm-<id>-nm-procedure.md` and points the agent config's `prompt` at it via `file://` URI; the worker drives the pipeline through `no-mistakes axi` shell commands. When `no-mistakes` is absent from PATH the procedure file is silently skipped. |
| Tools | The agent config must include `"tools": ["*"]`. Kiro-cli 2.18.0 grants **zero** tools when the `tools` field is omitted, so the worker cannot read, write, or run shell commands without it. Verified 2026-09-01 with controlled probes: config without `tools` produced `Tool validation failed: No tool with "read" is found`; byte-identical config with `"tools": ["*"]` succeeded. |
| Resume | `--resume-id <session-id>` or `--resume` (most recent). Session ids come from hook payloads and `/session-id`. V2 and V3 keep separate session stores, so a session started on one engine is not resumable on the other. |
| Autonomy | `--trust-all-tools` suppresses all tool-permission prompts. |
| Trust | `--trust-all-tools` triggers a three-option consent dialog ("No, exit" preselected, "Yes, I accept", "Yes, and don't ask again"); globally suppressed on this machine. |
| Marker | `KIRO_VERSION`, `KIRO_CHAT_CLI_BIN` (both engines), and `KIRO_AGENT_ENGINE=kas` (V3 only). `KIRO_SESSION_ID` was the V2 marker and is GONE from V3, so detection accepts any of the three above instead of depending on one vendor variable. Kiro does NOT clear inherited `CLAUDECODE`, `CURSOR_AGENT`, or other foreign markers under either engine, so detection tests kiro before claude in `../../../bin/fm-harness.sh` and spawn clears foreign markers at the launch boundary. |
| Composer | Bare row, no border, no prompt glyph. Idle placeholder `ask a question or describe a task` in RGB(158,158,158), luminance ~158 (above ghost threshold 128). Mid-turn `Kiro is working` text in same color. Identical under V3, so `../../../bin/fm-composer-lib.sh` needs no engine-specific shape. |
| Effort | `--effort <low\|medium\|high\|xhigh\|max>`, maps 1:1 with firstmate's shared vocabulary. No validation (invalid values silently accepted). |

## Interrupt and kill

| Event | V3 behavior | V2 behavior |
|---|---|---|
| Escape or Ctrl+C during a shell tool | The shell child and its entire subprocess tree die within a second (verified twice with `sleep 300`) | The shell children are orphaned and keep running; each occurrence needed a manual kill |
| Escape or Ctrl+C, hook signal | No `Stop`, no `StopFailure`, no interrupt event. When a tool was active, `PostToolUse` fires with `tool_response` containing `Exit Code: -1`. An interrupt during model thinking fires nothing at all | No hook and no signal of any kind |
| SIGTERM | No hook. Shell children are cleaned up; the KAS node process can orphan to PID 1 | No hook. Shell children orphaned |
| SIGKILL | No hook. Shell children and the whole process group die | No hook. Shell children orphaned |

The child-cleanup row is the reason firstmate launches V3: an orphan that inherits the tool's output pipe wedges the worker indefinitely, and that cost three manual interventions on 2026-09-01.

**Two gaps remain open under V3 and are NOT addressed by adopting it.**
The `stop` hook still does not fire on interrupt, so a busy record opened by `userPromptSubmit` is not closed by cancelling the turn.
No hook of any kind fires when the agent process is killed, so a killed worker's busy record keeps reporting work in progress.
Reconciling recorded busy state against live agent presence is the complete fix for both; nothing in the hook surface of either engine can be.
V3's `PostToolUse` cancel marker is a partial signal only, deliberately unused by `../../../bin/fm-busy-lib.sh` because busy state is a turn-scoped open/close contract and the marker is silent for an interrupt during thinking.

## Workspace-local agent config

Hooks, prompt, and resources live in `<worktree>/.kiro/agents/<name>.json`.
`--agent <name>` selects the config when kiro is launched from that worktree as cwd.
No global hook installation is needed (unlike grok's guarded global hook).
No trust grant is needed for workspace-local agent hooks (unlike grok's project hook trust).
Hook commands are fire-and-forget; exit code does not block or influence the turn.
V3 adds `/upgrade-agent` for migrating a V2 agent config to a shared V2+V3 format; firstmate generates its config fresh per task and never needs it.

## KAS engine process shape

V3 runs the Kiro Agent Server as separate child processes: `kiro-cli` -> `kiro-cli-chat` -> `bun` (KAS) -> `node` (agent server).
V2's tree is just `kiro-cli` -> `kiro-cli-chat`.
The node server adds roughly 230 MB RSS per worker, which matters when sizing a fleet on a memory-constrained machine but does not change credit cost.
A SIGTERM to `kiro-cli` can leave that node process orphaned to PID 1 even though the shell children are cleaned up.

## Foreign marker inheritance

Kiro does NOT clear inherited environment variables under either engine.
`CLAUDECODE=1`, `CURSOR_AGENT=1`, `AI_AGENT`, and all CLAUDE_* variables survive into kiro tool subprocesses.
Detection in `../../../bin/fm-harness.sh` tests kiro's own markers before `CLAUDECODE` (same precedence strategy as cursor before claude).
`../../../bin/fm-spawn.sh` clears `CLAUDECODE`, `CURSOR_AGENT`, `CURSOR_INVOKED_AS`, `AI_AGENT`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION`, `GROK_AGENT`, `PI_CODING_AGENT`, and `FM_PI_HARNESS` at the launch boundary.

## Maturity and primary limit

Kiro CLI 2.18.0 is verified for crewmate and scout work only.
It has no primary supervision protocol (no `asyncRewake`, no hook-driven continuation).
It has no secondmate contract (no primary turn-end integration).
It is outside the primary guard integrations in `../../../docs/turnend-guard.md`.
