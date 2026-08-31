local log = require("tasksd.log")
local output = require("tasksd.output")
local task_picker = require("tasksd.task_picker")

---`:Tasksd list_tasks [all|running|finished]` -- show the daemon's tasks in a
---picker, and show the output of whichever is chosen.
---
---The listing is daemon-wide, so it includes tasks this Neovim never started.
---The filter is applied here rather than by the daemon: `task.list` takes no
---params, and the whole listing is bounded anyway.
---@class tasksd.command.ListTasks : tasksd.Subcommand
local M = {}

M.desc = "List the daemon's tasks: [all|running|finished]"

M.DEFAULT_FILTER = "all"

---@param filter tasksd.TaskFilter
---@return string
M.title = function(filter)
  if filter == "all" then
    return "tasksd tasks"
  end
  return ("tasksd tasks (%s)"):format(filter)
end

---@param filter tasksd.TaskFilter
---@return string
M.empty_message = function(filter)
  if filter == "all" then
    return "the daemon has no tasks"
  end
  return ("the daemon has no %s tasks"):format(filter)
end

---@param args string[]
---@return tasksd.TaskFilter|nil filter, string|nil err
M.parse = function(args)
  if #args > 1 then
    return nil, ("expected at most one filter, got %d arguments"):format(#args)
  end

  local filter = args[1] or M.DEFAULT_FILTER
  if not vim.tbl_contains(task_picker.filters(), filter) then
    return nil,
      ("unknown filter `%s`, expected one of: %s"):format(
        filter,
        table.concat(task_picker.filters(), ", ")
      )
  end
  ---@cast filter tasksd.TaskFilter
  return filter, nil
end

M.impl = function(args)
  local filter, err = M.parse(args)
  if not filter then
    log.error(tostring(err))
    return
  end

  task_picker.open({
    title = M.title(filter),
    filter = filter,
    empty = M.empty_message(filter),
    on_choice = function(entry)
      output.show(entry.id)
    end,
  })
end

---@param arg_lead string
---@return string[]
M.complete = function(arg_lead)
  return vim.tbl_filter(function(name)
    return vim.startswith(name, arg_lead)
  end, task_picker.filters())
end

return M
