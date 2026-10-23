-- Save every Rex session to a file and bring them back later, like
-- tmux-resurrect: windows, splits, ratios, labels, each terminal's directory,
-- and programs such as nvim that are safe to start again.
--
-- Load it from ~/.config/rex/init.lua:
--
--   package.path = "/path/to/workspaces/rex/?.lua;" .. package.path
--   require("resurrect").setup()

local M = {}

local SHELL = "com.superlogical.terminal.shell"
local HOME = os.getenv("HOME") or ""
local DATA_HOME = os.getenv("XDG_DATA_HOME") or (HOME .. "/.local/share")
local VERSION = 1

M.config = {
  save_action = "resurrect_save",
  restore_action = "resurrect_restore",
  list_action = "resurrect_list",
  dir = DATA_HOME .. "/rex/resurrect",
  keep = 20, -- the number of timestamped saves kept; last.json is extra
  run_commands = true, -- false types restored programs at the prompt without running them
  shell = nil, -- the panes' shell, such as /opt/homebrew/bin/fish; nil uses the login shell
  -- Foreground programs typed back into their terminal on restore, matching
  -- tmux-resurrect's defaults. Anything else comes back as a plain shell.
  restore_programs = { "vi", "vim", "nvim", "emacs", "man", "less", "more", "tail", "top", "htop" },
}

local function url_decode(value)
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function basename(path)
  return path:match("([^/]+)/*$") or path
end

-- Terminal methods go through block.method, which takes the session and block.
local function call_block(session_id, block_id, method)
  local r = rex.call("block.method", { session_id = session_id, block_id = block_id, method = method, args = {} })
  if type(r) ~= "table" then
    return nil
  end
  return r
end

local function block_pwd(session_id, block_id)
  local r = call_block(session_id, block_id, "pwd")
  if r == nil or type(r.pwd) ~= "string" or r.pwd == "" then
    return nil
  end
  return url_decode(r.pwd:match("^file://[^/]*(/.*)$") or r.pwd)
end

-- Every name the process goes by: its executable's, and the file names of
-- the path and argv0 it was started by.
local function process_names(fg)
  local names = {}
  for _, key in ipairs({ "name", "invoked_path", "argv0" }) do
    local value = fg[key]
    if type(value) == "string" and value ~= "" then
      names[basename(value)] = true
    end
  end
  return names
end

-- The process method reports no arguments, so the command line comes from ps,
-- which drops their quoting.
local function command_line(pid)
  if pid == nil then
    return nil
  end
  local r = rex.exec({ "ps", "-ww", "-o", "args=", "-p", tostring(pid) })
  if r == nil or not r.ok then
    return nil
  end
  local line = r.stdout:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" or line:find("%c") then
    return nil
  end
  return line
end

-- Returns the command line to type back in, or nil when the foreground program
-- is the block's own shell or isn't in restore_programs. The block's shell is
-- the outermost process other than login, so a foreground process with any
-- other ancestor is a program the shell runs.
function M.foreground_command(process)
  local fg = type(process) == "table" and process.foreground
  if type(fg) ~= "table" or type(fg.name) ~= "string" then
    return nil
  end
  local is_program = false
  for _, ancestor in ipairs(type(process.ancestors) == "table" and process.ancestors or {}) do
    if ancestor.name ~= "login" then
      is_program = true
    end
  end
  if not is_program then
    return nil
  end
  local names = process_names(fg)
  for _, program in ipairs(M.config.restore_programs) do
    if names[program] then
      return command_line(fg.pid) or program
    end
  end
  return nil
end

-- Rex's generated labels are left out, so restore gets fresh ones rather
-- than stale copies such as "Window 1a2b3c4d".
local HEX8 = string.rep("%x", 8)

local function user_window_label(label)
  if type(label) ~= "string" or label:match("^Window " .. HEX8 .. "$") then
    return nil
  end
  return label
end

local function user_block_label(label)
  if type(label) ~= "string" or label == "shell" or label:match("^Block " .. HEX8 .. "$") then
    return nil
  end
  return label
end

-- Layout nodes are { block_id } leaves or { split = { direction, ratio,
-- before, after } }. Blocks maps each block_id to its entry in the layer.
local function save_node(session_id, node, blocks)
  if type(node) ~= "table" then
    return nil
  end
  if type(node.split) == "table" then
    local split = node.split
    local before = save_node(session_id, split.before, blocks)
    local after = save_node(session_id, split.after, blocks)
    if before == nil or after == nil then
      return before or after
    end
    return { split = split.direction, ratio = split.ratio or 0.5, before = before, after = after }
  end
  local id = node.block_id
  if id == nil then
    return nil
  end
  local block = blocks[id] or {}
  if block.flavor ~= nil and block.flavor ~= SHELL then
    return { label = user_block_label(block.label) }
  end
  local process = call_block(session_id, id, "process")
  local cwd = block_pwd(session_id, id)
  if cwd == nil and process ~= nil and type(process.foreground) == "table" then
    cwd = process.foreground.cwd
  end
  return {
    label = user_block_label(block.label),
    cwd = cwd,
    command = M.foreground_command(process),
  }
