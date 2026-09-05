# tmux-workspaces

A small tmux workspace launcher. Pick an existing session or a project directory,
or launch a saved layout with windows, commands, and panes.

## Install

Requires Bash, tmux, and fzf for interactive selection. YAML layouts also require
[Mike Farah's yq v4](https://github.com/mikefarah/yq). zoxide is optional for
looking up project names.

On macOS:

```sh
brew install tmux fzf yq
```

Add this repository's `scripts` directory to your PATH. For Fish, run this from
the repository root:

```fish
fish_add_path "$PWD/scripts"
type -a tmux-workspaces
```

For other shells, add the absolute path to `scripts` to your shell's PATH
configuration. To uninstall, remove that PATH entry.

## Commands

| Command | Behavior |
| --- | --- |
| `tmux-workspaces` | Pick an active session or project. Without an interactive terminal, use the current directory. |
| `tmux-workspaces <project-or-directory>` | Open or create that project's workspace. Use `.` for the current directory. |
| `tmux-workspaces --session [name]` | Switch to an existing session, or pick from sessions only when no name is supplied. |
| `tmux-workspaces --layout <name> [target]` | Use a named layout from `~/.config/tmux-workspaces/layouts/`. |
| `tmux-workspaces --file <path> [target]` | Use a specific YAML file. Relative file paths resolve from the current directory. |
| `tmux-workspaces --popup` | Fill an existing tmux popup without an inner border. Also works with `--session`. |
| `tmux-workspaces --help` | Show command help. |

Short options are `-s`, `-l`, `-f`, and `-h`. Value options also accept
`--option=value`. Use `--` before a target beginning with a dash.

Only one target is accepted. `--layout` and `--file` are alternatives; neither
can be combined with `--session`. Cancelling either picker exits successfully.
Session selection switches clients inside tmux and attaches outside tmux.

## Popup shortcut

Add this to `~/.tmux.conf` and reload the configuration:

```tmux
bind-key C-w display-popup -E -w 50% -h 28% "tmux-workspaces --popup"
```

Press your tmux prefix followed by Ctrl-W. tmux sets the popup size; `--popup`
makes fzf fill it. Regular terminal use keeps a bordered, 40%-height picker.
The command must be on tmux's shell PATH, or use its absolute path in the binding.

## Project and layout lookup

Project targets resolve through an explicit path, an existing local directory,
an optional zoxide match, then `~/Developer/<name>`.
The picker lists immediate subdirectories of `~/Developer`. Set
`PROJ_SEARCH_DIRS` to a colon-separated list of roots to search elsewhere.

An explicit `--layout` or `--file` takes precedence. Otherwise the launcher looks
for `.tmux-workspaces/layout.yaml` or `.yml` in the project. Without a layout,
it creates three windows: `editor`, `shell`, and `runtime`.
Named layouts also accept `.yaml` or `.yml`, with `.yaml` preferred.

With a layout and no target, `session.dir` supplies the project directory,
otherwise the current directory is used. An explicit or picker-selected project
always overrides `session.dir`. Existing sessions are reused; layouts run only
when creating a session.

## YAML layouts

```yaml
session:
  name: my-stack
  dir: ~/Developer/my-app
windows:
  - name: editor
    command: nvim
  - name: runtime
    dir: backend
    command: pnpm dev
    panes:
      - split: h
        command: tail -f app.log
      - split: v
        command: pnpm test
```

| Field | Meaning |
| --- | --- |
| `session.name` | Optional override for the session name derived from the project path. |
| `session.dir` | Optional project directory when no target is supplied. |
| `windows` | Nonempty list of windows. Each window needs a `name`. |
| `windows[].dir` | Working directory, relative to the project unless absolute or `~/…`. Defaults to the project directory. |
| `windows[].command` | Optional startup command. |
| `windows[].panes` | Optional list of objects with `command` and optional `split`. Empty commands are skipped. |
| `windows[].panes[].split` | `h` for top/bottom (default), or `v` for left/right. |

See [examples/layout.yaml](examples/layout.yaml) for a layout spanning projects.

### Migrating older commands and layouts

- Replace `--layout --file <path>` with `--file <path>`.
- Rename YAML `path` fields to `dir`, and `run` fields to `command`.
- Replace string panes such as `- nvim` with `- command: nvim`.
- Replace `horizontal` or `top-bottom` with `h`; replace `vertical` or
  `left-right` with `v`.
- Move commands embedded in `split: h:command` or `split: v:command` into the
  separate `command` field.

Removed YAML forms produce an error before session creation.

## Tests

```sh
bash tests/tmux-workspaces-regression.sh
```

Tests use real yq v4 to parse YAML and stub tmux, fzf, and zoxide to avoid changing
live sessions or consulting your directory history. Interactive cases use a
pseudo-terminal. They verify command behavior, not the rendered fzf appearance.
