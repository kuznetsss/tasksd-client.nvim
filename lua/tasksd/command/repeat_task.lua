local client = require("tasksd.client")
local config = require("tasksd.config")
local last = require("tasksd.last")
local log = require("tasksd.log")
local start_task = require("tasksd.command.start_task")
local task = require("tasksd.task")
local task_picker = require("tasksd.task_picker")

---`:Tasksd[!] repeat_task`, or `require("tasksd").repeat_task(opts)` -- start
---the last task again.
---
---The daemon is asked for its listing first, and a task still running is not
---started a second time; `force` skips that check. Choosing one out of the
---picker is not checked either: pointing at a task is asking for it.
---@class tasksd.command.RepeatTask : tasksd.Subcommand
local M = {}

M.desc = "Start the last task again: ! to start it even while it is running"

---@class tasksd.command.repeat_task.Opts
---@field force? boolean Start it again even while it is still running.

M.PICKER_TITLE = "Choose a task to start again"

M.EMPTY = "the daemon has no finished tasks to start again"

---@param result any The `task.list` result, straight off the wire.
---@param id integer
---@return boolean
M.is_running = function(result, id)
  for _, entry in ipairs(task.entries(result)) do
    if entry.id == id then
      return entry.state == "running"
    end
  end
  -- Absent from the listing altogether: the daemon only forgets tasks that
  -- finished, so this one did.
  return false
end

---`info` is how the daemon resolved a task, and carries no
---`subscribe_to_output`: whether to watch this one is the config's to say.
---@param info tasksd.TaskInfo
---@return tasksd.TaskStartParams
M.params = function(info)
  return {
    executable = info.executable,
    args = info.args or {},
    working_dir = info.working_dir,
    subscribe_to_output = config.current.output.show_on_start,
  }
end

---@param c tasksd.Client
---@param id integer
---@param params tasksd.TaskStartParams
M.guarded = function(c, id, params)
  local sent = c:request("task.list", nil, function(rpc_err, result)
    if rpc_err then
      log.error(("could not list tasks: %s"):format(client.describe_error(rpc_err)))
      return
    end
    if M.is_running(result, id) then
      log.warn(("task %d is still running; `:Tasksd! repeat_task` starts another"):format(id))
      return
    end
    start_task.request(c, params)
  end)
  if not sent then
    log.error("could not send task.list: the connection closed")
  end
end

---Nothing has been started from here, so the daemon's own memory of what it
---once ran is what is left to offer.
M.choose = function()
  task_picker.open({
    title = M.PICKER_TITLE,
    filter = "finished",
    empty = M.EMPTY,
    ---@param entry tasksd.TaskEntry
    on_choice = function(entry)
      start_task.send(M.params(entry.info))
    end,
  })
end

---@param opts tasksd.command.repeat_task.Opts|nil
M.run = function(opts)
  vim.validate("opts", opts, "table", true)
  local force = opts and opts.force

  client.get(function(c, connect_err)
    if not c then
      log.error(connect_err or "could not connect to tasksd")
      return
    end

    local params, id = last.for_client(c)
    if not params then
      M.choose()
      return
    end

    -- No id means a connection that is not the one the task was started on, so
    -- there is nothing here the id could still be running as.
    if force or not id then
      start_task.request(c, params)
      return
    end
    M.guarded(c, id, params)
  end)
end

M.impl = function(args, bang)
  if #args > 0 then
    log.error(("repeat_task takes no arguments, got `%s`"):format(table.concat(args, " ")))
    return
  end
  M.run({ force = bang or nil })
end

return M
