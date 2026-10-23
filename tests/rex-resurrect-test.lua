-- Tests for rex/resurrect.lua. Run with: luajit tests/rex-resurrect-test.lua
--
-- The rex global is stubbed: rex.exec runs real commands, a fake server holds
-- the sessions, and snapshots are written under TMPDIR.

local root = arg[0]:match("^(.*)/tests/[^/]+$") or "."
package.path = root .. "/rex/?.lua;" .. package.path

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function sh(command)
  local pipe = io.popen(command .. " 2>/dev/null; echo \"exit:$?\"")
  local out = pipe:read("*a")
  pipe:close()
  local stdout, code = out:match("^(.*)exit:(%d+)\n$")
  return { stdout = stdout, ok = code == "0", code = tonumber(code) }
end

local function encode(value)
  local kind = type(value)
  if kind == "string" then
    return '"' .. value:gsub('[%c"\\]', function(c)
      return ("\\u%04x"):format(c:byte())
    end) .. '"'
  elseif kind == "number" or kind == "boolean" then
    return tostring(value)
  end
  local parts = {}
  if #value > 0 then
    for _, item in ipairs(value) do
      table.insert(parts, encode(item))
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key, item in pairs(value) do
    table.insert(parts, encode(tostring(key)) .. ":" .. encode(item))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local calls, sessions, views, terminals, commands
local function reset()
  calls, sessions, views, terminals, commands = {}, {}, {}, {}, {}
end

local function record(method, args)
  table.insert(calls, { method = method, args = args })
end

