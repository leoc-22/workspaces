# tmux workflow

`tmux-workspace` is a tmux launcher in a Primeagen-style script path.

## Install

Commands:

- `tmux-workspace`

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
type -a tmux-workspace
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
tmux-workspace
tmux-workspace my-app
tmux-workspace --layout dev my-workspace
tmux-workspace --file ~/Developer/layouts/cow.yaml
```

CLI options:

- `--layout <name>`: use `~/.config/tmux-workspaces/layouts/<name>.yaml` (or `.yml`)
- `--file <path>`: use a specific YAML file path
- `-h`, `--help`: show help

Help shortcuts:

- `tmux-workspace --help`

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

Default auto-detected file (single target):

- `.workspace/layout.yaml` (or `.workspace/layout.yml`)

Named layout file:

- `~/.config/tmux-workspaces/layouts/<name>.yaml` (or `.yml`), used via `--layout <name>`

Recommended structure:

```text
~/.config/tmux-workspaces/
  layouts/
    dev.yaml
    debug.yaml
    staging.yaml

my-workspace/
  .workspace/
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

1. `--file <path>`
2. `--layout <name>`
3. `.workspace/layout.yaml` or `.workspace/layout.yml`
4. built-in default windows (`editor`, `runtime`, `ops`)

## External Dependencies

- `tmux` (required): session/window management
- `yq` (required for YAML layouts): parse `layout.yaml` and named layouts
- `fzf` (required for interactive no-arg mode): picker for `tmux-workspace` with no arguments
- `zoxide` (optional): smart directory match for `tmux-workspace <name>`

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
bash tests/tmux-workspace-regression.sh
```
