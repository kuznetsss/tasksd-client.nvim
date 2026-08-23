local client = require("tasksd.client")
local log = require("tasksd.log")

---`:Tasksd send_signal task_id=<id> [signal=<name|number>]` -- signal a task.
---
---The id is typed out until there is a picker to choose one from; the arguments
---are `key=value` so that ordering never matters and so a picker can later fill
---in `task_id=` while the user still writes `signal=`.
---@class tasksd.command.SendSignal : tasksd.Subcommand
local M = {}

M.desc = "Send a signal to a task: task_id=<id> [signal=<name or number>]"

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

M.impl = function(args)
  local params, err = M.params(args)
  if not params then
    log.error(tostring(err))
    return
  end
  M.send(params)
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
  -- Nothing to offer for `task_id=` until there is a picker; ids come from the
  -- daemon, not from anything this side knows.
  if key then
    return {}
  end
  return vim.tbl_filter(function(name)
    return vim.startswith(name, arg_lead)
  end, KEYS)
end

return M