rex = {
  exec = function(argv)
    -- ps reports the command lines of the fake terminals' programs.
    if argv[1] == "ps" then
      local line = commands[tonumber(argv[#argv])]
      return { stdout = line and (line .. "\n") or "", ok = line ~= nil }
    end
    local quoted = {}
    for i, word in ipairs(argv) do
      quoted[i] = shell_quote(word)
    end
    return sh(table.concat(quoted, " "))
  end,
  call = function(method, args)
    record(method, args)
    if method == "session.list" then
      return { sessions = sessions }
    end
    if method == "block.method" then
      local terminal = terminals[args.block_id]
      if terminal == nil then
        return nil, "no such block"
      end
      if args.method == "pwd" then
        return { pwd = terminal.pwd }
      end
      return { foreground = terminal.foreground, ancestors = terminal.ancestors, home = "/home/you" }
    end
    local windows = {}
    for i in ipairs(args.initial_windows) do
      windows[i] = { window_id = "window:" .. i }
    end
    return { session_id = "session:new", initial_windows = windows }
  end,
  session = setmetatable({
    view = function(args)
      return views[args.session_id]
    end,
  }, {
    __index = function(_, method)
      return function(args)
        record("session." .. method, args)
        return {}
      end
    end,
  }),
  layout = {
    block = function(spec)
      return { block = spec }
    end,
    horizontal = function(ratio, before, after)
      return { split = { direction = "horizontal", ratio = ratio, before = before, after = after } }
    end,
    vertical = function(ratio, before, after)
      return { split = { direction = "vertical", ratio = ratio, before = before, after = after } }
    end,
  },
  json = {
    encode = function(value)
      return encode(value)
    end,
    -- yq converts JSON to a Lua chunk, so the tests need no JSON library.
    decode = function(text)
      local path = os.getenv("TMPDIR") .. "/rex-resurrect-test.json"
      local file = assert(io.open(path, "w"))
      file:write(text)
      file:close()
      local r = sh("yq -p=json -o=lua . " .. shell_quote(path))
      os.remove(path)
      return assert(loadstring(r.stdout))()
    end,
  },
  action = function() end,
}

local resurrect = require("resurrect")

local failures = 0
local function check(name, got, want)
  if got ~= want then
    failures = failures + 1
    print(("FAIL %s: got %s, want %s"):format(name, tostring(got), tostring(want)))
  end
end

local function find_calls(method)
  local found = {}
  for _, call in ipairs(calls) do
    if call.method == method then
      table.insert(found, call.args)
    end
  end
  return found
end

-- Fixture directory. Cleanup only ever removes a path ending in this marker.
local MARKER = "rex-resurrect-test-" .. os.time()
local tmp_base = assert(os.getenv("TMPDIR"), "TMPDIR must be set")
local tmp = sh("mkdir " .. shell_quote(tmp_base .. "/" .. MARKER) .. " && cd " ..
  shell_quote(tmp_base .. "/" .. MARKER) .. " && pwd -P")
assert(tmp.ok, "could not create fixture directory under TMPDIR")
tmp = tmp.stdout:gsub("%s+$", "")
assert(tmp:sub(-#MARKER) == MARKER, "unexpected fixture path: " .. tmp)

resurrect.setup{ dir = tmp .. "/snapshots" }

reset()
local login = { { name = "login" } }
local in_shell = { { name = "zsh" }, { name = "login" } }
commands[42] = "/opt/bin/nvim a b.txt"
check("command idle shell", resurrect.foreground_command({ foreground = { name = "zsh" }, ancestors = login }), nil)
check("command nested shell", resurrect.foreground_command({ foreground = { name = "bash" }, ancestors = in_shell }), nil)
check("command ps", resurrect.foreground_command({ foreground = { name = "nvim", pid = 42 }, ancestors = in_shell }),
  "/opt/bin/nvim a b.txt")
check("command name", resurrect.foreground_command({ foreground = { name = "htop", pid = 7 }, ancestors = in_shell }), "htop")
check("command argv0", resurrect.foreground_command({
  foreground = { name = "nvim-0.10", argv0 = "vim", pid = 7 }, ancestors = in_shell,
}), "vim")
check("command none", resurrect.foreground_command(nil), nil)

-- Two sessions: "api" has an editor window and a window split three ways;
-- "notes" has one window. Block b5 isn't a terminal.
reset()
sessions = {
  { session_id = "session:api", label = "api" },
  { session_id = "session:notes", label = "notes" },
  { session_id = "session:empty", label = "empty" },
  { session_id = "session:app", label = "amber-ridge" },
}
local function tiled(layout, blocks)
  return { { kind = "floating", blocks = {} }, { kind = "tiled", layout = layout, blocks = blocks } }
end
local function block(id, label, flavor)
  return { block_id = id, label = label or "shell", flavor = flavor or "com.superlogical.terminal.shell" }
end
views["session:api"] = {
  label = "api",
  active_window_id = "window:run",
  windows = {
    { window_id = "window:edit", label = "editor", layers = tiled({ block_id = "b1" }, { block("b1", "editor") }) },
    {
      window_id = "window:run",
      label = "Window 0a1b2c3d",
      layers = tiled({ split = {
        direction = "vertical", ratio = 0.7,
        before = { split = {
          direction = "horizontal", ratio = 0.4,
          before = { block_id = "b2" },
          after = { block_id = "b3" },
        } },
        after = { block_id = "b4" },
      } }, { block("b2", "server"), block("b3", "Block 0a1b2c3d"), block("b4") }),
    },
  },
}
views["session:notes"] = {
  windows = { { window_id = "window:n", label = "notes", layers = tiled({ block_id = "b5" }, { block("b5", "web", "com.example.web") }) } },
}
views["session:empty"] = { windows = {} }
-- An untouched session, like the one the Rex app creates, isn't saved.
views["session:app"] = {
  windows = { { window_id = "window:a", label = "Window 0a1b2c3d", layers = tiled({ block_id = "b6" }, { block("b6") }) } },
}
terminals = {
  b1 = { pwd = "file://host/src/my%20api", foreground = { name = "nvim", pid = 1 }, ancestors = in_shell },
  b2 = { pwd = "file://host/src/my%20api/backend", foreground = { name = "fish" }, ancestors = login },
  b3 = { foreground = { name = "tail", cwd = "/var/log", pid = 3 }, ancestors = in_shell },
  b6 = { pwd = "file://host" .. os.getenv("HOME"), foreground = { name = "zsh" }, ancestors = login },
  b4 = { pwd = "/src/my api", foreground = { name = "node", argv0 = "pnpm", pid = 4 }, ancestors = in_shell },
}
commands = { [1] = "nvim main.go", [3] = "tail -f app.log", [4] = "pnpm dev" }

local saved = resurrect.save()
check("saved sessions", saved.sessions, 2)
check("untouched left out", #resurrect.load_snapshot(saved.file).sessions, 2)
check("saved file", saved.file:match("/rex_resurrect_%d+T%d+%.json$") ~= nil, true)
check("last written", io.open(tmp .. "/snapshots/last.json") ~= nil, true)

local snapshot = resurrect.load_snapshot(saved.file)
local api = snapshot.sessions[1]
check("api label", api.label, "api")
check("api active", api.active_window, 2)
check("editor label", api.windows[1].label, "editor")
check("default window label", api.windows[2].label, nil)
check("editor block label", api.windows[1].layout.label, "editor")
check("editor cwd", api.windows[1].layout.cwd, "/src/my api")
check("editor command", api.windows[1].layout.command, "nvim main.go")
local run = api.windows[2].layout
check("outer split", run.split, "vertical")
check("outer ratio", run.ratio, 0.7)
check("inner split", run.before.split, "horizontal")
check("server label", run.before.before.label, "server")
check("server cwd", run.before.before.cwd, "/src/my api/backend")
check("shell command", run.before.before.command, nil)
check("fallback cwd", run.before.after.cwd, "/var/log")
check("default block label", run.before.after.label, nil)
check("shell block label", run.after.label, nil)
check("tail command", run.before.after.command, "tail -f app.log")
check("unknown program", run.after.command, nil)
check("non-terminal", snapshot.sessions[2].windows[1].layout.cwd, nil)
check("non-terminal label", snapshot.sessions[2].windows[1].layout.label, "web")
check("notes label", snapshot.sessions[2].label, "notes")

-- Restoring skips sessions that are still open and rebuilds the rest.
reset()
sessions = { { session_id = "session:notes", label = "notes" } }
local result = resurrect.restore()
check("restored", result.restored[1], "api")
check("restored count", #result.restored, 1)
check("skipped", result.skipped[1], "notes")
local creates = find_calls("session.create")
check("create count", #creates, 1)
local create = creates[1]
check("create label", create.label, "api")
check("window count", #create.initial_windows, 2)
local editor = create.initial_windows[1]
check("window label", editor.window_label, "editor")
check("restored cwd", editor.layout.block.options.cwd, "/src/my api")
check("restored command", editor.layout.block.options.initial_input, "nvim main.go\r")
check("restored block label", editor.layout.block.label, "editor")
local outer = create.initial_windows[2].layout.split
check("restored outer", outer.direction, "vertical")
check("restored ratio", outer.ratio, 0.7)
check("restored inner", outer.before.split.direction, "horizontal")
check("restored shell", outer.before.split.before.block.options.initial_input, nil)
check("focused active", find_calls("session.focus_window")[1].window_id, "window:2")

-- The shell option applies to every restored pane.
resurrect.config.shell = "/opt/homebrew/bin/fish"
reset()
resurrect.restore(saved.file)
check("shell option", find_calls("session.create")[2].initial_windows[1].layout.block.options.shell,
  "/opt/homebrew/bin/fish")
resurrect.config.shell = nil

-- run_commands = false types programs at the prompt without running them.
resurrect.config.run_commands = false
reset()
resurrect.restore(saved.file)
check("typed only", find_calls("session.create")[1].initial_windows[1].layout.block.options.initial_input,
  "nvim main.go")
resurrect.config.run_commands = true

-- session restores only that session; dry_run creates nothing.
reset()
result = resurrect.restore(nil, { session = "notes" })
check("session filter", #find_calls("session.create"), 1)
check("session filter label", find_calls("session.create")[1].label, "notes")
reset()
sessions = { { session_id = "session:notes", label = "notes" } }
result = resurrect.restore(nil, { dry_run = true })
check("dry run creates nothing", #find_calls("session.create"), 0)
check("dry run restored", result.restored[1], "api")
check("dry run skipped", result.skipped[1], "notes")

-- A file name without a slash is looked up in the save directory.
local name = saved.file:match("[^/]+$")
reset()
check("file by name", resurrect.restore(name).file, saved.file)

-- One session failing doesn't stop the others.
local function write(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end
write(tmp .. "/partial.json", [[{"version": 1, "sessions": [
  {"label": "bad", "windows": [{"layout": {"split": "vertical", "ratio": 1.5,
    "before": {"cwd": "/"}, "after": {"cwd": "/"}}}]},
  {"label": "good", "windows": [{"layout": {"cwd": "/"}}]}]}]])
reset()
result = resurrect.restore(tmp .. "/partial.json")
check("failed", result.failed[1], "bad: split ratio must be between 0 and 1: 1.5")
check("still restored", result.restored[1], "good")
check("only good created", #find_calls("session.create"), 1)

-- Saves are private, pruned to keep, and an empty save leaves last.json alone.
check("file mode", sh("stat -c %a " .. shell_quote(saved.file) .. " || stat -f %Lp " .. shell_quote(saved.file)).stdout,
  "600\n")
check("dir mode", sh("stat -c %a " .. shell_quote(tmp .. "/snapshots") .. " || stat -f %Lp " ..
  shell_quote(tmp .. "/snapshots")).stdout, "700\n")
for _, stamp in ipairs({ "20000101T000000", "20000102T000000", "20000103T000000" }) do
  write(tmp .. "/snapshots/rex_resurrect_" .. stamp .. ".json", "{}")
end
resurrect.config.keep = 2
reset()
sessions = { { session_id = "session:notes", label = "notes" } }
views["session:notes"] = {
  windows = { { window_id = "window:n", label = "notes", layers = tiled({ block_id = "b5" }, { block("b5", "web", "com.example.web") }) } },
}
resurrect.save()
local listing = resurrect.list().snapshots
check("pruned", #listing, 2)
check("newest first", listing[1].file, name)
check("list sessions", listing[1].sessions, "notes")
check("oldest kept", listing[2].file, "rex_resurrect_20000103T000000.json")
check("unreadable", listing[2].sessions, "(unreadable)")
resurrect.config.keep = 20
local before = io.open(tmp .. "/snapshots/last.json"):read("*a")
reset()
sessions = { { session_id = "session:app", label = "amber-ridge" } }
views["session:app"] = {
  windows = { { window_id = "window:a", label = "Window 0a1b2c3d", layers = tiled({ block_id = "b6" }, { block("b6") }) } },
}
terminals = { b6 = { pwd = "file://host" .. os.getenv("HOME"), foreground = { name = "zsh" }, ancestors = login } }
check("nothing to save", resurrect.save().sessions, 0)
check("last unchanged", io.open(tmp .. "/snapshots/last.json"):read("*a"), before)

-- Errors.
local function check_error(name, fn, pattern)
  reset()
  local ok, err = pcall(fn)
  check(name, not ok and tostring(err):find(pattern, 1, true) ~= nil, true)
  check(name .. " not created", #find_calls("session.create"), 0)
end
check_error("unknown session", function() resurrect.restore(nil, { session = "nope" }) end, "no session labeled 'nope'")
check_error("missing snapshot", function() resurrect.restore(tmp .. "/nope.json") end, "no saved sessions")
local bad = assert(io.open(tmp .. "/bad.json", "w"))
bad:write('{"sessions": []}')
bad:close()
check_error("not a snapshot", function() resurrect.restore(tmp .. "/bad.json") end, "not a resurrect snapshot")

if tmp:sub(-#MARKER) == MARKER then
  sh("rm -rf " .. shell_quote(tmp))
end

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("ok")
