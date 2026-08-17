---User-facing messages, for the edge layers only -- commands and `setup`.
---`daemon.lua` and `client.lua` deliberately do not notify: they report
---failures by returning an `err` string, which keeps them testable without
---capturing UI side effects and lets a caller stay quiet or retry.
local M = {}

local PREFIX = "tasksd: "

---`vim.notify` is looked up per call rather than cached, because notifier
---plugins replace it at startup and modules are `require`d only once.
---@param msg string
---@param level integer One of `vim.log.levels`.
function M.notify(msg, level)
  vim.notify(PREFIX .. msg, level)
end

---@param msg string
function M.info(msg)
  M.notify(msg, vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

---@param msg string
function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

return M
