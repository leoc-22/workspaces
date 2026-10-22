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

## Rex

`rex/tmux_workspaces.lua` brings the workspace launcher to the
[Rex](https://www.superlogical.com/rex/docs) terminal as a custom action. Load it
from `~/.config/rex/init.lua`, using the absolute path to this repository:

```lua
package.path = "/path/to/tmux-workspaces/rex/?.lua;" .. package.path
require("tmux_workspaces").setup()
```

Run `rex config reload`, then search for "Open Workspace" in the command palette
or run it from the CLI:

```sh
rex do workspace                       # the focused terminal's directory
rex do workspace dir=my-app            # resolved like tmux-workspaces <project>
rex do workspace layout=dev            # like --layout dev
rex do workspace file=stack.yaml dir=. # like --file stack.yaml .
```

The action creates a session, names it like the tmux launcher does, and
switches to it. An existing session with that name is reused. Projects resolve
through an explicit path, a directory relative to the focused terminal, an
optional zoxide match, then `~/Developer/<name>`. Relative `file` paths also
resolve from the focused terminal.

[YAML layouts](#yaml-layouts) work as they do with tmux, found the same way and
with the same errors. Without one, the session gets `editor`, `shell`, and
`runtime` windows. Commands are typed into each pane's shell, and panes split
the window's first pane in order, matching the tmux layout.

`setup` accepts overrides for `action`, `project_root`, `window_names`,
`layouts_dir`, and the `zoxide` and `yq` programs to run. The Rex server may not
inherit your shell's PATH, so give absolute paths such as
`/opt/homebrew/bin/yq` if needed.

For session switching, Rex's built-in picker replaces `--session`:

```lua
rex.bind("cmd+k", "session.switch")
```

### Renaming sessions from their work

The `rename_session` action ("Rename Session from Work") asks Claude Haiku to name
the current session after what its panes show. It sends each terminal pane's
window name, directory, program, title, and last 15 lines of screen to
`claude -p`, so it needs the [Claude Code](https://claude.com/claude-code) CLI
signed in. A rename takes a few seconds.

```lua
rex.bind("cmd+shift+r", "rename_session")
```

Labels look like `stack: auth-refactor`. The part before the colon is the
workspace name, so `workspace` still finds and reuses the session. A session
without one gets the workspace name of the repository most of its panes are in.

`setup` also accepts `rename_action`, `rename_model` (default `haiku`), and
`claude`, the CLI to run. The Rex server may not find it on its PATH, so give its
absolute path, as in the example below.

A full `init.lua` with Homebrew tools:

```lua
package.path = "/path/to/tmux-workspaces/rex/?.lua;" .. package.path
require("tmux_workspaces").setup{
  yq = "/opt/homebrew/bin/yq",
  zoxide = "/opt/homebrew/bin/zoxide",
  claude = os.getenv("HOME") .. "/.local/bin/claude",
}
rex.bind("cmd+shift+o", "workspace")
rex.bind("cmd+shift+r", "rename_session")
rex.bind("cmd+k", "session.switch")
```

## Tests

```sh
bash tests/tmux-workspaces-regression.sh
luajit tests/rex-workspaces-test.lua
```

Tests use real yq v4 to parse YAML and stub tmux, fzf, and zoxide to avoid changing
live sessions or consulting your directory history. Interactive cases use a
pseudo-terminal. They verify command behavior, not the rendered fzf appearance.
