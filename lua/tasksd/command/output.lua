local arguments = require("tasksd.args")
local log = require("tasksd.log")
local output = require("tasksd.output")
local window = require("tasksd.output.window")

---`:Tasksd[!] output [task_id=<id>] [position=<where>]`, or
---`require("tasksd").output(opts)` -- show or hide a task's output.
---
---With no arguments this toggles: it hides an open window, and reopens the task
---the window last showed, asking which task when there has not been one yet. A
---`position=` says where the window goes rather than whether it is open, so it
---moves an open window instead of closing it.
---
---`force` is the forceful variant of the same action rather than another answer
---to a question, which is why the command line spells it `!` and not `force=`:
---it discards where the window was dragged to and puts it back where the config
---says.
---@class tasksd.command.Output : tasksd.Subcommand
local M = {}

M.desc = "Show or hide a task's output: [task_id=<id>] [position=<where>]"

local KEYS = { "position=", "task_id=" }

---@class tasksd.command.output.Opts
---@field task_id? integer The task to show; without one, the window toggles.
---@field position? tasksd.output.Position
---@field force? boolean

---@param args string[]
---@param force boolean
---@return tasksd.command.output.Opts|nil opts, string|nil err
M.from_argv = function(args, force)
  local values, err = arguments.parse(args, KEYS)
  if not values then
    return nil, err
  end

  local task_id
  if values.task_id then
    if not values.task_id:match("^%d+$") then
      return nil, ("`%s` is not a task id"):format(values.task_id)
    end
    task_id = tonumber(values.task_id)
  end

  ---@type tasksd.command.output.Opts
  local opts = { task_id = task_id, position = values.position, force = force or nil }
  return opts, nil
end

---@param opts tasksd.command.output.Opts
---@return tasksd.output.Opts|nil show_opts, string|nil err
M.validate = function(opts)
  if opts.position and not vim.tbl_contains(window.POSITIONS, opts.position) then
    return nil,
      ("unknown position `%s`, expected one of: %s"):format(
        opts.position,
        table.concat(window.POSITIONS, ", ")
      )
  end
  if opts.task_id ~= nil and (type(opts.task_id) ~= "number" or opts.task_id < 0) then
    return nil, ("`%s` is not a task id"):format(tostring(opts.task_id))
  end

  return { position = opts.position, reset = opts.force }, nil
end

---@param opts tasksd.command.output.Opts|nil
M.run = function(opts)
  vim.validate("opts", opts, "table", true)
  opts = opts or {}

  local show_opts, err = M.validate(opts)
  if not show_opts then
    log.error(tostring(err))
    return
  end

  if opts.task_id then
    output.show(opts.task_id, show_opts)
    return
  end
  output.toggle(show_opts)
end

M.impl = function(args, bang)
  local opts, err = M.from_argv(args, bang)
  if not opts then
    log.error(tostring(err))
    return
  end
  M.run(opts)
end

---@param arg_lead string
---@return string[]
M.complete = function(arg_lead)
  -- Nothing is offered for `task_id=`: completion has to answer synchronously
  -- and the ids are on the far side of a request. Omitting the argument
  -- entirely is what opens the task picker.
  return arguments.complete(arg_lead, KEYS, {
    position = function(lead)
      return arguments.starting_with(lead, window.POSITIONS)
    end,
  })
end

return M
