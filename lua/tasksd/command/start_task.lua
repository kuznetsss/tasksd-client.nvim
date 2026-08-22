local config = require("tasksd.config")
local form = require("tasksd.form")
local log = require("tasksd.log")

---`:Tasksd start_task` -- collect a command in a floating form, then start it.
---@class tasksd.command.StartTask : tasksd.Subcommand
local M = {}

M.desc = "Start a task on the daemon"

---Split what the user typed into the `executable` and `args` of `task.start`.
---No shell is involved, so quoting and globbing are not honoured.
---@param command string
---@return string|nil executable, string[] args
M.split = function(command)
  local words = vim.split(command, "%s+", { trimempty = true })
  return words[1], vim.list_slice(words, 2)
end

---@param values table<string, string>
M.start = function(values)
  local executable, args = M.split(values.command)
  if not executable then
    log.error("no command given")
    return
  end
  log.info(("would start %s %s in %s"):format(executable, vim.inspect(args), values.working_dir))
end

---@return tasksd.Form
M.open = function()
  return form.open({
    title = "Start task",
    keys = config.current.form.keys,
    fields = {
      { name = "working_dir", label = "Working directory: ", value = vim.fn.getcwd() },
      { name = "command", label = "Command: " },
    },
    on_submit = M.start,
  })
end

M.impl = function(_args)
  M.open()
end

return M
