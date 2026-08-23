local client = require("tasksd.client")
local log = require("tasksd.log")
local task = require("tasksd.task")
local task_picker = require("tasksd.task_picker")

---`:Tasksd send_input [task_id=<id>] [input=<text>]` -- write to a task's stdin.
---
---Whichever argument is missing becomes a question: a picker of running tasks,
---then `vim.ui.input` for the text.
---@class tasksd.command.SendInput : tasksd.Subcommand
local M = {}

M.desc = "Send input to a task's stdin: [task_id=<id>] [input=<text>]"

local KEYS = { "input=", "task_id=" }

---@param args string[]
---@return table<string, string>|nil values, string|nil err
M.parse = function(args)
  local values = {}
  for i, arg in ipairs(args) do
    local key, value = arg:match("^([%w_]+)=(.*)$")
    if not key then
      return nil, ("expected key=value, got `%s`"):format(arg)
    end
    if not vim.tbl_contains(KEYS, key .. "=") then
      return nil,
        ("unknown argument `%s`, expected one of: %s"):format(key, table.concat(KEYS, ", "))
    end
    -- The command line arrives already split on whitespace, so `input=` takes
    -- everything after it or it could never carry a space. Runs of whitespace
    -- collapse to one; anything more exact belongs in the `vim.ui.input` prompt.
    if key == "input" then
      values.input = table.concat(vim.list_extend({ value }, vim.list_slice(args, i + 1)), " ")
      break
    end
    values[key] = value
  end
  return values, nil
end

---@param spec string
---@return integer|nil task_id, string|nil err
M.task_id = function(spec)
  if not spec:match("^%d+$") then
    return nil, ("`%s` is not a task id"):format(spec)
  end
  return assert(tonumber(spec)), nil
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

---@param args string[]
---@return tasksd.TaskInputParams|nil params, string|nil err
M.params = function(args)
  local values, parse_err = M.parse(args)
  if not values then
    return nil, parse_err
  end
  return M.params_from(values)
end

---@param values table<string, string> As `M.parse` returns them.
---@return tasksd.TaskInputParams|nil params, string|nil err
M.params_from = function(values)
  if not values.task_id then
    return nil, "task_id= is required"
  end
  local task_id, id_err = M.task_id(values.task_id)
  if not task_id then
    return nil, id_err
  end
  if not values.input then
    return nil, "input= is required"
  end
  return { task_id = task_id, input = M.line(values.input) }, nil
end

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

M.impl = function(args)
  local values, parse_err = M.parse(args)
  if not values then
    log.error(tostring(parse_err))
    return
  end

  if values.task_id then
    local task_id, id_err = M.task_id(values.task_id)
    if not task_id then
      log.error(tostring(id_err))
      return
    end
    if values.input then
      M.send({ task_id = task_id, input = M.line(values.input) })
    else
      M.ask(task_id)
    end
    return
  end

  M.choose_task(function(entry)
    if values.input then
      M.send({ task_id = entry.id, input = M.line(values.input) })
      return
    end
    M.ask(entry.id, task.command_line(entry.info))
  end)
end

---@param arg_lead string
---@return string[]
M.complete = function(arg_lead)
  -- Neither value has candidates: the ids are on the far side of a request and
  -- completion has to answer synchronously, and the input is free text.
  if arg_lead:match("^([%w_]+)=") then
    return {}
  end
  return vim.tbl_filter(function(name)
    return vim.startswith(name, arg_lead)
  end, KEYS)
end

return M
