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
target_dir="$stub_dir/project"

cleanup() {
  rm -rf "$stub_dir"
}
trap cleanup EXIT

cat >"$stub_dir/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$stub_dir/fzf" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FZF_MARKER_FILE:-}" ]]; then
  : >"$FZF_MARKER_FILE"
fi
exit 1
EOF

chmod +x "$stub_dir/tmux" "$stub_dir/fzf"
mkdir -p "$target_dir"
printf 'windows: []\n' >"$target_dir/only-in-target.yaml"

run_tty() {
  script -q /dev/null env PATH="$stub_dir:$PATH" FZF_MARKER_FILE="$marker_file" "$SCRIPT_PATH" "$@"
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

printf '1..4\n'

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
