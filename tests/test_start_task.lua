local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local config = require("tasksd.config")
local last = require("tasksd.last")
local log = require("tasksd.log")
local start_task = require("tasksd.command.start_task")

local TASKSD = os.getenv("TASKSD_BIN")

local function needs_tasksd()
  if not TASKSD or vim.fn.executable(TASKSD) == 0 then
    MiniTest.skip("no tasksd binary; set TASKSD_BIN=/path/to/tasksd")
  end
end

local socket_counter = 0
local sockets = {}
local function new_socket()
  socket_counter = socket_counter + 1
  local path = ("/tmp/tasksd-nvim-start-%d-%d.sock"):format(vim.uv.os_getpid(), socket_counter)
  table.insert(sockets, path)
  vim.fn.delete(path)
  return path
end

---@class tests.Message
---@field msg string
---@field level integer

---Run `fn` with every user-facing message captured, waiting for `count` of
---them. `log.info`/`log.error` both route through `log.notify`, so this is the
---one interception point.
---@param count integer
---@param fn fun()
---@return tests.Message[]
local function capture(count, fn)
  local original = log.notify
  ---@type tests.Message[]
  local messages = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  log.notify = function(msg, level)
    table.insert(messages, { msg = msg, level = level })
  end

  local ok, raised = pcall(fn)
  if ok then
    vim.wait(15000, function()
      return #messages >= count
    end, 20)
  end

  log.notify = original
  if not ok then
    error(raised, 0)
  end
  return messages
end

---Run `start` against a daemon of this case's own.
---@param values table<string, string>
---@param count integer How many messages the case expects.
---@return tests.Message[] messages, string socket
local function start_sync(values, count)
  local socket = new_socket()
  config.setup({
    daemon = {
      path = TASKSD,
      socket = function()
        return socket
      end,
    },
  })

  local messages = capture(count, function()
    start_task.start(values)
  end)

  client.reset()
  return messages, socket
end

local T = new_set({
  hooks = {
    post_once = function()
      for _, path in ipairs(sockets) do
        vim.fn.system({ "pkill", "-f", path })
        vim.fn.delete(path)
      end
      config.setup({})
    end,
  },
})

--------------------------------------------------------------------------------
-- split
--------------------------------------------------------------------------------

T["split()"] = new_set()

T["split()"]["separates the executable from its arguments"] = function()
  local exe, args = start_task.split("cargo build --release")
  eq(exe, "cargo")
  eq(args, { "build", "--release" })
end

T["split()"]["ignores surrounding and repeated whitespace"] = function()
  local exe, args = start_task.split("  ls   -la  ")
  eq(exe, "ls")
  eq(args, { "-la" })
end

T["split()"]["reports an empty command"] = function()
  local exe, args = start_task.split("   ")
  eq(exe, nil)
  eq(args, {})
end

--------------------------------------------------------------------------------
-- shell
--------------------------------------------------------------------------------

-- These cases change `config.current`, which `require` keeps between them.
local restores_config = { hooks = {
  post_case = function()
    config.setup({})
  end,
} }

T["needs_shell()"] = new_set(restores_config)

T["needs_shell()"]["spots what a shell has to interpret"] = function()
  eq(start_task.needs_shell("make && ./run"), true)
end

T["needs_shell()"]["leaves a plain command alone"] = function()
  eq(start_task.needs_shell("cargo build --release"), false)
end

T["needs_shell()"]["takes the whole syntax list from the config"] = function()
  config.setup({ shell = { syntax = { "|" } } })
  eq(start_task.needs_shell("make && ./run"), false)
  eq(start_task.needs_shell("ls | wc -l"), true)
end

-- `&&` is a substring match, so a pattern character in the list is one too.
T["needs_shell()"]["matches literally, not as a pattern"] = function()
  config.setup({ shell = { syntax = { "$(" } } })
  eq(start_task.needs_shell("echo $(date)"), true)
  eq(start_task.needs_shell("echo xy"), false)
end

--------------------------------------------------------------------------------
-- params
--------------------------------------------------------------------------------

