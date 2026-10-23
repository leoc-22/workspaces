# workspaces

A small project workspace launcher for [tmux](#install) and [Rex](#rex). Open a
project as a session with `ai`, `editor`, and `shell` windows, or launch a saved
YAML layout with windows, commands, and panes. Both use the same layouts.

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
type -a workspaces
```

For other shells, add the absolute path to `scripts` to your shell's PATH
configuration. To uninstall, remove that PATH entry.

To use the launcher in the Rex terminal instead, see [Rex](#rex). It needs yq for
YAML layouts and optionally zoxide, but not tmux or fzf.

## Commands

| Command | Behavior |
| --- | --- |
| `workspaces` | Pick an active session or project. Without an interactive terminal, use the current directory. |
| `workspaces <project-or-directory>` | Open or create that project's workspace. Use `.` for the current directory. |
| `workspaces --session [name]` | Switch to an existing session, or pick from sessions only when no name is supplied. |
| `workspaces --layout <name> [target]` | Use a named layout from `~/.config/workspaces/layouts/`. |
| `workspaces --file <path> [target]` | Use a specific YAML file. Relative file paths resolve from the current directory. |
| `workspaces --popup` | Fill an existing tmux popup without an inner border. Also works with `--session`. |
| `workspaces --help` | Show command help. |

Short options are `-s`, `-l`, `-f`, and `-h`. Value options also accept
`--option=value`. Use `--` before a target beginning with a dash.

Only one target is accepted. `--layout` and `--file` are alternatives; neither
can be combined with `--session`. Cancelling either picker exits successfully.
Session selection switches clients inside tmux and attaches outside tmux.

## Popup shortcut

Add this to `~/.tmux.conf` and reload the configuration:

```tmux
bind-key C-w display-popup -E -w 50% -h 28% "workspaces --popup"
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
for `.workspaces/layout.yaml` or `.yml` in the project. Without a layout,
it creates three windows: `ai`, `editor`, and `shell`.
Named layouts also accept `.yaml` or `.yml`, with `.yaml` preferred.

With a layout and no target, `session.dir` supplies the project directory,
otherwise the current directory is used. An explicit or picker-selected project
always overrides `session.dir`. Existing sessions are reused; layouts run only
when creating a session.

Sessions are named after the project's path below `~/Developer`, or its full
path elsewhere, lowercased with each run of other characters replaced by `-`.
For example, `~/Developer/My App` becomes `my-app` and `/srv/api` becomes
`srv-api`. A layout's `session.name` overrides this.

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

## Rex

`rex/workspaces.lua` brings the workspace launcher to the
[Rex](https://www.superlogical.com/rex/docs) terminal as a custom action named
`workspace`. To create `~/.config/rex/init.lua` from
[rex/init.example.lua](rex/init.example.lua), run this from the repository root
in Fish, Bash, or Zsh:

```sh
mkdir -p ~/.config/rex
test -e ~/.config/rex/init.lua || sed "s|/path/to/workspaces|$PWD|" rex/init.example.lua > ~/.config/rex/init.lua
```

It fills in this repository's path and doesn't touch an existing `init.lua`. If
you already have one, append the example instead by changing `>` to `>>`. The
result looks like this:

```lua
-- Example ~/.config/rex/init.lua. The README's install command fills in
-- this repository's path below.
package.path = "/Users/you/Developer/workspaces/rex/?.lua;" .. package.path
require("workspaces").setup{
  yq = "/opt/homebrew/bin/yq",
  zoxide = "/opt/homebrew/bin/zoxide",
  -- shell = "/opt/homebrew/bin/fish", -- leave unset to use your login shell
}
rex.bind("cmd+shift+o", "workspace")

-- Save and restore every session, like tmux-resurrect.
require("resurrect").setup{
  -- shell = "/opt/homebrew/bin/fish", -- leave unset to use your login shell
}
rex.bind("cmd+alt+s", "resurrect_save")
rex.bind("cmd+alt+r", "resurrect_restore")
```

Then edit `~/.config/rex/init.lua` to fit your setup:

- **yq and zoxide:** the Rex server may not inherit your shell's PATH, so these
  are absolute paths. The ones above are Homebrew's on Apple silicon; check
  yours with `command -v yq zoxide`.
- **shell:** new panes run your account's login shell. If your other Rex panes
  run a different shell, such as Fish, uncomment this line and set it to that
  shell's path, from `command -v fish`.
- **Key:** bind any key Rex doesn't already use.

Then load the file and confirm the actions are there:

```sh
rex config check    # exists: yes, actions: 4
rex config reload
```

Press the key, or search for "Open Workspace" in the command palette. Both open
the focused terminal's directory, since neither passes arguments. To choose a
project or layout, run the action from the CLI:

```sh
rex do workspace                       # the focused terminal's directory
rex do workspace dir=my-app            # resolved like workspaces <project>
rex do workspace layout=dev            # like --layout dev
rex do workspace file=stack.yaml dir=. # like --file stack.yaml .
```

From the CLI, the app switches to the session only when Remote Control is on in
Rex's Settings under Rex Server. Without it the session is still created, and
`rex do` reports that Rex.app is not accepting actions.

The action creates a session, names it like the tmux launcher does, and
switches to it. An existing session with that name is reused. Projects resolve
through an explicit path, a directory relative to the focused terminal, an
optional zoxide match, then `~/Developer/<name>`. Relative `file` paths also
resolve from the focused terminal.

[YAML layouts](#yaml-layouts) work as they do with tmux, found the same way and
with the same errors. Without one, the session gets `ai`, `editor`, and
`shell` windows. Commands are typed into each pane's shell, and panes split
the window's first pane in order, matching the tmux layout.

`setup` accepts overrides for `action` (the action's name), `project_root`,
`window_names`, `layouts_dir`, `shell` (the panes' shell), and the `zoxide` and
`yq` programs to run.

There is no Rex equivalent of the project picker. For switching sessions, Rex's
built-in "Change Session…" picker replaces `--session`; bind it to a free key
with `rex.bind("<key>", "session.switch")`.

## Saving and restoring sessions

`rex/resurrect.lua` saves every Rex session to a file and brings them back
when you ask, like [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect).
The [example configuration](rex/init.example.lua) loads it and binds
Cmd+Alt+S to save and Cmd+Alt+R to restore. Both are also in the command
palette as "Save Sessions" and "Restore Sessions". From the CLI:

```sh
rex do resurrect_save                          # save every session
rex do resurrect_restore                       # restore the last save
rex do resurrect_restore dry_run=true          # show what restore would do
rex do resurrect_restore session=api           # restore only the session labeled api
rex do resurrect_list                          # list the saves, newest first
rex do resurrect_restore file=rex_resurrect_20261023T091500.json
```

A save records each session's label, its windows in order and which was
active, the splits and their ratios, the window and block labels you set, and
each terminal's directory. Labels Rex generated, such as `Window 1a2b3c4d`,
aren't saved, so restored windows and blocks get fresh ones. Directories come
from the shell's reported working directory, or from the foreground program
when the shell reports none.

A terminal running `vi`, `vim`, `nvim`, `emacs`, `man`, `less`, `more`,
`tail`, `top`, or `htop` gets that command typed back in and run on restore,
with its arguments as `ps` reports them, which drops their quoting. Set
`run_commands = false` to type the command at the prompt without running it.
Every other terminal comes back as a shell in the same directory. Screen
contents, scrollback, and floating layers aren't saved.

Untouched sessions aren't saved: one window holding one shell, with Rex's
labels, in your home directory, running nothing, like the session the Rex app
creates when it starts. If there's nothing else to save, the save writes no
file and leaves `last.json` alone, so saving right after a restart never
replaces the sessions you meant to restore.

Saves go to `~/.local/share/rex/resurrect/` (under `$XDG_DATA_HOME` when set),
one timestamped file per save plus `last.json`, which restore reads by
default. A `file` without a slash is looked up there. The newest 20
timestamped saves are kept. Saves can hold commands, so the directory and its
files are readable only by you, and each file is written in full before it
replaces the old one.

Restore skips any session whose label is already open, so it is safe to run
more than once. It reports what it `restored`, `skipped`, and why anything
`failed`; one session failing doesn't stop the others.

`setup` accepts overrides for `save_action`, `restore_action`, `list_action`,
`dir`, `keep`, `shell` (the restored panes' shell), `restore_programs`, and
`run_commands`.

## Tests

```sh
bash tests/workspaces-regression.sh
luajit tests/rex-workspaces-test.lua
luajit tests/rex-resurrect-test.lua
```

The shell tests need yq v4 and `script(1)`, which macOS includes. They use real
yq to parse YAML and stub tmux, fzf, and zoxide to
avoid changing live sessions or consulting your directory history. Interactive
cases use a pseudo-terminal. They verify command behavior, not the rendered fzf
appearance.

The Rex tests need [LuaJIT](https://luajit.org) (`brew install luajit`) and yq.
They stub the Rex API, so they create no sessions and Rex doesn't need to be
running.
