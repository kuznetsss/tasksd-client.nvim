local M = {}

---A single `:Tasksd` subcommand.
---@class tasksd.Subcommand
---@field impl fun(args: string[]) Runs the subcommand. `args` excludes the subcommand name.
---@field desc string One-line description, shown when the user gets it wrong.
---@field complete? fun(arg_lead: string): string[] Optional completion for this subcommand's own arguments.

---@type table<string, tasksd.Subcommand>
M.subcommands = {
  start = {
    desc = "Start the tasksd daemon",
    impl = function(_args)
      vim.notify("tasksd: `start` is not implemented yet", vim.log.levels.INFO)
    end,
  },
  shutdown = {
    desc = "Shut down the tasksd daemon",
    impl = function(_args)
      vim.notify("tasksd: `shutdown` is not implemented yet", vim.log.levels.INFO)
    end,
  },
  start_task = {
    desc = "Start a task on the daemon",
    impl = function(_args)
      vim.notify("tasksd: `start_task` is not implemented yet", vim.log.levels.INFO)
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
    vim.notify(
      "Tasksd: expected a subcommand, one of: " .. table.concat(M.names(), ", "),
      vim.log.levels.ERROR
    )
    return
  end

  local subcommand = M.subcommands[name]
  if not subcommand then
    vim.notify(
      ("Tasksd: unknown subcommand `%s`, expected one of: %s"):format(
        name,
        table.concat(M.names(), ", ")
      ),
      vim.log.levels.ERROR
    )
    return
  end

  -- Hand over every argument after the subcommand name.
  subcommand.impl(vim.list_slice(fargs, 2))
end

---Completion for `:Tasksd`.
---@param arg_lead string The partial word currently being completed.
---@param cmd_line string The whole command line as typed so far.
---@return string[]
M.complete = function(arg_lead, cmd_line, _cursor_pos)
  -- A subcommand is "settled" once it is followed by whitespace: at that point
  -- we are completing its arguments, not the subcommand name itself.
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
