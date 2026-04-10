# tmux workflow

`tmux-workspace` is a tmux launcher in a Primeagen-style script path.

## Install

Commands:

- `tmux-workspace`

The command lives in `bin/.local/scripts`.

Fish (current shell):

```fish
set -gx PATH /Users/leoc/Developer/tmux-workflow/bin/.local/scripts $PATH
```

Fish (persist):

```fish
fish_add_path /Users/leoc/Developer/tmux-workflow/bin/.local/scripts
```

## Usage

```bash
tmux-workspace
tmux-workspace my-app
tmux-workspace ../shared-lib
tmux-workspace a b c
tmux-workspace "a::pnpm dev" "b::go test ./..."
tmux-workspace --layout dev my-workspace
tmux-workspace --layout dev.yaml my-workspace
tmux-workspace --layout -f ~/Developer/layouts/cow.yaml
tmux-workspace --file ~/Developer/layouts/cow.yaml
```

CLI options:

- `--layout <name>`: use `.proj/layouts/<name>.yaml` (or `.yml`) in the target directory
- `--layout <file>`: use an exact YAML file under `.proj/layouts` (for example `dev.yaml`)
- `--layout -f <path>` or `--file <path>`: use a specific YAML file path
- `-h`, `--help`: show help

Help shortcuts:

- `tmux-workspace --help`

- No args: uses `fzf` picker when available, else current directory
- Multiple targets: one session, one window per target
- Inline `target::command`: runs once when session is first created
- `--layout` / `--file` are for single-target mode only

Target resolution order:

1. explicit path (`.`, `..`, `/...`, `~/...`)
2. existing local directory
3. fallback to `~/Developer/<name>`

## YAML layout (recommended)

YAML supports named layouts, windows, startup commands, and panes.

Default auto-detected file (single target):

- `.proj/layout.yaml` (or `.proj/layout.yml`)

Named layout file:

- `.proj/layouts/<name>.yaml` (or `.yml`), used via `--layout <name>`

Recommended project structure for multiple layouts:

```text
my-workspace/
  .proj/
    layout.yaml
    layouts/
      dev.yaml
      debug.yaml
      staging.yaml
```

YAML schema:

```yaml
session:
  name: optional-session-name
windows:
  - name: window-name
    dir: ~/Developer/some-repo
    command: pnpm dev
    panes:
      - split: h
        command: mysql ...
      - split: v
        command: tail -f log.txt
```

- `session.name` optional; when set it overrides derived tmux session name
- `windows[].name` required
- `windows[].dir` optional (defaults to target dir)
- `windows[].command` optional
- `panes` optional
- `split` values: `h` (top/bottom), `v` (left/right)

Cow/cob/cos example:

```yaml
session:
  name: cow-stack
windows:
  - name: cow
    dir: ~/Developer/cow
    command: z cow && pnpm dev
  - name: cob
    dir: ~/Developer/cob
    command: z cob && pnpm dev
  - name: cos
    dir: ~/Developer/cos
    command: z cos && ./gradlew bootRun
    panes:
      - split: h
        command: mysql -P 3301 --protocol=tcp -u root -ppaymenow
```

Selection order in single-target mode:

1. `--layout -f <path>` or `--file <path>`
2. `--layout <name|file>`
3. `.proj/layout.yaml` or `.proj/layout.yml`
4. built-in default windows (`editor`, `runtime`, `ops`)

## Requirements

- `tmux` (required)
- `yq` (required for YAML layouts)
- `fzf` (optional for no-arg picker)
