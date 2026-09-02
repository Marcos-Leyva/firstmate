#!/usr/bin/env bash
# Behavior tests for the per-project base-branch override
# (bin/fm-project-base-branch-lib.sh; docs/configuration.md "Project base branch").
#
# The field failure: a project's real working branch is not always the default
# branch its forge reports, and every base-branch consumer trusted the forge.
# A worktree was born from origin/main while the work belonged on origin/develop,
# and develop already carried a migration main did not have.
#
# bin/fm-spawn.sh's own coverage lives with the rest of the pooled-base refresh in
# tests/fm-spawn-pool-base-freshen.test.sh, and bin/fm-teardown.sh's landed-work
# refusal lives with the rest of teardown in tests/fm-teardown.test.sh. This suite
# covers the resolution contract itself plus the three remaining consumers that
# decide a review base, a landing target, and a clone's synced branch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-project-base-branch)

# shellcheck source=bin/fm-project-base-branch-lib.sh
. "$ROOT/bin/fm-project-base-branch-lib.sh"

# --- fixtures ---------------------------------------------------------------

# A home whose one clone has main as its forge default and develop as the branch
# work actually belongs on, with different content on each so a wrong base is
# provable by file contents and not only by SHA.
#
# Sets HOME_DIR, PROJECT_DIR, ORIGIN_DIR, and PROJECT_KEY for the current case.
# The label only has to be readable; a per-suite counter keeps each case's home
# and clone distinct even when one test builds several.
CASE_N=0
make_two_branch_home() {  # <label>
  local label=$1 publisher
  CASE_N=$((CASE_N + 1))
  HOME_DIR="$TMP_ROOT/$CASE_N-$label"
  PROJECT_KEY="proj-$CASE_N-$label"
  PROJECT_DIR="$HOME_DIR/projects/$PROJECT_KEY"
  ORIGIN_DIR="$HOME_DIR/remotes/$PROJECT_KEY.git"
  publisher="$HOME_DIR/publisher"
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/remotes" "$HOME_DIR/state" \
    "$HOME_DIR/config" "$HOME_DIR/data"
  touch "$HOME_DIR/state/.last-watcher-beat"

  git init -q --bare "$ORIGIN_DIR"
  git -C "$ORIGIN_DIR" symbolic-ref HEAD refs/heads/main
  git clone -q "$ORIGIN_DIR" "$publisher" >/dev/null 2>&1
  printf 'base\n' > "$publisher/README.md"
  git -C "$publisher" add README.md
  git -C "$publisher" commit -qm baseline >/dev/null
  git -C "$publisher" push -q origin HEAD:main

  git -C "$publisher" checkout -q -b develop >/dev/null 2>&1
  printf 'migration 074\n' > "$publisher/only-on-develop.txt"
  git -C "$publisher" add only-on-develop.txt
  git -C "$publisher" commit -qm develop-work >/dev/null
  git -C "$publisher" push -q origin develop

  git -C "$publisher" checkout -q main >/dev/null 2>&1
  printf 'only on main\n' > "$publisher/only-on-main.txt"
  git -C "$publisher" add only-on-main.txt
  git -C "$publisher" commit -qm main-work >/dev/null
  git -C "$publisher" push -q origin main

  git clone -q "$ORIGIN_DIR" "$PROJECT_DIR" >/dev/null 2>&1
  # The forge default stays main deliberately; nothing here may change it.
  git -C "$ORIGIN_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$PROJECT_DIR" remote set-head origin main >/dev/null 2>&1 || true
}

write_override() {  # <line...>
  printf '%s\n' "$@" > "$HOME_DIR/config/project-base-branch"
}

forge_default() {
  git -C "$ORIGIN_DIR" symbolic-ref HEAD
}

# --- resolution contract ----------------------------------------------------

# Absence must stay the unconfigured default: not an error, and not a value.
test_absent_and_empty_files_configure_nothing() {
  make_two_branch_home absent

  fm_project_base_branch_resolve "$HOME_DIR/config" "$PROJECT_KEY" \
    || fail "an absent override file must resolve cleanly as no override"
  [ -z "$FM_PROJECT_BASE_BRANCH" ] || fail "an absent file produced a base branch"
  [ -z "$FM_PROJECT_BASE_BRANCH_ERROR" ] || fail "an absent file produced an error"

  : > "$HOME_DIR/config/project-base-branch"
  fm_project_base_branch_resolve "$HOME_DIR/config" "$PROJECT_KEY" \
    || fail "an empty override file must resolve cleanly as no override"
  [ -z "$FM_PROJECT_BASE_BRANCH" ] || fail "an empty file produced a base branch"

  write_override '# only a comment'
  fm_project_base_branch_resolve "$HOME_DIR/config" "$PROJECT_KEY" \
    || fail "a comment-only override file must resolve cleanly as no override"
  [ -z "$FM_PROJECT_BASE_BRANCH" ] || fail "a comment-only file produced a base branch"
  pass "an absent, empty, or comment-only override file configures nothing"
}

