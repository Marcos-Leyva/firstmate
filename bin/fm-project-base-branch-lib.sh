# shellcheck shell=bash
# Per-project base-branch override, and the one project-facing resolution of
# "which branch is this project's real working base".
# Usage: . bin/fm-project-base-branch-lib.sh
#
# Why this exists: a project's real working branch is not always the default
# branch its forge reports. A project can deliberately keep main as its GitHub
# default while develop is the branch work actually lands on, and the forge
# setting is not always the operator's to change. Every consumer resolved that
# base from origin/HEAD alone, and bin/fm-spawn.sh additionally ran
# `git remote set-head origin --auto` before each spawn, which re-resolved
# origin/HEAD from the forge's answer and silently overwrote an operator's own
# `git remote set-head origin <branch>`. A task worktree then started from the
# wrong branch. This library is the local answer, and it is read-only with
# respect to the forge: no consumer of it ever writes a forge default-branch
# setting.
#
# The file is <config>/project-base-branch, local and gitignored like every other
# config/ item, keyed by the project's clone directory name - the same key
# data/projects.md and bin/fm-project-mode.sh already use:
#
#   # blank lines and comment lines are ignored
#   memo-forges develop
#
# One map file under config/, rather than a marker file inside each clone, for
# two reasons. Firstmate does not write into projects/, and an untracked marker
# in a clone would make that clone read as dirty, which bin/fm-merge-local.sh
# refuses outright and bin/fm-fleet-sync.sh reports as stuck. The item is
# declared in FM_INHERITABLE_CONFIG (bin/fm-config-inherit-lib.sh) because a
# secondmate home clones the same projects and has to land work on the same
# branch. docs/configuration.md owns the operator-facing schema.
#
# Absence is the unconfigured default and changes nothing: a home with no file,
# or a file that simply does not list this project, resolves to no override, and
# every consumer keeps its existing origin/HEAD-then-main-then-master behavior.
#
# A present-but-untrustworthy file is an actionable error and never a fallback to
# the forge's answer, because that fallback is exactly the silent wrong-base
# failure this exists to prevent. Two consequences follow. Every line is
# validated even when it names some other project, since one malformed line means
# the file cannot prove the requested project is absent from it. And a non-empty
# file must end in a newline, so a write truncated mid-line is refused instead of
# resolving a half-written project name to no override.
#
# Every function here returns non-zero on failure and must therefore be called in
# a tested context (`if ! fm_...`), never as a bare statement under `set -e`.

FM_PROJECT_BASE_BRANCH_FILE="project-base-branch"
# Set by fm_project_base_branch_resolve: the configured branch, or empty for no
# override.
FM_PROJECT_BASE_BRANCH=""
# The concrete reason an override file could not be trusted, else empty.
FM_PROJECT_BASE_BRANCH_ERROR=""
# Set by fm_project_default_branch: the resolved base branch name.
FM_PROJECT_DEFAULT_BRANCH=""

fm_project_base_branch_fail() {  # <reason>
  FM_PROJECT_BASE_BRANCH=""
  FM_PROJECT_BASE_BRANCH_ERROR=$1
  return 1
}

# A project key names one clone directory, so it must be a single safe path
# component. Rejecting a leading dash keeps a key from reaching git as an option.
fm_project_base_branch_key_valid() {  # <key>
  local key=$1
  case "$key" in
    ''|.|..|-*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# git check-ref-format is the authority on branch syntax, but it accepts a
# leading dash, which would reach git as an option, so that case is rejected here
# rather than left to each consumer.
fm_project_base_branch_ref_valid() {  # <branch>
  local branch=$1
  case "$branch" in
    ''|-*) return 1 ;;
  esac
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1
}

# True when the file's last byte is a newline. See the truncation argument above.
fm_project_base_branch_newline_terminated() {  # <path>
  local path=$1 last
  last=$(tail -c 1 "$path" 2>/dev/null | od -A n -t x1 | tr -d '[:space:]') || return 1
  [ "$last" = 0a ]
}

