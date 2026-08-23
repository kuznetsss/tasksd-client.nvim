local client = require("tasksd.client")
local log = require("tasksd.log")
local picker = require("tasksd.picker")
local task = require("tasksd.task")

---`:Tasksd list_tasks` -- show the daemon's tasks in a picker.
---
---The listing is daemon-wide, so it includes tasks this Neovim never started.
---@class tasksd.command.ListTasks : tasksd.Subcommand
local M = {}

M.desc = "List the daemon's tasks"

M.TITLE = "tasksd tasks"

---@type table<tasksd.TaskState, string>
local STATE_HL = { running = "DiagnosticOk", finished = "Comment" }

---@param entries tasksd.TaskEntry[]
---@return tasksd.picker.Row[]
M.rows = function(entries)
  local rows = {}
  for _, entry in ipairs(entries) do
    table.insert(rows, {
      value = entry,
      columns = {
        { text = tostring(entry.id), hl = "Number", align = "right" },
        { text = entry.state, hl = STATE_HL[entry.state] },
        { text = task.command_line(entry.info) },
        { text = vim.fn.fnamemodify(entry.info.working_dir, ":~"), hl = "Directory" },
      },
    })
  end
  return rows
end

---An empty daemon is said rather than shown: a picker with nothing in it makes
---the user work out which of "no tasks" and "no answer" they are looking at.
---@param entries tasksd.TaskEntry[]
M.show = function(entries)
  if vim.tbl_isempty(entries) then
    log.info("the daemon has no tasks")
    return
  end

  local ok, err = picker.pick({
    title = M.TITLE,
    items = picker.align(M.rows(entries)),
  })
  if not ok then
    log.error(tostring(err))
  end
end

M.list = function()
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
      M.show(task.entries(result))
    end)
    if not sent then
      log.error("could not send task.list: the connection closed")
    end
  end)
end

M.impl = function(_args)
  M.list()
end

return M