test_entries_parse_with_comments_blank_lines_and_indentation() {
  make_two_branch_home parse
  write_override \
    '# the real working branch, deliberately not the forge default' \
    '' \
    'other-project release/2.0' \
    "  $PROJECT_KEY	develop  " \
    '   # an indented comment' \
    'third-project main'

  fm_project_base_branch_resolve "$HOME_DIR/config" "$PROJECT_KEY" \
    || fail "a well-formed override file must resolve: $FM_PROJECT_BASE_BRANCH_ERROR"
  [ "$FM_PROJECT_BASE_BRANCH" = develop ] \
    || fail "expected develop, resolved '$FM_PROJECT_BASE_BRANCH'"

  fm_project_base_branch_resolve "$HOME_DIR/config" other-project \
    || fail "a sibling entry must resolve too: $FM_PROJECT_BASE_BRANCH_ERROR"
  [ "$FM_PROJECT_BASE_BRANCH" = release/2.0 ] \
    || fail "expected release/2.0, resolved '$FM_PROJECT_BASE_BRANCH'"

  fm_project_base_branch_resolve "$HOME_DIR/config" unlisted-project \
    || fail "an unlisted project must resolve as no override"
  [ -z "$FM_PROJECT_BASE_BRANCH" ] \
    || fail "an unlisted project resolved to '$FM_PROJECT_BASE_BRANCH'"
  pass "entries parse across comments, blank lines, tabs, and surrounding whitespace"
}

# The whole file is validated even when the bad line names another project: one
# malformed line means the file cannot prove THIS project is absent from it, and
# resolving to the forge default is the failure the override exists to prevent.
test_malformed_line_for_another_project_still_fails_closed() {
  make_two_branch_home other-project
  write_override "$PROJECT_KEY develop" 'other-project'

  if fm_project_base_branch_resolve "$HOME_DIR/config" "$PROJECT_KEY"; then
    fail "a malformed line for another project was silently ignored"
  fi
  [ -n "$FM_PROJECT_BASE_BRANCH_ERROR" ] || fail "the refusal carried no reason"
  [ -z "$FM_PROJECT_BASE_BRANCH" ] || fail "a refused file still produced a base branch"
  assert_contains "$FM_PROJECT_BASE_BRANCH_ERROR" 'line 2' \
    "the reason did not locate the malformed line"
  pass "a malformed entry for another project still refuses rather than resolving this one"
}

test_untrustworthy_files_are_refused_with_a_reason() {
  local bad
  for bad in \
    'KEY develop extra' \
    'KEY' \
    'KEY bad..branch' \
    'KEY -dashed' \
    'KEY branch.lock' \
    '../escape develop' \
    'has/slash develop' \
    '. develop'; do
    make_two_branch_home untrusted
    write_override "${bad//KEY/$PROJECT_KEY}"
    if fm_project_base_branch_resolve "$HOME_DIR/config" "$PROJECT_KEY"; then
      fail "'$bad' was accepted as a valid override entry"
    fi
    [ -n "$FM_PROJECT_BASE_BRANCH_ERROR" ] || fail "'$bad' was refused with no reason"
    [ -z "$FM_PROJECT_BASE_BRANCH" ] || fail "'$bad' still produced a base branch"
  done

  # Duplicates are ambiguous, so taking the first would be a guess.
  make_two_branch_home untrusted
  write_override "$PROJECT_KEY develop" "$PROJECT_KEY main"
  if fm_project_base_branch_resolve "$HOME_DIR/config" "$PROJECT_KEY"; then
    fail "a duplicated project entry was accepted"
  fi
  assert_contains "$FM_PROJECT_BASE_BRANCH_ERROR" duplicate \
    "the duplicate refusal did not name the cause"

  # A write truncated mid-entry must not resolve a half-written name to nothing.
  make_two_branch_home untrusted
  printf '%s deve' "$PROJECT_KEY" > "$HOME_DIR/config/project-base-branch"
  if fm_project_base_branch_resolve "$HOME_DIR/config" "$PROJECT_KEY"; then
    fail "a truncated override file was accepted"
  fi
  assert_contains "$FM_PROJECT_BASE_BRANCH_ERROR" 'does not end in a newline' \
    "the truncation refusal did not explain itself"

  # A symlink or a directory at that path is not a config file.
  make_two_branch_home untrusted
  printf '%s develop\n' "$PROJECT_KEY" > "$HOME_DIR/elsewhere"
  ln -s "$HOME_DIR/elsewhere" "$HOME_DIR/config/project-base-branch"
  if fm_project_base_branch_resolve "$HOME_DIR/config" "$PROJECT_KEY"; then
    fail "a symlinked override file was accepted"
  fi
  assert_contains "$FM_PROJECT_BASE_BRANCH_ERROR" symlink \
    "the symlink refusal did not name the cause"

  make_two_branch_home untrusted
  mkdir -p "$HOME_DIR/config/project-base-branch"
  if fm_project_base_branch_resolve "$HOME_DIR/config" "$PROJECT_KEY"; then
    fail "a directory at the override path was accepted"
  fi
  assert_contains "$FM_PROJECT_BASE_BRANCH_ERROR" 'regular file' \
    "the non-regular-file refusal did not name the cause"
  pass "every untrustworthy override file is refused with a concrete reason"
}

