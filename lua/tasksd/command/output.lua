local arguments = require("tasksd.args")
local log = require("tasksd.log")
local output = require("tasksd.output")
local window = require("tasksd.output.window")

---`:Tasksd[!] output [task_id=<id>] [position=<where>]` -- show or hide a
---task's output.
---
---With no arguments this toggles: it hides an open window, and reopens the task
---the window last showed, asking which task when there has not been one yet. A
---`position=` says where the window goes rather than whether it is open, so it
---moves an open window instead of closing it.
---
---The bang is the forceful variant of the same action rather than another
---answer to a question, which is why it is a bang and not a `reset=`: it
---discards where the window was dragged to and puts it back where the config
---says.
---@class tasksd.command.Output : tasksd.Subcommand
local M = {}

M.desc = "Show or hide a task's output: [task_id=<id>] [position=<where>]"

local KEYS = { "position=", "task_id=" }

---@param args string[]
---@return table<string, string>|nil values, string|nil err
M.parse = function(args)
  return arguments.parse(args, KEYS)
end

---What the command line asked for: a task to show, or nothing and a toggle.
---@class tasksd.command.output.Request
---@field task_id integer|nil
---@field opts tasksd.output.Opts

---@param args string[]
---@param bang boolean
---@return tasksd.command.output.Request|nil request, string|nil err
M.request = function(args, bang)
  local values, err = M.parse(args)
  if not values then
    return nil, err
  end

  ---@type tasksd.output.Opts
  local opts = { reset = bang or nil }

  if values.position then
    if not vim.tbl_contains(window.POSITIONS, values.position) then
      return nil,
        ("unknown position `%s`, expected one of: %s"):format(
          values.position,
          table.concat(window.POSITIONS, ", ")
        )
    end
    ---@cast values -nil
    opts.position = values.position
  end

  if values.task_id and not values.task_id:match("^%d+$") then
    return nil, ("`%s` is not a task id"):format(values.task_id)
  end

  return { task_id = values.task_id and tonumber(values.task_id) or nil, opts = opts }, nil
end

M.impl = function(args, bang)
  local request, err = M.request(args, bang)
  if not request then
    log.error(tostring(err))
    return
  end

  if request.task_id then
    output.show(request.task_id, request.opts)
    return
  end
  output.toggle(request.opts)
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