# fm_project_base_branch_resolve <config-dir> <project-key>
# Sets FM_PROJECT_BASE_BRANCH to this home's configured base branch for that
# project, or to the empty string when this home configures no override for it,
# and returns 0 in both cases.
# Returns 1 with FM_PROJECT_BASE_BRANCH_ERROR set when an override file is
# present but cannot be trusted.
fm_project_base_branch_resolve() {  # <config-dir> <project-key>
  local config_dir=$1 key=$2 path line lineno name branch extra seen found
  FM_PROJECT_BASE_BRANCH=""
  FM_PROJECT_BASE_BRANCH_ERROR=""
  if [ -z "$config_dir" ]; then
    fm_project_base_branch_fail "no config directory supplied for the project base-branch override"
    return 1
  fi
  if [ -z "$key" ]; then
    fm_project_base_branch_fail "no project name supplied for the project base-branch override"
    return 1
  fi
  path="$config_dir/$FM_PROJECT_BASE_BRANCH_FILE"

  # Nothing at that path at all is the unconfigured default. A dangling symlink
  # is something, so it is checked below rather than read as absence.
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  if [ -L "$path" ]; then
    fm_project_base_branch_fail "$path is a symlink; the project base-branch override must be a regular file"
    return 1
  fi
  if [ ! -f "$path" ]; then
    fm_project_base_branch_fail "$path is not a regular file; the project base-branch override must be a regular file"
    return 1
  fi
  if [ ! -r "$path" ]; then
    fm_project_base_branch_fail "$path is not readable; fix its permissions or remove it"
    return 1
  fi
  # An empty file is a created-but-unused override and configures nothing.
  if [ ! -s "$path" ]; then
    return 0
  fi
  if ! fm_project_base_branch_newline_terminated "$path"; then
    fm_project_base_branch_fail "$path does not end in a newline, so its last entry may be truncated; complete the file"
    return 1
  fi

  lineno=0
  seen=""
  found=""
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    name=""
    branch=""
    extra=""
    # Default-IFS read strips surrounding whitespace and splits on whitespace
    # runs, so an indented or trailing-space entry is ordinary content.
    read -r name branch extra <<EOF
$line
EOF
    [ -n "$name" ] || continue
    case "$name" in '#'*) continue ;; esac
    if ! fm_project_base_branch_key_valid "$name"; then
      fm_project_base_branch_fail "$path line $lineno: '$name' is not a valid project name; expected one clone directory name of letters, digits, dot, underscore, or dash"
      return 1
    fi
    if [ -z "$branch" ]; then
      fm_project_base_branch_fail "$path line $lineno: '$name' has no branch; expected '<project-name> <branch>'"
      return 1
    fi
    if [ -n "$extra" ]; then
      fm_project_base_branch_fail "$path line $lineno: expected exactly '<project-name> <branch>' for '$name', found extra fields"
      return 1
    fi
    if ! fm_project_base_branch_ref_valid "$branch"; then
      fm_project_base_branch_fail "$path line $lineno: '$branch' is not a valid git branch name for project '$name'"
      return 1
    fi
    case $'\n'"$seen"$'\n' in
      *$'\n'"$name"$'\n'*)
        fm_project_base_branch_fail "$path line $lineno: duplicate entry for project '$name'; keep exactly one"
        return 1
        ;;
    esac
    seen="$seen$name"$'\n'
    if [ "$name" = "$key" ]; then
      found=$branch
    fi
  done < "$path"

  FM_PROJECT_BASE_BRANCH=$found
  return 0
}

# fm_git_default_branch <dir>
# The unchanged git-only resolution: the checkout's origin/HEAD, then a local
# main or master. Sets FM_PROJECT_DEFAULT_BRANCH and returns 0, or returns 1.
# Call this directly only for a subject that is not a registered project and so
# has no override, such as a firstmate or secondmate home.
fm_git_default_branch() {  # <dir>
  local dir=$1 ref branch
  FM_PROJECT_DEFAULT_BRANCH=""
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    FM_PROJECT_DEFAULT_BRANCH=${ref#origin/}
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      FM_PROJECT_DEFAULT_BRANCH=$branch
      return 0
    fi
  done
  return 1
}

# fm_project_default_branch <config-dir> <project-key> <dir>
# The one project-facing base-branch resolution: this home's explicit override
# first, then the git-only resolution above. <dir> is the git checkout to read;
# it is never written.
# Sets FM_PROJECT_DEFAULT_BRANCH and returns 0 on success.
# Returns 1 otherwise, with FM_PROJECT_BASE_BRANCH_ERROR carrying the concrete
# override problem when the file could not be trusted, and empty when no base
# branch could be determined at all (the unchanged pre-override outcome).
fm_project_default_branch() {  # <config-dir> <project-key> <dir>
  local config_dir=$1 key=$2 dir=$3
  FM_PROJECT_DEFAULT_BRANCH=""
  if ! fm_project_base_branch_resolve "$config_dir" "$key"; then
    return 1
  fi
  if [ -n "$FM_PROJECT_BASE_BRANCH" ]; then
    FM_PROJECT_DEFAULT_BRANCH=$FM_PROJECT_BASE_BRANCH
    return 0
  fi
  fm_git_default_branch "$dir"
}

# fm_project_default_branch_message <dir>
# The one failure message for the call above, so every consumer reports the
# concrete override problem when there is one and keeps its existing
# cannot-determine text otherwise. Consumers add their own prefix.
fm_project_default_branch_message() {  # <dir>
  if [ -n "$FM_PROJECT_BASE_BRANCH_ERROR" ]; then
    printf '%s\n' "$FM_PROJECT_BASE_BRANCH_ERROR"
  else
    printf 'cannot determine default branch for %s; expected origin/HEAD, main, or master\n' "$1"
  fi
}