end

-- A window's layout is its tiled layer's; floating layers aren't saved.
local function tiled_layer(window)
  for _, layer in ipairs(type(window.layers) == "table" and window.layers or {}) do
    if layer.kind == "tiled" then
      return layer
    end
  end
  return nil
end

function M.save_session(session)
  local view, err = rex.session.view{ session_id = session.session_id }
  if view == nil then
    error(err, 0)
  end
  local saved = { label = session.label or view.label, windows = {} }
  for _, window in ipairs(view.windows or {}) do
    local layer = tiled_layer(window)
    local blocks = {}
    for _, block in ipairs(layer and layer.blocks or {}) do
      blocks[block.block_id] = block
    end
    local layout = layer and save_node(session.session_id, layer.layout, blocks)
    if layout ~= nil then
      table.insert(saved.windows, { label = user_window_label(window.label), layout = layout })
      if window.window_id ~= nil and window.window_id == view.active_window_id then
        saved.active_window = #saved.windows
      end
    end
  end
  return saved
end

-- Writes through a temporary file and a rename, so a failed save never
-- leaves a partial snapshot. Snapshots hold commands, so only you can read them.
local function write_file(path, text)
  local tmp = path .. ".tmp"
  local file, err = io.open(tmp, "w")
  if file == nil then
    error(err, 0)
  end
  file:write(text)
  file:close()
  rex.exec({ "chmod", "600", tmp })
  local ok, rename_err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    error(rename_err, 0)
  end
end

local SNAPSHOT_PATTERN = "^rex_resurrect_%d+T%d+%.json$"

-- Snapshot file names, oldest first. Their timestamps sort as text.
local function snapshot_files()
  local r = rex.exec({ "ls", "-1", M.config.dir })
  local files = {}
  if r == nil or not r.ok then
    return files
  end
  for name in r.stdout:gmatch("[^\n]+") do
    if name:match(SNAPSHOT_PATTERN) then
      table.insert(files, name)
    end
  end
  table.sort(files)
  return files
end

local function prune()
  local files = snapshot_files()
  for i = 1, #files - M.config.keep do
    os.remove(M.config.dir .. "/" .. files[i])
  end
end

-- An untouched session has nothing worth restoring: one window holding one
-- shell with Rex's labels, in the home directory, running nothing. The Rex
-- app creates one when it starts with no sessions.
local function untouched(saved)
  local window = saved.windows[1]
  if #saved.windows ~= 1 or window.label ~= nil or window.layout.split ~= nil then
    return false
  end
  local block = window.layout
  return block.label == nil and block.command == nil and (block.cwd == nil or block.cwd == HOME)
end

