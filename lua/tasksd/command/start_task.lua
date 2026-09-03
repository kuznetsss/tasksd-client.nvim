local arguments = require("tasksd.args")
local client = require("tasksd.client")
local config = require("tasksd.config")
local form = require("tasksd.form")
local last = require("tasksd.last")
local log = require("tasksd.log")
local output = require("tasksd.output")
local task = require("tasksd.task")

---`:Tasksd start_task [working_dir=<dir>] [show_output=<bool>] [shell=<bool>]
---[command=<argv>]`, or `require("tasksd").start_task(opts)` -- start a task.
---
---A `command` starts straight away; without one the floating form opens, with
---whatever else was given already filled in. `command=` takes the rest of the
---line, so it goes last.
---@class tasksd.command.StartTask : tasksd.Subcommand
local M = {}

M.desc = "Start a task on the daemon: [working_dir=] [show_output=] [shell=] [command=]"

local KEYS = { "command=", "shell=", "show_output=", "working_dir=" }

---The answers the form collects, and the arguments the command line takes.
---@class tasksd.command.start_task.Opts
---@field command? string The argv to run. Without one, the form asks.
---@field working_dir? string Defaults to the current working directory.
---@field show_output? boolean Defaults to `output.show_on_start`.
---@field shell? boolean Run through `sh -c` whatever `shell.auto` would decide.

---Split what the user typed into the `executable` and `args` of `task.start`.
---No shell is involved, so quoting and globbing are not honoured.
---@param command string
---@return string|nil executable, string[] args
M.split = function(command)
  local words = vim.split(command, "%s+", { trimempty = true })
  return words[1], vim.list_slice(words, 2)
end

---Whether `command` holds anything only a shell can make sense of. Every entry
---of `shell.syntax` is matched literally.
---@param command string
---@return boolean
M.needs_shell = function(command)
  for _, item in ipairs(config.current.shell.syntax) do
    if command:find(item, 1, true) then
      return true
    end
  end
  return false
end

---The `task.start` params; see `docs/API.md` in tasksd.
---@class tasksd.TaskStartParams
---@field executable string
---@field args string[]
---@field working_dir string
---@field subscribe_to_output boolean

---@param opts tasksd.command.start_task.Opts
---@return tasksd.TaskStartParams|nil params, string|nil err
M.params = function(opts)
  local command = vim.trim(type(opts.command) == "string" and opts.command or "")
  local executable, args = M.split(command)
  if not executable then
    return nil, "no command given"
  end

  if opts.shell == true or (config.current.shell.auto and M.needs_shell(command)) then
    -- `sh` rather than `vim.o.shell`: the daemon is what spawns this, and an
    -- interactive login shell's rc files can change what the command means.
    executable, args = "sh", { "-c", command }
  end

  -- The daemon resolves a relative `working_dir` against its own cwd, which is
  -- wherever it happened to be launched from and outlives any `:cd` here.
  local given = opts.working_dir
  local dir = vim.trim(type(given) == "string" and given or "")
  dir = dir == "" and vim.fn.getcwd() or vim.fn.fnamemodify(vim.fs.normalize(dir), ":p")

  local show = opts.show_output
  if show == nil then
    show = config.current.output.show_on_start
  end

  return {
    executable = executable,
    args = args,
    working_dir = dir,
    -- Subscribing here rather than with `task.subscribe` once the window is
    -- open is what puts the task's first lines in the buffer: a subscription
    -- made later starts from wherever the output has got to.
    subscribe_to_output = show == true,
  }
end

---Start `params` on a connection the caller already has, which is how a command
---that asked the daemon something first goes on to act on the answer without
---giving up the connection it asked over.
---@param c tasksd.Client
---@param params tasksd.TaskStartParams
M.request = function(c, params)
  -- Before the request, not after: a task that exits at once can have its
  -- `task.exit` on the wire before this connection has read the response.
  task.watch(c, log.notify)

  local sent = c:request("task.start", params, function(rpc_err, result)
    if rpc_err then
      log.error(
        ("could not start `%s`: %s"):format(params.executable, client.describe_error(rpc_err))
      )
      return
    end
    local task_id = result and result.task_id
    if not task_id then
      log.error("tasksd started the task but did not report its id")
      return
    end
    last.record(c, task_id, params)
    log.info(("started `%s` as task %d"):format(params.executable, task_id))

    if params.subscribe_to_output then
      -- `attach` rather than `show`: this connection is the one carrying the
      -- output. Unfocused, because asking to watch a task is not asking to
      -- stop what you were doing.
      output.attach(c, task_id, { enter = false })
    end
  end)
  if not sent then
    log.error("could not send task.start: the connection closed")
  end
