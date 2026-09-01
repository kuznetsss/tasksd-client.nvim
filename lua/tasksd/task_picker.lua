local client = require("tasksd.client")
local highlights = require("tasksd.highlights")
local log = require("tasksd.log")
local picker = require("tasksd.picker")
local task = require("tasksd.task")

---Choosing a task out of the daemon's listing: ask for `task.list`, filter it,
---lay it out, open a picker. The one place that turns tasks into rows, so every
---command that shows a task shows the same thing.
---
---Unlike the other non-edge modules this one notifies rather than reporting
---back. Its whole purpose is a user-facing side effect, so there is no version
---of it a caller could keep quiet.
local M = {}

---@alias tasksd.TaskFilter tasksd.TaskState|"all"

---Filter names, sorted so completion order is stable.
---@return string[]
M.filters = function()
  local names = vim.list_extend({ "all" }, task.STATES)
  table.sort(names)
  return names
end

---@type table<tasksd.TaskState, string>
local STATE_HL = { running = "TasksdTaskRunning", finished = "TasksdTaskFinished" }

---@param entries tasksd.TaskEntry[]
---@param filter tasksd.TaskFilter|nil Defaults to "all".
---@return tasksd.TaskEntry[]
M.filter = function(entries, filter)
  if filter == nil or filter == "all" then
    return entries
  end
  return vim.tbl_filter(function(entry)
    return entry.state == filter
  end, entries)
end

---@param entries tasksd.TaskEntry[]
---@return tasksd.picker.Row[]
M.rows = function(entries)
  highlights.ensure()
  local rows = {}
  for _, entry in ipairs(entries) do
    table.insert(rows, {
      value = entry,
      columns = {
        { text = tostring(entry.id), hl = "TasksdTaskId", align = "right" },
        { text = entry.state, hl = STATE_HL[entry.state] },
        { text = task.command_line(entry.info), hl = "TasksdTaskCommand" },
        { text = vim.fn.fnamemodify(entry.info.working_dir, ":~"), hl = "TasksdTaskDir" },
      },
    })
  end
  return rows
end

---@class tasksd.task_picker.Opts
---@field title string
---@field filter? tasksd.TaskFilter Which tasks to show. Defaults to "all".
---@field empty string What to say when nothing matches the filter.
---@field on_choice? fun(entry: tasksd.TaskEntry)

---An empty listing is said rather than shown: a picker with nothing in it
---leaves the user to work out which of "no tasks" and "no answer" they are
---looking at.
---@param opts tasksd.task_picker.Opts
---@param entries tasksd.TaskEntry[]
M.show = function(opts, entries)
  local matching = M.filter(entries, opts.filter)
  if vim.tbl_isempty(matching) then
    log.info(opts.empty)
    return
  end

  local ok, err = picker.pick({
    title = opts.title,
    items = picker.align(M.rows(matching)),
    on_choice = opts.on_choice,
  })
  if not ok then
    log.error(tostring(err))
  end
end

---Ask the daemon what it has, then show it.
---@param opts tasksd.task_picker.Opts
M.open = function(opts)
  client.get(function(c, connect_err)
    if not c then
      log.error(connect_err or "could not connect to tasksd")
      return
    end

    local sent = c:request("task.list", nil, function(rpc_err, result)
      if rpc_err then
        log.error(("could not list tasks: %s"):format(client.describe_error(rpc_err)))
        return
      end
      M.show(opts, task.entries(result))
    end)
    if not sent then
      log.error("could not send task.list: the connection closed")
    end
  end)
end

return M
