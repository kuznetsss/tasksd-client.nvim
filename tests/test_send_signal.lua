local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local config = require("tasksd.config")
local last = require("tasksd.last")
local log = require("tasksd.log")
local send_signal = require("tasksd.command.send_signal")
local start_task = require("tasksd.command.start_task")

local TASKSD = os.getenv("TASKSD_BIN")

local function needs_tasksd()
  if not TASKSD or vim.fn.executable(TASKSD) == 0 then
    MiniTest.skip("no tasksd binary; set TASKSD_BIN=/path/to/tasksd")
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

---Point the plugin at a daemon of this case's own, and at a picker that only
---records what it is asked to open. Both questions this command asks go
---through the same recorder, so the table is a list.
---@return tasksd.picker.Spec[] specs
local function use_own_daemon()
  local socket = new_socket()
  local specs = {}
  config.setup({
    daemon = {
      path = TASKSD,
      socket = function()
        return socket
      end,
    },
    picker = function(spec)
      table.insert(specs, spec)
    end,
  })
  return specs
end

---@param id integer
---@return tasksd.TaskEntry
local function entry(id)
  return {
    id = id,
    state = "running",
    info = { executable = "sleep", args = { "60" }, working_dir = "/tmp" },
  }
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
    post_case = function()
      config.setup({})
      last.reset()
    end,
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
-- arguments
--------------------------------------------------------------------------------

T["from_argv()"] = new_set()

T["from_argv()"]["reads both keys"] = function()
  eq(send_signal.from_argv({ "task_id=3", "signal=9" }), { task_id = 3, signal = "9" })
end

T["from_argv()"]["does not care about argument order"] = function()
  eq(
    send_signal.from_argv({ "signal=9", "task_id=3" }),
    send_signal.from_argv({ "task_id=3", "signal=9" })
  )
end

-- Carried through as it stands: only a connection can put a number to it.
T["from_argv()"]["takes `last` in place of an id"] = function()
  eq(send_signal.from_argv({ "task_id=last" }).task_id, "last")
end

T["from_argv()"]["rejects a task id that is not a number"] = function()
  local opts, err = send_signal.from_argv({ "task_id=abc" })
  eq(opts, nil)
  eq(err, "expected a task id or `last`, got `abc`")
end

T["from_argv()"]["rejects a bare word"] = function()
  local opts, err = send_signal.from_argv({ "3" })
  eq(opts, nil)
  eq(err, "expected key=value, got `3`")
end

T["from_argv()"]["rejects an unknown key"] = function()
  local opts, err = send_signal.from_argv({ "task=3" })
  eq(opts, nil)
  eq(tostring(err):match("^unknown argument `task`") ~= nil, true)
end

T["validate()"] = new_set()

T["validate()"]["turns a signal name into a number"] = function()
  eq(send_signal.validate({ task_id = 3, signal = "KILL" }), {
    task_id = 3,
    signal = vim.uv.constants.SIGKILL,
  })
end

T["validate()"]["takes a signal number as it stands"] = function()
  eq(send_signal.validate({ task_id = 3, signal = 9 }), { task_id = 3, signal = 9 })
end

-- Left unanswered rather than defaulted: without a task id the picker asks for
-- the signal too, and only the other path falls back to TERM.
T["validate()"]["leaves a missing signal alone"] = function()
  eq(send_signal.validate({ task_id = 3 }), { task_id = 3 })
end

T["validate()"]["carries `last` through"] = function()
  eq(send_signal.validate({ task_id = "last", signal = 9 }), { task_id = "last", signal = 9 })
end

T["validate()"]["rejects a task id that is neither a number nor `last`"] = function()
  ---@diagnostic disable-next-line: assign-type-mismatch
  local target, err = send_signal.validate({ task_id = "3" })
  eq(target, nil)
  eq(err, "expected a task id or `last`, got `3`")
end

T["validate()"]["rejects an unknown signal"] = function()
  local target, err = send_signal.validate({ task_id = 3, signal = "BOGUS" })
  eq(target, nil)
  eq(tostring(err):match("^unknown signal `BOGUS`") ~= nil, true)
end

T["run()"] = new_set()

---Run `fn` with `send` replaced by a recorder, so nothing here reaches a daemon.
---@param fn fun(sent: tasksd.command.SignalTarget[])
local function with_stubbed_send(fn)
  local original = send_signal.send
  local sent = {}

  ---@diagnostic disable-next-line: duplicate-set-field
  send_signal.send = function(target)
    table.insert(sent, target)
  end

  local ok, err = pcall(fn, sent)

  send_signal.send = original
  if not ok then
    error(err, 0)
  end
