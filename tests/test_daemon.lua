local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local config = require("tasksd.config")
local daemon = require("tasksd.daemon")
local install = require("tasksd.install")
local pin = require("tasksd.install.pin")

local temps = {}

-- There is no automated tasksd installation yet, so the integration tests run
-- against a local build. Override with TASKSD_BIN=/path/to/tasksd.
local TASKSD = os.getenv("TASKSD_BIN")
  or vim.fn.expand("~/Documents/rust/tasksd/target/debug/tasksd")

---@return string|nil
local function flag_value(argv, flag)
  for i, value in ipairs(argv) do
    if value == flag then
      return argv[i + 1]
    end
  end
  return nil
end

--------------------------------------------------------------------------------

local T = new_set({
  hooks = {
    pre_case = function()
      config.setup({ daemon = { path = TASKSD } })
    end,
    post_once = function()
      for _, path in ipairs(temps) do
        vim.fn.delete(path)
      end
    end,
  },
})

--------------------------------------------------------------------------------
-- argv: pure, no daemon required
--------------------------------------------------------------------------------

T["executable()"] = new_set()

---Run `fn` with `tasksd.install` pretending a binary is (or is not) installed,
---so the result does not depend on whether this machine has a real one.
---
---`daemon.lua` calls these through the module table at call time, so replacing
---the fields is enough.
---@param path string|nil nil means "nothing installed".
local function with_installed(path, fn)
  local is_installed, bin_path = install.is_installed, install.bin_path
  ---@diagnostic disable-next-line: duplicate-set-field
  install.is_installed = function()
    return path ~= nil
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  install.bin_path = function()
    return path
  end

  local ok, err = pcall(fn)
  install.is_installed, install.bin_path = is_installed, bin_path
  if not ok then
    error(err)
  end
end

T["executable()"]["prefers the configured path over an installed binary"] = function()
  config.setup({ daemon = { path = "/bin/sh" } })
  with_installed("/managed/bin/tasksd", function()
    eq({ daemon.executable() }, { "/bin/sh", "config" })
  end)
end

T["executable()"]["uses an installed binary when path is unset"] = function()
  config.setup({ daemon = { path = "" } })
  with_installed("/managed/bin/tasksd", function()
    eq({ daemon.executable() }, { "/managed/bin/tasksd", "installed" })
  end)
end

-- Bare rather than resolved: vim.system does the $PATH lookup.
T["executable()"]["falls back to a bare name when nothing is installed"] = function()
  config.setup({ daemon = { path = "" } })
  with_installed(nil, function()
    eq({ daemon.executable() }, { "tasksd", "env" })
  end)
end

-- A path that cannot be launched is worth less than one that can, so it loses
-- to a binary this plugin installed rather than guaranteeing an ENOENT.
T["executable()"]["ignores a configured path with nothing behind it"] = function()
  config.setup({ daemon = { path = "/nonexistent/tasksd" } })
  with_installed("/managed/bin/tasksd", function()
    eq({ daemon.executable() }, { "/managed/bin/tasksd", "installed" })
  end)
  with_installed(nil, function()
    eq({ daemon.executable() }, { "tasksd", "env" })
  end)
end

-- A shell expands ~, vim.system does not, so an unexpanded path would be
-- rejected as unrunnable on a file the user can plainly see.
T["executable()"]["expands ~ in the configured path"] = function()
  local exe =
    vim.fs.joinpath(vim.uv.os_homedir(), (".tasksd-nvim-test-exe-%d"):format(vim.uv.os_getpid()))
  vim.fn.writefile({ "#!/bin/sh", "exit 0" }, exe)
  vim.fn.setfperm(exe, "rwx------")

  config.setup({ daemon = { path = "~/" .. vim.fs.basename(exe) } })
  local resolved, source = daemon.executable()
  vim.fn.delete(exe)

  eq(resolved, exe)
  eq(source, "config")
end

T["argv()"] = new_set()

T["argv()"]["maps config onto tasksd flags"] = function()
  config.setup({
    daemon = {
      path = "/bin/sh",
      thread_number = 7,
      task_buffer_size = 123,
      graceful_period = 11,
    },
  })
  local argv = daemon.argv("/tmp/x.sock")

  eq(argv[1], "/bin/sh")
  eq(flag_value(argv, "--unix-socket-path"), "/tmp/x.sock")
  eq(flag_value(argv, "--thread-number"), "7")
  eq(flag_value(argv, "--process-buffer-size"), "123")
  eq(flag_value(argv, "--graceful-period"), "11")
end

-- Stubbed because executable() prefers a plugin-installed binary, so on a
-- machine that has run `:Tasksd install` the answer is a path, not a bare name.
T["argv()"]["takes its program from executable()"] = function()
  config.setup({ daemon = { path = "" } })
  with_installed(nil, function()
    eq(daemon.argv("/tmp/x.sock")[1], "tasksd")
  end)
  with_installed("/managed/bin/tasksd", function()
    eq(daemon.argv("/tmp/x.sock")[1], "/managed/bin/tasksd")
  end)
