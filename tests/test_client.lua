local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local config = require("tasksd.config")
local install = require("tasksd.install")
local pin = require("tasksd.install.pin")

local TASKSD = os.getenv("TASKSD_BIN")

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function needs_tasksd()
  if not TASKSD or vim.fn.executable(TASKSD) == 0 then
    MiniTest.skip("no tasksd binary; set TASKSD_BIN=/path/to/tasksd")
  end
end

---Run `fn` with both of the fallbacks behind `daemon.path` taken away, so a
---case about an unlaunchable daemon fails the same on a machine that has a
---tasksd installed or on $PATH as on one that has neither.
local function with_no_tasksd(fn)
  local is_installed, path = install.is_installed, assert(vim.uv.os_getenv("PATH"))
  ---@diagnostic disable-next-line: duplicate-set-field
  install.is_installed = function()
    return false
  end
  vim.uv.os_setenv("PATH", "/nonexistent")

  local ok, err = pcall(fn)

  install.is_installed = is_installed
  vim.uv.os_setenv("PATH", path)
  if not ok then
    error(err)
  end
end

-- Short path on purpose: unix socket paths are capped near 104 bytes, which
-- vim.fn.tempname() can exceed.
local socket_counter = 0
local sockets = {}
local function new_socket()
  socket_counter = socket_counter + 1
  local path = ("/tmp/tasksd-nvim-test-%d-%d.sock"):format(vim.uv.os_getpid(), socket_counter)
  table.insert(sockets, path)
  vim.fn.delete(path)
  return path
end

---@return tasksd.Client|nil, string|nil
local function connect_sync(socket)
  local done, result, err = false, nil, nil
  client.connect(socket, function(c, e)
    done, result, err = true, c, e
  end)
  local finished = vim.wait(15000, function()
    return done
  end, 20)
  if not finished then
    error("client.connect never invoked its callback")
  end
  return result, err
end

---Fails with the underlying error rather than a nil-index traceback.
---@return tasksd.Client
local function connect_ok(socket)
  local c, err = connect_sync(socket)
  if not c then
    error("expected a connected client, got: " .. tostring(err))
  end
  return c
end

local function pid_for(socket)
  return vim.trim(vim.fn.system({ "pgrep", "-f", socket }))
end

--------------------------------------------------------------------------------

local T = new_set({
  hooks = {
    pre_case = function()
      config.setup({ daemon = { path = TASKSD } })
    end,
    post_once = function()
      for _, path in ipairs(sockets) do
        vim.fn.system({ "pkill", "-f", path })
        vim.fn.delete(path)
      end
    end,
  },
})

--------------------------------------------------------------------------------
-- connect: integration against a real daemon
--------------------------------------------------------------------------------

T["connect()"] = new_set()

T["connect()"]["launches the daemon when none is running"] = function()
  needs_tasksd()
  local socket = new_socket()

  local c = connect_ok(socket)

  eq(c:is_connected(), true)
  eq(vim.uv.fs_stat(socket) ~= nil, true)
  c:disconnect()
end

T["connect()"]["reports the daemon version from the handshake"] = function()
  needs_tasksd()
  local c = connect_ok(new_socket())

  eq(type(c.server_version), "string")
  MiniTest.expect.no_equality(c.server_version, "")
  -- The client only ever hands out a daemon it supports.
  eq(client.check_server_version(c.server_version), nil)
  c:disconnect()
end

T["connect()"]["refuses a daemon older than the minimum"] = function()
  needs_tasksd()
  local socket = new_socket()

  -- Started while the bar is still normal: `daemon.ensure` pre-flights the
  -- binary's version, so a raised bar would refuse before a handshake ever
  -- happened. A daemon already listening is the case only this check covers.
  connect_ok(socket):disconnect()

  -- Nothing can install an old tasksd here, so raise the bar instead. pcall so
  -- a failing connect still restores the constant for every later case.
  local real_minimum = pin.MIN_VERSION
  pin.MIN_VERSION = "999.0.0"
  local ok, c, err = pcall(connect_sync, socket)
  pin.MIN_VERSION = real_minimum
  eq(ok, true)

  eq(c, nil)
  eq(type(err) == "string" and err:find("too old", 1, true) ~= nil, true)

  -- Only the handshake was refused; the daemon is still running and usable.
  connect_ok(socket):disconnect()
end

