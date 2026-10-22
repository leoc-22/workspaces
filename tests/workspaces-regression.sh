#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_PATH="$ROOT_DIR/scripts/workspaces"

if ! command -v yq >/dev/null 2>&1 || ! [[ "$(yq --version)" == *"mikefarah/yq"*"version v4"* ]]; then
  printf 'Mike Farah yq v4 is required for these tests\n' >&2
  exit 1
fi

if ! command -v script >/dev/null 2>&1; then
  printf 'script(1) is required for this regression test\n' >&2
  exit 1
fi

stub_dir="$(mktemp -d)"
stub_dir="$(cd "$stub_dir" && pwd -P)"
marker_file="$stub_dir/fzf-called"
fzf_input_file="$stub_dir/fzf-input"
fzf_args_file="$stub_dir/fzf-args"
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
if [[ -n "${FZF_ARGS_FILE:-}" ]]; then
  printf '%s\n' "$*" >"$FZF_ARGS_FILE"
fi
if [[ -n "${FZF_SELECTION:-}" ]]; then
  printf '%s\n' "$FZF_SELECTION"
  exit 0
fi
exit 1
EOF

# Keep directory lookup independent of the user's zoxide database.
cat >"$stub_dir/zoxide" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$stub_dir/tmux" "$stub_dir/fzf" "$stub_dir/zoxide"
mkdir -p "$target_dir" "$session_target_dir"
session_target_dir="$(cd "$session_target_dir" && pwd -P)"
printf 'windows: []\n' >"$target_dir/only-in-target.yaml"
printf 'session:\n  name: fixture\n  dir: %s\nwindows:\n  - name: editor\n' "$session_target_dir" >"$layout_file"
cat >"$panes_layout_file" <<'EOF'
windows:
  - name: editor
    command: 'printf "hello: world"'
    panes:
      - split: h
        command: npm ls -g
      - split: v
        command: nvim
      - command: 'printf "default split"'
  - name: shell
    command: 'printf "second window"'
EOF

run_command() {
  env PATH="$stub_dir:$PATH" PROJ_SEARCH_DIRS="$stub_dir" \
    FZF_MARKER_FILE="$marker_file" FZF_INPUT_FILE="$fzf_input_file" \
    FZF_ARGS_FILE="$fzf_args_file" FZF_SELECTION="${FZF_SELECTION:-}" \
    TMUX_MARKER_FILE="$tmux_log" TMUX_HAS_SESSION_STATUS="${TMUX_HAS_SESSION_STATUS:-0}" \
    TMUX="${TEST_TMUX:-}" "$SCRIPT_PATH" "$@"
}

run_tty() {
  # Only interactive cases need a pseudo-terminal. Pass the same isolated env.
  local -a invocation=(env PATH="$stub_dir:$PATH" PROJ_SEARCH_DIRS="$stub_dir"
    FZF_MARKER_FILE="$marker_file" FZF_INPUT_FILE="$fzf_input_file"
    FZF_ARGS_FILE="$fzf_args_file" FZF_SELECTION="${FZF_SELECTION:-}"
    TMUX_MARKER_FILE="$tmux_log" TMUX_HAS_SESSION_STATUS="${TMUX_HAS_SESSION_STATUS:-0}"
    TMUX="${TEST_TMUX:-}" "$SCRIPT_PATH" "$@")
  if [[ "$(uname -s)" == Darwin ]]; then
    script -q /dev/null "${invocation[@]}"
  else
    local command
    printf -v command '%q ' "${invocation[@]}"
    script -q -e -c "$command" /dev/null
  fi
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || { printf 'expected output to contain: %s\nactual: %s\n' "$2" "$1" >&2; exit 1; }
}

assert_absent() {
  [[ "$1" != *"$2"* ]] || { printf 'unexpected output: %s\n' "$2" >&2; exit 1; }
}

expect() {
  local expected="$1"
  shift
  rm -f "$marker_file" "$tmux_log" "$fzf_input_file" "$fzf_args_file"
  local status=0
  output="$("$@" 2>&1)" || status=$?
  [[ "$status" -eq "$expected" ]] || { printf 'expected status %s, got %s: %s\n' "$expected" "$status" "$output" >&2; exit 1; }
}

count=0
ok() {
  count=$((count + 1))
  printf 'ok %s - %s\n' "$count" "$1"
}

