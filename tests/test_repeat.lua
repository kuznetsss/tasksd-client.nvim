local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local config = require("tasksd.config")
local last = require("tasksd.last")
local log = require("tasksd.log")
local repeat_task = require("tasksd.command.repeat")
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
  local path = ("/tmp/tasksd-nvim-repeat-%d-%d.sock"):format(vim.uv.os_getpid(), socket_counter)
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

---Every case here starts a task before repeating it, and both report the same
---way, so `from` is what tells the second start from the first.
---@param messages tests.Message[]
---@param pattern string
---@param from? integer Index to search from. Defaults to 1.
---@return tests.Message|nil
local function find(messages, pattern, from)
  for i = from or 1, #messages do
    if messages[i].msg:match(pattern) then
      return messages[i]
    end
  end
  return nil
end

---Point the plugin at a daemon of this case's own, and at a picker that only
---records what it is asked to open.
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
-- is_running
--------------------------------------------------------------------------------

---@param running integer[]
---@param finished integer[]
---@return table
local function listing(running, finished)
  local function group(ids)
    return vim.tbl_map(function(id)
      return { id = id, info = { executable = "sleep", args = { "60" }, working_dir = "/tmp" } }
    end, ids)
  end
  return { tasks = { running = group(running), finished = group(finished) } }
end

T["is_running()"] = new_set()

T["is_running()"]["spots a task the daemon still calls running"] = function()
  eq(repeat_task.is_running(listing({ 2 }, { 1 }), 2), true)
end

T["is_running()"]["a finished task is not running"] = function()
  eq(repeat_task.is_running(listing({ 2 }, { 1 }), 1), false)
end

-- The daemon remembers only the 100 most recent finished tasks, so falling out
-- of the listing is what ageing out looks like -- and only finished tasks age.
T["is_running()"]["a task the daemon has forgotten is not running"] = function()
  eq(repeat_task.is_running(listing({ 2 }, { 1 }), 99), false)
end

T["is_running()"]["copes with a listing it cannot read"] = function()
  eq(repeat_task.is_running(nil, 1), false)
  eq(repeat_task.is_running({}, 1), false)
end

--------------------------------------------------------------------------------
-- params
--------------------------------------------------------------------------------

T["params()"] = new_set()

T["params()"]["rebuilds the argv the daemon reported"] = function()
  local params = repeat_task.params({ executable = "ls", args = { "-la" }, working_dir = "/tmp" })
  eq(params.executable, "ls")
  eq(params.args, { "-la" })
  eq(params.working_dir, "/tmp")
end

-- `info` has no `subscribe_to_output` to carry, so the config answers instead.
T["params()"]["takes the output box from the config"] = function()
  config.setup({ output = { show_on_start = false } })
  local info = { executable = "ls", args = {}, working_dir = "/tmp" }
  eq(repeat_task.params(info).subscribe_to_output, false)

  config.setup({ output = { show_on_start = true } })
  eq(repeat_task.params(info).subscribe_to_output, true)
end

T["params()"]["sends an empty argument list as a JSON array"] = function()
  local params = repeat_task.params({ executable = "ls", args = {}, working_dir = "/tmp" })
  eq(vim.json.encode(params.args), "[]")
end

--------------------------------------------------------------------------------
-- impl: against a real daemon
--------------------------------------------------------------------------------

T["impl()"] = new_set()

---Start `command` and wait until the daemon reports its id.
---@param messages tests.Message[]
---@param command string
---@return integer task_id
local function start(messages, command)
  local before = #messages
  start_task.start({ working_dir = "/tmp", command = command })
  wait_for(messages, before + 1)
  return assert(tonumber(messages[before + 1].msg:match("as task (%d+)$")), "no task id reported")
end

-- The `<F6>` path: the same command runs again, as a task of its own.
T["impl()"]["starts the last task again once it has finished"] = function()
  needs_tasksd()
  use_own_daemon()

  local messages = with_capture(function(msgs)
    local first = start(msgs, "true")
    -- The daemon moves a task to `finished` a moment after its `task.exit`, so
    -- the exit notification is not enough on its own to know it is there.
    wait_for(msgs, 2)
    eq(find(msgs, ("^task %d finished$"):format(first)) ~= nil, true)

    local before = #msgs
    repeat_task.impl({}, false)
    wait_for(msgs, before + 2)

    local again =
      assert(find(msgs, "^started `true` as task %d+$", before + 1), "it did not start again")
    eq(tonumber(again.msg:match("as task (%d+)$")) ~= first, true)
  end)

  eq(find(messages, "still running") == nil, true)
  client.reset()
end

T["impl()"]["refuses while the last task is still running"] = function()
  needs_tasksd()
  use_own_daemon()

  local messages = with_capture(function(msgs)
    local id = start(msgs, "sleep 60")

    repeat_task.impl({}, false)
    wait_for(msgs, 2)

    eq(msgs[2].level, vim.log.levels.WARN)
    eq(msgs[2].msg, ("task %d is still running; `:Tasksd repeat!` starts another"):format(id))
  end)

  -- One start, one refusal, and nothing else.
  eq(#messages, 2)
  client.reset()
end

T["impl()"]["a bang starts another one anyway"] = function()
  needs_tasksd()
  use_own_daemon()

  local messages = with_capture(function(msgs)
    local id = start(msgs, "sleep 60")

    local before = #msgs
    repeat_task.impl({}, true)
    wait_for(msgs, before + 1)

    local again =
      assert(find(msgs, "^started `sleep` as task %d+$", before + 1), "the bang did not start it")
    eq(tonumber(again.msg:match("as task (%d+)$")) ~= id, true)
  end)

  eq(find(messages, "still running") == nil, true)
  client.reset()
end

-- Nothing has been started from here, so the daemon's memory is what is left.
T["impl()"]["offers the finished tasks when there is no last task"] = function()
  needs_tasksd()
  local specs = use_own_daemon()

  local chosen_at
  local messages = with_capture(function(msgs)
    local id = start(msgs, "true")
    wait_for(msgs, 2)
    last.reset()

    repeat_task.impl({}, false)
    vim.wait(15000, function()
      return #specs >= 1
    end, 20)

    eq(#specs, 1)
    eq(specs[1].title, repeat_task.PICKER_TITLE)
    local chosen = specs[1].items[1].value
    eq(chosen.id, id)
    eq(chosen.state, "finished")

    -- Choosing one is not guarded: pointing at a task is asking for it.
    chosen_at = #msgs
    specs[1].on_choice(chosen)
    wait_for(msgs, chosen_at + 1)
  end)

  eq(find(messages, "^started `true` as task %d+$", chosen_at + 1) ~= nil, true)
  client.reset()
end

T["impl()"]["says so when the daemon has nothing to offer either"] = function()
  needs_tasksd()
  local specs = use_own_daemon()

  local messages = with_capture(function(msgs)
    repeat_task.impl({}, false)
    wait_for(msgs, 1)
  end)

  eq(#specs, 0)
  eq(messages[1].level, vim.log.levels.INFO)
  eq(messages[1].msg, repeat_task.EMPTY)
  client.reset()
end

T["impl()"]["reports an unusable socket setting without connecting"] = function()
  config.setup({ daemon = { socket = "nonsense" } })

  local messages = with_capture(function(msgs)
    repeat_task.impl({}, false)
    wait_for(msgs, 1)
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("daemon.socket must be one of") ~= nil, true)
end

return T
