-- Rex port of tmux-workspaces: open a project as a Rex session with
-- ai, editor, and shell windows, or with a YAML layout, reusing the
-- session when it exists.
--
-- Load it from ~/.config/rex/init.lua:
--
--   package.path = "/path/to/tmux-workspaces/rex/?.lua;" .. package.path
--   require("tmux_workspaces").setup()

local M = {}

local SHELL = "com.superlogical.terminal.shell"
local TERMINAL = "com.superlogical.terminal"
local HOME = os.getenv("HOME") or ""

M.config = {
  action = "workspace",
  project_root = HOME .. "/Developer",
  window_names = { "ai", "editor", "shell" },
  layouts_dir = HOME .. "/.config/tmux-workspaces/layouts",
  zoxide = "zoxide",
  yq = "yq",
}

local LAYOUT_FILES = { ".tmux-workspaces/layout.yaml", ".tmux-workspaces/layout.yml" }

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.normalize_name(value)
  local name = value:lower():gsub("[^%w]+", "-")
  return (name:gsub("^%-", ""):gsub("%-$", ""))
end

function M.expand_path(path)
  if path == "~" then
    return HOME
  end
  if path:sub(1, 2) == "~/" then
    return HOME .. path:sub(2)
  end
  return path
end

-- Mirrors session_name_for_target: paths under the project root keep their
-- relative path, anything else uses the whole path.
function M.session_name_for(dir, root)
  local source = dir
  if dir:sub(1, #root + 1) == root .. "/" then
    source = dir:sub(#root + 2)
  end
  local name = M.normalize_name(source)
  if name == "" then
    return "project"
  end
  return name
end

-- Returns the physical path of an existing directory, or nil.
function M.canonical_dir(path)
  if path == nil or path == "" then
    return nil
  end
  local r = rex.exec({ "/bin/sh", "-c", 'cd -- "$1" 2>/dev/null && pwd -P', "sh", path })
  if r == nil or not r.ok then
    return nil
  end
  return trim(r.stdout)
end

-- Returns the physical path of an existing file, or nil.
function M.canonical_file(path)
  if path == nil or path == "" then
    return nil
  end
  local r = rex.exec({
    "/bin/sh", "-c", 'test -f "$1" && cd -- "$(dirname -- "$1")" && printf "%s/%s\\n" "$(pwd -P)" "$(basename -- "$1")"',
    "sh", path,
  })
  if r == nil or not r.ok then
    return nil
  end
  return trim(r.stdout)
end

local function zoxide_query(name)
  local r = rex.exec({ M.config.zoxide, "query", "--", name })
  if r == nil or not r.ok then
    return nil
  end
  local dir = trim(r.stdout)
  if dir == "" then
    return nil
  end
  return dir
end

-- Resolves a target like the shell script: an explicit path, a directory
-- relative to base, a zoxide match, then project_root/<name>.
function M.resolve_target(target, base)
  if target == nil or target == "" or target == "." then
    return base
  end
  local path = M.expand_path(target)
  if path:sub(1, 1) == "/" then
    return path
  end
  if path:find("/") or path:sub(1, 1) == "." or M.canonical_dir(base .. "/" .. path) then
    return base .. "/" .. path
  end
  return zoxide_query(path) or (M.config.project_root .. "/" .. path)
end

local function url_decode(value)
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

-- The focused terminal's directory stands in for the shell's current directory.
local function focused_dir(ctx)
  if ctx.block_id == nil then
    return nil
  end
  local r = rex.block.call(TERMINAL, "pwd", { block_id = ctx.block_id })
  if r == nil or r.pwd == nil then
    return nil
  end
  local path = r.pwd:match("^file://[^/]*(/.*)$") or r.pwd
  return url_decode(path)
end

local function find_session(label)
  local r, err = rex.call("session.list")
  if r == nil then
    error(err, 0)
  end
  for _, session in ipairs(r.sessions or {}) do
    if session.label == label then
      return session.session_id
    end
  end
  return nil
end

local function shell_block(dir, label, command)
  local options = { cwd = dir }
  if command ~= nil and command ~= "" then
    options.initial_input = command .. "\r"
  end
  return rex.layout.block{ flavor = SHELL, label = label, options = options }
end

function M.default_windows(dir)
  local windows = {}
  for _, name in ipairs(M.config.window_names) do
    table.insert(windows, { window_label = name, layout = shell_block(dir, name) })
  end
  return windows
end

-- Finds the layout file: an explicit file (relative to base), a named layout,
-- then the project's own .tmux-workspaces/layout.yaml or .yml.
function M.find_layout_file(args, base, target)
  if args.file ~= nil then
    local path = M.expand_path(args.file)
    if path:sub(1, 1) ~= "/" then
      path = base .. "/" .. path
    end
    return M.canonical_file(path) or error("layout file not found: " .. args.file, 0)
  end
  if args.layout ~= nil then
    local name = args.layout:gsub("%.yaml$", ""):gsub("%.yml$", "")
    for _, ext in ipairs({ ".yaml", ".yml" }) do
      local file = M.canonical_file(M.config.layouts_dir .. "/" .. name .. ext)
      if file ~= nil then
        return file
      end
    end
    error(("layout '%s' not found under %s"):format(args.layout, M.config.layouts_dir), 0)
  end
  for _, relative in ipairs(LAYOUT_FILES) do
    local file = M.canonical_file(target .. "/" .. relative)
    if file ~= nil then
      return file
    end
  end
  return nil
end

local function is_list(value)
  return type(value) == "table" and #value > 0
end

-- Mirrors validate_layout, including the errors for removed YAML forms.
function M.validate_layout(layout)
  local errors = {}
  local function add(message)
    for _, seen in ipairs(errors) do
      if seen == message then
        return
      end
    end
    table.insert(errors, message)
  end

  if not is_list(layout.windows) then
    return { "windows must be a nonempty list" }
  end
  if type(layout.session) == "table" and layout.session.path ~= nil then
    add("rename path to dir")
  end
  for _, window in ipairs(layout.windows) do
    if type(window) == "table" then
      if window.path ~= nil then
        add("rename path to dir")
      end
      if window.run ~= nil then
        add("rename run to command")
      end
      for _, pane in ipairs(type(window.panes) == "table" and window.panes or {}) do
        if type(pane) ~= "table" then
          add("panes must be objects with command and optional split")
        else
          if pane.run ~= nil then
            add("rename run to command")
          end
          local split = pane.split or "h"
          if split ~= "h" and split ~= "v" then
            add("pane split must be h (top/bottom) or v (left/right)")
          end
        end
      end
    end
  end
  return errors
end

function M.load_layout(file)
  local r, err = rex.exec({ M.config.yq, "-o=json", ".", file })
  if r == nil then
    error("yq is required for YAML layouts (" .. err .. ")", 0)
  end
  local layout = r.ok and rex.json.decode(r.stdout)
  if type(layout) ~= "table" then
    error("invalid YAML layout: " .. file, 0)
  end
  local errors = M.validate_layout(layout)
  if #errors > 0 then
    error(("invalid layout %s:\n%s"):format(file, table.concat(errors, "\n")), 0)
  end
  return layout
end

local function field(value)
  if value == nil then
    return ""
  end
  return trim(tostring(value))
end

local function resolve_layout_dir(target, raw)
  if raw == "" then
    raw = "."
  end
  local path = M.expand_path(raw)
  if path:sub(1, 1) ~= "/" then
    path = target .. "/" .. path
  end
  return M.canonical_dir(path) or error("layout directory not found: " .. path, 0)
end

-- tmux splits the window's first pane for each entry in panes, so the first
-- pane ends up innermost and the first split outermost. YAML h is top/bottom,
-- which Rex calls vertical.
local function window_layout(dir, name, command, panes)
  local function build(i)
    if i > #panes then
      return shell_block(dir, name, command)
    end
    local pane = panes[i]
    local split = (pane.split or "h") == "h" and rex.layout.vertical or rex.layout.horizontal
    return split(0.5, build(i + 1), shell_block(dir, nil, pane.command))
  end
  return build(1)
end

function M.layout_windows(layout, target, file)
  local windows = {}
  for i, window in ipairs(layout.windows) do
    local name = type(window) == "table" and field(window.name) or ""
    if name == "" then
      error(("missing windows[%d].name in %s"):format(i - 1, file), 0)
    end
    local dir = resolve_layout_dir(target, field(window.dir))
    local panes = {}
    for _, pane in ipairs(type(window.panes) == "table" and window.panes or {}) do
      local command = field(pane.command)
      if command ~= "" then
        table.insert(panes, { command = command, split = pane.split })
      end
    end
    table.insert(windows, {
      window_label = name,
      layout = window_layout(dir, name, field(window.command), panes),
    })
  end
  return windows
end

-- Shows the session in the app that ran the action. From the CLI there may be
-- no client to ask, which is fine.
local function show(session_id, window_id)
  pcall(rex.client.queue, "session.select", { session_id = session_id, window_id = window_id })
end

function M.open(ctx, args)
  if args.layout ~= nil and args.file ~= nil then
    error("layout and file cannot be combined", 0)
  end
  local base = focused_dir(ctx) or HOME
  local target = M.canonical_dir(M.resolve_target(args.dir, base))
  if target == nil then
    error("project directory not found: " .. (args.dir or base), 0)
  end

  local file = M.find_layout_file(args, base, target)
  local layout = file and M.load_layout(file)
  local session = layout and type(layout.session) == "table" and layout.session or {}

  -- An explicit target always wins over session.dir.
  local session_dir = field(session.dir)
  if args.dir == nil and session_dir ~= "" then
    target = M.canonical_dir(M.resolve_target(session_dir, base))
      or error("session.dir directory not found: " .. session_dir, 0)
  end

  local label = M.session_name_for(target, M.config.project_root)
  local name_override = field(session.name)
  if name_override ~= "" then
    label = M.normalize_name(name_override)
    if label == "" then
      error("invalid session.name in " .. file, 0)
    end
  end

  local existing = find_session(label)
  if existing ~= nil then
    show(existing)
    return { session_id = existing, created = false }
  end

  local s, err = rex.call("session.create", {
    label = label,
    initial_windows = layout and M.layout_windows(layout, target, file) or M.default_windows(target),
  })
  if s == nil then
    error(err, 0)
  end

  -- session.create activates the last window; tmux-workspaces starts on the
  -- first. Scripts run with rex do must attach to focus a window; actions in
  -- the configuration file have no attach.
  local first = s.initial_windows[1].window_id
  local attach = type(rex.session.attach) == "function"
  if attach then
    rex.session.attach{ session_id = s.session_id }
  end
  rex.session.focus_window{ session_id = s.session_id, window_id = first }
  if attach then
    rex.session.detach{ session_id = s.session_id }
  end
  show(s.session_id, first)
  return { session_id = s.session_id, created = true }
end

function M.setup(opts)
  for key, value in pairs(opts or {}) do
    M.config[key] = value
  end
  rex.action{
    name = M.config.action,
    title = "Open Workspace",
    description = "Open a project as a session from its YAML layout, or with ai, editor, and shell windows.",
    keywords = "tmux-workspaces project layout",
    args = { dir = "string?", layout = "string?", file = "string?" },
    run = M.open,
  }
end

return M
