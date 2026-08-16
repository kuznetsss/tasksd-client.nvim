local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local config = require("tasksd.config")
local daemon = require("tasksd.daemon")
local install = require("tasksd.install")

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
  },
})

--------------------------------------------------------------------------------
-- argv: pure, no daemon required
--------------------------------------------------------------------------------

T["executable()"] = new_set()

---Run `fn` with `tasksd.install` pretending a binary is (or is not) installed.
---
---`daemon.lua` calls these through the module table at call time, so replacing
---the fields is enough -- and it keeps the cases from depending on whether the
---machine running them happens to have a real installation.
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

-- A user who names a binary means it, even if :Tasksd install put one nearby.
T["executable()"]["prefers the configured path over an installed binary"] = function()
  config.setup({ daemon = { path = "/bin/tasksd" } })
  with_installed("/managed/bin/tasksd", function()
    eq(daemon.executable(), "/bin/tasksd")
  end)
end

T["executable()"]["uses an installed binary when path is unset"] = function()
  config.setup({ daemon = { path = "" } })
  with_installed("/managed/bin/tasksd", function()
    eq(daemon.executable(), "/managed/bin/tasksd")
  end)
end

-- Left as a bare name rather than resolved here: vim.system does the $PATH
-- lookup, and `tasksd.health` reports on whatever that finds.
T["executable()"]["falls back to a bare name when nothing is installed"] = function()
  config.setup({ daemon = { path = "" } })
  with_installed(nil, function()
    eq(daemon.executable(), "tasksd")
  end)
end

T["argv()"] = new_set()

T["argv()"]["maps config onto tasksd flags"] = function()
  config.setup({
    daemon = {
      path = "/bin/tasksd",
      thread_number = 7,
      task_buffer_size = 123,
      graceful_period = 11,
    },
  })
  local argv = daemon.argv("/tmp/x.sock")

  eq(argv[1], "/bin/tasksd")
  eq(flag_value(argv, "--unix-socket-path"), "/tmp/x.sock")
  eq(flag_value(argv, "--thread-number"), "7")
  eq(flag_value(argv, "--process-buffer-size"), "123")
  eq(flag_value(argv, "--graceful-period"), "11")
end

-- Stubbed rather than left to chance: argv[1] comes from executable(), which
-- prefers a plugin-installed binary -- so on a machine that has run
-- `:Tasksd install` the unstubbed answer is a path, not a bare name.
T["argv()"]["takes its program from executable()"] = function()
  config.setup({ daemon = { path = "" } })
  with_installed(nil, function()
    eq(daemon.argv("/tmp/x.sock")[1], "tasksd")
  end)
  with_installed("/managed/bin/tasksd", function()
    eq(daemon.argv("/tmp/x.sock")[1], "/managed/bin/tasksd")
  end)
end

-- Regression: a renamed or misspelled option used to reach the daemon as the
-- literal string "nil", which tasksd rejected with an opaque clap error.
T["argv()"]["rejects a non-numeric option instead of passing nil"] = function()
  config.setup({ daemon = { path = TASKSD, thread_number = "many" } })
  MiniTest.expect.error(function()
    daemon.argv("/tmp/x.sock")
  end, "thread_number must be a number")
end

--------------------------------------------------------------------------------
-- ensure: the callback contract
--------------------------------------------------------------------------------

T["ensure()"] = new_set()

-- Regression. `ensure` promises its callback runs on the main loop, but the
-- early-exit path used to hand it straight out of vim.system's on_exit, which
-- Neovim runs in a |fast-event| context -- where vim.fn and vim.wait raise
-- E5560. Callers log from that callback, so the failure only showed up when a
-- daemon died right after launching.
--
-- /bin/sh stands in for a binary that spawns fine and then rejects tasksd's
-- flags: exactly the shape of that path.
T["ensure()"]["hands its callback back on the main loop"] = function()
  config.setup({ daemon = { path = "/bin/sh" } })
  local socket_path = ("/tmp/tasksd-nvim-test-ensure-%d.sock"):format(vim.uv.os_getpid())
  vim.fn.delete(socket_path)

  local done, ok, fast_context_err = false, nil, nil
  daemon.ensure(socket_path, function(o)
    ok = o
    -- Anything vimscript-backed is illegal in a fast-event context; if the
    -- callback arrives there, this raises instead of returning a path.
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
