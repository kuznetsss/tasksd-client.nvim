local buffer = require("tasksd.output.buffer")
local client = require("tasksd.client")
local config = require("tasksd.config")
local log = require("tasksd.log")
local task_picker = require("tasksd.task_picker")
local window = require("tasksd.output.window")

---One task's output on screen: the window, the buffer behind it, and the
---subscription feeding it.
---
---The window is the subscription's lifetime. Opening it subscribes, closing it
---unsubscribes and drops the buffer, so the daemon never sends output nobody is
---looking at. There is one of these at a time; output window slots turn it into
---a table keyed by slot.
---
---`window.lua` and `buffer.lua` are told their sizes rather than reading
---`config.current.output` for themselves. The one other module that reads it is
---`highlights.lua`, for `shade`: a highlight group has no caller to be told by,
---and it is read when the group is defined rather than when a window opens.
local M = {}

---`docs/API.md` in tasksd: the task has already exited.
local EXITED = 5

---@class tasksd.output.Session
---@field client tasksd.Client
---@field task_id integer
---@field buffer tasksd.output.Buffer
---@field detach fun()[]
---@field finished boolean The task has exited, so there is no subscription left to drop.

---@type tasksd.output.Session|nil
local session = nil

---What the window last showed, so a bare toggle has something to reopen.
---@type integer|nil
local last_task = nil

---The task a `M.show` is waiting on a `task.subscribe` for. Two shows of the
---same task in one turn would otherwise open two buffers and subscribe twice.
---@type integer|nil
local opening = nil

---@class tasksd.output.Opts
---@field position? tasksd.output.Position Open the window here rather than where it last was.
---@field reset? boolean Put the window back where the config says.
---@field enter? boolean Focus the window. Defaults to true.

--------------------------------------------------------------------------------
-- The session
--------------------------------------------------------------------------------

---End a session: stop listening, give the subscription back, drop the buffer.
---Does not touch the window, which is what calls this on its way out.
---@param ending tasksd.output.Session|nil
local function stop(ending)
  if not ending then
    return
  end
  for _, detach in ipairs(ending.detach) do
    detach()
  end
  -- A subscription the daemon has already dropped answers `7 Task not found`,
  -- and there is nothing worth saying about a window the user just closed.
  if not ending.finished and ending.client:is_connected() then
    ending.client:request("task.unsubscribe", { task_id = ending.task_id }, function() end)
  end
  ending.buffer:close()
end

---@param s tasksd.output.Session
---@return boolean
local function alive(s)
  return session == s and vim.api.nvim_buf_is_valid(s.buffer.buf)
end

---Ask for the lines a `task.missed_output` reported dropped, and put them over
---the rows `Buffer:missed` reserved for them.
---@param s tasksd.output.Session
---@param params tasksd.output.Missed
local function fetch(s, params)
  s.client:request("task.get_output", {
    task_id = s.task_id,
    from_line = params.from_line,
    lines_number = params.missed,
  }, function(err, result)
    if not alive(s) then
      return
    end
    s.buffer:fill(params, not err and result and result.lines or nil)
  end)
end

---Run `write` and keep the view on the last line, unless the user has scrolled
---up. Sampled before the write, because the write is what moves the end.
---
---Moving the cursor is the scroll: there is no way to scroll a window that does
---not hold the focus, but a cursor put on the last line drags the view with it.
---@param s tasksd.output.Session
---@param write fun()
local function tailing(s, write)
  local win = window.win()
  local following = config.current.output.autoscroll
    and win
    and vim.api.nvim_win_get_buf(win) == s.buffer.buf
    and vim.api.nvim_win_get_cursor(win)[1] >= vim.api.nvim_buf_line_count(s.buffer.buf)

  write()

  if win and following and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(s.buffer.buf), 0 })
  end
end

---@param s tasksd.output.Session
local function listen(s)
  ---@param method string
  ---@param handler fun(params: table)
  local function on(method, handler)
    local detach = s.client:on(method, function(params)
      -- One connection carries every task in this Neovim, so another task's
      -- notifications arrive here too. `alive` covers a buffer the user wiped
      -- by hand, which would otherwise raise and take the listeners behind this
      -- one down with it.
      if params.task_id == s.task_id and alive(s) then
        handler(params)
      end
    end)
    table.insert(s.detach, detach)
  end

  on("task.output", function(params)
    tailing(s, function()
      s.buffer:output(params)
    end)
  end)

  on("task.missed_output", function(params)
    -- Reserving rows for a gap at the tail moves the end too, so it has to
    -- follow like output does or the cursor is left behind for good.
    tailing(s, function()
      s.buffer:missed(params)
    end)
    fetch(s, params)
  end)

  on("task.exit", function(params)
    s.finished = true
    tailing(s, function()
      s.buffer:finish(params)
    end)
  end)
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