end

-- Unchecked, a renamed or misspelled option reaches the daemon as the literal
-- string "nil", which tasksd rejects with an opaque clap error.
T["argv()"]["rejects a non-numeric option instead of passing nil"] = function()
  config.setup({ daemon = { path = TASKSD, thread_number = "many" } })
  MiniTest.expect.error(function()
    daemon.argv("/tmp/x.sock")
  end, "thread_number must be a number")
end

--------------------------------------------------------------------------------
-- usable_version: the pre-launch version gate
--------------------------------------------------------------------------------

T["usable_version()"] = new_set()

---tostring() rather than indexing directly, so a nil error message fails the
---assertion instead of raising a nil-index inside the test.
local function contains(text, needle)
  return tostring(text):find(needle, 1, true) ~= nil
end

---An executable stand-in for tasksd that prints `output` for --version.
---@return string path
local function fake_tasksd(output)
  local path = vim.fn.tempname()
  vim.fn.writefile({ "#!/bin/sh", ("printf '%%s\\n' %s"):format(vim.fn.shellescape(output)) }, path)
  vim.fn.setfperm(path, "rwx------")
  table.insert(temps, path)
  return path
end

T["usable_version()"]["accepts a binary at the minimum"] = function()
  local version, err = daemon.usable_version(fake_tasksd("tasksd " .. pin.MIN_VERSION), "config")

  eq(version, pin.MIN_VERSION)
  eq(err, nil)
end

-- Naming the source is the point: "too old" alone leaves the user guessing
-- which of the three candidates the client even picked.
T["usable_version()"]["names daemon.path when that is what is stale"] = function()
  local version, err = daemon.usable_version(fake_tasksd("tasksd 0.0.1"), "config")

  eq(version, nil)
  eq(contains(err, "daemon.path"), true)
  eq(contains(err, "0.0.1"), true)
  eq(contains(err, pin.MIN_VERSION), true)
end

T["usable_version()"]["points at :Tasksd install for a stale installed binary"] = function()
  local _, err = daemon.usable_version(fake_tasksd("tasksd 0.0.1"), "installed")

  eq(contains(err, ":Tasksd install"), true)
end

T["usable_version()"]["rejects a binary that will not say what it is"] = function()
  local version, err = daemon.usable_version("/nonexistent/tasksd", "env")

  eq(version, nil)
  eq(contains(err, "could not read the version"), true)
end

-- Refusing rather than quietly launching something else: the user pointed at
-- this binary, so substituting another one behind their back is worse than
-- failing with a reason.
T["usable_version()"]["stops ensure() before anything is spawned"] = function()
  config.setup({ daemon = { path = fake_tasksd("tasksd 0.0.1") } })
  local socket_path = ("/tmp/tasksd-nvim-test-stale-%d.sock"):format(vim.uv.os_getpid())
  vim.fn.delete(socket_path)

  local done, ok, err = false, nil, nil
  daemon.ensure(socket_path, function(o, e)
    done, ok, err = true, o, e
  end)

  eq(
    vim.wait(10000, function()
      return done
    end, 20),
    true
  )
  eq(ok, false)
  eq(contains(err, "could not launch tasksd"), true)
  eq(contains(err, "0.0.1"), true)
  eq(vim.uv.fs_stat(socket_path), nil)
end

--------------------------------------------------------------------------------
-- ensure: the callback contract
--------------------------------------------------------------------------------

T["ensure()"] = new_set()

-- The early-exit path runs out of vim.system's on_exit, a |fast-event| context
-- where vim.fn and vim.wait raise E5560. Callers log from this callback, so a
-- missing hop to the main loop only bites when a daemon dies right after
-- launching. /bin/sh spawns fine and then rejects tasksd's flags: that shape.
T["ensure()"]["hands its callback back on the main loop"] = function()
  config.setup({ daemon = { path = "/bin/sh" } })
  local socket_path = ("/tmp/tasksd-nvim-test-ensure-%d.sock"):format(vim.uv.os_getpid())
  vim.fn.delete(socket_path)

  local done, ok, fast_context_err = false, nil, nil
  daemon.ensure(socket_path, function(o)
    ok = o
    -- Vimscript-backed, so this raises rather than returning a path if the
    -- callback arrived in a fast-event context.
    local called, err = pcall(vim.fn.tempname)
    fast_context_err = not called and tostring(err) or nil
    done = true
  end)

  local finished = vim.wait(10000, function()
    return done
  end, 20)

  eq(finished, true)
  eq(ok, false) -- sh cannot parse tasksd's flags, so it exits non-zero
  eq(fast_context_err, nil)
end

T["argv()"]["omits --log-file unless configured"] = function()
  config.setup({ daemon = { path = TASKSD } })
  eq(flag_value(daemon.argv("/tmp/x.sock"), "--log-file"), nil)

  config.setup({ daemon = { path = TASKSD, log_file = "/tmp/tasksd.log" } })
  eq(flag_value(daemon.argv("/tmp/x.sock"), "--log-file"), "/tmp/tasksd.log")
end

return T
