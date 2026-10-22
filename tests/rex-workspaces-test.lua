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

local calls, sessions, focused_pwd, session_results, block_results
local function reset()
  calls, sessions, focused_pwd, session_results, block_results = {}, {}, nil, {}, {}
end
reset()

rex = {
  exec = function(argv, opts)
    opts = opts or {}
    local quoted = {}
    for i, word in ipairs(argv) do
      quoted[i] = shell_quote(word)
    end
    local command = table.concat(quoted, " ")
    if opts.cwd ~= nil then
      command = "cd " .. shell_quote(opts.cwd) .. " && " .. command
    end
    if opts.stdin ~= nil then
      command = "printf '%s' " .. shell_quote(opts.stdin) .. " | (" .. command .. ")"
    end
    local r = sh("{ (" .. command .. ") 2>&1; }")
    r.stderr = r.ok and "" or r.stdout
    return r
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
        return session_results[method] or {}
      end
    end,
  }),
  block = {
    call = function(_, method, args)
      if method == "pwd" then
        return { pwd = focused_pwd }
      end
      return block_results[args.block_id][method]
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
    horizontal = function(ratio, before, after)
      return { split = { direction = "horizontal", ratio = ratio, before = before, after = after } }
    end,
    vertical = function(ratio, before, after)
      return { split = { direction = "vertical", ratio = ratio, before = before, after = after } }
    end,
  },
  json = {
    -- yq converts JSON to a Lua chunk, so the tests need no JSON library.
    decode = function(text)
      local path = os.getenv("TMPDIR") .. "/rex-workspaces-test.json"
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

-- YAML layouts.
local function write(path, text)
  assert(sh("mkdir -p " .. shell_quote(path:match("^(.*)/[^/]+$"))).ok)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local function open_error(args)
  reset()
  local ok, err = pcall(ws.open, {}, args)
  check("error " .. tostring(err) .. " not created", find_call("session.create"), nil)
  return not ok and tostring(err) or nil
end

local app = tmp .. "/Developer/stack"
assert(sh("mkdir -p " .. shell_quote(app .. "/backend")).ok)
write(app .. "/.tmux-workspaces/layout.yaml", [[
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
      - command: "  "
]])

-- The project's layout replaces the default windows.
reset()
ws.open({}, { dir = app })
create = find_call("session.create")
check("layout label", create.label, "stack")
check("layout window count", #create.initial_windows, 2)
local editor = create.initial_windows[1]
check("editor label", editor.window_label, "editor")
check("editor cwd", editor.layout.block.options.cwd, app)
check("editor input", editor.layout.block.options.initial_input, "nvim\r")

-- Each pane splits the first pane: the first split is outermost.
local runtime = create.initial_windows[2]
local outer = runtime.layout.split
check("outer direction", outer.direction, "vertical")
check("outer pane", outer.after.block.options.initial_input, "tail -f app.log\r")
check("outer cwd", outer.after.block.options.cwd, app .. "/backend")
local inner = outer.before.split
check("inner direction", inner.direction, "horizontal")
check("inner pane", inner.after.block.options.initial_input, "pnpm test\r")
check("main pane", inner.before.block.options.initial_input, "pnpm dev\r")
check("main label", inner.before.block.label, "runtime")

-- session.name and session.dir; an explicit target overrides session.dir.
ws.config.layouts_dir = tmp .. "/layouts"
write(tmp .. "/layouts/dev.yml", [[
session:
  name: My Stack
  dir: ]] .. app .. "\n" .. [[
windows:
  - name: main
]])
reset()
ws.open({}, { layout = "dev.yml" })
create = find_call("session.create")
check("named layout label", create.label, "my-stack")
check("session.dir", create.initial_windows[1].layout.block.options.cwd, app)
reset()
ws.open({}, { layout = "dev", dir = tmp .. "/cwd" })
check("target beats session.dir", find_call("session.create").initial_windows[1].layout.block.options.cwd, tmp .. "/cwd")

-- An explicit file resolves from the focused terminal's directory.
write(tmp .. "/cwd/my.yaml", "windows:\n  - name: solo\n")
reset()
focused_pwd = "file://host" .. tmp .. "/cwd"
ws.open({ block_id = "block:1" }, { file = "my.yaml" })
check("file layout", find_call("session.create").initial_windows[1].window_label, "solo")

-- Errors happen before any session is created.
local function check_error(name, args, pattern)
  local err = open_error(args)
  check(name, err ~= nil and err:find(pattern, 1, true) ~= nil, true)
  if err ~= nil and not err:find(pattern, 1, true) then
    print("  message: " .. err)
  end
end

local function layout_error(name, text, pattern)
  write(tmp .. "/bad/" .. name .. ".yaml", text)
  check_error(name, { file = tmp .. "/bad/" .. name .. ".yaml", dir = app }, pattern)
end

check_error("layout and file", { layout = "dev", file = "my.yaml" }, "cannot be combined")
check_error("missing named layout", { layout = "nope" }, "layout 'nope' not found")
check_error("missing file", { file = tmp .. "/nope.yaml" }, "layout file not found")
layout_error("empty", "windows: []\n", "windows must be a nonempty list")
layout_error("path", "windows:\n  - name: a\n    path: x\n", "rename path to dir")
layout_error("run", "windows:\n  - name: a\n    panes:\n      - run: x\n", "rename run to command")
layout_error("string pane", "windows:\n  - name: a\n    panes:\n      - nvim\n", "panes must be objects")
layout_error("old split", "windows:\n  - name: a\n    panes:\n      - split: horizontal\n        command: x\n", "pane split must be h")
layout_error("no name", "windows:\n  - command: x\n", "missing windows[0].name")
layout_error("bad dir", "windows:\n  - name: a\n    dir: nope\n", "layout directory not found")
layout_error("bad name", "session:\n  name: '---'\nwindows:\n  - name: a\n", "invalid session.name")

-- A renamed session is still found by its workspace name.
reset()
sessions = { { label = "my-app-v2", session_id = "session:other" }, { label = "my-app: fix-auth", session_id = "session:renamed" } }
check("renamed reused", ws.open({}, { dir = "My App" }).session_id, "session:renamed")

-- Rename labels.
check("summary words", ws.summary_label("Fix the Login Redirect Bug!\n", nil), "fix-the-login-redirect")
check("summary strips prefix", ws.summary_label("stack-auth-refactor", "stack"), "auth-refactor")
check("summary empty", ws.summary_label("...", "stack"), "")
check("prefix kept", ws.rename_prefix("stack: old-work", {}), "stack")

assert(sh("mkdir -p " .. shell_quote(app .. "/src") .. " && git -C " .. shell_quote(app) .. " init -q").ok)
local panes = { { dir = app .. "/src" }, { dir = app }, { dir = tmp .. "/cwd" } }
check("prefix from repo", ws.rename_prefix("quiet-meadow", panes), "stack")
check("prefix none", ws.rename_prefix("quiet-meadow", {}), nil)

-- rename_session sends the panes to claude and sets "project: summary".
local fake_claude = tmp .. "/fake-claude"
write(fake_claude, "#!/bin/sh\ncat > " .. shell_quote(tmp .. "/prompt.txt") .. "\necho 'Stack Auth Refactor'\n")
assert(sh("chmod +x " .. shell_quote(fake_claude)).ok)
ws.config.claude = fake_claude

local function terminal(cwd, program, screen)
  return {
    process = { foreground = { cwd = cwd, argv0 = program } },
    title = { title = program .. " title" },
    format = { content = screen },
  }
end

reset()
session_results.view = { label = "quiet-meadow", windows = { { window_id = "w1", label = "editor" }, { window_id = "w2", label = "runtime" } } }
session_results.list_blocks = { blocks = {
  { block_id = "b1", window_id = "w1", creator_name = "com.superlogical.terminal", placement = "placed" },
  { block_id = "b2", window_id = "w2", creator_name = "com.superlogical.terminal", placement = "placed" },
  { block_id = "b3", window_id = "w2", creator_name = "com.superlogical.terminal", placement = "detached" },
} }
block_results = {
  b1 = terminal(app .. "/src", "nvim", "auth.ts\n\n  middleware\n"),
  b2 = terminal(app, "pnpm", "compiled"),
}
result = ws.rename({}, {})
check("rename label", result.label, "stack: auth-refactor")
check("rename set", find_call("session.set_label").label, "stack: auth-refactor")
local prompt = assert(io.open(tmp .. "/prompt.txt")):read("*a")
check("prompt window", prompt:find("## Window editor", 1, true) ~= nil, true)
check("prompt program", prompt:find("Program: pnpm", 1, true) ~= nil, true)
check("prompt screen", prompt:find("auth.ts\n  middleware", 1, true) ~= nil, true)

write(fake_claude, "#!/bin/sh\necho 'rate limited' >&2\nexit 1\n")
reset()
session_results.view = { label = "x", windows = {} }
session_results.list_blocks = { blocks = { { block_id = "b1", creator_name = "com.superlogical.terminal", placement = "placed" } } }
block_results = { b1 = terminal(app, "zsh", "") }
ok, err = pcall(ws.rename, {}, {})
check("claude failure", ok == false and tostring(err):find("claude failed: rate limited", 1, true) ~= nil, true)
check("claude failure no rename", find_call("session.set_label"), nil)

cleanup()

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("ok")
