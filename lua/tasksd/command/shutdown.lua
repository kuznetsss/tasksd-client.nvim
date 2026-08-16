local client = require("tasksd.client")
local daemon = require("tasksd.daemon")
local log = require("tasksd.log")

---`:Tasksd shutdown` -- ask the daemon to stop.
---
---This is not scoped to this Neovim: tasksd terminates every task and
---disconnects every client, whoever started them.
---@type tasksd.Subcommand
return {
  desc = "Shut down the tasksd daemon",
  impl = function(_args)
    -- socket_path raises on a bad `daemon.socket` setting. A misconfigured
    -- option is the user's problem to fix, so it becomes a message rather
    -- than a stack trace out of a command callback.
    local ok, socket_path = pcall(daemon.socket_path)
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

      -- tasksd always answers `shutdown` before it exits, so this callback is
      -- reliable -- but the EOF right behind it is what actually ends the
      -- connection, and client.get's own hook drops the cached client then.
      -- Nothing here has to clean up.
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