expect 1 run_tty --file definitely-missing.yaml
assert_contains "$output" 'layout file not found: definitely-missing.yaml'
[[ ! -e "$marker_file" ]]
ok 'standalone --file skips picker and reports missing file'

expect 1 run_command --layout dev --file "$layout_file"
assert_contains "$output" 'use either --layout <name> or --file <path>'
expect 1 run_command --layout --file "$layout_file"
assert_contains "$output" 'missing value for --layout'
ok 'layout name and explicit file are distinct alternatives'

expect 1 run_command --file only-in-target.yaml "$target_dir"
assert_contains "$output" 'layout file not found: only-in-target.yaml'
ok 'relative layout files resolve from the working directory'

expect 0 run_tty
[[ -e "$marker_file" ]]
assert_contains "$(cat "$fzf_args_file")" '--height=40%'
ok 'normal picker retains compact layout and cancellation succeeds'

TMUX_HAS_SESSION_STATUS=1 expect 0 run_tty --file "$layout_file"
assert_contains "$(cat "$tmux_log")" 'new-session -d -s fixture'
assert_contains "$(cat "$tmux_log")" "-c $session_target_dir"
[[ ! -e "$marker_file" ]]
ok 'real YAML session name and directory are used'

TMUX_HAS_SESSION_STATUS=1 expect 0 run_command -f "$layout_file" "$target_dir"
assert_contains "$(cat "$tmux_log")" "-c $target_dir"
assert_absent "$(cat "$tmux_log")" "$session_target_dir"
ok 'explicit target overrides session.dir'

TMUX_HAS_SESSION_STATUS=1 expect 0 run_command --file="$panes_layout_file" "$target_dir"
log="$(cat "$tmux_log")"
assert_contains "$log" 'split-window -v'
assert_contains "$log" 'split-window -h'
assert_contains "$log" 'send-keys -t %1 npm ls -g C-m'
assert_contains "$log" 'send-keys -t %1 nvim C-m'
assert_contains "$log" 'printf "default split"'
assert_contains "$log" 'printf "hello: world"'
assert_contains "$log" 'new-window -t'
assert_contains "$log" 'printf "second window"'
ok 'real YAML creates multiple windows and both pane directions with intact commands'

FZF_SELECTION='[session] api' TEST_TMUX=/tmp/test-tmux expect 0 run_tty --popup
assert_contains "$(cat "$fzf_input_file")" $'\033[36m[session] api\033[0m'
assert_contains "$(cat "$fzf_input_file")" "[project] $target_dir"
assert_contains "$(cat "$fzf_args_file")" '--ansi'
assert_contains "$(cat "$fzf_args_file")" '--no-height --border=none --margin=0 --padding=0'
assert_absent "$(cat "$fzf_args_file")" '--height=40%'
assert_contains "$(cat "$tmux_log")" 'switch-client -t api'
ok 'popup picker fills the popup and switches the selected session'

FZF_SELECTION=web TEST_TMUX=/tmp/test-tmux expect 0 run_tty --popup --session
assert_contains "$(cat "$fzf_args_file")" '--no-height'
assert_absent "$(cat "$fzf_input_file")" '[project]'
assert_contains "$(cat "$tmux_log")" 'switch-client -t web'
ok 'session-only picker also supports popup mode'

TEST_TMUX=/tmp/test-tmux expect 0 run_command -s web
assert_contains "$(cat "$tmux_log")" 'switch-client -t web'
[[ ! -e "$marker_file" ]]
expect 0 run_command --session=web
assert_contains "$(cat "$tmux_log")" 'attach-session -t web'
ok 'direct session selection switches inside tmux and attaches outside'

TMUX_HAS_SESSION_STATUS=1 expect 1 run_command --session missing
assert_contains "$output" 'tmux session not found: missing'
expect 1 run_command --session --file "$layout_file"
assert_contains "$output" '--session cannot be combined'
ok 'missing sessions and conflicting modes fail clearly'

expect 1 run_command "$target_dir" "$session_target_dir"
assert_contains "$output" 'only one target is supported'
expect 1 run_command -- "$target_dir" "$session_target_dir"
assert_contains "$output" 'only one target is supported'
ok 'second positional target is rejected with and without --'

