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

return M