T["connect()"]["reuses a daemon that is already running"] = function()
  needs_tasksd()
  local socket = new_socket()

  local first = connect_ok(socket)
  local pid = pid_for(socket)
  first:disconnect()

  local second = connect_ok(socket)
  eq(pid_for(socket), pid)
  second:disconnect()
end

T["connect()"]["recovers from a socket left by a killed daemon"] = function()
  needs_tasksd()
  local socket = new_socket()

  local first = connect_ok(socket)
  first:disconnect()
  local pid = pid_for(socket)

  -- SIGKILL means the daemon's Drop never runs, so the socket file survives
  -- and would make the next bind fail with EADDRINUSE.
  vim.fn.system({ "kill", "-9", pid })
  vim.wait(500)
  eq(vim.uv.fs_stat(socket) ~= nil, true)

  local second = connect_ok(socket)
  MiniTest.expect.no_equality(pid_for(socket), pid)
  second:disconnect()
end

T["connect()"]["returns nil and an error when tasksd is missing"] = function()
  config.setup({ daemon = { path = "/nonexistent/tasksd" } })

  local c, err
  with_no_tasksd(function()
    c, err = connect_sync(new_socket())
  end)

  eq(c, nil)
  eq(type(err) == "string" and err:find("could not launch tasksd", 1, true) ~= nil, true)
end

--------------------------------------------------------------------------------
-- on: notification listeners, integration against a real daemon
--------------------------------------------------------------------------------

T["on()"] = new_set()

---Start a task that exits at once, so a `task.exit` follows immediately.
---@param c tasksd.Client
local function start_quick_task(c)
  eq(
    c:request("task.start", {
      executable = "true",
      args = {},
      working_dir = "/tmp",
      subscribe_to_output = false,
    }, function() end),
    true
  )
end

T["on()"]["delivers a notification to every listener"] = function()
  needs_tasksd()
  local c = connect_ok(new_socket())

  local seen = {}
  c:on("task.exit", function()
    table.insert(seen, "first")
  end)
  c:on("task.exit", function()
    table.insert(seen, "second")
  end)

  start_quick_task(c)
  vim.wait(5000, function()
    return #seen >= 2
  end, 20)
  c:disconnect()

  eq(seen, { "first", "second" })
end

T["on()"]["stops delivering to a listener that detached"] = function()
  needs_tasksd()
  local c = connect_ok(new_socket())

  local kept, detached = 0, 0
  c:on("task.exit", function()
    kept = kept + 1
  end)
  local detach = c:on("task.exit", function()
    detached = detached + 1
  end)
  detach()
  detach()

  start_quick_task(c)
  vim.wait(5000, function()
    return kept > 0
  end, 20)
  c:disconnect()

  eq({ kept, detached }, { 1, 0 })
end

-- Detaching mid-dispatch shortens the list the loop is walking, which would
-- otherwise skip whichever listener slid into the freed slot.
T["on()"]["runs the listeners behind one that detaches itself"] = function()
  needs_tasksd()
  local c = connect_ok(new_socket())

  local seen = {}
  local detach
  detach = c:on("task.exit", function()
    table.insert(seen, "first")
    detach()
  end)
  c:on("task.exit", function()
    table.insert(seen, "second")
  end)

  start_quick_task(c)
  vim.wait(5000, function()
    return #seen >= 2
  end, 20)
  c:disconnect()

  eq(seen, { "first", "second" })
end

--------------------------------------------------------------------------------
-- check_server_version: the minimum-version policy, no daemon needed
--------------------------------------------------------------------------------

-- Pinned to a fixed value so these cases stay meaningful when the real minimum
-- is bumped. `require` caches modules, so this is the *same* table every other
-- case in the run sees -- hence the restore in post_once.
local REAL_MINIMUM = pin.MIN_VERSION

T["check_server_version()"] = new_set({
  hooks = {
    pre_case = function()
      pin.MIN_VERSION = "1.2.3"
    end,
    post_once = function()
      pin.MIN_VERSION = REAL_MINIMUM
    end,
  },
})

local function accepts(version)
  eq(client.check_server_version(version), nil)
end

---Returns the rejection message, for the cases that check its wording.
local function rejects(version)
  local err = client.check_server_version(version)
  eq(type(err), "string")
  return err
end

T["check_server_version()"]["accepts the minimum and anything newer"] = function()
  accepts("1.2.3")
  accepts("1.2.4")
  accepts("1.3.0")
  accepts("2.0.0")
end

