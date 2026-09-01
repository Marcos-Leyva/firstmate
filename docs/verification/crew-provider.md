# Crewmate provider verification

Audience: maintainer verification.

This record supports the default-on worker Bedrock provider configuration written by `bin/fm-spawn.sh` from account-specific values in `config/crew-bedrock-values`, gated by the `config/crew-bedrock` kill switch, documented in [`docs/configuration.md`](../configuration.md#crewmate-bedrock-provider-configcrew-bedrock).
It records only the facts that must be re-established when Claude Code changes how it reads project-level settings.
Task chronology and delivery evidence stay in private reports or PR evidence.

The portable regressions in `tests/fm-spawn-dispatch-profile.test.sh` prove which keys a spawn writes.
They cannot prove that Claude Code honors those keys, because no fake agent reads them.
That half of the guarantee is empirical and is what this record holds.

## Claude Code honors env and modelOverrides from a worktree settings.local.json

Verified 2026-08-26 (America/Mexico_City) against Claude Code 2.1.246, tmux 3.7b, and treehouse v2.1.1, on firstmate at `60bedde` plus this change.

Both cases spawned a real claude scout through `bin/fm-spawn.sh` into an isolated `FM_HOME`, an isolated scratch project, and a private tmux server (`TMUX_TMPDIR`), so no fleet home, pool, or session was involved.
The machine's own `~/.claude/settings.json` was in direct-Anthropic mode throughout, which is what makes the first case conclusive: nothing but the per-worktree file could have selected Bedrock.

```
bin/fm-spawn.sh --scout --backend tmux <id> <scratch-project> claude
tmux capture-pane -p -t firstmate:fm-<id>
```

Default, with `config/crew-bedrock-values` populated for the account, the worker's own banner and shell reported Bedrock:

```
▝▜██████▀  Opus 4.6 with high effort · Amazon Bedrock
⏺ Bash(echo "USE_BEDROCK=[$CLAUDE_CODE_USE_BEDROCK] REGION=[$AWS_REGION] MODEL=[$ANTHROPIC_MODEL]")
  ⎿  USE_BEDROCK=[1] REGION=[<account-region>] MODEL=[<account-model>]
```

The worker also completed a real turn, so the account reached Bedrock rather than only being configured for it.

With `config/crew-bedrock` set to `off`, the same spawn produced a hooks-only settings file and the worker fell back to the machine's own provider:

```
▝▜██████▀  Opus 5 with high effort · Claude Team
  ⎿  USE_BEDROCK=[] REGION=[] MODEL=[]
```

Three properties follow and are load-bearing:

- Claude Code applies a project-level `.claude/settings.local.json` `env` block to the agent process environment, so `CLAUDE_CODE_USE_BEDROCK` selects the provider per worktree rather than per machine.
- The worker's rendered provider label distinguishes the two states (`Amazon Bedrock` against `Claude Team`), so the banner is a usable refresh signal.
- An absent `env` block leaves the machine's own settings in charge, which is why the kill switch needs no compensating write.

## What silent degradation would look like

If a future Claude Code stopped reading `env` or `modelOverrides` from a project-level settings file, every worker would quietly bill against the captain's direct Anthropic subscription again while the portable regressions still passed.
Re-run the two spawns above after a Claude Code upgrade and confirm the two provider labels still diverge.
The values themselves are account-specific and live in `config/crew-bedrock-values`, verified only by the worker reaching Bedrock.

## Primary isolation

The firstmate primary is never launched through `bin/fm-spawn.sh`, so it cannot receive this configuration.
Confirmed in the same session that `~/.claude/settings.json` was byte-identical before and after both live spawns, and that the primary firstmate checkout's `.claude/` directory gained no `settings.local.json`.
