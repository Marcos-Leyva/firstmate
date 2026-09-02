#!/usr/bin/env bash
# Behavior tests for the verified Kiro CLI crewmate adapter's V3 agent engine.
#
# Covers the two things V3 adoption changed: the launch selects the KAS engine,
# and harness detection no longer depends on the single vendor variable V3
# removed. Both are exercised through the real scripts - a real fm-spawn with a
# fake tmux and an isolated git worktree, and real fm-harness.sh runs against a
# fake process ancestry.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry, so a suite run
# from inside Cursor, Claude, Pi, or Grok would otherwise have its own primary's
# marker outrank the fixtures below.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS
unset KIRO_VERSION KIRO_CHAT_CLI_BIN KIRO_AGENT_ENGINE KIRO_SESSION_ID

TMP_ROOT=$(fm_test_tmproot fm-kiro-harness)
HARNESS="$ROOT/bin/fm-harness.sh"

make_kiro_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  fm_fake_exit0 "$fakebin" kiro-cli
  printf '%s\n' "$fakebin"
}

# A kiro crewmate spawn must select the V3 (KAS) agent engine. V3 is what makes
# an interrupt safe for firstmate: it kills the shell child and its subprocess
# tree, while V2 orphans them and an orphan holding the tool's output pipe wedges
# the worker.
test_kiro_launch_selects_the_v3_agent_engine() {
  local id=kiro-v3-launch case_dir home proj wt fakebin launchlog out rc launch
  case_dir="$TMP_ROOT/v3-launch"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_kiro_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" kiro
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" wt-v3-launch
  : > "$launchlog"

  rc=0
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
      --mode direct-PR --yolo off --model claude-haiku-4.5 --effort high) || rc=$?
  expect_code 0 "$rc" "kiro spawn should succeed: $out"

  launch=$(grep -m1 'kiro-cli' "$launchlog") \
    || fail "kiro spawn logged no launch command: $(cat "$launchlog")"
  assert_contains "$launch" "chat --agent-engine v3 --agent fm-${id}" \
    "kiro launch did not select the V3 agent engine ahead of its agent config"
  assert_contains "$launch" "--trust-all-tools --tui" \
    "kiro launch lost its autonomy or TUI flags"
  assert_contains "$launch" "--model 'claude-haiku-4.5'" \
    "kiro launch lost the requested model"
  assert_contains "$launch" "--effort 'high'" \
    "kiro launch lost the requested effort"
  pass "fm-spawn: a kiro crewmate launches on the V3 agent engine"
}

# fm-harness.sh must identify kiro from any ONE of its engine markers. This is
# the regression that matters: the V2 marker KIRO_SESSION_ID vanished in V3, so
# depending on a single vendor variable is what previously broke, and each
# remaining marker is asserted on its own with a foreign CLAUDECODE present to
# prove precedence survives too.
test_kiro_detection_survives_losing_any_single_marker() {
  local cfg out marker
  cfg="$TMP_ROOT/detect-config"
  mkdir -p "$cfg"

  for marker in KIRO_VERSION=2.18.0 KIRO_CHAT_CLI_BIN=/opt/kiro/bin/kiro-cli-chat \
    KIRO_AGENT_ENGINE=kas; do
    out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u GROK_AGENT \
      CLAUDECODE=1 "$marker" FM_CONFIG_OVERRIDE="$cfg" "$HARNESS")
    [ "$out" = kiro ] \
      || fail "kiro was not detected from $marker alone, got '$out'"
  done

  # The divergence that keeps the cases above from being vacuous: with every
  # kiro marker absent, the same environment must resolve to the foreign primary.
  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u GROK_AGENT \
    CLAUDECODE=1 FM_CONFIG_OVERRIDE="$cfg" "$HARNESS")
  [ "$out" = claude ] \
    || fail "an environment with no kiro marker resolved to '$out' rather than its foreign primary"
  pass "fm-harness: any single kiro engine marker identifies kiro, and none of them means it is not kiro"
}

# V3 interposes a KAS server between the pane and the tool subprocess
# (kiro-cli -> kiro-cli-chat -> bun -> node), so a marker-less environment must
# still resolve through the node ancestor's script path.
test_kiro_ancestry_detects_the_kas_node_server() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/kas-ancestry"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4343) printf '/opt/kiro/node\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  args=:4343)
    printf 'node /Users/test/.local/share/kiro-cli/kas/2.18.0/node_modules/@kiro/agent/dist/server/acp-server.js\n' ;;
  args=:*) printf 'bash\n' ;;
  ppid=:4343) printf '1\n' ;;
  ppid=:*) printf '4343\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT \
    -u GROK_AGENT -u KIRO_VERSION -u KIRO_CHAT_CLI_BIN -u KIRO_AGENT_ENGINE \
    PATH="$fakebin:$PATH" FM_CONFIG_OVERRIDE="$cfg" "$HARNESS")
  [ "$out" = kiro ] \
    || fail "a marker-less V3 tool subprocess under the KAS node server detected '$out'"
  pass "fm-harness: the V3 KAS node server is recognized by ancestry when no marker is present"
}

test_kiro_launch_selects_the_v3_agent_engine
test_kiro_detection_survives_losing_any_single_marker
test_kiro_ancestry_detects_the_kas_node_server
