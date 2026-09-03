local client = require("tasksd.client")
local log = require("tasksd.log")

---`:Tasksd shutdown`, or `require("tasksd").shutdown()` -- ask the daemon to
---stop.
---
---This is not scoped to this Neovim: tasksd terminates every task and
---disconnects every client, whoever started them.
---@class tasksd.command.Shutdown : tasksd.Subcommand
local M = {}

M.desc = "Shut down the tasksd daemon"

M.run = function()
  client.get(function(c, err)
    if not c then
      log.error(err or "could not connect to tasksd")
      return
    end

    -- Registered before the request is sent, because the response and the
    -- notification are not ordered against each other: the daemon may
    -- already be shutting down by the time we are told the request landed.
    c:on("shutting_down", function()
      log.info("the daemon is shutting down")
    end)

    local sent = c:request("shutdown", nil, function(rpc_err)
      if rpc_err then
        log.error(("shutdown was rejected: %s"):format(vim.inspect(rpc_err)))
        return
      end
      log.info("shutdown request accepted")
    end)
    if not sent then
      log.error("could not send shutdown: the connection closed")
    end
  end)
end

M.impl = function(args)
  if #args > 0 then
    log.error(("shutdown takes no arguments, got `%s`"):format(table.concat(args, " ")))
    return
  end
  M.run()
end

return M
