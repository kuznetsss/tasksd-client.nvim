local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local config = require("tasksd.config")
local output = require("tasksd.output")
local start_task = require("tasksd.command.start_task")
local window = require("tasksd.output.window")

-- There is no automated tasksd installation yet, so the integration tests run
-- against a local build. Override with TASKSD_BIN=/path/to/tasksd.
local TASKSD = os.getenv("TASKSD_BIN")
  or vim.fn.expand("~/Documents/rust/tasksd/target/debug/tasksd")

-- Short path on purpose: unix socket paths are capped near 104 bytes.
local SOCKET = ("/tmp/tasksd-nvim-output-%d.sock"):format(vim.uv.os_getpid())

local function needs_tasksd()
  if vim.fn.executable(TASKSD) == 0 then
    MiniTest.skip(("no tasksd binary at %s (set TASKSD_BIN)"):format(TASKSD))
  end
end

---@return integer|nil
local function shown()
  local win = window.win()
  return win and vim.api.nvim_win_get_buf(win) or nil
end

---@return string[]
local function lines()
  local buf = shown()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---`vim.wait` keeps the event loop running, which is what lets notifications
---arrive while a case is blocking on them.
---@param what string
---@param predicate fun(): boolean
local function until_(what, predicate)
  if not vim.wait(15000, predicate, 20) then
    error(("timed out waiting for %s; the window held: %s"):format(what, vim.inspect(lines())))
  end
end

---@param lines_ string[]
---@param text string
---@return boolean
local function has(lines_, text)
  return vim.iter(lines_):any(function(line)
    return line:find(text, 1, true) ~= nil
  end)
end

---Start a task and wait for the daemon to report its id.
---@param argv string[]
---@return integer task_id
local function start(argv)
  local id, err
  client.get(function(c, connect_err)
    if not c then
      err = connect_err
      return
    end
    c:request("task.start", {
      executable = argv[1],
      args = vim.list_slice(argv, 2),
      working_dir = "/tmp",
      subscribe_to_output = false,
    }, function(rpc_err, result)
      err = rpc_err and vim.inspect(rpc_err) or nil
      id = result and result.task_id
    end)
  end)
  until_("task.start", function()
    return id ~= nil or err ~= nil
  end)
  assert(id, tostring(err))
  return id
end

---@param seconds number
---@return string[]
local function talker(seconds)
  return { "sh", "-c", ("echo one; echo two; sleep %s"):format(seconds) }
end

---Keeps printing, so a window opened part-way through still sees something.
---Bounded, so a failed run cannot leave it behind for good.
---@return string[]
local function ticker()
  return { "sh", "-c", "i=0; while [ $i -lt 40 ]; do echo tick; sleep 0.25; i=$((i+1)); done" }
end

local T = new_set({
  hooks = {
    pre_case = function()
      needs_tasksd()
      config.setup({
        daemon = {
          path = TASKSD,
          socket = function()
            return SOCKET
          end,
        },
      })
    end,
    post_case = function()
      output.reset()
      client.reset()
    end,
    post_once = function()
      vim.fn.system({ "pkill", "-f", SOCKET })
      vim.fn.delete(SOCKET)
    end,
  },
})

T["show()"] = new_set()

T["show()"]["puts a running task's output in the window"] = function()
  local id = start(talker(5))
  output.show(id)

  until_("the task's output", function()
    return has(lines(), "two")
  end)
  eq(lines()[1], "one")
  eq(window.is_open(), true)
end

T["show()"]["keeps the view on the last line as output arrives"] = function()
  local id = start(talker(5))
  output.show(id)

  until_("the task's output", function()
    return has(lines(), "two")
  end)
  local win = assert(window.win())
  eq(vim.api.nvim_win_get_cursor(win)[1], vim.api.nvim_buf_line_count(assert(shown())))
end

---Wait for the window to hold more lines than it does now.
local function grows()
  local count = vim.api.nvim_buf_line_count(assert(shown()))
  until_("more output", function()
    local buf = shown()
    return buf ~= nil and vim.api.nvim_buf_line_count(buf) > count
  end)
end

T["show()"]["leaves the cursor where the user put it"] = function()
  local id = start(ticker())
  output.show(id)
  -- More than one line, so putting the cursor on the first is a scroll away
  -- from the tail rather than a no-op.
  until_("the task's output", function()
    return #lines() >= 3
  end)

  local win = assert(window.win())
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  grows()

  eq(vim.api.nvim_win_get_cursor(win)[1], 1)
end

T["show()"]["does not follow the tail with autoscroll off"] = function()
  config.current.output.autoscroll = false
  local id = start(ticker())
  output.show(id)
  until_("the task's output", function()
    return has(lines(), "tick")
  end)
  grows()

  local win = assert(window.win())
  eq(vim.api.nvim_win_get_cursor(win)[1], 1)
