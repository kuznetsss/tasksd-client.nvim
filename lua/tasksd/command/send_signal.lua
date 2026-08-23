local client = require("tasksd.client")
local log = require("tasksd.log")
local picker = require("tasksd.picker")
local task = require("tasksd.task")
local task_picker = require("tasksd.task_picker")

---`:Tasksd send_signal [task_id=<id>] [signal=<name|number>]` -- signal a task.
---
---With neither argument this asks two questions in pickers: which task, then
---which signal. The arguments are `key=value` so that ordering never matters
---and so either question can be answered in advance without answering both.
---@class tasksd.command.SendSignal : tasksd.Subcommand
local M = {}

M.desc = "Send a signal to a task: [task_id=<id>] [signal=<name or number>]"

M.DEFAULT_SIGNAL = "TERM"

local KEYS = { "signal=", "task_id=" }

---Signal names as *this* machine numbers them, which is also how the daemon
---numbers them: the two talk over a unix socket, so they always share a kernel.
---The numbers are not portable -- SIGUSR1 is 30 on macOS and 10 on Linux.
---@return table<string, integer>
local function signals()
  local found = {}
  for name, value in pairs(vim.uv.constants) do
    if type(value) == "number" and name:match("^SIG") then
      found[name] = value
    end
  end
  return found
end

---Signal names without their `SIG` prefix, sorted.
---@return string[]
M.signal_names = function()
  local names = {}
  for name in pairs(signals()) do
    table.insert(names, name:sub(4))
  end
  table.sort(names)
  return names
end

---@param spec string A signal number, or a name such as `TERM`/`sigterm`.
---@return integer|nil signal, string|nil err
M.signal_number = function(spec)
  if spec:match("^%d+$") then
    local number = assert(tonumber(spec))
    if number < 1 then
      return nil, ("`%s` is not a signal number"):format(spec)
    end
    return number
  end

  local name = spec:upper()
  if not vim.startswith(name, "SIG") then
    name = "SIG" .. name
  end
  local number = signals()[name]
  if not number then
    return nil,
      ("unknown signal `%s`, expected a number or one of: %s"):format(
        spec,
        table.concat(M.signal_names(), ", ")
      )
  end
  return number
end

---@param args string[]
---@return table<string, string>|nil values, string|nil err
M.parse = function(args)
  local values = {}
  for _, arg in ipairs(args) do
    local key, value = arg:match("^([%w_]+)=(.*)$")
    if not key then
      return nil, ("expected key=value, got `%s`"):format(arg)
    end
    if not vim.tbl_contains(KEYS, key .. "=") then
      return nil,
        ("unknown argument `%s`, expected one of: %s"):format(key, table.concat(KEYS, ", "))
    end
    values[key] = value
  end
  return values, nil
end

---The `task.send_signal` params; see `docs/API.md` in tasksd.
---@class tasksd.TaskSignalParams
---@field task_id integer
---@field signal integer

---@param args string[]
---@return tasksd.TaskSignalParams|nil params, string|nil err
M.params = function(args)
  local values, parse_err = M.parse(args)
  if not values then
    return nil, parse_err
  end
  return M.params_from(values)
end

---@param values table<string, string> As `M.parse` returns them.
---@return tasksd.TaskSignalParams|nil params, string|nil err
M.params_from = function(values)
  if not values.task_id then
    return nil, "task_id= is required"
  end
  if not values.task_id:match("^%d+$") then
    return nil, ("`%s` is not a task id"):format(values.task_id)
  end

  local signal, signal_err = M.signal_number(values.signal or M.DEFAULT_SIGNAL)
  if not signal then
    return nil, signal_err
  end

  return { task_id = assert(tonumber(values.task_id)), signal = signal }, nil
end

---@param params tasksd.TaskSignalParams
M.send = function(params)
  client.get(function(c, connect_err)
    if not c then
      log.error(connect_err or "could not connect to tasksd")
      return
    end

    local sent = c:request("task.send_signal", params, function(rpc_err)
      if rpc_err then
        log.error(
          ("could not signal task %d: %s"):format(params.task_id, client.describe_error(rpc_err))
        )
        return
      end
      log.info(("sent signal %d to task %d"):format(params.signal, params.task_id))
    end)
    if not sent then
      log.error("could not send task.send_signal: the connection closed")
    end
  end)
end

---The default first: it is the common signal, and the first row is what `<CR>`
---sends without any typing. The rest stay alphabetical.
---@return tasksd.picker.Row[]
M.signal_rows = function()
  local numbers = signals()

  local names = { M.DEFAULT_SIGNAL }
  for _, name in ipairs(M.signal_names()) do
    if name ~= M.DEFAULT_SIGNAL then
      table.insert(names, name)
    end
  end

  local rows = {}
  for _, name in ipairs(names) do
    table.insert(rows, {
      value = name,
      columns = {
        { text = name, hl = "Identifier" },
        { text = tostring(numbers["SIG" .. name]), hl = "Number", align = "right" },
      },
    })
  end
  return rows
end

---@param entry tasksd.TaskEntry
---@return string
M.signal_title = function(entry)
  return ("Choose a signal to send to task %d: %s"):format(entry.id, task.command_line(entry.info))
end

---@param entry tasksd.TaskEntry
M.choose_signal = function(entry)
  local ok, err = picker.pick({
    title = M.signal_title(entry),
    items = picker.align(M.signal_rows()),
    ---@param name string
    on_choice = function(name)
      local signal, signal_err = M.signal_number(name)
      if not signal then
        log.error(tostring(signal_err))
        return
      end
      M.send({ task_id = entry.id, signal = signal })
    end,
  })
  if not ok then
    log.error(tostring(err))
  end
end

M.TASK_TITLE = "Choose a task to send a signal to"

---Only running tasks are offered: the daemon rejects a signal to a finished one
---with `5`, unless it left children behind in its process group.
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
    local params, err = M.params_from(values)
    if not params then
      log.error(tostring(err))
      return
    end
    M.send(params)
    return
  end

  M.choose_task(function(entry)
    -- A `signal=` on the command line answers the second question in advance.
    if not values.signal then
      M.choose_signal(entry)
      return
    end
    local signal, signal_err = M.signal_number(values.signal)
    if not signal then
      log.error(tostring(signal_err))
      return
    end
    M.send({ task_id = entry.id, signal = signal })
  end)
end

---@param arg_lead string
---@return string[]
M.complete = function(arg_lead)
  local key, value = arg_lead:match("^([%w_]+)=(.*)$")
  if key == "signal" then
    local lead = value:upper()
    return vim.tbl_map(
      function(name)
        return "signal=" .. name
      end,
      vim.tbl_filter(function(name)
        return vim.startswith(name, lead)
      end, M.signal_names())
    )
  end
  -- Nothing to offer for `task_id=`: completion has to answer synchronously and
  -- the ids are on the far side of a request. Omitting the argument entirely is
  -- what opens the task picker.
  if key then
    return {}
  end
  return vim.tbl_filter(function(name)
    return vim.startswith(name, arg_lead)
  end, KEYS)
end

return M
