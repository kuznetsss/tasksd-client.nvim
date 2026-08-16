local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local config = require("tasksd.config")
local daemon = require("tasksd.daemon")

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

T["argv()"]["falls back to tasksd on $PATH when path is empty"] = function()
  config.setup({ daemon = { path = "" } })
  eq(daemon.argv("/tmp/x.sock")[1], "tasksd")
end

-- Regression: a renamed or misspelled option used to reach the daemon as the
-- literal string "nil", which tasksd rejected with an opaque clap error.
T["argv()"]["rejects a non-numeric option instead of passing nil"] = function()
  config.setup({ daemon = { path = TASKSD, thread_number = "many" } })
  MiniTest.expect.error(function()
    daemon.argv("/tmp/x.sock")
  end, "thread_number must be a number")
end

T["argv()"]["omits --log-file unless configured"] = function()
  config.setup({ daemon = { path = TASKSD } })
  eq(flag_value(daemon.argv("/tmp/x.sock"), "--log-file"), nil)

  config.setup({ daemon = { path = TASKSD, log_file = "/tmp/tasksd.log" } })
  eq(flag_value(daemon.argv("/tmp/x.sock"), "--log-file"), "/tmp/tasksd.log")
end

return T