# The override is consulted first, and only then the unchanged git resolution.
test_resolution_order_and_git_only_fallback() {
  make_two_branch_home order

  fm_project_default_branch "$HOME_DIR/config" "$PROJECT_KEY" "$PROJECT_DIR" \
    || fail "no-override resolution failed"
  [ "$FM_PROJECT_DEFAULT_BRANCH" = main ] \
    || fail "without an override the forge default must win, got '$FM_PROJECT_DEFAULT_BRANCH'"

  write_override "$PROJECT_KEY develop"
  fm_project_default_branch "$HOME_DIR/config" "$PROJECT_KEY" "$PROJECT_DIR" \
    || fail "override resolution failed: $FM_PROJECT_BASE_BRANCH_ERROR"
  [ "$FM_PROJECT_DEFAULT_BRANCH" = develop ] \
    || fail "the override must win over origin/HEAD, got '$FM_PROJECT_DEFAULT_BRANCH'"

  # A subject that is not a project (a firstmate or secondmate home) has no
  # override and keeps the plain git resolution.
  fm_git_default_branch "$PROJECT_DIR" || fail "git-only resolution failed"
  [ "$FM_PROJECT_DEFAULT_BRANCH" = main ] \
    || fail "git-only resolution must ignore the override, got '$FM_PROJECT_DEFAULT_BRANCH'"

  # origin/HEAD absent falls back to a local main, unchanged.
  git -C "$PROJECT_DIR" remote set-head origin --delete >/dev/null 2>&1
  rm -f "$HOME_DIR/config/project-base-branch"
  fm_project_default_branch "$HOME_DIR/config" "$PROJECT_KEY" "$PROJECT_DIR" \
    || fail "local main fallback failed"
  [ "$FM_PROJECT_DEFAULT_BRANCH" = main ] \
    || fail "expected the local main fallback, got '$FM_PROJECT_DEFAULT_BRANCH'"
  pass "the override wins over the forge answer, and every unconfigured path is unchanged"
}

# The item must be inherited, because a secondmate home clones the same projects
# and has to land work on the same branch.
test_override_is_declared_inheritable() {
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  case " $FM_INHERITABLE_CONFIG " in
    *" project-base-branch "*) ;;
    *) fail "config/project-base-branch must be in FM_INHERITABLE_CONFIG so secondmate homes land on the same branch" ;;
  esac
  fm_config_inherit_items | grep -Fxq 'config/project-base-branch' \
    || fail "config/project-base-branch is not in the inherited-material item set"
  pass "config/project-base-branch is declared inheritable for secondmate homes"
}

# --- fm-review-diff.sh ------------------------------------------------------

# A branch cut from the project's real base has to be reviewed against that base,
# or the diff carries every unrelated commit the two branches differ by.
review_diff_case() {  # -> sets HOME_DIR/PROJECT_DIR/... and adds a task
  make_two_branch_home review
  git -C "$PROJECT_DIR" fetch -q origin
  git -C "$PROJECT_DIR" worktree add -q -b fm/task-b1 "$HOME_DIR/wt" origin/develop
  printf 'task work\n' > "$HOME_DIR/wt/task.txt"
  git -C "$HOME_DIR/wt" add task.txt
  git -C "$HOME_DIR/wt" commit -qm 'task work'
  fm_write_meta "$HOME_DIR/state/task-b1.meta" \
    "window=fm-task-b1" \
    "worktree=$HOME_DIR/wt" \
    "project=$PROJECT_DIR"
}

