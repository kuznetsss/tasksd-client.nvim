local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local config = require("tasksd.config")
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
---@return tests.Message[]
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
  return messages
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
-- params
--------------------------------------------------------------------------------

T["params()"] = new_set()

T["params()"]["builds the request from the form values"] = function()
  local params = start_task.params({ working_dir = "/tmp", command = "ls -la" })
  eq(params, {
    executable = "ls",
    args = { "-la" },
    working_dir = "/tmp/",
    subscribe_to_output = false,
  })
end

-- Subscribing at `task.start` rather than with `task.subscribe` once the window
-- is open is what puts the task's first lines in the buffer.
T["params()"]["subscribes to the output when the box is ticked"] = function()
  local params = assert(start_task.params({ command = "ls", show_output = true }))
  eq(params.subscribe_to_output, true)

  params = assert(start_task.params({ command = "ls", show_output = false }))
  eq(params.subscribe_to_output, false)
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

T["start()"]["reports a rejected request with the daemon's reason"] = function()
  needs_tasksd()

  local messages = start_sync({ working_dir = "/no/such/directory", command = "true" }, 1)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("^could not start `true`: ") ~= nil, true)
end

T["start()"]["reports an unusable socket setting without connecting"] = function()
  config.setup({ daemon = { socket = "nonsense" } })

  local messages = capture(1, function()
    start_task.start({ working_dir = "/tmp", command = "ls" })
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
