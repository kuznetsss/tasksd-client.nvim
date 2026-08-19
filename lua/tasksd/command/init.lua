local log = require("tasksd.log")

---The `:Tasksd` subcommand registry, dispatch, and completion. Each subcommand
---lives in its own module beside this one and returns a `tasksd.Subcommand`;
---nothing here knows what any of them do.
local M = {}

---A single `:Tasksd` subcommand.
---@class tasksd.Subcommand
---@field impl fun(args: string[]) Runs the subcommand. `args` excludes the subcommand name.
---@field desc string One-line description, shown when the user gets it wrong.
---@field complete? fun(arg_lead: string): string[] Optional completion for this subcommand's own arguments.

---@type table<string, tasksd.Subcommand>
M.subcommands = {
  install = require("tasksd.command.install"),
  shutdown = require("tasksd.command.shutdown"),
  start_task = {
    desc = "Start a task on the daemon",
    impl = function(_args)
      log.info("`start_task` is not implemented yet")
    end,
  },
}

---Subcommand names, sorted so completion order is stable.
---@return string[]
M.names = function()
  local names = vim.tbl_keys(M.subcommands)
  table.sort(names)
  return names
end

---Entry point for `:Tasksd`.
---@param opts table Command arguments, as passed by nvim_create_user_command.
M.run = function(opts)
  local fargs = opts.fargs
  local name = fargs[1]

  if not name then
    log.error("expected a subcommand, one of: " .. table.concat(M.names(), ", "))
    return
  end

  local subcommand = M.subcommands[name]
  if not subcommand then
    log.error(
      ("unknown subcommand `%s`, expected one of: %s"):format(name, table.concat(M.names(), ", "))
    )
    return
  end

  subcommand.impl(vim.list_slice(fargs, 2))
end

---Completion for `:Tasksd`.
---@param arg_lead string The partial word currently being completed.
---@param cmd_line string The whole command line as typed so far.
---@return string[]
M.complete = function(arg_lead, cmd_line, _cursor_pos)
  -- Trailing whitespace means the subcommand name is finished, so what is being
  -- completed now is its arguments.
  local settled = cmd_line:match("^%s*Tasksd%s+(%S+)%s")

  if settled then
    local subcommand = M.subcommands[settled]
    if subcommand and subcommand.complete then
      return subcommand.complete(arg_lead)
    end
    return {}
  end

  return vim.tbl_filter(function(name)
    return vim.startswith(name, arg_lead)
  end, M.names())
end

return M
