local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local config = require("tasksd.config")
local log = require("tasksd.log")
local send_signal = require("tasksd.command.send_signal")
local start_task = require("tasksd.command.start_task")

-- Same local build the other integration tests use; see tests/test_client.lua.
local TASKSD = os.getenv("TASKSD_BIN")
  or vim.fn.expand("~/Documents/rust/tasksd/target/debug/tasksd")

local function needs_tasksd()
  if vim.fn.executable(TASKSD) == 0 then
    MiniTest.skip(("no tasksd binary at %s (set TASKSD_BIN)"):format(TASKSD))
  end
end

local socket_counter = 0
local sockets = {}
local function new_socket()
  socket_counter = socket_counter + 1
  local path = ("/tmp/tasksd-nvim-signal-%d-%d.sock"):format(vim.uv.os_getpid(), socket_counter)
  table.insert(sockets, path)
  vim.fn.delete(path)
  return path
end

---Run `fn` with every user-facing message captured, handing it the table they
---land in.
---
---`task.watch` keeps the report function it was given, so a case that starts a
---task and then signals it has to stay inside one capture: a second one would
---install a stub the already-registered `task.exit` handler never sees.
---@param fn fun(messages: tests.Message[])
---@return tests.Message[]
local function with_capture(fn)
  local original = log.notify
  ---@type tests.Message[]
  local messages = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  log.notify = function(msg, level)
    table.insert(messages, { msg = msg, level = level })
  end

  local ok, raised = pcall(fn, messages)

  log.notify = original
  if not ok then
    error(raised, 0)
  end
  return messages
end

---@param messages tests.Message[]
---@param count integer
local function wait_for(messages, count)
  vim.wait(15000, function()
    return #messages >= count
  end, 20)
end

---@param count integer
---@param fn fun()
---@return tests.Message[]
local function capture(count, fn)
  return with_capture(function(messages)
    fn()
    wait_for(messages, count)
  end)
end

---Point the plugin at a daemon of this case's own.
local function use_own_daemon()
  local socket = new_socket()
  config.setup({
    daemon = {
      path = TASKSD,
      socket = function()
        return socket
      end,
    },
  })
end

---@param messages tests.Message[]
---@param pattern string
---@return tests.Message|nil
local function find(messages, pattern)
  for _, message in ipairs(messages) do
    if message.msg:match(pattern) then
      return message
    end
  end
  return nil
end

local T = new_set({
  hooks = {
    post_once = function()
      for _, path in ipairs(sockets) do
        vim.fn.system({ "pkill", "-f", path })
        vim.fn.delete(path)
      end
      config.setup({})
    end,
  },
})

--------------------------------------------------------------------------------
-- signal_number
--------------------------------------------------------------------------------

T["signal_number()"] = new_set()

T["signal_number()"]["accepts a number"] = function()
  eq(send_signal.signal_number("15"), 15)
end

T["signal_number()"]["accepts a name with or without the SIG prefix"] = function()
  eq(send_signal.signal_number("TERM"), vim.uv.constants.SIGTERM)
  eq(send_signal.signal_number("SIGKILL"), vim.uv.constants.SIGKILL)
end

T["signal_number()"]["is case insensitive"] = function()
  eq(send_signal.signal_number("sigint"), vim.uv.constants.SIGINT)
end

T["signal_number()"]["rejects an unknown name"] = function()
  local number, err = send_signal.signal_number("BOGUS")
  eq(number, nil)
  eq(tostring(err):match("^unknown signal `BOGUS`") ~= nil, true)
end

-- Only names starting with SIG are signals; vim.uv.constants also holds
-- unrelated numbers such as O_RDONLY.
T["signal_number()"]["does not resolve other libuv constants"] = function()
  local number = send_signal.signal_number("O_RDONLY")
  eq(number, nil)
end

T["signal_number()"]["rejects zero"] = function()
  local number, err = send_signal.signal_number("0")
  eq(number, nil)
  eq(err ~= nil, true)
end