T["check_server_version()"]["rejects anything older"] = function()
  eq(rejects("1.2.2"):find("too old", 1, true) ~= nil, true)
  rejects("1.1.9")
  rejects("0.9.0")
end

T["check_server_version()"]["tolerates the loose spellings of a version"] = function()
  accepts("v1.2.3")
  accepts("1.3")
  accepts("1.2.3+build.7")
end

T["check_server_version()"]["rejects a pre-release of the minimum"] = function()
  rejects("1.2.3-rc1")
end

T["check_server_version()"]["rejects a version it cannot parse"] = function()
  eq(rejects("nightly"):find("unrecognisable", 1, true) ~= nil, true)
  rejects("")
end

-- A protocol violation must not become a nil-index crash: whatever lands in the
-- `hello` result has to be survivable.
T["check_server_version()"]["rejects a missing or non-string version"] = function()
  eq(rejects(nil):find("did not report", 1, true) ~= nil, true)
  rejects(42)
  rejects({})
end

--------------------------------------------------------------------------------
-- Client object
--------------------------------------------------------------------------------

T["Client"] = new_set()

T["Client"]["stops reporting connected after disconnect"] = function()
  needs_tasksd()
  local c = connect_ok(new_socket())

  eq(c:is_connected(), true)
  c:disconnect()
  eq(c:is_connected(), false)
end

T["Client"]["refuses to send on a closed connection"] = function()
  needs_tasksd()
  local c = connect_ok(new_socket())
  c:disconnect()

  eq(c:request("hello", {}, function() end), false)
  eq(c:notify("hello", {}), false)
end

T["Client"]["disconnect is idempotent"] = function()
  needs_tasksd()
  local c = connect_ok(new_socket())

  c:disconnect()
  c:disconnect()
  eq(c:is_connected(), false)
end

-- The three ways a connection can end. All arrive through the same on_exit
-- dispatcher; close_reason is what tells them apart afterwards.

T["Client"]["labels a local disconnect"] = function()
  needs_tasksd()
  local c = connect_ok(new_socket())
  eq(c.close_reason, nil)

  c:disconnect()

  eq(c.close_reason, "closed locally")
end

T["Client"]["labels a deliberate daemon shutdown"] = function()
  needs_tasksd()
  local c = connect_ok(new_socket())

  c:request("shutdown", {}, function() end)

  -- The `shutting_down` notification lands before the EOF, so by the time the
  -- connection reports closed the reason is already recorded.
  eq(
    vim.wait(5000, function()
      return not c:is_connected()
    end, 20),
    true
  )
  eq(c.close_reason, "daemon shut down")
end

T["Client"]["labels a lost connection"] = function()
  needs_tasksd()
  local socket = new_socket()
  local c = connect_ok(socket)

  -- SIGKILL: no shutting_down notification, nothing but the EOF.
  vim.fn.system({ "kill", "-9", pid_for(socket) })

  eq(
    vim.wait(5000, function()
      return not c:is_connected()
    end, 20),
    true
  )
  eq(c.close_reason, "connection lost")
end

T["Client"]["round-trips a request to the daemon"] = function()
  needs_tasksd()
  local c = connect_ok(new_socket())

  local done, result, err = false, nil, nil
  c:request("task.list", {}, function(e, r)
    done, err, result = true, e, r
  end)
  eq(
    vim.wait(5000, function()
      return done
    end, 20),
    true
  )

  eq(err, nil)
  eq(type(result), "table")
  c:disconnect()
end

--------------------------------------------------------------------------------
-- get(): cached connections
--------------------------------------------------------------------------------

T["get()"] = new_set({
  hooks = {
    post_case = function()
      client.reset()
    end,
  },
})

local function get_sync(socket)
  local done, result, err = false, nil, nil
  client.get(socket, function(c, e)
    done, result, err = true, c, e
  end)
  local finished = vim.wait(15000, function()
    return done
  end, 20)
  if not finished then
    error("client.get never invoked its callback")
  end
  return result, err
end

---@return tasksd.Client
local function get_ok(socket)
  local c, err = get_sync(socket)
  if not c then
    error("expected a connected client, got: " .. tostring(err))
  end
  return c
end

T["get()"]["reuses the same client instead of reconnecting"] = function()
  needs_tasksd()
  local socket = new_socket()

  local first = get_sync(socket)
  local second = get_sync(socket)

  eq(first, second)
end

