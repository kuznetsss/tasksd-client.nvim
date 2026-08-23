local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local task = require("tasksd.task")

---A client that only records what was registered on it.
---@return tasksd.Client, table<string, fun(params: table)>
local function fake_client()
  local handlers = {}
  local client = {
    on = function(_, method, handler)
      handlers[method] = handler
    end,
  }
  ---@cast client tasksd.Client
  return client, handlers
end

local T = new_set()

T["exit_message()"] = new_set()

T["exit_message()"]["a zero exit code is success"] = function()
  local msg, level = task.exit_message({ task_id = 1, exit_code = 0, signal = nil })
  eq(msg, "task 1 finished")
  eq(level, vim.log.levels.INFO)
end

T["exit_message()"]["a non-zero exit code is a warning"] = function()
  local msg, level = task.exit_message({ task_id = 1, exit_code = 2, signal = nil })
  eq(msg, "task 1 exited with code 2")
  eq(level, vim.log.levels.WARN)
end

T["exit_message()"]["a signal is named instead of a code"] = function()
  local msg, level = task.exit_message({ task_id = 1, exit_code = nil, signal = 9 })
  eq(msg, "task 1 was killed by signal 9")
  eq(level, vim.log.levels.WARN)
end

-- vim.lsp.rpc decodes JSON null to vim.NIL, which is truthy: the fields arrive
-- this way, not as nil, whenever the daemon sends them as null.
T["exit_message()"]["treats vim.NIL as an absent field"] = function()
  local msg = task.exit_message({ task_id = 1, exit_code = 0, signal = vim.NIL })
  eq(msg, "task 1 finished")

  msg = task.exit_message({ task_id = 1, exit_code = vim.NIL, signal = 15 })
  eq(msg, "task 1 was killed by signal 15")
end

T["exit_message()"]["reports an exit it cannot explain"] = function()
  local msg, level = task.exit_message({ task_id = 4, exit_code = vim.NIL, signal = vim.NIL })
  eq(msg, "task 4 exited")
  eq(level, vim.log.levels.WARN)
end

T["watch()"] = new_set()

T["watch()"]["reports a task as it exits"] = function()
  local client, handlers = fake_client()
  local reported = {}

  task.watch(client, function(msg, level)
    table.insert(reported, { msg = msg, level = level })
  end)
  handlers["task.exit"]({ task_id = 3, exit_code = 0, signal = vim.NIL })

  eq(reported, { { msg = "task 3 finished", level = vim.log.levels.INFO } })
end

T["entries()"] = new_set()

---@param id integer
---@return table
local function listed(id)
  return { id = id, info = { executable = "sleep", args = { "60" }, working_dir = "/tmp" } }
end

---@param entries tasksd.TaskEntry[]
---@return string[]
local function ids_and_states(entries)
  return vim.tbl_map(function(entry)
    return ("%d:%s"):format(entry.id, entry.state)
  end, entries)
end

T["entries()"]["puts running tasks before finished ones"] = function()
  local entries = task.entries({
    tasks = { running = { listed(2) }, finished = { listed(7) } },
  })
  eq(ids_and_states(entries), { "2:running", "7:finished" })
end

T["entries()"]["orders each state by descending id"] = function()
  local entries = task.entries({
    tasks = { running = { listed(1), listed(5), listed(3) }, finished = { listed(2), listed(4) } },
  })
  eq(ids_and_states(entries), { "5:running", "3:running", "1:running", "4:finished", "2:finished" })
end

T["entries()"]["keeps the info the daemon reported"] = function()
  local entries = task.entries({ tasks = { running = { listed(1) }, finished = {} } })
  eq(entries[1].info, { executable = "sleep", args = { "60" }, working_dir = "/tmp" })
end

T["entries()"]["is empty for a daemon with no tasks"] = function()
  eq(task.entries({ tasks = { running = {}, finished = {} } }), {})
end

T["entries()"]["is empty for a result it cannot read"] = function()
  eq(task.entries(nil), {})
  eq(task.entries({}), {})
end

T["command_line()"] = new_set()

T["command_line()"]["joins the executable and its arguments"] = function()
  eq(task.command_line({ executable = "sleep", args = { "60" }, working_dir = "/tmp" }), "sleep 60")
end

T["command_line()"]["is the executable alone when there are no arguments"] = function()
  eq(task.command_line({ executable = "ls", args = {}, working_dir = "/tmp" }), "ls")
end

return T
