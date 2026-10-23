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
local TERMINAL = "com.superlogical.terminal"
local HOME = os.getenv("HOME") or ""
local DATA_HOME = os.getenv("XDG_DATA_HOME") or (HOME .. "/.local/share")
local VERSION = 1

M.config = {
  save_action = "resurrect_save",
  restore_action = "resurrect_restore",
  dir = DATA_HOME .. "/rex/resurrect",
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

local function call_block(session_id, block_id, method)
  local r = rex.block.call(TERMINAL, method, { session_id = session_id, block_id = block_id })
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

-- Quotes a word only when the shell could read it differently. This quoting
-- reads the same in sh, bash, zsh, and fish.
local function shell_word(word)
  if word:match("^[%w%._/:=@%%+,-]+$") then
    return word
  end
  return "'" .. word:gsub("'", [['"'"']]) .. "'"
end

-- Returns the command line to type back in, or nil when the foreground program
-- is the shell or isn't in restore_programs.
function M.foreground_command(process)
  local fg = type(process) == "table" and process.foreground
  if type(fg) ~= "table" or type(fg.name) ~= "string" then
    return nil
  end
  local name = basename(fg.name)
  local allowed = false
  for _, program in ipairs(M.config.restore_programs) do
    if program == name then
      allowed = true
    end
  end
  if not allowed then
    return nil
  end
  if type(fg.argv) == "table" and #fg.argv > 0 then
    local words = { name }
    for i = 2, #fg.argv do
      table.insert(words, shell_word(tostring(fg.argv[i])))
    end
    return table.concat(words, " ")
  end
  return name
end

-- session.view's layout nodes have the shape rex.layout builds:
-- { block = { block_id, label } } or
-- { split = { direction, ratio, before, after } }.
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
  local block = type(node.block) == "table" and node.block or node
  local id = block.block_id
  if id == nil then
    return nil
  end
  local info = blocks[id] or {}
  local process = call_block(session_id, id, "process")
  local cwd = block_pwd(session_id, id)
  if cwd == nil and process ~= nil and type(process.foreground) == "table" then
    cwd = process.foreground.cwd
  end
  return {
    label = block.label or info.label,
    cwd = cwd,
    command = M.foreground_command(process),
  }
end

-- view.blocks may be a list of blocks or a map from block_id to block.
local function index_blocks(view)
  local blocks = {}
  for key, block in pairs(type(view.blocks) == "table" and view.blocks or {}) do
    if type(block) == "table" then
      blocks[block.block_id or key] = block
    end
  end
  return blocks
end

function M.save_session(session)
  local view, err = rex.session.view{ session_id = session.session_id }
  if view == nil then
    error(err, 0)
  end
  local blocks = index_blocks(view)
  local saved = { label = session.label or view.label, windows = {} }
  for _, window in ipairs(view.windows or {}) do
    local layout = save_node(session.session_id, window.layout, blocks)
    if layout ~= nil then
      table.insert(saved.windows, { label = window.label, layout = layout })
      if window.window_id ~= nil and window.window_id == view.active_window_id then
        saved.active_window = #saved.windows
      end
    end
  end
  return saved
end

local function write_file(path, text)
  local file, err = io.open(path, "w")
  if file == nil then
    error(err, 0)
  end
  file:write(text)
  file:close()
end

function M.save()
  local list, err = rex.call("session.list")
  if list == nil then
    error(err, 0)
  end
  local snapshot = { version = VERSION, saved_at = os.time(), sessions = {} }
  for _, session in ipairs(list.sessions or {}) do
    local saved = M.save_session(session)
    if #saved.windows > 0 then
      table.insert(snapshot.sessions, saved)
    end
  end

  local r = rex.exec({ "mkdir", "-p", M.config.dir })
  if r == nil or not r.ok then
    error("could not create " .. M.config.dir, 0)
  end
  local text = assert(rex.json.encode(snapshot, { indent = true }))
  local file = ("%s/rex_resurrect_%s.json"):format(M.config.dir, os.date("%Y%m%dT%H%M%S", snapshot.saved_at))
  write_file(file, text)
  write_file(M.config.dir .. "/last.json", text)
  return { file = file, sessions = #snapshot.sessions }
end

local function restore_node(node)
  if node.split ~= nil then
    if node.split ~= "horizontal" and node.split ~= "vertical" then
      error("unknown split direction in snapshot: " .. tostring(node.split), 0)
    end
    return rex.layout[node.split](node.ratio or 0.5, restore_node(node.before), restore_node(node.after))
  end
  local options = { cwd = node.cwd, shell = M.config.shell }
  if node.command ~= nil and node.command ~= "" then
    options.initial_input = node.command .. "\r"
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

-- Sessions whose label already exists are left alone, like tmux-resurrect.
function M.restore(file)
  file = file or (M.config.dir .. "/last.json")
  local snapshot = M.load_snapshot(file)
  local labels = existing_labels()
  local restored, skipped = {}, {}
  for _, saved in ipairs(snapshot.sessions) do
    if saved.label ~= nil and labels[saved.label] then
      table.insert(skipped, saved.label)
    else
      local windows = {}
      for _, window in ipairs(saved.windows or {}) do
        table.insert(windows, { window_label = window.label, layout = restore_node(window.layout) })
      end
      local s, err = rex.call("session.create", { label = saved.label, initial_windows = windows })
      if s == nil then
        error(err, 0)
      end
      local active = s.initial_windows[saved.active_window or 1]
      if active ~= nil then
        focus_window(s.session_id, active.window_id)
      end
      table.insert(restored, saved.label or s.session_id)
    end
  end
  return { file = file, restored = restored, skipped = skipped }
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
    args = { file = "string?" },
    run = function(_, args)
      return M.restore(args.file)
    end,
  }
end

return M