end

T["run()"]["defaults to TERM"] = function()
  with_stubbed_send(function(sent)
    send_signal.run({ task_id = 3 })
    eq(sent, { { task_id = 3, signal = vim.uv.constants.SIGTERM } })
  end)
end

T["run()"]["defaults to TERM for `last` too"] = function()
  with_stubbed_send(function(sent)
    send_signal.run({ task_id = "last" })
    eq(sent, { { task_id = "last", signal = vim.uv.constants.SIGTERM } })
  end)
end

-- The command line and the Lua call are the same request written two ways.
T["run()"]["matches the command line"] = function()
  with_stubbed_send(function(sent)
    vim.cmd("Tasksd send_signal task_id=3 signal=KILL")
    send_signal.run({ task_id = 3, signal = "KILL" })
    eq(#sent, 2)
    eq(sent[1], sent[2])
  end)
end

--------------------------------------------------------------------------------
-- resolve
--------------------------------------------------------------------------------

---`resolve` only ever reads `last` off a connection, which compares it by
---identity and keys it by socket path.
---@param socket_path string
---@return tasksd.Client
local function fake_client(socket_path)
  local c = { socket_path = socket_path }
  ---@cast c tasksd.Client
  return c
end

---@type tasksd.TaskStartParams
local STARTED = {
  executable = "sleep",
  args = { "60" },
  working_dir = "/tmp",
  subscribe_to_output = false,
}

T["resolve()"] = new_set()

T["resolve()"]["leaves a numbered task alone"] = function()
  local params = send_signal.resolve({ task_id = 3, signal = 9 }, fake_client("/tmp/a.sock"))
  eq(params, { task_id = 3, signal = 9 })
end

T["resolve()"]["puts the last task's id in place of `last`"] = function()
  local c = fake_client("/tmp/a.sock")
  last.record(c, 7, STARTED)

  local params = send_signal.resolve({ task_id = "last", signal = 9 }, c)
  eq(params, { task_id = 7, signal = 9 })
end

T["resolve()"]["says so when nothing has been started here"] = function()
  local c = fake_client("/tmp/a.sock")
  local params, err = send_signal.resolve({ task_id = "last", signal = 9 }, c)
  eq(params, nil)
  eq(tostring(err):match("^no task to signal") ~= nil, true)
end

-- The other daemon's task is none of this one's business.
T["resolve()"]["does not reach across sockets"] = function()
  last.record(fake_client("/tmp/a.sock"), 7, STARTED)

  local params = send_signal.resolve({ task_id = "last", signal = 9 }, fake_client("/tmp/b.sock"))
  eq(params, nil)
end

-- A later connection to the same socket may be a restarted daemon, whose id
-- counter began again at 1.
T["resolve()"]["refuses an id from an earlier connection"] = function()
  last.record(fake_client("/tmp/a.sock"), 7, STARTED)

  local params = send_signal.resolve({ task_id = "last", signal = 9 }, fake_client("/tmp/a.sock"))
  eq(params, nil)
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

-- The ids are behind a request and completion answers synchronously; `last` is
-- the one value that is known here.
T["complete()"]["offers only `last` for a task id"] = function()
  eq(send_signal.complete("task_id="), { "task_id=last" })
end

T["complete()"]["filters `last` by prefix"] = function()
  eq(send_signal.complete("task_id=la"), { "task_id=last" })
  eq(send_signal.complete("task_id=x"), {})
end

T["complete()"]["is reachable from the command line"] = function()
  eq(vim.fn.getcompletion("Tasksd send_signal ", "cmdline"), { "signal=", "task_id=" })
end

--------------------------------------------------------------------------------
-- the signal picker
--------------------------------------------------------------------------------

T["signal_rows()"] = new_set()

-- The first row is what <CR> takes without any typing.
T["signal_rows()"]["puts the default signal first"] = function()
  local rows = send_signal.signal_rows()
  eq(rows[1].value, send_signal.DEFAULT_SIGNAL)
  eq(rows[1].columns[1].text, send_signal.DEFAULT_SIGNAL)
  eq(rows[1].columns[2].text, tostring(vim.uv.constants.SIGTERM))
end

T["signal_rows()"]["offers every signal, the rest alphabetically"] = function()
  local rows = send_signal.signal_rows()
  eq(#rows, #send_signal.signal_names())

  local rest = vim.tbl_map(function(row)
    return row.value
  end, vim.list_slice(rows, 2))
  local sorted = vim.deepcopy(rest)
  table.sort(sorted)
  eq(rest, sorted)
end

T["choose_signal()"] = new_set()

T["choose_signal()"]["names the task in the title"] = function()
  local specs = use_own_daemon()

  send_signal.choose_signal(entry(3))

  eq(specs[1].title, "Choose a signal to send to task 3: sleep 60")
  eq(specs[1].items[1].text:match("^TERM") ~= nil, true)
end

T["choose_signal()"]["sends what was chosen to the task it was opened for"] = function()
  local specs = use_own_daemon()
  local sent
  local original = send_signal.send
  ---@diagnostic disable-next-line: duplicate-set-field
  send_signal.send = function(params)
    sent = params
  end

  send_signal.choose_signal(entry(3))
  specs[1].on_choice("KILL")

  send_signal.send = original
  eq(sent, { task_id = 3, signal = vim.uv.constants.SIGKILL })
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
    start_task.start({ working_dir = "/tmp", command = "sleep 60", show_output = false })
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

-- The whole `<F7>` path: start something, then kill it without naming its id.
T["send()"]["signals the last task started"] = function()
  needs_tasksd()
  use_own_daemon()

  local task_id
  local messages = with_capture(function(msgs)
    start_task.start({ working_dir = "/tmp", command = "sleep 60", show_output = false })
    wait_for(msgs, 1)
    task_id = msgs[1].msg:match("as task (%d+)$")
    eq(task_id ~= nil, true)

    send_signal.impl({ "task_id=last", "signal=KILL" })
    wait_for(msgs, 3)
  end)

  local sent = assert(find(messages, ("^sent signal %%d+ to task %s$"):format(task_id)))
  eq(sent.level, vim.log.levels.INFO)
  eq(find(messages, ("^task %s was killed by signal %%d+$"):format(task_id)) ~= nil, true)

  client.reset()
end

-- Reported after connecting, unlike every other argument error here: only a
-- connection says which daemon `last` is about.
T["send()"]["says so when nothing has been started here"] = function()
  needs_tasksd()
  use_own_daemon()

  local messages = capture(1, function()
    send_signal.impl({ "task_id=last" })
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("^no task to signal") ~= nil, true)

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

--------------------------------------------------------------------------------
-- impl: both questions, against a real daemon
--------------------------------------------------------------------------------

T["impl()"] = new_set()

T["impl()"]["asks which task, then which signal, then sends it"] = function()
  needs_tasksd()
  local specs = use_own_daemon()

  local messages = with_capture(function(msgs)
    start_task.start({ working_dir = "/tmp", command = "sleep 60", show_output = false })
    wait_for(msgs, 1)
    local task_id = assert(tonumber(msgs[1].msg:match("as task (%d+)$")))

    send_signal.impl({})
    vim.wait(15000, function()
      return #specs >= 1
    end, 20)

    eq(specs[1].title, send_signal.TASK_TITLE)
    local chosen = specs[1].items[1].value
    eq(chosen.id, task_id)
    eq(chosen.state, "running")

    -- Answering the first question asks the second, in the same tick.
    specs[1].on_choice(chosen)
    eq(#specs, 2)
    eq(specs[2].title, ("Choose a signal to send to task %d: sleep 60"):format(task_id))

    specs[2].on_choice("TERM")
    wait_for(msgs, 3)
  end)

  eq(find(messages, "^sent signal %d+ to task %d+$") ~= nil, true)
  eq(find(messages, "^task %d+ was killed by signal %d+$") ~= nil, true)

  client.reset()
end

T["impl()"]["takes signal= as the second answer in advance"] = function()
  needs_tasksd()
  local specs = use_own_daemon()

  local messages = with_capture(function(msgs)
    start_task.start({ working_dir = "/tmp", command = "sleep 60", show_output = false })
    wait_for(msgs, 1)

    send_signal.impl({ "signal=KILL" })
    vim.wait(15000, function()
      return #specs >= 1
    end, 20)

    specs[1].on_choice(specs[1].items[1].value)
    wait_for(msgs, 3)
  end)

  eq(#specs, 1)
  eq(find(messages, ("^sent signal %d+ to task"):format(vim.uv.constants.SIGKILL)) ~= nil, true)

  client.reset()
end

T["impl()"]["says so when the daemon has nothing running"] = function()
  needs_tasksd()
  local specs = use_own_daemon()

  local messages = capture(1, function()
    send_signal.impl({})
  end)

  eq(#specs, 0)
  eq(messages[1].msg, "the daemon has no running tasks")
  eq(messages[1].level, vim.log.levels.INFO)

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
