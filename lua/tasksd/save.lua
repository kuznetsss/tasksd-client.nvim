local config = require("tasksd.config")
local log = require("tasksd.log")

---Putting the working tree on disk before a task is allowed to read it.
---
---Called from the commands' synchronous entry points rather than from
---`start_task.request`: every route to that one runs from a `client.get` or an
---RPC response callback, so on a cold start the write would land after the
---daemon had been spawned and waited for, whole keystrokes away from the one
---that asked for it.
local M = {}

---Write every modified buffer, if `auto_save` is on.
---
---`:wall` reports a buffer it cannot write and carries on through the rest, but
---raises once it is done -- and a single modified buffer with no file name
---(E141) is no reason to refuse to start the task.
---
---`silent`, because one "N lines written" per buffer is a hit-enter prompt
---between the user and the task they asked for. It hides messages, not errors.
M.all = function()
  if not config.current.auto_save then
    return
  end
  local ok, err = pcall(vim.cmd.wall, { mods = { silent = true } })
  if not ok then
    log.warn(("auto_save: %s"):format(err))
  end
end

return M
