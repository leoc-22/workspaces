# tmux-workspaces

`tmux-workspaces` is a tmux workspace launcher inspired by ThePrimeagen's sessionizer.

## Install

The command is the `scripts/tmux-workspaces` shell script. Add the repo's `scripts` directory to your `PATH`.

Fish (current shell):

```fish
set -gx PATH /Users/leoc/Developer/tmux-workspaces/scripts $PATH
```

Fish (persist):

```fish
fish_add_path /Users/leoc/Developer/tmux-workspaces/scripts
```

Check command path:

```fish
type -a tmux-workspaces
```

The command should appear as `tmux-workspaces`.

## Uninstall (Fish)

Remove persisted PATH entry:

```fish
set -l target /Users/leoc/Developer/tmux-workspaces/scripts
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
tmux-workspaces ../shared-lib
tmux-workspaces --layout dev
tmux-workspaces --layout --file ~/layouts/cow.yaml
tmux-workspaces --help
```

## Command Modes

`tmux-workspaces` supports one target per invocation. A target can be a project name or a directory path.

| Command | Mode | Behavior |
| --- | --- | --- |
| `tmux-workspaces` | Interactive picker | Opens `fzf` when running in an interactive terminal. Cancel exits without error. |
| `tmux-workspaces` | Current directory | In non-interactive use, uses the current directory. |
| `tmux-workspaces <target>` | Target workspace | Resolves `<target>` to a directory, then uses project-local layout if present, otherwise default windows. |
| `tmux-workspaces --layout <name> [target]` | Named layout | Loads `~/.config/tmux-workspaces/layouts/<name>.yaml` or `.yml`. If no target is given, uses `session.dir` from the layout when present, otherwise the current directory. |
| `tmux-workspaces --layout --file <path> [target]` | Explicit layout file | Loads the YAML file at `<path>` from anywhere. If no target is given, uses `session.dir` from the layout when present, otherwise the current directory. |
| `tmux-workspaces --help` | Help | Prints command help. |

## Options

| Option | Meaning |
| --- | --- |
| `--layout <name>` | Use a named global layout from `~/.config/tmux-workspaces/layouts/<name>.yaml` or `.yml`. The value must be a layout name, not a path. |
| `--layout --file <path>` | Use a specific YAML layout file. The path can point anywhere and is resolved exactly as supplied. |
| `-h`, `--help` | Show help. |

Notes:

- `--file <path>` by itself is not a valid mode; use `--layout --file <path>`.
- `--layout` modes skip `fzf` when no target is provided and use `session.dir` from the layout when present, otherwise the current directory.
- A target passed on the command line overrides `session.dir`.
- Only one target is supported per command invocation.

## Resolution Order

When a target is provided, it resolves to a directory in this order:

1. explicit path (`.`, `..`, `./...`, `../...`, `/...`, `~/...`)
2. existing local directory in current working directory
3. `zoxide` match (`zoxide query <name>`) when available
4. fallback to `~/Developer/<name>`

In single-target mode, the layout is selected in this order:

1. `--layout --file <path>`: explicit YAML file from anywhere
2. `--layout <name>`: global named layout from `~/.config/tmux-workspaces/layouts/`
3. auto-detect project-local `.tmux-workspaces/layout.yaml` or `.tmux-workspaces/layout.yml` in the target directory
4. built-in default windows (`editor`, `shell`, `runtime`)

## YAML layout (recommended)

YAML supports named layouts, windows, startup commands, and panes.

There are two different YAML layout sources:

- Project-local layout: `.tmux-workspaces/layout.yaml` (or `.tmux-workspaces/layout.yml`) inside the target directory
  - Auto-detected when you run `tmux-workspaces <target>` without `--layout`
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
  name: optional-session-name       # optional
  dir: ~/Developer/my-workspace     # optional; target directory for the session
  path: ~/Developer/my-workspace    # optional alias for session.dir
windows:
  - name: window-name               # required
    dir: ~/Developer/some-repo      # optional; defaults to target directory
    path: ~/Developer/some-repo     # optional alias for dir
    command: pnpm dev               # optional
    run: pnpm dev                   # optional alias for command
    panes:
      - mysql ...                   # string form; split defaults to h
      - split: h                    # optional; h/top-bottom or v/left-right
        command: tail -f log.txt
      - split: v
        run: pnpm test              # run is an alias for command
```

Field reference:

| Field | Required | Meaning |
| --- | --- | --- |
| `session.name` | No | Overrides the derived tmux session name. The value is normalized before use. |
| `session.dir` | No | Target directory for the session. Used when the command does not pass a target. |
| `session.path` | No | Alias for `session.dir`. Used only when `dir` is not set. |
| `windows` | Yes | List of windows to create. Must contain at least one item. |
| `windows[].name` | Yes | tmux window name. |
| `windows[].dir` | No | Working directory for the window. Defaults to the selected target directory. |
| `windows[].path` | No | Alias for `windows[].dir`. Used only when `dir` is not set. |
| `windows[].command` | No | Command sent to the window after it is created. |
| `windows[].run` | No | Alias for `windows[].command`. Used only when `command` is not set. |
| `windows[].panes` | No | Extra panes to split from the window. Each item can be a command string or a map. |
| `windows[].panes[]` | No | String form pane command. Uses horizontal split (`h`). |
| `windows[].panes[].command` | No | Command sent to the pane after it is created. Empty commands are skipped. |
| `windows[].panes[].run` | No | Alias for pane `command`. Used only when `command` is not set. |
| `windows[].panes[].split` | No | Split direction. Supported values: `h`, `horizontal`, `top-bottom`, `v`, `vertical`, `left-right`. Defaults to `h`. |

Split directions:

- `h`, `horizontal`, `top-bottom`: create a top/bottom tmux split.
- `v`, `vertical`, `left-right`: create a left/right tmux split.

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
