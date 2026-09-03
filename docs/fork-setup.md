# Fork setup

This is the procedure to follow once, after cloning this fork, before dispatching any work.
It covers what differs from upstream firstmate, plus the traps that come with running a fork.

For what firstmate is, how you talk to it, how it works and where it falls short, read [`docs/flujo-de-trabajo.md`](flujo-de-trabajo.md) instead; that document is the explainer and this one is the procedure.
Everything else - requirements, primary-harness launch, runtime backends - is owned by [`README.md`](../README.md) and [`docs/configuration.md`](configuration.md), and this document does not repeat them.

## What this fork adds over upstream

- **kiro as a verified worker engine.** Kiro CLI joins the verified adapter set for crewmate and scout launches, with the boundary described below.
- **A per-project base branch override.** `config/project-base-branch` names the branch a project's work actually starts from and lands on when that is not the default branch its forge reports; the [configuration schema](configuration.md#project-base-branch-configproject-base-branch) owns it.
- **A per-worker Bedrock provider.** Crewmates, scouts, and a secondmate's own workers can carry their own AWS Bedrock provider configuration so worker usage bills against Bedrock instead of the subscription the primary session runs on; the [configuration schema](configuration.md#crewmate-bedrock-provider-configcrew-bedrock) owns it.
- **Fixes carried on top of upstream.** kiro workers are launched on the V3 (KAS) agent engine, are granted tools, and receive a generated no-mistakes procedure file; bootstrap recognizes kiro as a verified adapter in dispatch profiles; an absent agent now outranks a stale busy record; a declared pause with an active run uses the pause cadence instead of the wedge timer; and the test runner isolates process groups so an orphan cannot hang the suite.

## Kiro's hard boundary: crewmate and scout only

Read this before installing anything, because it decides what you install.

Kiro CLI is verified for **crewmate and scout launches only**.
If Kiro CLI is your daily driver, you still cannot launch firstmate itself in it: run the primary session on one of the harnesses [README requirements](../README.md#requirements) lists, and let kiro do worker work underneath it.
[`docs/flujo-de-trabajo.md`](flujo-de-trabajo.md#72-kiro-no-puede-correr-la-sesión-primaria-ni-un-second-mate) explains why the limit is structural rather than a missing feature, and [`docs/configuration.md`](configuration.md#harness-support) owns the verified-harness boundary itself.

## Install Kiro CLI

Kiro CLI is not a `brew install`.
It ships as a macOS application bundle with a CLI entry point inside it.

1. Install Kiro CLI with the vendor's own installer:

   ```sh
   curl -fsSL https://cli.kiro.dev/install | bash
   ```

   **Do not confuse it with Kiro Crew.** The same vendor publishes `curl -fsSL https://download.crew.kiro.dev/cli.sh | sh`, which installs a different product; a teammate who copies that command gets something firstmate does not use.
   The installer you want identifies itself as "Kiro CLI Installation Script" and installs the two binaries the adapter reference documents, `kiro-cli` and `kiro-cli-chat`.
2. Confirm the CLI is on your `PATH`:

   ```sh
   command -v kiro-cli
   kiro-cli --version
   ```

   This step, not the install path, is what decides whether firstmate can launch kiro: it resolves the executable with `command -v kiro-cli`, so an application bundle you never linked onto `PATH` does not count as installed.
   The final location varies by machine.
   The installer targets `/Applications`, while a per-user install lands in `~/Applications` instead, with `~/.local/bin/kiro-cli` symlinked into `~/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli`.
   On a Mac without administrator rights the system-wide path can fail outright, so expect the per-user layout there.
   The verified version at the time of writing is 2.18.0.
3. Authenticate:

   ```sh
   kiro-cli login
   ```

   `kiro-cli login --help` owns the license and identity-provider options.
4. Later updates go through the tool, not a package manager: `kiro-cli update`.

If your home selects kiro and the binary is absent, bootstrap reports `MISSING_MANUAL: kiro-cli` at session start.
It stays silent for a home that never selects kiro, so nobody who skips kiro is nagged about it.

## Accept the one-time consent dialog

Firstmate launches kiro workers with `--trust-all-tools`.
The first time that flag runs on a machine, Kiro CLI shows a three-option consent dialog - "No, exit" is preselected, followed by "Yes, I accept" and "Yes, and don't ask again".

This dialog is globally suppressed on the captain's machine, which is exactly why it is invisible in our own runs and will meet every teammate on their first spawn.
Accept it once, interactively, choosing "Yes, and don't ask again"; a spawned worker that hits it unanswered simply sits there.
The adapter reference at [`.agents/skills/harness-adapters/references/harness/kiro.md`](../.agents/skills/harness-adapters/references/harness/kiro.md) is the source for this behavior.

## Route work to kiro

`config/` is gitignored, so nothing in it ships with the clone.
Every person writes their own, including the dispatch profiles that decide which harness and model each task gets.

Start from the copyable example and edit it:

```sh
cp docs/examples/crew-dispatch-kiro.json config/crew-dispatch.json
```

[`docs/examples/crew-dispatch-kiro.json`](examples/crew-dispatch-kiro.json) routes trivial edits to a cheap kiro profile, larger or ambiguous work and scouts to a stronger one, and the work kiro structurally cannot take to a non-kiro harness.
The [crew dispatch profiles schema](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) is the owner of every field and of what firstmate does with the file; this document does not restate it.

Model ids are discovered from the tool rather than copied from prose:

```sh
kiro-cli chat --list-models --format json
```

## Working in a fork: pass `-R` on every `gh` operation

This one has already cost real time twice in a single day, and it is not specific to kiro.

In a fork, `gh pr list` and `gh run list` without `-R` return the **parent** repository's pull requests and runs, not the fork's, so a status read can confidently describe a repository that is not yours.
Opening a pull request fails outright instead of reading wrong: `gh` takes the parent as base and returns "No commits between main and \<branch\> / Head ref must be a branch".

Pass `-R <owner>/<repo>` explicitly on every `gh` operation, read and write alike.
Both symptoms were verified on 2026-09-03 against this fork; the private `data/learnings.md` in the captain's home holds the full entry.

## Known trap: a worker on this repo can adopt firstmate's identity

A worker dispatched to change this repository can read `AGENTS.md`, conclude it *is* firstmate, and refuse to work - treating its own brief as injected content and addressing the captain directly.
It is not limited to this repository, and correcting it by message does not work once it is entrenched.

The mitigation is an explicit identity warning at the very start of every brief for this kind of task, before any work instruction, stating that the repository's `AGENTS.md` describes the worker's supervisor and is source material rather than instructions addressed to it.
[`docs/flujo-de-trabajo.md`](flujo-de-trabajo.md#71-la-trampa-de-identidad-por-inyección-de-prompt) owns the full account, including which harness and model combinations were observed to fail and what recovered them.