T["get()"]["shares one connection attempt between concurrent callers"] = function()
  needs_tasksd()
  local socket = new_socket()

  -- Both calls are made before either can finish, so a naive implementation
  -- would probe twice, find nothing twice, and launch two daemons.
  local results = {}
  local function collect(c)
    table.insert(results, c)
  end
  client.get(socket, collect)
  client.get(socket, collect)

  eq(
    vim.wait(15000, function()
      return #results == 2
    end, 20),
    true
  )
  eq(results[1], results[2])
  -- pgrep prints one line per match; a second daemon would add a newline.
  eq(select(2, pid_for(socket):gsub("\n", "")), 0)
end

T["get()"]["reconnects when the cached client has died"] = function()
  needs_tasksd()
  local socket = new_socket()

  local first = get_ok(socket)
  first:disconnect()

  local second = get_ok(socket)
  eq(second:is_connected(), true)
  MiniTest.expect.no_equality(first, second)
end

-- Nothing calls reset() here: the client has to evict itself.
T["get()"]["reconnects after the daemon is killed"] = function()
  needs_tasksd()
  local socket = new_socket()

  local first = get_ok(socket)
  vim.fn.system({ "kill", "-9", pid_for(socket) })
  eq(
    vim.wait(5000, function()
      return not first:is_connected()
    end, 20),
    true
  )

  local second = get_ok(socket)
  MiniTest.expect.no_equality(first, second)
  eq(second:is_connected(), true)
end

-- What a per-project socket provider does after :cd.
T["get()"]["replaces the client when the socket path changes"] = function()
  needs_tasksd()
  local first = get_ok(new_socket())
  local second = get_ok(new_socket())

  MiniTest.expect.no_equality(first, second)
  eq(first:is_connected(), false)
  eq(second:is_connected(), true)
end

T["get()"]["does not cache a failure"] = function()
  config.setup({ daemon = { path = "/nonexistent/tasksd" } })
  local socket = new_socket()

  local first, err
  with_no_tasksd(function()
    first, err = get_sync(socket)
  end)
  eq(first, nil)
  MiniTest.expect.no_equality(err, nil)

  needs_tasksd()
  config.setup({ daemon = { path = TASKSD } })
  local second = get_sync(socket)
  eq(second ~= nil, true)
end

T["get()"]["always calls back asynchronously, including on a cache hit"] = function()
  needs_tasksd()
  local socket = new_socket()
  get_sync(socket) -- prime the cache

  local order = {}
  client.get(socket, function()
    table.insert(order, "callback")
  end)
  table.insert(order, "returned")
  vim.wait(1000, function()
    return #order == 2
  end, 10)

  eq(order, { "returned", "callback" })
end

--------------------------------------------------------------------------------
-- get(): the default socket
--------------------------------------------------------------------------------

T["default socket"] = new_set({
  hooks = {
    post_case = function()
      client.reset()
    end,
  },
})

T["default socket"]["connects to the socket `daemon.socket` names"] = function()
  needs_tasksd()
  local socket = new_socket()
  config.setup({
    daemon = {
      path = TASKSD,
      socket = function()
        return socket
      end,
    },
  })

  eq(get_ok().socket_path, socket)
end

-- socket.path raises; the callback is the only channel a caller has.
T["default socket"]["reports an unresolvable setting through the callback"] = function()
  config.setup({ daemon = { socket = "nonsense" } })

  local c, err = get_sync()

  eq(c, nil)
  eq(tostring(err):match("daemon.socket must be one of") ~= nil, true)
end

-- The resolution happens before the cache is read, so a setting broken
-- mid-session cannot cost a live connection its subscriptions.
T["default socket"]["leaves the live client alone when it cannot resolve"] = function()
  needs_tasksd()
  local live = get_ok(new_socket())

  config.setup({ daemon = { socket = "nonsense" } })
  local c, err = get_sync()

  eq(c, nil)
  MiniTest.expect.no_equality(err, nil)
  eq(live:is_connected(), true)
end

T["default socket"]["takes the callback as its only argument"] = function()
  config.setup({ daemon = { socket = "nonsense" } })

  local order, err = {}, nil
  client.get(function(_, e)
    table.insert(order, "callback")
    err = e
  end)
  table.insert(order, "returned")
  vim.wait(1000, function()
    return #order == 2
  end, 10)

  -- Asynchronous even here, where the failure is known before any I/O.
  eq(order, { "returned", "callback" })
  MiniTest.expect.no_equality(err, nil)
end

return T
