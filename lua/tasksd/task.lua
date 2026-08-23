---How a task's end is put into words, and the subscription that reports it.
---
---Nothing about a task is kept here between notifications: the daemon owns that
---state and `task.list` is where to ask for it, so a table on this side could
---only drift out of agreement with it. A `task.exit` carries an id, and an id
---is what the user is told about.
---
---Reports through a callback rather than notifying: the messages belong to the
---command layer, and a pure function is testable without capturing UI side
---effects.
local M = {}

---As it comes off the wire: JSON `null` decodes to `vim.NIL`, not to nil.
---@class tasksd.TaskExit
---@field task_id integer
---@field exit_code integer|vim.NIL|nil
---@field signal integer|vim.NIL|nil

---JSON `null` decodes to `vim.NIL`, which is *truthy*: an absent `signal` would
---otherwise read as one.
---@param value any
---@return any
local function present(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return value
end

---@param params tasksd.TaskExit
---@return string msg, integer level One of `vim.log.levels`.
M.exit_message = function(params)
  local label = ("task %d"):format(params.task_id)
  local signal, code = present(params.signal), present(params.exit_code)

  if signal then
    return ("%s was killed by signal %s"):format(label, tostring(signal)), vim.log.levels.WARN
  end
  if code == 0 then
    return ("%s finished"):format(label), vim.log.levels.INFO
  end
  if code then
    return ("%s exited with code %s"):format(label, tostring(code)), vim.log.levels.WARN
  end
  return ("%s exited"):format(label), vim.log.levels.WARN
end

---Report every task this client started as it exits. Replaces any previous
---report function on this client.
---@param client tasksd.Client
---@param report fun(msg: string, level: integer)
M.watch = function(client, report)
  client:on("task.exit", function(params)
    report(M.exit_message(params))
  end)
end

---How the daemon resolved a task when it started it, which is not the same as
---the `task.start` params it was given.
---@class tasksd.TaskInfo
---@field executable string
---@field args string[]
---@field working_dir string

---@alias tasksd.TaskState "running"|"finished"

---One entry of a `task.list` result, with the array it came out of folded in.
---@class tasksd.TaskEntry
---@field id integer
---@field state tasksd.TaskState
---@field info tasksd.TaskInfo

---The states a `task.list` result is split by, in the order they are shown.
---@type tasksd.TaskState[]
M.STATES = { "running", "finished" }

---Flatten a `task.list` result into a single list: running tasks first, and
---within each state the highest id first.
---
---The daemon leaves the order of `running` unspecified and hands back
---`finished` oldest first, so neither array can be shown as it arrives. Ids
---come from a counter, so descending id is "most recently started first".
---@param result any The `task.list` result, straight off the wire.
---@return tasksd.TaskEntry[]
M.entries = function(result)
  local tasks = type(result) == "table" and result.tasks
  if type(tasks) ~= "table" then
    return {}
  end

  local entries = {}
  for _, state in ipairs(M.STATES) do
    local group = {}
    for _, entry in ipairs(tasks[state] or {}) do
      table.insert(group, { id = entry.id, state = state, info = entry.info })
    end
    table.sort(group, function(a, b)
      return a.id > b.id
    end)
    vim.list_extend(entries, group)
  end
  return entries
end

---The command as `task.start` was asked for it. No shell was involved, so this
---is a display of the argv rather than something that could be run again.
---@param info tasksd.TaskInfo
---@return string
M.command_line = function(info)
  return table.concat(vim.list_extend({ info.executable }, info.args or {}), " ")
end

return M
