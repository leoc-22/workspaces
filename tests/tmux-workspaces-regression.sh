#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_PATH="$ROOT_DIR/scripts/tmux-workspaces"

if ! command -v script >/dev/null 2>&1; then
  printf 'script(1) is required for this regression test\n' >&2
  exit 1
fi

stub_dir="$(mktemp -d)"
marker_file="$stub_dir/fzf-called"
fzf_input_file="$stub_dir/fzf-input"
tmux_log="$stub_dir/tmux.log"
target_dir="$stub_dir/project"
session_target_dir="$stub_dir/session-target"
layout_file="$stub_dir/layout.yaml"
panes_layout_file="$stub_dir/panes-layout.yaml"

cleanup() {
  rm -rf "$stub_dir"
}
trap cleanup EXIT

cat >"$stub_dir/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list-sessions" ]]; then
  printf '%s\n' ${TMUX_SESSIONS:-api web}
  exit 0
fi
if [[ "${1:-}" == "has-session" ]]; then
  exit "${TMUX_HAS_SESSION_STATUS:-0}"
fi
if [[ -n "${TMUX_MARKER_FILE:-}" ]]; then
  printf '%s\n' "$*" >>"$TMUX_MARKER_FILE"
fi
if [[ "${1:-}" == "split-window" ]]; then
  printf '%%1\n'
fi
exit 0
EOF

cat >"$stub_dir/fzf" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FZF_MARKER_FILE:-}" ]]; then
  : >"$FZF_MARKER_FILE"
fi
if [[ -n "${FZF_INPUT_FILE:-}" ]]; then
  cat >"$FZF_INPUT_FILE"
else
  cat >/dev/null
fi
if [[ -n "${FZF_SELECTION:-}" ]]; then
  printf '%s\n' "$FZF_SELECTION"
  exit 0
fi
exit 1
EOF

cat >"$stub_dir/yq" <<'EOF'
#!/usr/bin/env bash
shift
if [[ "${1:-}" == "-r" ]]; then
  shift
fi
expr="$1"
file="$2"
name="$(basename "$file")"

case "$expr" in
  '.session.name // ""')
    printf '\n'
    ;;
  '.session.dir // .session.path // ""')
    awk -F': ' '$1 == "  dir" { print $2; exit }' "$file"
    ;;
  '(.windows // []) | length')
    printf '1\n'
    ;;
  '.windows[0].name // ""')
    printf 'editor\n'
    ;;
  '.windows[0].dir // .windows[0].path // "."')
    printf '.\n'
    ;;
  '.windows[0].command // .windows[0].run // ""')
    printf '\n'
    ;;
  '(.windows[0].panes // []) | length')
    if [[ "$name" == "panes-layout.yaml" ]]; then
      printf '2\n'
    else
      printf '0\n'
    fi
    ;;
  '.windows[0].panes[0] | tag')
    printf '!!map\n'
    ;;
  '.windows[0].panes[0].command // .windows[0].panes[0].run // ""')
    printf 'npm ls -g\n'
    ;;
  '.windows[0].panes[0].split // "h"')
    printf 'h\n'
    ;;
  '.windows[0].panes[1] | tag')
    printf '!!map\n'
    ;;
  '.windows[0].panes[1].command // .windows[0].panes[1].run // ""')
    printf 'nvim\n'
    ;;
  '.windows[0].panes[1].split // "h"')
    printf 'v\n'
    ;;
  *)
    printf '\n'
    ;;
esac
EOF

chmod +x "$stub_dir/tmux" "$stub_dir/fzf" "$stub_dir/yq"
mkdir -p "$target_dir" "$session_target_dir"
session_target_dir="$(cd "$session_target_dir" && pwd -P)"
printf 'windows: []\n' >"$target_dir/only-in-target.yaml"
printf 'session:\n  dir: %s\nwindows:\n  - name: editor\n' "$session_target_dir" >"$layout_file"
printf 'windows:\n  - name: editor\n    panes:\n      - split: h\n        command: npm ls -g\n      - split: v\n        command: nvim\n' >"$panes_layout_file"

run_tty() {
  script -q /dev/null env PATH="$stub_dir:$PATH" PROJ_SEARCH_DIRS="${PROJ_SEARCH_DIRS:-$stub_dir}" FZF_MARKER_FILE="$marker_file" FZF_INPUT_FILE="${FZF_INPUT_FILE:-}" FZF_SELECTION="${FZF_SELECTION:-}" TMUX_MARKER_FILE="$tmux_log" TMUX_HAS_SESSION_STATUS="${TMUX_HAS_SESSION_STATUS:-0}" TMUX_SESSIONS="${TMUX_SESSIONS:-api web}" TMUX="${TMUX:-}" "$SCRIPT_PATH" "$@"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'expected output to contain: %s\n' "$needle" >&2
    return 1
  fi
}

assert_not_exists() {
  local file_path="$1"

  if [[ -e "$file_path" ]]; then
    printf 'did not expect file to exist: %s\n' "$file_path" >&2
    return 1
  fi
}

assert_exists() {
  local file_path="$1"

  if [[ ! -e "$file_path" ]]; then
    printf 'expected file to exist: %s\n' "$file_path" >&2
    return 1
  fi
}

