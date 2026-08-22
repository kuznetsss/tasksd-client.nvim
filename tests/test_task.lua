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

return T
