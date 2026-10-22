-- Tests for rex/tmux_workspaces.lua. Run with: luajit tests/rex-workspaces-test.lua
--
-- The rex global is stubbed: rex.exec runs real commands, and server calls
-- are recorded instead of creating sessions.

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

local calls, sessions, focused_pwd
local function reset()
  calls, sessions, focused_pwd = {}, {}, nil
end

rex = {
  exec = function(argv)
    local quoted = {}
    for i, word in ipairs(argv) do
      quoted[i] = shell_quote(word)
    end
    return sh(table.concat(quoted, " "))
  end,
  call = function(method, args)
    table.insert(calls, { method = method, args = args })
    if method == "session.list" then
      return { sessions = sessions }
    end
    local windows = {}
    for i in ipairs(args.initial_windows) do
      windows[i] = { window_id = "window:" .. i }
    end
    return { session_id = "session:new", initial_windows = windows }
  end,
  session = setmetatable({}, {
    __index = function(_, method)
      return function(args)
        table.insert(calls, { method = "session." .. method, args = args })
        return {}
      end
    end,
  }),
  block = {
    call = function()
      return { pwd = focused_pwd }
    end,
  },
  client = {
    queue = function(name, args)
      table.insert(calls, { method = "client." .. name, args = args })
    end,
  },
  layout = {
    block = function(spec)
      return { block = spec }
    end,
  },
  action = function() end,
}

local ws = require("tmux_workspaces")

local failures = 0
local function check(name, got, want)
  if got ~= want then
    failures = failures + 1
    print(("FAIL %s: got %s, want %s"):format(name, tostring(got), tostring(want)))
  end
end

local function find_call(method)
  for _, call in ipairs(calls) do
    if call.method == method then
      return call.args
    end
  end
end

-- Fixture directory. Cleanup only ever removes a path ending in this marker.
local MARKER = "rex-workspaces-test-" .. os.time()
local tmp_base = assert(os.getenv("TMPDIR"), "TMPDIR must be set")
local tmp = sh("mkdir " .. shell_quote(tmp_base .. "/" .. MARKER) .. " && cd " ..
  shell_quote(tmp_base .. "/" .. MARKER) .. " && pwd -P")
assert(tmp.ok, "could not create fixture directory under TMPDIR")
tmp = tmp.stdout:gsub("%s+$", "")
assert(tmp:sub(-#MARKER) == MARKER, "unexpected fixture path: " .. tmp)

local function cleanup()
  if tmp:sub(-#MARKER) == MARKER then
    sh("rm -rf " .. shell_quote(tmp))
  end
end

assert(sh("mkdir -p " .. shell_quote(tmp .. "/Developer/My App") .. " " .. shell_quote(tmp .. "/cwd/local")).ok)
ws.setup{ project_root = tmp .. "/Developer", zoxide = "/nonexistent/zoxide" }

check("normalize", ws.normalize_name("  My_App.v2 "), "my-app-v2")
check("normalize empty", ws.normalize_name("---"), "")
check("expand home", ws.expand_path("~/x"), os.getenv("HOME") .. "/x")
check("canonical empty", ws.canonical_dir(""), nil)
check("name under root", ws.session_name_for(tmp .. "/Developer/My App", tmp .. "/Developer"), "my-app")
check("name outside root", ws.session_name_for("/srv/api", tmp .. "/Developer"), "srv-api")
check("name root only", ws.session_name_for("/", tmp .. "/Developer"), "project")
check("resolve dot", ws.resolve_target(".", tmp .. "/cwd"), tmp .. "/cwd")
check("resolve local", ws.resolve_target("local", tmp .. "/cwd"), tmp .. "/cwd/local")
check("resolve project", ws.resolve_target("My App", tmp .. "/cwd"), tmp .. "/Developer/My App")
check("resolve absolute", ws.resolve_target("/srv", tmp .. "/cwd"), "/srv")

-- Creates a session with three windows rooted in the project, focused on editor.
reset()
focused_pwd = "file://host" .. tmp:gsub(" ", "%%20") .. "/cwd"
local result = ws.open({ block_id = "block:1" }, { dir = "My App" })
local create = find_call("session.create")
check("created", result.created, true)
check("label", create.label, "my-app")
check("window count", #create.initial_windows, 3)
for i, name in ipairs({ "editor", "shell", "runtime" }) do
  local window = create.initial_windows[i]
  check("window " .. i .. " label", window.window_label, name)
  check("window " .. i .. " cwd", window.layout.block.options.cwd, tmp .. "/Developer/My App")
  check("window " .. i .. " no input", window.layout.block.options.initial_input, nil)
end
check("focus first", find_call("session.focus_window").window_id, "window:1")
check("select first", find_call("client.session.select").window_id, "window:1")

-- No target uses the focused terminal's directory.
reset()
focused_pwd = "file://host" .. tmp .. "/cwd/local"
ws.open({ block_id = "block:1" }, {})
check("focused dir", find_call("session.create").label, ws.normalize_name(tmp .. "/cwd/local"))

-- An existing session is selected, not recreated.
reset()
sessions = { { label = "my-app", session_id = "session:old" } }
result = ws.open({}, { dir = "My App" })
check("reused", result.session_id, "session:old")
check("not created", find_call("session.create"), nil)
check("select existing", find_call("client.session.select").session_id, "session:old")

-- A missing project fails before creating anything.
reset()
local ok, err = pcall(ws.open, {}, { dir = tmp .. "/missing" })
check("missing fails", ok, false)
check("missing message", tostring(err):match("^project directory not found") ~= nil, true)
check("missing not created", find_call("session.create"), nil)

cleanup()

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("ok")