-- With nothing to save, last.json is left alone, so saving right after a
-- restart doesn't replace the sessions you meant to restore.
function M.save()
  local list, err = rex.call("session.list")
  if list == nil then
    error(err, 0)
  end
  local snapshot = { version = VERSION, saved_at = os.time(), sessions = {} }
  for _, session in ipairs(list.sessions or {}) do
    local saved = M.save_session(session)
    if #saved.windows > 0 and not untouched(saved) then
      table.insert(snapshot.sessions, saved)
    end
  end
  if #snapshot.sessions == 0 then
    return { sessions = 0, message = "nothing to save; the last save is unchanged" }
  end

  local r = rex.exec({ "mkdir", "-p", "-m", "700", M.config.dir })
  if r == nil or not r.ok then
    error("could not create " .. M.config.dir, 0)
  end
  local text = assert(rex.json.encode(snapshot, { indent = true }))
  local file = ("%s/rex_resurrect_%s.json"):format(M.config.dir, os.date("%Y%m%dT%H%M%S", snapshot.saved_at))
  write_file(file, text)
  write_file(M.config.dir .. "/last.json", text)
  prune()
  return { file = file, sessions = #snapshot.sessions }
end

local function restore_node(node)
  if type(node) ~= "table" then
    error("snapshot has a missing layout", 0)
  end
  if node.split ~= nil then
    if node.split ~= "horizontal" and node.split ~= "vertical" then
      error("unknown split direction in snapshot: " .. tostring(node.split), 0)
    end
    local ratio = node.ratio or 0.5
    if type(ratio) ~= "number" or ratio <= 0 or ratio >= 1 then
      error("split ratio must be between 0 and 1: " .. tostring(ratio), 0)
    end
    return rex.layout[node.split](ratio, restore_node(node.before), restore_node(node.after))
  end
  local options = { cwd = node.cwd, shell = M.config.shell }
  if node.command ~= nil and node.command ~= "" then
    options.initial_input = node.command .. (M.config.run_commands and "\r" or "")
  end
  return rex.layout.block{ flavor = SHELL, label = node.label, options = options }
end

local function existing_labels()
  local list, err = rex.call("session.list")
  if list == nil then
    error(err, 0)
  end
  local labels = {}
  for _, session in ipairs(list.sessions or {}) do
    if session.label ~= nil then
      labels[session.label] = true
    end
  end
  return labels
end

-- session.create activates the last window; focus the one that was active.
local function focus_window(session_id, window_id)
  local attach = type(rex.session.attach) == "function"
  if attach then
    rex.session.attach{ session_id = session_id }
  end
  rex.session.focus_window{ session_id = session_id, window_id = window_id }
  if attach then
    rex.session.detach{ session_id = session_id }
  end
end

function M.load_snapshot(file)
  local handle = io.open(file, "r")
  if handle == nil then
    error("no saved sessions at " .. file, 0)
  end
  local text = handle:read("*a")
  handle:close()
  local snapshot = rex.json.decode(text)
  if type(snapshot) ~= "table" or snapshot.version ~= VERSION or type(snapshot.sessions) ~= "table" then
    error("not a resurrect snapshot: " .. file, 0)
  end
  return snapshot
end

local function restore_session(saved)
  local windows = {}
  for _, window in ipairs(saved.windows or {}) do
    table.insert(windows, { window_label = window.label, layout = restore_node(window.layout) })
  end
  if #windows == 0 then
    error("it has no windows", 0)
  end
  local s, err = rex.call("session.create", { label = saved.label, initial_windows = windows })
  if s == nil then
    error(err, 0)
  end
  local active = s.initial_windows[saved.active_window or 1]
  if active ~= nil then
    focus_window(s.session_id, active.window_id)
  end
end

-- Sessions whose label already exists are left alone, like tmux-resurrect.
-- opts.session restores only the saved sessions with that label, and
-- opts.dry_run reports what would happen without creating anything. One
-- session failing doesn't stop the others.
function M.restore(file, opts)
  opts = opts or {}
  if file ~= nil and not file:find("/") then
    file = M.config.dir .. "/" .. file
  end
  file = file or (M.config.dir .. "/last.json")
  local snapshot = M.load_snapshot(file)
  local labels = existing_labels()
  local result = { file = file, restored = {}, skipped = {}, failed = {}, dry_run = opts.dry_run or nil }
  local matched = false
  for _, saved in ipairs(snapshot.sessions) do
    if opts.session == nil or saved.label == opts.session then
      matched = true
      local label = saved.label or "(unlabeled)"
      if saved.label ~= nil and labels[saved.label] then
        table.insert(result.skipped, label)
      elseif opts.dry_run then
        table.insert(result.restored, label)
      else
        local ok, err = pcall(restore_session, saved)
        if ok then
          table.insert(result.restored, label)
        else
          table.insert(result.failed, label .. ": " .. tostring(err))
        end
      end
    end
  end
  if not matched then
    error(("no session labeled '%s' in %s"):format(opts.session, file), 0)
  end
  return result
end

-- Lists the saves, newest first, with the sessions in each.
function M.list()
  local files = snapshot_files()
  local snapshots = {}
  for i = #files, 1, -1 do
    local ok, snapshot = pcall(M.load_snapshot, M.config.dir .. "/" .. files[i])
    local labels = {}
    for _, saved in ipairs(ok and snapshot.sessions or {}) do
      table.insert(labels, saved.label or "(unlabeled)")
    end
    table.insert(snapshots, { file = files[i], sessions = ok and table.concat(labels, ", ") or "(unreadable)" })
  end
  return { dir = M.config.dir, snapshots = snapshots }
end

function M.setup(opts)
  for key, value in pairs(opts or {}) do
    M.config[key] = value
  end
  rex.action{
    name = M.config.save_action,
    title = "Save Sessions",
    description = "Save every session's windows, splits, directories, and programs to a file.",
    keywords = "resurrect save sessions snapshot",
    run = function()
      return M.save()
    end,
  }
  rex.action{
    name = M.config.restore_action,
    title = "Restore Sessions",
    description = "Recreate the saved sessions that aren't already open.",
    keywords = "resurrect restore sessions snapshot",
    args = { file = "string?", session = "string?", dry_run = "boolean?" },
    run = function(_, args)
      return M.restore(args.file, { session = args.session, dry_run = args.dry_run })
    end,
  }
  rex.action{
    name = M.config.list_action,
    title = "List Saved Sessions",
    description = "List the saved snapshots, newest first, with the sessions in each.",
    keywords = "resurrect list snapshots",
    run = function()
      return M.list()
    end,
  }
end

return M