--------------------------------------------------------------------------------
-- params
--------------------------------------------------------------------------------

T["params()"] = new_set()

T["params()"]["builds the request from key=value arguments"] = function()
  eq(send_signal.params({ "task_id=3", "signal=9" }), { task_id = 3, signal = 9 })
end

T["params()"]["does not care about argument order"] = function()
  eq(send_signal.params({ "signal=9", "task_id=3" }), { task_id = 3, signal = 9 })
end

T["params()"]["defaults to TERM"] = function()
  local params = assert(send_signal.params({ "task_id=3" }))
  eq(params.signal, vim.uv.constants.SIGTERM)
end

T["params()"]["requires a task id"] = function()
  local params, err = send_signal.params({ "signal=9" })
  eq(params, nil)
  eq(err, "task_id= is required")
end

T["params()"]["rejects a task id that is not a number"] = function()
  local params, err = send_signal.params({ "task_id=abc" })
  eq(params, nil)
  eq(err, "`abc` is not a task id")
end

T["params()"]["rejects a bare word"] = function()
  local params, err = send_signal.params({ "3" })
  eq(params, nil)
  eq(err, "expected key=value, got `3`")
end

T["params()"]["rejects an unknown key"] = function()
  local params, err = send_signal.params({ "task=3" })
  eq(params, nil)
  eq(tostring(err):match("^unknown argument `task`") ~= nil, true)
end

--------------------------------------------------------------------------------
-- completion
--------------------------------------------------------------------------------

T["complete()"] = new_set()

T["complete()"]["offers the keys"] = function()
  eq(send_signal.complete(""), { "signal=", "task_id=" })
end

T["complete()"]["filters the keys by prefix"] = function()
  eq(send_signal.complete("ta"), { "task_id=" })
end

T["complete()"]["offers signal names"] = function()
  eq(vim.tbl_contains(send_signal.complete("signal="), "signal=TERM"), true)
end

T["complete()"]["filters signal names by prefix, ignoring case"] = function()
  eq(send_signal.complete("signal=ter"), { "signal=TERM" })
end

T["complete()"]["offers nothing for a task id"] = function()
  eq(send_signal.complete("task_id="), {})
end

T["complete()"]["is reachable from the command line"] = function()
  eq(vim.fn.getcompletion("Tasksd send_signal ", "cmdline"), { "signal=", "task_id=" })
end

--------------------------------------------------------------------------------
-- send: integration against a real daemon
--------------------------------------------------------------------------------

T["send()"] = new_set()

T["send()"]["signals a running task, which then reports its exit"] = function()
  needs_tasksd()
  use_own_daemon()

  local task_id
  local messages = with_capture(function(msgs)
    start_task.start({ working_dir = "/tmp", command = "sleep 60" })
    wait_for(msgs, 1)
    task_id = msgs[1].msg:match("as task (%d+)$")
    eq(task_id ~= nil, true)

    send_signal.impl({ "task_id=" .. task_id, "signal=TERM" })
    wait_for(msgs, 3)
  end)

  -- The response and the `task.exit` notification are not ordered against each
  -- other, so both are looked for and neither is assumed to be first.
  local sent = assert(find(messages, ("^sent signal %%d+ to task %s$"):format(task_id)))
  eq(sent.level, vim.log.levels.INFO)

  eq(find(messages, ("^task %s was killed by signal %%d+$"):format(task_id)) ~= nil, true)

  client.reset()
end

T["send()"]["reports a task the daemon does not know"] = function()
  needs_tasksd()
  use_own_daemon()

  local messages = capture(1, function()
    send_signal.impl({ "task_id=999999", "signal=TERM" })
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("^could not signal task 999999: ") ~= nil, true)

  client.reset()
end

T["send()"]["reports an unusable socket setting without connecting"] = function()
  config.setup({ daemon = { socket = "nonsense" } })

  local messages = capture(1, function()
    send_signal.impl({ "task_id=1" })
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("daemon.socket must be one of") ~= nil, true)
end

return T