T["params()"] = new_set(restores_config)

T["params()"]["builds the request from the form values"] = function()
  local params =
    start_task.params({ working_dir = "/tmp", command = "ls -la", show_output = false })
  eq(params, {
    executable = "ls",
    args = { "-la" },
    working_dir = "/tmp/",
    subscribe_to_output = false,
  })
end

-- The form always submits a boolean, so this is the path a Lua caller or a
-- command line that left `show_output=` out takes.
T["params()"]["falls back to show_on_start when nothing says"] = function()
  local original = config.current.output.show_on_start

  config.current.output.show_on_start = true
  eq(assert(start_task.params({ command = "ls" })).subscribe_to_output, true)
  config.current.output.show_on_start = false
  eq(assert(start_task.params({ command = "ls" })).subscribe_to_output, false)

  config.current.output.show_on_start = original
end

-- Subscribing at `task.start` rather than with `task.subscribe` once the window
-- is open is what puts the task's first lines in the buffer.
T["params()"]["subscribes to the output when the box is ticked"] = function()
  local params = assert(start_task.params({ command = "ls", show_output = true }))
  eq(params.subscribe_to_output, true)

  params = assert(start_task.params({ command = "ls", show_output = false }))
  eq(params.subscribe_to_output, false)
end

T["params()"]["runs the command through a shell when the box is ticked"] = function()
  local params = assert(start_task.params({ command = "ls -la", shell = true }))
  eq(params.executable, "sh")
  eq(params.args, { "-c", "ls -la" })
end

T["params()"]["runs a command that needs a shell through one unasked"] = function()
  local params = assert(start_task.params({ command = "make && ./run" }))
  eq(params.executable, "sh")
  eq(params.args, { "-c", "make && ./run" })
end

T["params()"]["splits the command as written when autoshell is off"] = function()
  config.setup({ shell = { auto = false } })
  local params = assert(start_task.params({ command = "make && ./run" }))
  eq(params.executable, "make")
  eq(params.args, { "&&", "./run" })
end

T["params()"]["refuses an empty command even with the box ticked"] = function()
  local params, err = start_task.params({ command = "   ", shell = true })
  eq(params, nil)
  eq(err, "no command given")
end

T["params()"]["refuses an empty command"] = function()
  local params, err = start_task.params({ working_dir = "/tmp", command = "" })
  eq(params, nil)
  eq(err, "no command given")
end

T["params()"]["makes a relative working directory absolute"] = function()
  local params = assert(start_task.params({ working_dir = ".", command = "ls" }))
  eq(params.working_dir, vim.fn.getcwd() .. "/")
end

T["params()"]["expands ~ in the working directory"] = function()
  local params = assert(start_task.params({ working_dir = "~", command = "ls" }))
  eq(params.working_dir, vim.uv.os_homedir() .. "/")
end

T["params()"]["falls back to the current directory"] = function()
  local params = assert(start_task.params({ working_dir = "  ", command = "ls" }))
  eq(params.working_dir, vim.fn.getcwd())
end

T["params()"]["sends an empty argument list as a JSON array"] = function()
  local params = assert(start_task.params({ working_dir = "/tmp", command = "ls" }))
  eq(vim.json.encode(params.args), "[]")
end

--------------------------------------------------------------------------------
-- completion
--------------------------------------------------------------------------------

T["open()"] = new_set()

T["open()"]["offers the working directory with $HOME collapsed"] = function()
  local f = start_task.open()
  local values = f:values()
  f:close()

  eq(values.working_dir, vim.fn.fnamemodify(vim.fn.getcwd(), ":~"))
  -- Round trip: what the form shows is what `params` can expand again.
  values.command = "ls"
  local params = assert(start_task.params(values))
  eq(params.working_dir, vim.fn.getcwd() .. "/")
end

T["open()"]["starts the output box from the config"] = function()
  config.setup({ output = { show_on_start = false } })
  local f = start_task.open()
  local values = f:values()
  f:close()
  config.setup({})

  eq(values.show_output, false)
end

