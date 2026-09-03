local arguments = require("tasksd.args")
local log = require("tasksd.log")
local output = require("tasksd.output")
local task_picker = require("tasksd.task_picker")

---`:Tasksd list_tasks [filter=<all|running|finished>]`, or
---`require("tasksd").list_tasks(opts)` -- show the daemon's tasks in a picker,
---and show the output of whichever is chosen.
---
---The listing is daemon-wide, so it includes tasks this Neovim never started.
---The filter is applied here rather than by the daemon: `task.list` takes no
---params, and the whole listing is bounded anyway.
---@class tasksd.command.ListTasks : tasksd.Subcommand
local M = {}

M.desc = "List the daemon's tasks: [filter=<all|running|finished>]"

M.DEFAULT_FILTER = "all"

local KEYS = { "filter=" }

---@class tasksd.command.list_tasks.Opts
---@field filter? tasksd.TaskFilter Defaults to "all".

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
---@return tasksd.command.list_tasks.Opts|nil opts, string|nil err
M.from_argv = function(args)
  local values, err = arguments.parse(args, KEYS)
  if not values then
    return nil, err
  end
  ---@type tasksd.command.list_tasks.Opts
  local opts = { filter = values.filter }
  return opts, nil
end

---@param opts tasksd.command.list_tasks.Opts
---@return tasksd.TaskFilter|nil filter, string|nil err
M.validate = function(opts)
  local filter = opts.filter or M.DEFAULT_FILTER
  if not vim.tbl_contains(task_picker.filters(), filter) then
    return nil,
      ("unknown filter `%s`, expected one of: %s"):format(
        tostring(filter),
        table.concat(task_picker.filters(), ", ")
      )
  end
  return filter, nil
end

---@param opts tasksd.command.list_tasks.Opts|nil
M.run = function(opts)
  vim.validate("opts", opts, "table", true)

  local filter, err = M.validate(opts or {})
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

M.impl = function(args)
  local opts, err = M.from_argv(args)
  if not opts then
    log.error(tostring(err))
    return
  end
  M.run(opts)
end

---@param arg_lead string
---@return string[]
M.complete = function(arg_lead)
  return arguments.complete(arg_lead, KEYS, {
    filter = function(lead)
      return arguments.starting_with(lead, task_picker.filters())
    end,
  })
end

return M
