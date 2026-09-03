local config = require("tasksd.config")

---The public Lua API: one function per `:Tasksd` subcommand, taking the same
---arguments the command line takes as a table. `:Tasksd! output position=right`
---is `require("tasksd").output({ position = "right", force = true })`, and a
---bang is always `force`.
---
---Each is a forwarder that requires its module when called rather than when
---this one loads: `setup` runs at startup, and pulling the subcommand registry
---in here would drag every command's dependencies -- the client, the pickers,
---the form, the installer -- into every launch.
local M = {}

M.setup = function(opts)
  config.setup(opts)
end

---@param opts tasksd.command.install.Opts|nil
M.install = function(opts)
  require("tasksd.command.install").run(opts)
end

---@param opts tasksd.command.list_tasks.Opts|nil
M.list_tasks = function(opts)
  require("tasksd.command.list_tasks").run(opts)
end

---@param opts tasksd.command.output.Opts|nil
M.output = function(opts)
  require("tasksd.command.output").run(opts)
end

---@param opts tasksd.command.repeat_task.Opts|nil
M.repeat_task = function(opts)
  require("tasksd.command.repeat_task").run(opts)
end

---@param opts tasksd.command.send_input.Opts|nil
M.send_input = function(opts)
  require("tasksd.command.send_input").run(opts)
end

---@param opts tasksd.command.send_signal.Opts|nil
M.send_signal = function(opts)
  require("tasksd.command.send_signal").run(opts)
end

M.shutdown = function()
  require("tasksd.command.shutdown").run()
end

---@param opts tasksd.command.start_task.Opts|nil
M.start_task = function(opts)
  require("tasksd.command.start_task").run(opts)
end

return M