printf '1..9\n'

rm -f "$marker_file"
set +e
output_1="$(run_tty --layout --file definitely-missing.yaml 2>&1)"
status_1=$?
set -e

if [[ $status_1 -ne 1 ]]; then
  printf 'not ok 1 - --layout --file no-target should fail on missing file (got status %s)\n' "$status_1"
  exit 1
fi

assert_contains "$output_1" 'layout file not found: definitely-missing.yaml'
assert_not_exists "$marker_file"
printf 'ok 1 - --layout --file no-target skips fzf and resolves current dir\n'

rm -f "$marker_file"
set +e
output_2="$(run_tty --file definitely-missing.yaml 2>&1)"
status_2=$?
set -e

if [[ $status_2 -ne 1 ]]; then
  printf 'not ok 2 - standalone --file should fail (got status %s)\n' "$status_2"
  exit 1
fi

assert_contains "$output_2" 'use --layout --file for explicit layout files'
assert_not_exists "$marker_file"
printf 'ok 2 - standalone --file is rejected\n'

rm -f "$marker_file"
set +e
output_3="$(run_tty --layout --file only-in-target.yaml "$target_dir" 2>&1)"
status_3=$?
set -e

if [[ $status_3 -ne 1 ]]; then
  printf 'not ok 3 - --layout --file should not search target directory (got status %s)\n' "$status_3"
  exit 1
fi

assert_contains "$output_3" 'layout file not found: only-in-target.yaml'
assert_not_exists "$marker_file"
printf 'ok 3 - --layout --file does not search target directory\n'

rm -f "$marker_file"
set +e
run_tty >/dev/null 2>&1
status_4=$?
set -e

if [[ $status_4 -ne 0 ]]; then
  printf 'not ok 4 - no-arg interactive should allow fzf cancel (got status %s)\n' "$status_4"
  exit 1
fi

assert_exists "$marker_file"
printf 'ok 4 - no-arg interactive still invokes fzf\n'

rm -f "$marker_file" "$tmux_log"
set +e
TMUX_HAS_SESSION_STATUS=1 run_tty --layout --file "$layout_file" >/dev/null 2>&1
status_5=$?
set -e

if [[ $status_5 -ne 0 ]]; then
  printf 'not ok 5 - --layout --file should use session.dir as target (got status %s)\n' "$status_5"
  exit 1
fi

assert_contains "$(cat "$tmux_log")" "new-session -d -s"
assert_contains "$(cat "$tmux_log")" "-c $session_target_dir"
assert_not_exists "$marker_file"
printf 'ok 5 - --layout --file uses session.dir as target\n'

rm -f "$marker_file" "$tmux_log"
set +e
TMUX_HAS_SESSION_STATUS=1 run_tty --layout --file "$panes_layout_file" "$target_dir" >/dev/null 2>&1
status_6=$?
set -e

if [[ $status_6 -ne 0 ]]; then
  printf 'not ok 6 - map-form panes should parse with yq tag checks (got status %s)\n' "$status_6"
  exit 1
fi

assert_contains "$(cat "$tmux_log")" "split-window -v"
assert_contains "$(cat "$tmux_log")" "send-keys -t %1"
assert_contains "$(cat "$tmux_log")" "npm ls -g"
assert_contains "$(cat "$tmux_log")" "nvim"
printf 'ok 6 - map-form panes parse with yq tag checks\n'

rm -f "$marker_file" "$tmux_log" "$fzf_input_file"
set +e
FZF_INPUT_FILE="$fzf_input_file" FZF_SELECTION="[session] api" TMUX=/tmp/tmux run_tty >/dev/null 2>&1
status_7=$?
set -e

if [[ $status_7 -ne 0 ]]; then
  printf 'not ok 7 - no-arg interactive should switch selected tmux session (got status %s)\n' "$status_7"
  exit 1
fi

assert_contains "$(cat "$fzf_input_file")" "[session] api"
assert_contains "$(cat "$fzf_input_file")" "[project] $target_dir"
assert_contains "$(cat "$tmux_log")" "switch-client -t api"
printf 'ok 7 - no-arg interactive can fuzzy-switch existing tmux sessions\n'

rm -f "$marker_file" "$tmux_log"
set +e
TMUX=/tmp/tmux run_tty --session web >/dev/null 2>&1
status_8=$?
set -e

if [[ $status_8 -ne 0 ]]; then
  printf 'not ok 8 - --session name should switch directly (got status %s)\n' "$status_8"
  exit 1
fi

assert_not_exists "$marker_file"
assert_contains "$(cat "$tmux_log")" "switch-client -t web"
printf 'ok 8 - --session switches directly without fzf\n'

rm -f "$marker_file" "$tmux_log"
set +e
TMUX_HAS_SESSION_STATUS=1 run_tty --session missing >/dev/null 2>&1
status_9=$?
set -e

if [[ $status_9 -ne 1 ]]; then
  printf 'not ok 9 - --session should fail for missing sessions (got status %s)\n' "$status_9"
  exit 1
fi

assert_not_exists "$marker_file"
printf 'ok 9 - --session fails for missing sessions\n'