---@param opts tasksd.output.Opts
---@return tasksd.output.window.Opts
local function placement(opts)
  return {
    default = {
      position = config.current.output.position,
      size = config.current.output.size,
    },
    position = opts.position,
    reset = opts.reset,
    enter = opts.enter,
    on_close = function()
      local ending = session
      session = nil
      stop(ending)
    end,
  }
end

---@param task_id integer
---@return string
local function buffer_name(task_id)
  return ("tasksd://task/%d"):format(task_id)
end

---@param c tasksd.Client
---@param task_id integer
---@param opts tasksd.output.Opts
---@param note string|nil Shown instead of output, when there is nothing to subscribe to.
local function begin(c, task_id, opts, note)
  local previous = session
  -- Buffer names are unique, and `previous` is still around to be named against
  -- because it cannot be dropped until the window holds the new buffer. A
  -- daemon that restarted and reissued a task id would otherwise raise E95.
  if previous and vim.api.nvim_buf_is_valid(previous.buffer.buf) then
    vim.api.nvim_buf_set_name(previous.buffer.buf, "")
  end

  local s = {
    client = c,
    task_id = task_id,
    buffer = buffer.new({
      max_lines = config.current.output.max_lines,
      name = buffer_name(task_id),
    }),
    detach = {},
    finished = note ~= nil,
  }
  session = s
  last_task = task_id

  if note then
    s.buffer:note(note)
  else
    listen(s)
  end

  window.open(s.buffer.buf, placement(opts))
  -- Only once the window holds the new buffer: deleting one still on screen
  -- takes its window down with it.
  stop(previous)
end

---Show the output of a task this connection already receives, because it was
---started with `subscribe_to_output`.
---
---Takes the connection in hand rather than asking for one, which is why it is
---not a flag on `M.show`: `client.get` resolves the socket afresh, and a
---provider that has changed its mind -- a per-project one after a `:cd` -- hands
---back a different connection, leaving the output on the one that started the
---task with nothing listening for it.
---@param c tasksd.Client
---@param task_id integer
---@param opts tasksd.output.Opts|nil
M.attach = function(c, task_id, opts)
  begin(c, task_id, opts or {})
end

---Show a task's output, subscribing to it for as long as the window is open.
---@param task_id integer
---@param opts tasksd.output.Opts|nil
M.show = function(task_id, opts)
  vim.validate("task_id", task_id, "number")
  opts = opts or {}

  if session and session.task_id == task_id then
    window.open(session.buffer.buf, placement(opts))
    return
  end
  if opening == task_id then
    return
  end
  opening = task_id

  client.get(function(c, connect_err)
    if not c then
      opening = nil
      log.error(connect_err or "could not connect to tasksd")
      return
    end

    local sent = c:request("task.subscribe", { task_id = task_id }, function(rpc_err)
      opening = nil
      if not rpc_err then
        begin(c, task_id, opts)
        return
      end
      -- A finished task has nothing to subscribe to, but its window is still
      -- worth opening: it says so, and it is where its output will go once the
      -- daemon can hand back a task's last lines.
      if rpc_err.code == EXITED then
        begin(c, task_id, opts, ("task %d has already finished"):format(task_id))
        return
      end
      log.error(("could not show task %d: %s"):format(task_id, client.describe_error(rpc_err)))
    end)
    if not sent then
      opening = nil
      log.error("could not send task.subscribe: the connection closed")
    end
  end)
end

M.PICKER_TITLE = "Choose a task to show the output of"

---Show the output window, or hide it. With nothing shown yet, this asks which
---task to show.
---@param opts tasksd.output.Opts|nil
M.toggle = function(opts)
  opts = opts or {}

  local live = session
  if live and window.is_open() then
    -- A position or a reset says where the window goes, not whether it is open.
    if opts.position or opts.reset then
      window.open(live.buffer.buf, placement(opts))
      return
    end
    window.close()
    return
  end

  if last_task then
    M.show(last_task, opts)
    return
  end
  task_picker.open({
    title = M.PICKER_TITLE,
    empty = "the daemon has no tasks",
    on_choice = function(entry)
      M.show(entry.id, opts)
    end,
  })
end

---Close the output window, which is what ends the subscription.
M.close = function()
  window.close()
end

---Drop everything this module remembers. Intended for tests and teardown.
M.reset = function()
  M.close()
  local ending = session
  session = nil
  stop(ending)
  window.forget()
  last_task, opening = nil, nil
end

return M