literal_dir="$stub_dir/project :: with spaces "
mkdir -p "$literal_dir"
TMUX_HAS_SESSION_STATUS=1 expect 0 run_command -- "$literal_dir"
assert_contains "$(cat "$tmux_log")" "-c $literal_dir"
ok 'literal paths preserve spaces and accept ::'

FZF_SELECTION="[project] $target_dir" TMUX_HAS_SESSION_STATUS=1 expect 0 run_tty --popup
assert_contains "$(cat "$tmux_log")" "-c $target_dir"
assert_contains "$(cat "$tmux_log")" '-n ai'
assert_contains "$(cat "$tmux_log")" '-n editor'
assert_contains "$(cat "$tmux_log")" '-n shell'
ok 'picker-selected projects create the default workspace'

(
  cd "$target_dir"
  TMUX_HAS_SESSION_STATUS=1 expect 0 run_command
  assert_contains "$(cat "$tmux_log")" "-c $target_dir"
  [[ ! -e "$marker_file" ]]
)
ok 'noninteractive no-target mode uses the current directory'

for option in --layout -l --file -f; do
  expect 1 run_command "$option"
  assert_contains "$output" 'missing value'
done
expect 1 run_command ''
assert_contains "$output" 'target cannot be empty'
expect 1 run_command --session
assert_contains "$output" 'requires a session name'
expect 0 run_tty --popup --session
[[ ! -e "$tmux_log" ]]
ok 'missing arguments fail clearly and session picker cancellation succeeds'

mkdir -p "$target_dir/.workspaces"
printf 'session:\n  name: "null"\nwindows:\n  - name: editor\n' >"$target_dir/.workspaces/layout.yml"
TMUX_HAS_SESSION_STATUS=1 expect 0 run_command "$target_dir"
assert_contains "$(cat "$tmux_log")" 'new-session -d -s null'
ok 'project-local .yml discovery preserves literal null session name'

cp "$layout_file" "$stub_dir/null"
(cd "$stub_dir"; expect 0 run_command --file null)
# Exercise named lookup against fixture layouts, without reading user layouts.
mkdir -p "$stub_dir/layouts"
cp "$layout_file" "$stub_dir/layouts/null.yaml"
cp "$panes_layout_file" "$stub_dir/layouts/null.yml"
(
  sed '/^parse_args "\$@"/,$d' "$SCRIPT_PATH" >"$stub_dir/functions.sh"
  source "$stub_dir/functions.sh"
  GLOBAL_YAML_LAYOUTS_DIR="$stub_dir/layouts"
  parse_args --layout=null
  [[ "$(resolve_yaml_layout_file "$target_dir")" == "$stub_dir/layouts/null.yaml" ]]
  rm "$stub_dir/layouts/null.yaml"
  [[ "$(resolve_yaml_layout_file "$target_dir")" == "$stub_dir/layouts/null.yml" ]]
)
ok 'literal null names work and named layouts prefer .yaml then .yml'

invalid_file="$stub_dir/invalid.yaml"
for legacy in \
  'session: {path: /tmp}' \
  'windows: [{name: editor, path: /tmp}]' \
  'windows: [{name: editor, run: echo hi}]' \
  'windows: [{name: editor, panes: [{run: echo hi}]}]' \
  'windows: [{name: editor, panes: [echo hi]}]' \
  'windows: [{name: editor, panes: [{split: horizontal, command: echo hi}]}]' \
  'windows: [{name: editor, panes: [{split: "h:echo wrong", command: echo right}]}]'; do
  if [[ "$legacy" == session:* ]]; then
    printf 'windows: [{name: editor}]\n%s\n' "$legacy" >"$invalid_file"
  else
    printf '%s\n' "$legacy" >"$invalid_file"
  fi
  TMUX_HAS_SESSION_STATUS=1 expect 1 run_command --file "$invalid_file" "$target_dir"
  assert_contains "$output" 'invalid layout'
  [[ ! -e "$tmux_log" ]]
done
ok 'removed YAML aliases and pane formats fail before session creation'

printf 'windows: []\n' >"$invalid_file"
expect 1 run_command --file "$invalid_file"
assert_contains "$output" 'windows must be a nonempty list'
printf 'windows: [\n' >"$invalid_file"
expect 1 run_command --file "$invalid_file"
assert_contains "$output" 'invalid YAML layout'
ok 'empty and malformed YAML fail with real parser'

printf '1..%s\n' "$count"
