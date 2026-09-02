#!/usr/bin/env bash
# Live opt-in drift guard: the agent engine a kiro spawn actually launches must
# still be an engine the INSTALLED kiro-cli accepts.
#
# The engine selection is a vendor flag surface, and kiro already retired one
# thing firstmate depended on (the V2 KIRO_SESSION_ID marker) inside a single
# release line. `--v3` is an alias for the same choice, so the flag firstmate
# launches with can be retired without the engine going anywhere. This guard
# reads the launch command out of a real fm-spawn - with a fake tmux, so no kiro
# session is ever started and no credits are spent - and validates its engine
# flag against the installed binary's own advertised values.
#
# Opt in with FM_KIRO_ENGINE_LIVE=1. Needs kiro-cli installed; no credentials.
set -u

if [ "${FM_KIRO_ENGINE_LIVE:-}" != 1 ]; then
  echo "skip: set FM_KIRO_ENGINE_LIVE=1 to run the real kiro agent-engine flag guard"
  exit 0
fi

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

KIRO_BIN=$(command -v kiro-cli 2>/dev/null || true)
[ -n "$KIRO_BIN" ] && [ -x "$KIRO_BIN" ] \
  || fail "FM_KIRO_ENGINE_LIVE=1 but no real kiro-cli executable is installed on PATH"
KIRO_VERSION_LINE=$("$KIRO_BIN" --version 2>&1 | head -1)

TMP_ROOT=$(fm_test_tmproot fm-kiro-engine-flag-live)

test_launched_engine_flag_is_accepted_by_the_installed_binary() {
  local id=kiro-live-engine case_dir home proj wt fakebin launchlog out rc
  local launch engine help_out
  case_dir="$TMP_ROOT/engine-flag"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  # Only tmux and treehouse are faked; kiro-cli stays the real installed binary
  # so the launch command carries the path and flags a real spawn would use.
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" kiro
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" wt-live-engine
  : > "$launchlog"

  rc=0
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
      --mode direct-PR --yolo off) || rc=$?
  [ "$rc" = 0 ] || fail "kiro spawn failed against the installed binary ($KIRO_VERSION_LINE): $out"

  launch=$(grep -m1 'kiro-cli' "$launchlog") \
    || fail "kiro spawn logged no launch command against $KIRO_VERSION_LINE"
  case "$launch" in
    *"$KIRO_BIN"*) : ;;
    *) fail "kiro launch did not resolve the installed binary $KIRO_BIN: $launch" ;;
  esac

  engine=$(printf '%s\n' "$launch" | sed -n 's/.*--agent-engine \([A-Za-z0-9][A-Za-z0-9]*\).*/\1/p')
  help_out=$("$KIRO_BIN" chat --help 2>&1) \
    || fail "kiro-cli chat --help failed on $KIRO_VERSION_LINE"

  if [ -n "$engine" ]; then
    printf '%s\n' "$help_out" | grep -q -- '--agent-engine' \
      || fail "kiro ($KIRO_VERSION_LINE) no longer advertises --agent-engine, which the launch passes"
    printf '%s\n' "$help_out" | grep -A3 -- '--agent-engine' | grep -q "$engine" \
      || fail "kiro ($KIRO_VERSION_LINE) no longer accepts --agent-engine $engine"
    pass "kiro $KIRO_VERSION_LINE accepts the --agent-engine $engine the spawn launches"
    return
  fi

  case "$launch" in
    *' --v3'*)
      printf '%s\n' "$help_out" | grep -q -- '--v3' \
        || fail "kiro ($KIRO_VERSION_LINE) no longer advertises the --v3 alias the launch passes"
      pass "kiro $KIRO_VERSION_LINE accepts the --v3 alias the spawn launches"
      ;;
    *)
      fail "kiro launch selected no agent engine at all, so it would run the binary's default: $launch"
      ;;
  esac
}

test_launched_engine_flag_is_accepted_by_the_installed_binary