T["open()"]["ticks the output box by default"] = function()
  config.setup({})
  local f = start_task.open()
  local values = f:values()
  f:close()

  eq(values.show_output, true)
end

T["open()"]["leaves the shell box unticked"] = function()
  config.setup({})
  local f = start_task.open()
  local values = f:values()
  f:close()

  eq(values.shell, false)
end

--------------------------------------------------------------------------------
-- arguments
--------------------------------------------------------------------------------

T["from_argv()"] = new_set()

T["from_argv()"]["takes nothing at all"] = function()
  eq(start_task.from_argv({}), {})
end

-- fargs is already split on whitespace, so command= has to take what follows.
T["from_argv()"]["gives command= the rest of the arguments"] = function()
  eq(
    start_task.from_argv({ "command=cargo", "build", "--release" }).command,
    "cargo build --release"
  )
end

T["from_argv()"]["reads the other keys"] = function()
  eq(start_task.from_argv({ "working_dir=/tmp", "shell=true", "show_output=false" }), {
    working_dir = "/tmp",
    shell = true,
    show_output = false,
  })
end

T["from_argv()"]["rejects a value that is not a boolean"] = function()
  local opts, err = start_task.from_argv({ "shell=yes" })
  eq(opts, nil)
  eq(err, "shell: expected true or false, got `yes`")
end

T["from_argv()"]["rejects an unknown key"] = function()
  local opts, err = start_task.from_argv({ "cwd=/tmp" })
  eq(opts, nil)
  eq(tostring(err):match("^unknown argument `cwd`") ~= nil, true)
end

T["complete()"] = new_set()

T["complete()"]["offers the keys"] = function()
  eq(start_task.complete(""), { "command=", "shell=", "show_output=", "working_dir=" })
end

T["complete()"]["offers true and false for a toggle"] = function()
  eq(start_task.complete("shell="), { "shell=false", "shell=true" })
end

--------------------------------------------------------------------------------
-- run
--------------------------------------------------------------------------------

T["run()"] = new_set()

---Run `fn` with `send` replaced by a recorder and the form stubbed out, so
---nothing here opens a window or reaches for a daemon.
---@param fn fun(sent: tasksd.TaskStartParams[], opened: tasksd.command.start_task.Opts[])
local function without_side_effects(fn)
  local original_send, original_open = start_task.send, start_task.open
  local sent, opened = {}, {}

  ---@diagnostic disable-next-line: duplicate-set-field
  start_task.send = function(params)
    table.insert(sent, params)
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  start_task.open = function(opts)
    table.insert(opened, opts or {})
  end

  local ok, err = pcall(fn, sent, opened)

  start_task.send, start_task.open = original_send, original_open
  if not ok then
    error(err, 0)
  end
end