run_review_diff() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-review-diff.sh" task-b1 --stat 2>&1
}

test_review_diff_uses_the_configured_base() {
  local out status
  review_diff_case

  out=$(run_review_diff)
  status=$?
  expect_code 0 "$status" "review diff should run without an override"
  assert_contains "$out" 'diff base: origin/main' \
    "without an override the review base must stay the forge default"
  assert_contains "$out" 'only-on-develop.txt' \
    "fixture did not prove the forge default drags in unrelated branch content"

  write_override "$PROJECT_KEY develop"
  out=$(run_review_diff)
  status=$?
  expect_code 0 "$status" "review diff should run with an override"
  assert_contains "$out" 'diff base: origin/develop' \
    "the review base did not honor the configured branch"
  assert_not_contains "$out" 'only-on-develop.txt' \
    "the configured review base still reported unrelated branch content"
  assert_contains "$out" 'task.txt' "the configured review base lost the task's own change"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed review base: %s\n' "$(printf '%s\n' "$out" | grep 'diff base:')"
  fi
  pass "the review base follows the configured branch and reports only the task's own change"
}

test_review_diff_refuses_an_untrustworthy_override() {
  local out status
  review_diff_case
  write_override "$PROJECT_KEY develop extra"

  out=$(run_review_diff)
  status=$?
  [ "$status" -ne 0 ] || fail "review diff ran despite an untrustworthy override"
  assert_contains "$out" 'project-base-branch' "the refusal did not name the override file"
  assert_not_contains "$out" 'diff base:' "review diff still produced a base after refusing"
  pass "an untrustworthy override refuses the review instead of reviewing the wrong base"
}

# --- fm-merge-local.sh -----------------------------------------------------

# Landing into the wrong branch is worse than starting from it.
merge_local_case() {  # <checkout-branch>
  local checkout=$1
  make_two_branch_home merge
  git -C "$PROJECT_DIR" fetch -q origin
  git -C "$PROJECT_DIR" checkout -q -B "$checkout" "origin/$checkout"
  git -C "$PROJECT_DIR" branch -q fm/task-m1 "origin/$checkout"
  git -C "$PROJECT_DIR" worktree add -q "$HOME_DIR/wt" fm/task-m1
  printf 'landed work\n' > "$HOME_DIR/wt/landed.txt"
  git -C "$HOME_DIR/wt" add landed.txt
  git -C "$HOME_DIR/wt" commit -qm 'work to land'
  fm_write_meta "$HOME_DIR/state/task-m1.meta" \
    "window=fm-task-m1" \
    "worktree=$HOME_DIR/wt" \
    "project=$PROJECT_DIR" \
    "mode=local-only"
}

run_merge_local() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-merge-local.sh" task-m1 2>&1
}

test_merge_local_lands_on_the_configured_branch() {
  local out status main_before
  merge_local_case develop
  write_override "$PROJECT_KEY develop"
  main_before=$(git -C "$PROJECT_DIR" rev-parse origin/main)

  out=$(run_merge_local)
  status=$?
  expect_code 0 "$status" "an approved local landing should fast-forward the configured branch: $out"
  [ "$(git -C "$PROJECT_DIR" rev-parse develop)" = "$(git -C "$PROJECT_DIR" rev-parse fm/task-m1)" ] \
    || fail "the local landing did not fast-forward the configured develop branch"
  assert_grep 'landed work' "$PROJECT_DIR/landed.txt" \
    "the configured branch does not carry the landed work"
  [ "$(git -C "$PROJECT_DIR" rev-parse origin/main)" = "$main_before" ] \
    || fail "the local landing touched the forge default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed local landing: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an approved local landing fast-forwards the configured branch, not the forge default"
}

test_merge_local_without_override_still_requires_the_forge_default() {
  local out status
  # Checked out on develop with no override: the landing must still measure
  # itself against main, exactly as before, and refuse rather than guess.
  merge_local_case develop

  out=$(run_merge_local)
  status=$?
  [ "$status" -ne 0 ] || fail "a landing with no override accepted a non-default checkout"
  assert_contains "$out" "expected default branch 'main'" \
    "without an override the landing must still expect the forge default"
  pass "with no override the local landing still resolves the forge default branch"
}