end

---@param params tasksd.TaskStartParams
M.send = function(params)
  client.get(function(c, connect_err)
    if not c then
      log.error(connect_err or "could not connect to tasksd")
      return
    end
    M.request(c, params)
  end)
end

---@param opts tasksd.command.start_task.Opts
M.start = function(opts)
  local params, err = M.params(opts)
  if not params then
    log.error(tostring(err))
    return
  end
  M.send(params)
end

---A directory can contain spaces, so the whole field is one candidate.
---@param before string
---@return integer start, string[] matches
M.complete_dir = function(before)
  return 0, vim.fn.getcompletion(before, "dir")
end

---Executables for the first word, paths for the rest -- the same split
---`M.split` makes.
---@param before string
---@return integer start, string[] matches
M.complete_command = function(before)
  local start = assert(before:find("%S*$")) - 1
  local lead = before:sub(start + 1)
  if vim.trim(before:sub(1, start)) == "" then
    return start, vim.fn.getcompletion(lead, "shellcmd")
  end
  return start, vim.fn.getcompletion(lead, "file")
end

---The box forces a shell; autoshell can still turn one on when it is unticked,
---so the label says whether that is armed.
---@return string
M.shell_label = function()
  return config.current.shell.auto and "Shell (autoshell enabled): " or "Shell: "
end

---@param opts tasksd.command.start_task.Opts|nil Answers to fill in already.
---@return tasksd.Form
M.open = function(opts)
  opts = opts or {}
  local dir = opts.working_dir
  return form.open({
    title = "Start task",
    keys = config.current.form.keys,
    blink = config.current.form.blink,
    fields = {
      { name = "command", label = "Command: ", complete = M.complete_command },
      {
        name = "working_dir",
        label = "Working directory: ",
        -- `:~` shortens a path under $HOME; `M.params` expands it again, and
        -- `getcompletion` completes it as it stands.
        value = dir or vim.fn.fnamemodify(vim.fn.getcwd(), ":~"),
        complete = M.complete_dir,
      },
      {
        name = "show_output",
        label = "Show output: ",
        type = "toggle",
        value = opts.show_output == nil and config.current.output.show_on_start or opts.show_output,
      },
      {
        name = "shell",
        label = M.shell_label(),
        type = "toggle",
        value = opts.shell or false,
      },
    },
    -- The form's field names are the option names, so what it submits is
    -- already an Opts.
    on_submit = M.start,
  })
end

---@param args string[]
---@return tasksd.command.start_task.Opts|nil opts, string|nil err
M.from_argv = function(args)
  local values, err = arguments.parse(args, KEYS, "command")
  if not values then
    return nil, err
  end

  ---@type tasksd.command.start_task.Opts
  local opts = { command = values.command, working_dir = values.working_dir }

  for key, value in pairs({ shell = values.shell, show_output = values.show_output }) do
    local flag, flag_err = arguments.boolean(value)
    if flag == nil then
      return nil, ("%s: %s"):format(key, flag_err)
    end
    ---@diagnostic disable-next-line: assign-type-mismatch
    opts[key] = flag
  end

  return opts, nil
end

---@param opts tasksd.command.start_task.Opts
---@return string|nil err
M.validate = function(opts)
  for key, want in pairs({ command = "string", working_dir = "string" }) do
    if opts[key] ~= nil and type(opts[key]) ~= want then
      return ("expected %s to be a %s, got %s"):format(key, want, type(opts[key]))
    end
  end
  for _, key in ipairs({ "shell", "show_output" }) do
    if opts[key] ~= nil and type(opts[key]) ~= "boolean" then
      return ("expected %s to be a boolean, got %s"):format(key, type(opts[key]))
    end
  end
  return nil
end

---@param opts tasksd.command.start_task.Opts|nil
M.run = function(opts)
  vim.validate("opts", opts, "table", true)
  opts = opts or {}

  local err = M.validate(opts)
  if err then
    log.error(err)
    return
  end

  if opts.command and vim.trim(opts.command) ~= "" then
    M.start(opts)
    return
  end
  M.open(opts)
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
  return arguments.complete(arg_lead, KEYS, {
    command = function(lead)
      return vim.fn.getcompletion(lead, "shellcmd")
    end,
    working_dir = function(lead)
      return vim.fn.getcompletion(lead, "dir")
    end,
    shell = function(lead)
      return arguments.starting_with(lead, arguments.BOOLEANS)
    end,
    show_output = function(lead)
      return arguments.starting_with(lead, arguments.BOOLEANS)
    end,
  })
end

return M