T["run()"]["starts a command it was given"] = function()
  without_side_effects(function(sent, opened)
    start_task.run({ command = "ls -la", working_dir = "/tmp" })
    eq(#opened, 0)
    eq(#sent, 1)
    eq({ sent[1].executable, sent[1].args }, { "ls", { "-la" } })
  end)
end

-- The point of the argument: a keymap for a fixed command should not stop to
-- ask about it.
T["run()"]["opens the form without a command"] = function()
  without_side_effects(function(sent, opened)
    start_task.run({ working_dir = "/tmp" })
    eq(#sent, 0)
    eq(opened, { { working_dir = "/tmp" } })
  end)
end

T["run()"]["treats a blank command as none"] = function()
  without_side_effects(function(sent, opened)
    start_task.run({ command = "   " })
    eq(#sent, 0)
    eq(#opened, 1)
  end)
end

-- The command line and the Lua call are the same request written two ways.
T["run()"]["matches the command line"] = function()
  without_side_effects(function(sent)
    vim.cmd("Tasksd start_task working_dir=/tmp show_output=false command=ls -la")
    require("tasksd").start_task({ working_dir = "/tmp", show_output = false, command = "ls -la" })
    eq(#sent, 2)
    eq(sent[1], sent[2])
  end)
end

T["shell_label()"] = new_set(restores_config)

T["shell_label()"]["says whether autoshell is armed"] = function()
  config.setup({})
  eq(start_task.shell_label(), "Shell (autoshell enabled): ")

  config.setup({ shell = { auto = false } })
  eq(start_task.shell_label(), "Shell: ")
end

T["complete_dir()"] = new_set()

T["complete_dir()"]["offers directories, and only directories"] = function()
  local start, matches = start_task.complete_dir("lua/tasksd/")
  eq(start, 0)
  eq(vim.tbl_contains(matches, "lua/tasksd/install/"), true)
  eq(vim.tbl_contains(matches, "lua/tasksd/form.lua"), false)
end

T["complete_command()"] = new_set()

T["complete_command()"]["offers executables for the first word"] = function()
  local start, matches = start_task.complete_command("  ls")
  eq(start, 2)
  eq(vim.tbl_contains(matches, "ls"), true)
end

T["complete_command()"]["offers paths for later words"] = function()
  local start, matches = start_task.complete_command("cat lua/tasksd/for")
  eq(start, 4)
  eq(vim.tbl_contains(matches, "lua/tasksd/form.lua"), true)
end

T["complete_command()"]["starts a new word after a trailing space"] = function()
  local start, matches = start_task.complete_command("cat ")
  eq(start, 4)
  eq(#matches > 0, true)
end

--------------------------------------------------------------------------------
-- start: integration against a real daemon
--------------------------------------------------------------------------------

T["start()"] = new_set()

T["start()"]["reports the id the daemon assigned"] = function()
  needs_tasksd()

  local messages = start_sync({ working_dir = "/tmp", command = "true" }, 1)

  eq(messages[1].level, vim.log.levels.INFO)
  eq(messages[1].msg:match("^started `true` as task %d+$") ~= nil, true)
end

T["start()"]["remembers the task it started"] = function()
  needs_tasksd()

  local _, socket = start_sync({ working_dir = "/tmp", command = "true" }, 1)

  -- Asked as a later connection to the same socket, which is what a restarted
  -- daemon looks like: the params carry over, the id does not.
  local other = { socket_path = socket }
  ---@cast other tasksd.Client
  local found, id = last.for_client(other)
  local params = assert(found, "nothing was recorded")
  eq(params.executable, "true")
  eq(params.working_dir, "/tmp/")
  eq(id, nil)

  last.reset()
end

T["start()"]["remembers nothing when the daemon refused"] = function()
  needs_tasksd()

  local _, socket = start_sync({ working_dir = "/no/such/directory", command = "true" }, 1)

  local other = { socket_path = socket }
  ---@cast other tasksd.Client
  eq(last.for_client(other), nil)
end

T["start()"]["reports a rejected request with the daemon's reason"] = function()
  needs_tasksd()

  local messages = start_sync({ working_dir = "/no/such/directory", command = "true" }, 1)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("^could not start `true`: ") ~= nil, true)
end

T["start()"]["reports an unusable socket setting without connecting"] = function()
  config.setup({ daemon = { socket = "nonsense" } })

  local messages = capture(1, function()
    start_task.start({ working_dir = "/tmp", command = "ls", show_output = false })
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("daemon.socket must be one of") ~= nil, true)
end

--------------------------------------------------------------------------------
-- task.exit, end to end
--------------------------------------------------------------------------------

T["exit"] = new_set()

T["exit"]["reports a task that finished"] = function()
  needs_tasksd()

  local messages = start_sync({ working_dir = "/tmp", command = "true" }, 2)

  eq(#messages, 2)
  eq(messages[2].level, vim.log.levels.INFO)
  eq(messages[2].msg:match("^task %d+ finished$") ~= nil, true)
end

T["exit"]["reports a non-zero exit code"] = function()
  needs_tasksd()

  local messages = start_sync({ working_dir = "/tmp", command = "false" }, 2)

  eq(#messages, 2)
  eq(messages[2].level, vim.log.levels.WARN)
  eq(messages[2].msg:match("^task %d+ exited with code 1$") ~= nil, true)
end

return T
