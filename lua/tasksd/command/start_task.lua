local client = require("tasksd.client")
local config = require("tasksd.config")
local form = require("tasksd.form")
local log = require("tasksd.log")
local task = require("tasksd.task")

---`:Tasksd start_task` -- collect a command in a floating form, then start it.
---@class tasksd.command.StartTask : tasksd.Subcommand
local M = {}

M.desc = "Start a task on the daemon"

---Split what the user typed into the `executable` and `args` of `task.start`.
---No shell is involved, so quoting and globbing are not honoured.
---@param command string
---@return string|nil executable, string[] args
M.split = function(command)
  local words = vim.split(command, "%s+", { trimempty = true })
  return words[1], vim.list_slice(words, 2)
end

---The `task.start` params; see `docs/API.md` in tasksd.
---@class tasksd.TaskStartParams
---@field executable string
---@field args string[]
---@field working_dir string
---@field subscribe_to_output boolean

---Turn what the form collected into `task.start` params.
---@param values table<string, string>
---@return tasksd.TaskStartParams|nil params, string|nil err
M.params = function(values)
  local executable, args = M.split(values.command or "")
  if not executable then
    return nil, "no command given"
  end

  -- The daemon resolves a relative `working_dir` against its own cwd, which is
  -- wherever it happened to be launched from and outlives any `:cd` here.
  local dir = vim.trim(values.working_dir or "")
  dir = dir == "" and vim.fn.getcwd() or vim.fn.fnamemodify(vim.fs.normalize(dir), ":p")

  return {
    executable = executable,
    args = args,
    working_dir = dir,
    -- Nothing consumes `task.output` yet; `task.exit` arrives either way.
    subscribe_to_output = false,
  }
end

---@param values table<string, string>
M.start = function(values)
  local params, err = M.params(values)
  if not params then
    log.error(tostring(err))
    return
  end

  client.get(function(c, connect_err)
    if not c then
      log.error(connect_err or "could not connect to tasksd")
      return
    end

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
      log.info(("started `%s` as task %d"):format(params.executable, task_id))
    end)
    if not sent then
      log.error("could not send task.start: the connection closed")
    end
  end)
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

---@return tasksd.Form
M.open = function()
  return form.open({
    title = "Start task",
    keys = config.current.form.keys,
    blink = config.current.form.blink,
    fields = {
      {
        name = "working_dir",
        label = "Working directory: ",
        -- `:~` shortens a path under $HOME; `M.params` expands it again, and
        -- `getcompletion` completes it as it stands.
        value = vim.fn.fnamemodify(vim.fn.getcwd(), ":~"),
        complete = M.complete_dir,
      },
      { name = "command", label = "Command: ", complete = M.complete_command },
    },
    on_submit = M.start,
  })
end

M.impl = function(_args)
  M.open()
end

return M