end

T["show()"]["writes how the task ended"] = function()
  local id = start({ "sh", "-c", "echo one; sleep 0.3" })
  output.show(id)

  until_("the exit line", function()
    return has(lines(), ("task %d finished"):format(id))
  end)
  eq(lines()[1], "one")
end

T["show()"]["says so for a task that has already finished"] = function()
  local id = start({ "true" })
  -- Subscribing to a finished task is refused with `5`, which is the branch
  -- this covers; wait for the daemon to have reaped it.
  vim.wait(2000)
  output.show(id)

  until_("the note", function()
    return has(lines(), ("task %d has already finished"):format(id))
  end)
  eq(window.is_open(), true)
end

T["show()"]["moves the window rather than reopening it for the same task"] = function()
  local id = start(talker(5))
  output.show(id)
  until_("the task's output", function()
    return has(lines(), "two")
  end)

  local buf = shown()
  output.show(id, { position = "right" })
  eq(shown(), buf)
  eq(#vim.api.nvim_list_wins(), 2)
end

T["show()"]["swaps the buffer when told to show a different task"] = function()
  local first = start(talker(5))
  output.show(first)
  until_("the first task's output", function()
    return has(lines(), "two")
  end)
  local buf = assert(shown())

  local second = start({ "sh", "-c", "echo other; sleep 5" })
  output.show(second)
  until_("the second task's output", function()
    return has(lines(), "other")
  end)

  eq(vim.api.nvim_buf_is_valid(buf), false)
  eq(#vim.api.nvim_list_wins(), 2)
end

T["show()"]["names the buffer after the task"] = function()
  local id = start(talker(5))
  output.show(id)
  until_("the task's output", function()
    return has(lines(), "two")
  end)

  eq(vim.api.nvim_buf_get_name(assert(shown())), ("tasksd://task/%d"):format(id))
end

T["attach()"] = new_set()

---@return tasksd.Client
local function connection()
  local c
  client.get(function(got)
    c = got
  end)
  until_("a connection", function()
    return c ~= nil
  end)
  return c
end

-- A daemon that restarted can hand out a task id a live session already holds,
-- and buffer names are unique, so the outgoing buffer has to give its name up.
T["attach()"]["takes the buffer name back from the session it replaces"] = function()
  local c = connection()
  local id = start(talker(5))

  output.attach(c, id)
  local first = assert(shown())
  output.attach(c, id)

  eq(vim.api.nvim_buf_is_valid(first), false)
  eq(vim.api.nvim_buf_get_name(assert(shown())), ("tasksd://task/%d"):format(id))
end

-- `subscribe_to_output` at `task.start` is what makes a task's opening lines
-- reachable at all, and the window has to be listening in time to keep them:
-- line 1, not just the tail.
T["show()"]["catches the first line of a task started subscribed"] = function()
  local notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function() end
  local ok, err = pcall(function()
    start_task.start({ command = "seq 1 300", working_dir = "/tmp", show_output = true })
    until_("the task's output", function()
      return has(lines(), "300")
    end)
  end)
  vim.notify = notify
  assert(ok, err)

  eq(lines()[1], "1")
end

T["close()"] = new_set()

T["close()"]["drops the buffer with the window"] = function()
  local id = start(talker(5))
  output.show(id)
  until_("the task's output", function()
    return has(lines(), "two")
  end)

  local buf = assert(shown())
  output.close()

  eq(window.is_open(), false)
  eq(vim.api.nvim_buf_is_valid(buf), false)
end

T["close()"]["leaves output still on the wire with nowhere to go, and no error"] = function()
  local id = start({ "sh", "-c", "echo one; sleep 0.2; echo two; sleep 3" })
  output.show(id)
  until_("the first line", function()
    return has(lines(), "one")
  end)

  output.close()
  vim.wait(1000)
  eq(window.is_open(), false)
end

T["toggle()"] = new_set()

T["toggle()"]["closes a window that is open"] = function()
  local id = start(talker(5))
  output.show(id)
  until_("the task's output", function()
    return has(lines(), "two")
  end)

  output.toggle()
  eq(window.is_open(), false)
end

-- A reopened window starts from whatever the task produces next, not from what
-- it printed while nothing was watching, so this needs a task still talking.
T["toggle()"]["reopens the task the window last showed"] = function()
  local id = start(ticker())
  output.show(id)
  until_("the task's output", function()
    return has(lines(), "tick")
  end)
  output.close()

  output.toggle()
  until_("the task's output again", function()
    return window.is_open() and has(lines(), "tick")
  end)
end

T["toggle()"]["moves rather than closes when given a position"] = function()
  local id = start(talker(5))
  output.show(id)
  until_("the task's output", function()
    return has(lines(), "two")
  end)

  output.toggle({ position = "right" })
  eq(window.is_open(), true)
end

return T
