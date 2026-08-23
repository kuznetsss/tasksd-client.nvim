local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local config = require("tasksd.config")
local log = require("tasksd.log")
local send_input = require("tasksd.command.send_input")
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
  local path = ("/tmp/tasksd-nvim-input-%d-%d.sock"):format(vim.uv.os_getpid(), socket_counter)
  table.insert(sockets, path)
  vim.fn.delete(path)
  return path
end

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

---A daemon of this case's own, and a picker that records rather than opens.
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

---Stand in for whatever dressing plugin owns `vim.ui.input`, recording the opts
---it is given and answering with `answer` (nil stands for a cancelled prompt).
---@param answer string|nil
---@return table[] prompts
local function stub_ui_input(answer)
  local prompts = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function(opts, on_confirm)
    table.insert(prompts, opts)
    on_confirm(answer)
  end
  return prompts
end

local original_ui_input = vim.ui.input

local T = new_set({
  hooks = {
    post_case = function()
      vim.ui.input = original_ui_input
      config.setup({})
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
-- parse
--------------------------------------------------------------------------------

T["parse()"] = new_set()

T["parse()"]["reads both keys"] = function()
  eq(send_input.parse({ "task_id=3", "input=yes" }), { task_id = "3", input = "yes" })
end

-- fargs is already split on whitespace, so input= has to take what follows.
T["parse()"]["gives input= the rest of the arguments"] = function()
  eq(send_input.parse({ "task_id=3", "input=hello", "there", "world" }).input, "hello there world")
end

T["parse()"]["keeps an empty input"] = function()
  eq(send_input.parse({ "input=" }).input, "")
end

T["parse()"]["rejects a bare word"] = function()
  local values, err = send_input.parse({ "3" })
  eq(values, nil)
  eq(err, "expected key=value, got `3`")
end

T["parse()"]["rejects an unknown key"] = function()
  local values, err = send_input.parse({ "text=hi" })
  eq(values, nil)
  eq(tostring(err):match("^unknown argument `text`") ~= nil, true)
end

--------------------------------------------------------------------------------
-- line
--------------------------------------------------------------------------------

T["line()"] = new_set()

T["line()"]["ends the line for a task waiting on one"] = function()
  eq(send_input.line("yes"), "yes\n")
end

T["line()"]["leaves text that already ends in a newline"] = function()
  eq(send_input.line("yes\n"), "yes\n")
end

T["line()"]["turns an empty answer into a bare newline"] = function()
  eq(send_input.line(""), "\n")
end

--------------------------------------------------------------------------------
-- params
--------------------------------------------------------------------------------

T["params()"] = new_set()

T["params()"]["builds the request from key=value arguments"] = function()
  eq(send_input.params({ "task_id=3", "input=yes" }), { task_id = 3, input = "yes\n" })
end

T["params()"]["requires a task id"] = function()
  local params, err = send_input.params({ "input=yes" })
  eq(params, nil)
  eq(err, "task_id= is required")
end

T["params()"]["requires input"] = function()
  local params, err = send_input.params({ "task_id=3" })
  eq(params, nil)
  eq(err, "input= is required")
end

T["params()"]["rejects a task id that is not a number"] = function()
  local params, err = send_input.params({ "task_id=abc", "input=yes" })
  eq(params, nil)
  eq(err, "`abc` is not a task id")
end

--------------------------------------------------------------------------------
-- completion
--------------------------------------------------------------------------------

T["complete()"] = new_set()

T["complete()"]["offers the keys"] = function()
  eq(send_input.complete(""), { "input=", "task_id=" })
end

T["complete()"]["filters the keys by prefix"] = function()
  eq(send_input.complete("ta"), { "task_id=" })
end

T["complete()"]["offers nothing for either value"] = function()
  eq(send_input.complete("task_id="), {})
  eq(send_input.complete("input=he"), {})
end

T["complete()"]["is reachable from the command line"] = function()
  eq(vim.fn.getcompletion("Tasksd send_input ", "cmdline"), { "input=", "task_id=" })
end

--------------------------------------------------------------------------------
-- the prompt
--------------------------------------------------------------------------------

T["ask()"] = new_set()

T["ask()"]["names the task, and its command line when it knows it"] = function()
  local prompts = stub_ui_input(nil)

  send_input.ask(3)
  send_input.ask(4, "cat -")

  eq(prompts[1].prompt, "Input for task 3: ")
  eq(prompts[2].prompt, "Input for task 4 (cat -): ")
end

T["ask()"]["sends nothing when the prompt is cancelled"] = function()
  stub_ui_input(nil)
  local sent
  local original = send_input.send
  ---@diagnostic disable-next-line: duplicate-set-field
  send_input.send = function(params)
    sent = params
  end

  send_input.ask(3)

  send_input.send = original
  eq(sent, nil)
end

T["ask()"]["ends what was typed with a newline"] = function()
  stub_ui_input("yes")
  local sent
  local original = send_input.send
  ---@diagnostic disable-next-line: duplicate-set-field
  send_input.send = function(params)
    sent = params
  end

  send_input.ask(3)

  send_input.send = original
  eq(sent, { task_id = 3, input = "yes\n" })
end

--------------------------------------------------------------------------------
-- send: integration against a real daemon
--------------------------------------------------------------------------------

T["send()"] = new_set()

T["send()"]["writes to a running task's stdin"] = function()
  needs_tasksd()
  use_own_daemon()

  local messages = with_capture(function(msgs)
    start_task.start({ working_dir = "/tmp", command = "cat" })
    wait_for(msgs, 1)
    local task_id = assert(msgs[1].msg:match("as task (%d+)$"))

    send_input.impl({ "task_id=" .. task_id, "input=hello" })
    wait_for(msgs, 2)

    eq(find(msgs, ("^sent input to task %s$"):format(task_id)) ~= nil, true)
  end)

  eq(find(messages, "^could not"), nil)

  client.reset()
end

T["send()"]["reports a task the daemon does not know"] = function()
  needs_tasksd()
  use_own_daemon()

  local messages = capture(1, function()
    send_input.impl({ "task_id=999999", "input=hello" })
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("^could not send input to task 999999: ") ~= nil, true)

  client.reset()
end

T["send()"]["reports an unusable socket setting without connecting"] = function()
  config.setup({ daemon = { socket = "nonsense" } })

  local messages = capture(1, function()
    send_input.impl({ "task_id=1", "input=hello" })
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("daemon.socket must be one of") ~= nil, true)
end

--------------------------------------------------------------------------------
-- impl: both questions, against a real daemon
--------------------------------------------------------------------------------

T["impl()"] = new_set()

T["impl()"]["asks which task, then for the text, then sends it"] = function()
  needs_tasksd()
  local specs = use_own_daemon()
  local prompts = stub_ui_input("hello")

  local messages = with_capture(function(msgs)
    start_task.start({ working_dir = "/tmp", command = "cat" })
    wait_for(msgs, 1)
    local task_id = assert(tonumber(msgs[1].msg:match("as task (%d+)$")))

    send_input.impl({})
    vim.wait(15000, function()
      return #specs >= 1
    end, 20)

    eq(specs[1].title, send_input.TASK_TITLE)
    local chosen = specs[1].items[1].value
    eq(chosen.id, task_id)
    eq(chosen.state, "running")

    -- Answering the first question asks the second, in the same tick.
    specs[1].on_choice(chosen)
    eq(prompts[1].prompt, ("Input for task %d (cat): "):format(task_id))

    wait_for(msgs, 2)
  end)

  eq(find(messages, "^sent input to task %d+$") ~= nil, true)

  client.reset()
end

T["impl()"]["takes input= as the second answer in advance"] = function()
  needs_tasksd()
  local specs = use_own_daemon()
  local prompts = stub_ui_input("unused")

  local messages = with_capture(function(msgs)
    start_task.start({ working_dir = "/tmp", command = "cat" })
    wait_for(msgs, 1)

    send_input.impl({ "input=hello", "there" })
    vim.wait(15000, function()
      return #specs >= 1
    end, 20)

    specs[1].on_choice(specs[1].items[1].value)
    wait_for(msgs, 2)
  end)

  eq(#prompts, 0)
  eq(find(messages, "^sent input to task %d+$") ~= nil, true)

  client.reset()
end

T["impl()"]["asks only for the text when task_id= is given"] = function()
  local prompts = stub_ui_input(nil)
  local specs = use_own_daemon()

  send_input.impl({ "task_id=7" })

  eq(#specs, 0)
  eq(prompts[1].prompt, "Input for task 7: ")
end

T["impl()"]["says so when the daemon has nothing running"] = function()
  needs_tasksd()
  local specs = use_own_daemon()

  local messages = capture(1, function()
    send_input.impl({})
  end)

  eq(#specs, 0)
  eq(messages[1].msg, "the daemon has no running tasks")
  eq(messages[1].level, vim.log.levels.INFO)

  client.reset()
end

return T
