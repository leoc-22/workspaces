# tmux-workspaces

`tmux-workspaces` is a tmux launcher in a Primeagen-style script path.

## Install

Commands:

- `tmux-workspaces`

The command lives in `scripts`.

Fish (current shell):

```fish
set -gx PATH /Users/leoc/Developer/tmux-workflow/scripts $PATH
```

Fish (persist):

```fish
fish_add_path /Users/leoc/Developer/tmux-workflow/scripts
```

Check command path:

```fish
type -a tmux-workspaces
```

## Uninstall (Fish)

Remove persisted PATH entry:

```fish
set -l target /Users/leoc/Developer/tmux-workflow/scripts
set -l i (contains -i -- $target $fish_user_paths)
if test -n "$i"
    set -e fish_user_paths[$i]
end
```

Remove from current shell PATH too:

```fish
set -gx PATH (string match -v -- $target $PATH)
```

If you manually added `set -gx PATH .../scripts $PATH` in `~/.config/fish/config.fish`, remove that line.

## Usage

```bash
tmux-workspaces
tmux-workspaces my-app
tmux-workspaces --layout dev my-workspace
tmux-workspaces --file ~/Developer/layouts/cow.yaml
```

CLI options:

- `--layout <name>`: use a named global layout from `~/.config/tmux-workspaces/layouts/<name>.yaml` (or `.yml`)
- `--file <path>`: use a specific YAML file path
- `-h`, `--help`: show help

Help shortcuts:

- `tmux-workspaces --help`

- No args (interactive): opens `fzf`; cancel exits
- No args (non-interactive): uses current directory
- With `--layout`/`--file` and no target: uses current directory (skips `fzf`)
- One target per command invocation
- `--layout` / `--file` are for single-target mode only

Target resolution order:

1. explicit path (`.`, `..`, `/...`, `~/...`)
2. existing local directory in current working directory
3. `zoxide` match (`zoxide query <name>`) when available
4. fallback to `~/Developer/<name>`

## YAML layout (recommended)

YAML supports named layouts, windows, startup commands, and panes.

There are two different YAML layout sources:

- Project-local layout: `.tmux-workspaces/layout.yaml` (or `.tmux-workspaces/layout.yml`) inside the target directory
  - Auto-detected when you run `tmux-workspaces <target>` without `--layout` or `--file`
  - Best for project-specific setup that should live with that repo
- Global named layout: `~/.config/tmux-workspaces/layouts/<name>.yaml` (or `.yml`)
  - Used only when you pass `--layout <name>`
  - Best for reusable templates shared across multiple projects

In short: `.tmux-workspaces/layout.yaml` is automatic per project; `~/.config/tmux-workspaces/layouts/*.yaml` is opt-in via `--layout`.

Recommended structure:

```text
~/.config/tmux-workspaces/
  layouts/
    dev.yaml
    debug.yaml
    staging.yaml

my-workspace/
  .tmux-workspaces/
    layout.yaml
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

See `examples/layout.yaml` for this example in the repo.

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

1. `--file <path>`: explicit YAML file (any location)
2. `--layout <name>`: global named layout from `~/.config/tmux-workspaces/layouts/`
3. auto-detect project-local `.tmux-workspaces/layout.yaml` or `.tmux-workspaces/layout.yml` in the target directory
4. built-in default windows (`editor`, `runtime`, `ops`)

## External Dependencies

- `tmux` (required): session/window management
- `yq` (required for YAML layouts): parse project-local `.tmux-workspaces/layout.yaml` and global named layouts
- `fzf` (required for interactive no-arg mode): picker for `tmux-workspaces` with no arguments
- `zoxide` (optional): smart directory match for `tmux-workspaces <name>`

Install (macOS/Homebrew):

```bash
brew install tmux yq fzf
```

Optional (`zoxide`):

```bash
brew install zoxide
```

Install (Ubuntu/Debian):

```bash
sudo apt update
sudo apt install -y tmux yq fzf
```

Optional (`zoxide`):

```bash
sudo apt install -y zoxide
```

## Regression Test

Run the tiny shell regression harness:

```bash
bash tests/tmux-workspaces-regression.sh
```
