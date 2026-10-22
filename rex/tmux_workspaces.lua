-- Rex port of tmux-workspaces: open a project as a Rex session with
-- editor, shell, and runtime windows, reusing the session when it exists.
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
  window_names = { "editor", "shell", "runtime" },
  zoxide = "zoxide",
}

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

-- Shows the session in the app that ran the action. From the CLI there may be
-- no client to ask, which is fine.
local function show(session_id, window_id)
  pcall(rex.client.queue, "session.select", { session_id = session_id, window_id = window_id })
end

function M.open(ctx, args)
  local base = focused_dir(ctx) or HOME
  local target = M.canonical_dir(M.resolve_target(args.dir, base))
  if target == nil then
    error("project directory not found: " .. (args.dir or base), 0)
  end

  local label = M.session_name_for(target, M.config.project_root)
  local existing = find_session(label)
  if existing ~= nil then
    show(existing)
    return { session_id = existing, created = false }
  end

  local s, err = rex.call("session.create", {
    label = label,
    initial_windows = M.default_windows(target),
  })
  if s == nil then
    error(err, 0)
  end

  -- session.create activates the last window; tmux-workspaces starts on the
  -- first. Focusing a window requires attaching to its session.
  local first = s.initial_windows[1].window_id
  rex.session.attach{ session_id = s.session_id }
  rex.session.focus_window{ session_id = s.session_id, window_id = first }
  rex.session.detach{ session_id = s.session_id }
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
    description = "Open a project as a session with editor, shell, and runtime windows.",
    keywords = "tmux-workspaces project",
    args = { dir = "string?" },
    run = M.open,
  }
end

return M
