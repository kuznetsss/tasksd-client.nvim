local arguments = require("tasksd.args")
local client = require("tasksd.client")
local last = require("tasksd.last")
local log = require("tasksd.log")
local picker = require("tasksd.picker")
local task = require("tasksd.task")
local task_picker = require("tasksd.task_picker")

---`:Tasksd send_signal [task_id=<id|last>] [signal=<name|number>]`, or
---`require("tasksd").send_signal(opts)` -- signal a task.
---
---With neither argument this asks two questions in pickers: which task, then
---which signal. Either can be answered in advance without answering both, and
---ordering never matters.
---@class tasksd.command.SendSignal : tasksd.Subcommand
local M = {}

M.desc = "Send a signal to a task: [task_id=<id or last>] [signal=<name or number>]"

M.DEFAULT_SIGNAL = "TERM"

---The task this Neovim started most recently on the daemon being talked to.
local LAST = "last"

local KEYS = { "signal=", "task_id=" }

---@class tasksd.command.send_signal.Opts
---@field task_id? integer|"last" The task to signal; without one, a picker asks.
---@field signal? string|integer A number, or a name such as `TERM`/`sigterm`.

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

---@param spec string|integer A signal number, or a name such as `TERM`/`sigterm`.
---@return integer|nil signal, string|nil err
M.signal_number = function(spec)
  if type(spec) == "number" then
    if spec < 1 or spec % 1 ~= 0 then
      return nil, ("`%s` is not a signal number"):format(tostring(spec))
    end
    return spec
  end
  if type(spec) ~= "string" then
    return nil, ("expected a signal name or number, got %s"):format(type(spec))
  end

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

---The `task.send_signal` params; see `docs/API.md` in tasksd.
---@class tasksd.TaskSignalParams
---@field task_id integer
---@field signal integer

---The same request as the arguments asked for it. `last` names a task that only
---a connection can put a number to, so this is what the pure layer can get to
---and `M.resolve` is the rest of the way.
---@class tasksd.command.SignalTarget
---@field task_id integer|"last"
---@field signal integer

---@param args string[]
---@return tasksd.command.send_signal.Opts|nil opts, string|nil err
M.from_argv = function(args)
  local values, err = arguments.parse(args, KEYS)
  if not values then
    return nil, err
  end

  local task_id
  if values.task_id then
    if values.task_id ~= LAST and not values.task_id:match("^%d+$") then
      return nil, ("expected a task id or `%s`, got `%s`"):format(LAST, values.task_id)
    end
    task_id = tonumber(values.task_id) or LAST
  end

  ---@type tasksd.command.send_signal.Opts
  local opts = { task_id = task_id, signal = values.signal }
  return opts, nil
end

---Everything that can be checked without a connection. The signal is left nil
---when none was asked for: `M.run` defaults it only on the path that already
---knows which task, since the other path opens a picker for it instead.
---@param opts tasksd.command.send_signal.Opts
---@return { task_id: integer|"last"|nil, signal: integer|nil }|nil target, string|nil err
M.validate = function(opts)
  local task_id
  if opts.task_id ~= nil then
    if opts.task_id ~= LAST and (type(opts.task_id) ~= "number" or opts.task_id < 0) then
      return nil, ("expected a task id or `%s`, got `%s`"):format(LAST, tostring(opts.task_id))
    end
    task_id = opts.task_id
  end

  local signal
  if opts.signal ~= nil then
    local number, err = M.signal_number(opts.signal)
    if not number then
      return nil, err
    end
    signal = number
  end

  return { task_id = task_id, signal = signal }, nil
end

---Put a number to `target`, which is everything `M.validate` could not do
---without a connection.
---@param target tasksd.command.SignalTarget
---@param c tasksd.Client
---@return tasksd.TaskSignalParams|nil params, string|nil err
M.resolve = function(target, c)
  if target.task_id ~= LAST then
    return { task_id = target.task_id, signal = target.signal }, nil
  end

  local _, id = last.for_client(c)
  if not id then
    return nil, "no task to signal: nothing has been started on this daemon from here"
  end
  return { task_id = id, signal = target.signal }, nil
end

---@param target tasksd.command.SignalTarget
M.send = function(target)
  client.get(function(c, connect_err)
    if not c then
      log.error(connect_err or "could not connect to tasksd")
      return
    end

    local params, resolve_err = M.resolve(target, c)
    if not params then
      log.error(tostring(resolve_err))
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

---@param opts tasksd.command.send_signal.Opts|nil
M.run = function(opts)
  vim.validate("opts", opts, "table", true)

  local target, err = M.validate(opts or {})
  if not target then
    log.error(tostring(err))
    return
  end

  if target.task_id then
    M.send({
      task_id = target.task_id,
      signal = target.signal or assert(M.signal_number(M.DEFAULT_SIGNAL)),
    })
    return
  end

  M.choose_task(function(entry)
    -- A signal given in advance answers the second question, so only the task
    -- is asked for.
    if not target.signal then
      M.choose_signal(entry)
      return
    end
    M.send({ task_id = entry.id, signal = target.signal })
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
  -- `last` is the only candidate for `task_id=`: completion has to answer
  -- synchronously and the ids themselves are on the far side of a request.
  -- Omitting the argument entirely is what opens the task picker.
  return arguments.complete(arg_lead, KEYS, {
    signal = function(lead)
      return arguments.starting_with(lead:upper(), M.signal_names())
    end,
    task_id = function(lead)
      return arguments.starting_with(lead, { LAST })
    end,
  })
end

return M
