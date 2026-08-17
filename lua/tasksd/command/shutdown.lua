local client = require("tasksd.client")
local log = require("tasksd.log")
local socket = require("tasksd.socket")

---`:Tasksd shutdown` -- ask the daemon to stop.
---
---This is not scoped to this Neovim: tasksd terminates every task and
---disconnects every client, whoever started them.
---@type tasksd.Subcommand
return {
  desc = "Shut down the tasksd daemon",
  impl = function(_args)
    -- socket.path raises on a bad `daemon.socket` setting; a misconfigured
    -- option should reach the user as a message, not a stack trace.
    local ok, socket_path = pcall(socket.path)
    if not ok then
      log.error(tostring(socket_path))
      return
    end

    client.get(socket_path, function(c, err)
      if not c then
        log.error(("could not connect to tasksd: %s"):format(err or "unknown error"))
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
  end,
}
