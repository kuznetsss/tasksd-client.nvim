local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local config = require("tasksd.config")
local list_tasks = require("tasksd.command.list_tasks")
local log = require("tasksd.log")
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
  local path = ("/tmp/tasksd-nvim-list-%d-%d.sock"):format(vim.uv.os_getpid(), socket_counter)
  table.insert(sockets, path)
  vim.fn.delete(path)
  return path
end

---Run `fn` with every user-facing message captured.
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

---Point the plugin at a daemon of this case's own, and at a picker that only
---records the spec it was handed.
---@return fun(): tasksd.picker.Spec|nil opened
local function use_own_daemon()
  local socket = new_socket()
  local opened
  config.setup({
    daemon = {
      path = TASKSD,
      socket = function()
        return socket
      end,
    },
    picker = function(spec)
      opened = spec
    end,
  })
  return function()
    return opened
  end
end

local T = new_set({
  hooks = {
    post_case = function()
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

T["parse()"]["defaults to all"] = function()
  eq(list_tasks.parse({}), "all")
end

T["parse()"]["takes a state as the filter"] = function()
  eq(list_tasks.parse({ "running" }), "running")
  eq(list_tasks.parse({ "finished" }), "finished")
end

T["parse()"]["rejects a filter that is not a state"] = function()
  local filter, err = list_tasks.parse({ "sleeping" })
  eq(filter, nil)
  eq(tostring(err):match("^unknown filter `sleeping`") ~= nil, true)
  eq(tostring(err):match("all, finished, running$") ~= nil, true)
end

T["parse()"]["rejects more than one filter"] = function()
  local filter, err = list_tasks.parse({ "running", "finished" })
  eq(filter, nil)
  eq(err, "expected at most one filter, got 2 arguments")
end

--------------------------------------------------------------------------------
-- messages
--------------------------------------------------------------------------------

T["title()"] = new_set()

T["title()"]["names the filter unless it is all"] = function()
  eq(list_tasks.title("all"), "tasksd tasks")
  eq(list_tasks.title("running"), "tasksd tasks (running)")
end

T["empty_message()"] = new_set()

T["empty_message()"]["names the filter unless it is all"] = function()
  eq(list_tasks.empty_message("all"), "the daemon has no tasks")
  eq(list_tasks.empty_message("finished"), "the daemon has no finished tasks")
end

--------------------------------------------------------------------------------
-- completion
--------------------------------------------------------------------------------

T["complete()"] = new_set()

T["complete()"]["offers the filters"] = function()
  eq(list_tasks.complete(""), { "all", "finished", "running" })
end

T["complete()"]["filters them by prefix"] = function()
  eq(list_tasks.complete("f"), { "finished" })
end

T["complete()"]["is reachable from the command line"] = function()
  eq(vim.fn.getcompletion("Tasksd list_tasks ", "cmdline"), { "all", "finished", "running" })
end

--------------------------------------------------------------------------------
-- impl
--------------------------------------------------------------------------------

T["impl()"] = new_set()

T["impl()"]["reports a bad filter without connecting"] = function()
  local messages = with_capture(function()
    list_tasks.impl({ "sleeping" })
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("^unknown filter `sleeping`") ~= nil, true)
end

--------------------------------------------------------------------------------
-- against a real daemon
--------------------------------------------------------------------------------

T["impl()"]["shows a task the daemon is running"] = function()
  needs_tasksd()
  local opened = use_own_daemon()

  with_capture(function(messages)
    start_task.start({ working_dir = "/tmp", command = "sleep 60" })
    vim.wait(15000, function()
      return #messages >= 1
    end, 20)
    local task_id = messages[1].msg:match("as task (%d+)$")
    eq(task_id ~= nil, true)

    list_tasks.impl({ "running" })
    vim.wait(15000, function()
      return opened() ~= nil
    end, 20)

    local spec = assert(opened())
    eq(spec.title, "tasksd tasks (running)")
    local item = spec.items[1]
    eq(item.value.id, assert(tonumber(task_id)))
    eq(item.value.state, "running")
    eq(item.text:match("sleep 60") ~= nil, true)
  end)

  client.reset()
end

T["impl()"]["says so when nothing matches the filter"] = function()
  needs_tasksd()
  local opened = use_own_daemon()

  local messages = with_capture(function(msgs)
    list_tasks.impl({ "finished" })
    vim.wait(15000, function()
      return #msgs >= 1
    end, 20)
  end)

  eq(opened(), nil)
  eq(messages[1].msg, "the daemon has no finished tasks")
  eq(messages[1].level, vim.log.levels.INFO)

  client.reset()
end

T["impl()"]["reports an unusable socket setting without connecting"] = function()
  config.setup({ daemon = { socket = "nonsense" } })

  local messages = with_capture(function(msgs)
    list_tasks.impl({})
    vim.wait(1000, function()
      return #msgs >= 1
    end, 20)
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("daemon.socket must be one of") ~= nil, true)
end

return T