test_merge_local_refuses_an_untrustworthy_override() {
  local out status before
  merge_local_case develop
  write_override "$PROJECT_KEY develop" "$PROJECT_KEY main"
  before=$(git -C "$PROJECT_DIR" rev-parse develop)

  out=$(run_merge_local)
  status=$?
  [ "$status" -ne 0 ] || fail "a landing ran despite an untrustworthy override"
  assert_contains "$out" 'project-base-branch' "the refusal did not name the override file"
  [ "$(git -C "$PROJECT_DIR" rev-parse develop)" = "$before" ] \
    || fail "a refused landing still moved a branch"
  pass "an untrustworthy override refuses the local landing instead of merging a guess"
}

# --- fm-fleet-sync.sh ------------------------------------------------------

run_fleet_sync() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null
}

test_fleet_sync_keeps_the_configured_branch_current() {
  local out status behind
  make_two_branch_home sync-ok
  git -C "$PROJECT_DIR" fetch -q origin
  git -C "$PROJECT_DIR" checkout -q -B develop origin/develop
  # Advance origin/develop so a sync has something real to fast-forward.
  git -C "$PROJECT_DIR" reset -q --hard HEAD~1
  behind=$(git -C "$PROJECT_DIR" rev-parse origin/develop)
  write_override "$PROJECT_KEY develop"

  out=$(run_fleet_sync)
  status=$?
  expect_code 0 "$status" "fleet sync should succeed with an override"
  [ "$(git -C "$PROJECT_DIR" rev-parse develop)" = "$behind" ] \
    || fail "fleet sync did not fast-forward the configured develop branch"
  assert_not_contains "$out" STUCK \
    "a clone cleanly on its configured branch was reported as stuck: $out"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed fleet sync: %s\n' "$(printf '%s\n' "$out" | head -n 1)"
  fi
  pass "fleet sync keeps a clone current on its configured branch instead of calling it stuck"
}

test_fleet_sync_reports_an_untrustworthy_override_loudly() {
  local out status
  make_two_branch_home sync-bad
  git -C "$PROJECT_DIR" fetch -q origin
  git -C "$PROJECT_DIR" checkout -q -B develop origin/develop
  write_override "$PROJECT_KEY develop extra"

  out=$(run_fleet_sync)
  status=$?
  expect_code 0 "$status" "fleet sync should keep going past one project's config problem"
  assert_contains "$out" "$PROJECT_KEY: STUCK" \
    "an untrustworthy override was not reported loudly per project: $out"
  assert_contains "$out" 'project-base-branch' "the report did not name the override file"
  assert_contains "$out" 'needs attention' "the report was not actionable"
  # A benign "skipped" would let bootstrap treat this as routine noise.
  assert_not_contains "$out" "$PROJECT_KEY: skipped" \
    "an untrustworthy override was reported as a benign skip"
  pass "fleet sync reports an untrustworthy override as a loud per-project problem"
}

# --- the forge setting stays read-only -------------------------------------

test_no_consumer_writes_the_forge_default() {
  local before after
  make_two_branch_home readonly
  before=$(forge_default)
  write_override "$PROJECT_KEY develop"

  git -C "$PROJECT_DIR" fetch -q origin
  git -C "$PROJECT_DIR" checkout -q -B develop origin/develop
  run_fleet_sync >/dev/null 2>&1 || true

  review_diff_case
  write_override "$PROJECT_KEY develop"
  run_review_diff >/dev/null 2>&1 || true

  merge_local_case develop
  write_override "$PROJECT_KEY develop"
  run_merge_local >/dev/null 2>&1 || true

  after=$(forge_default)
  [ "$after" = "$before" ] \
    || fail "a consumer rewrote the remote's default branch ($before -> $after)"
  [ "$after" = refs/heads/main ] || fail "fixture did not keep the remote default at main"
  pass "no consumer writes the remote's default-branch setting"
}

test_absent_and_empty_files_configure_nothing
test_entries_parse_with_comments_blank_lines_and_indentation
test_malformed_line_for_another_project_still_fails_closed
test_untrustworthy_files_are_refused_with_a_reason
test_resolution_order_and_git_only_fallback
test_override_is_declared_inheritable
test_review_diff_uses_the_configured_base
test_review_diff_refuses_an_untrustworthy_override
test_merge_local_lands_on_the_configured_branch
test_merge_local_without_override_still_requires_the_forge_default
test_merge_local_refuses_an_untrustworthy_override
test_fleet_sync_keeps_the_configured_branch_current
test_fleet_sync_reports_an_untrustworthy_override_loudly
test_no_consumer_writes_the_forge_default

echo "# all fm-project-base-branch tests passed"
