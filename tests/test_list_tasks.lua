local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local config = require("tasksd.config")
local list_tasks = require("tasksd.command.list_tasks")
local log = require("tasksd.log")
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
-- rows
--------------------------------------------------------------------------------

T["rows()"] = new_set()

---@param id integer
---@param state tasksd.TaskState
---@return tasksd.TaskEntry
local function entry(id, state)
  return {
    id = id,
    state = state,
    info = { executable = "sleep", args = { "60" }, working_dir = "/tmp" },
  }
end

T["rows()"]["puts the id, state, command and directory in columns"] = function()
  local rows = list_tasks.rows({ entry(3, "running") })
  eq(#rows, 1)
  eq(rows[1].columns, {
    { text = "3", hl = "Number", align = "right" },
    { text = "running", hl = "DiagnosticOk" },
    { text = "sleep 60" },
    { text = "/tmp", hl = "Directory" },
  })
end

T["rows()"]["carries the entry as the row's value"] = function()
  local task_entry = entry(3, "running")
  eq(list_tasks.rows({ task_entry })[1].value, task_entry)
end

T["rows()"]["shortens a working directory under $HOME"] = function()
  local rows = list_tasks.rows({
    {
      id = 1,
      state = "finished",
      info = { executable = "ls", args = {}, working_dir = vim.fn.expand("~/somewhere") },
    },
  })
  eq(rows[1].columns[4].text, "~/somewhere")
end

--------------------------------------------------------------------------------
-- show
--------------------------------------------------------------------------------

T["show()"] = new_set()

T["show()"]["opens the picker with one aligned item per task"] = function()
  local opened
  config.setup({
    picker = function(spec)
      opened = spec
    end,
  })

  list_tasks.show({ entry(3, "running"), entry(12, "finished") })

  eq(opened.title, list_tasks.TITLE)
  eq(opened.items[1].text, " 3  running   sleep 60  /tmp")
  eq(opened.items[2].text, "12  finished  sleep 60  /tmp")
  eq(opened.items[1].value.id, 3)
end

-- An empty picker leaves the user to work out which of "no tasks" and "no
-- answer" they are looking at.
T["show()"]["says so instead of opening an empty picker"] = function()
  local opened = false
  config.setup({
    picker = function()
      opened = true
    end,
  })

  local messages = with_capture(function()
    list_tasks.show({})
  end)

  eq(opened, false)
  eq(messages, { { msg = "the daemon has no tasks", level = vim.log.levels.INFO } })
end

T["show()"]["reports an unusable picker setting"] = function()
  config.setup({ picker = "nonsense" })

  local messages = with_capture(function()
    list_tasks.show({ entry(1, "running") })
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("^unknown picker `nonsense`") ~= nil, true)
end

--------------------------------------------------------------------------------
-- list: integration against a real daemon
--------------------------------------------------------------------------------

T["list()"] = new_set()

T["list()"]["shows a task the daemon is running"] = function()
  needs_tasksd()
  local opened = use_own_daemon()

  with_capture(function(messages)
    start_task.start({ working_dir = "/tmp", command = "sleep 60" })
    vim.wait(15000, function()
      return #messages >= 1
    end, 20)
    local task_id = messages[1].msg:match("as task (%d+)$")
    eq(task_id ~= nil, true)

    list_tasks.list()
    vim.wait(15000, function()
      return opened() ~= nil
    end, 20)

    local spec = assert(opened())
    local item = spec.items[1]
    eq(item.value.id, assert(tonumber(task_id)))
    eq(item.value.state, "running")
    eq(item.text:match("sleep 60") ~= nil, true)
  end)

  client.reset()
end

T["list()"]["reports an unusable socket setting without connecting"] = function()
  config.setup({ daemon = { socket = "nonsense" } })

  local messages = with_capture(function(msgs)
    list_tasks.list()
    vim.wait(1000, function()
      return #msgs >= 1
    end, 20)
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("daemon.socket must be one of") ~= nil, true)
end

return T
