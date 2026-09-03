local arguments = require("tasksd.args")
local client = require("tasksd.client")
local log = require("tasksd.log")
local task = require("tasksd.task")
local task_picker = require("tasksd.task_picker")

---`:Tasksd send_input [task_id=<id>] [input=<text>]`, or
---`require("tasksd").send_input(opts)` -- write to a task's stdin.
---
---Whichever argument is missing becomes a question: a picker of running tasks,
---then `vim.ui.input` for the text.
---@class tasksd.command.SendInput : tasksd.Subcommand
local M = {}

M.desc = "Send input to a task's stdin: [task_id=<id>] [input=<text>]"

local KEYS = { "input=", "task_id=" }

---@class tasksd.command.send_input.Opts
---@field task_id? integer The task to write to; without one, a picker asks.
---@field input? string The text to write; without it, `vim.ui.input` asks.

---@param args string[]
---@return tasksd.command.send_input.Opts|nil opts, string|nil err
M.from_argv = function(args)
  local values, err = arguments.parse(args, KEYS, "input")
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

  ---@type tasksd.command.send_input.Opts
  local opts = { task_id = task_id, input = values.input }
  return opts, nil
end

---@param opts tasksd.command.send_input.Opts
---@return string|nil err
M.validate = function(opts)
  if opts.task_id ~= nil and (type(opts.task_id) ~= "number" or opts.task_id < 0) then
    return ("`%s` is not a task id"):format(tostring(opts.task_id))
  end
  if opts.input ~= nil and type(opts.input) ~= "string" then
    return ("expected input to be a string, got %s"):format(type(opts.input))
  end
  return nil
end

---The daemon writes the bytes verbatim, and a task reading a line stays blocked
---until one ends. Text that already ends in a newline is left alone, so a
---deliberate `input=` of nothing sends a bare newline rather than nothing.
---@param text string
---@return string
M.line = function(text)
  if vim.endswith(text, "\n") then
    return text
  end
  return text .. "\n"
end

---The `task.send_input` params; see `docs/API.md` in tasksd.
---@class tasksd.TaskInputParams
---@field task_id integer
---@field input string

---@param params tasksd.TaskInputParams
M.send = function(params)
  client.get(function(c, connect_err)
    if not c then
      log.error(connect_err or "could not connect to tasksd")
      return
    end

    local sent = c:request("task.send_input", params, function(rpc_err)
      if rpc_err then
        log.error(
          ("could not send input to task %d: %s"):format(
            params.task_id,
            client.describe_error(rpc_err)
          )
        )
        return
      end
      log.info(("sent input to task %d"):format(params.task_id))
    end)
    if not sent then
      log.error("could not send task.send_input: the connection closed")
    end
  end)
end

---@param task_id integer
---@param description string|nil The task's command line, when the caller knows it.
---@return string
M.prompt = function(task_id, description)
  if description then
    return ("Input for task %d (%s): "):format(task_id, description)
  end
  return ("Input for task %d: "):format(task_id)
end

---@param task_id integer
---@param description string|nil
M.ask = function(task_id, description)
  vim.ui.input({ prompt = M.prompt(task_id, description) }, function(input)
    -- nil is a cancelled prompt; "" is an answered one, and sends a newline.
    if not input then
      return
    end
    M.send({ task_id = task_id, input = M.line(input) })
  end)
end

M.TASK_TITLE = "Choose a task to send input to"

---Only running tasks are offered: the daemon rejects input to a finished one
---with `5`.
---@param on_choice fun(entry: tasksd.TaskEntry)
M.choose_task = function(on_choice)
  task_picker.open({
    title = M.TASK_TITLE,
    filter = "running",
    empty = "the daemon has no running tasks",
    on_choice = on_choice,
  })
end

---@param opts tasksd.command.send_input.Opts|nil
M.run = function(opts)
  vim.validate("opts", opts, "table", true)
  opts = opts or {}

  local err = M.validate(opts)
  if err then
    log.error(err)
    return
  end

  if opts.task_id then
    if opts.input then
      M.send({ task_id = opts.task_id, input = M.line(opts.input) })
    else
      M.ask(opts.task_id)
    end
    return
  end

  M.choose_task(function(entry)
    if opts.input then
      M.send({ task_id = entry.id, input = M.line(opts.input) })
      return
    end
    M.ask(entry.id, task.command_line(entry.info))
  end)
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
  -- Neither value has candidates: the ids are on the far side of a request and
  -- completion has to answer synchronously, and the input is free text.
  return arguments.complete(arg_lead, KEYS, {})
end

return M
