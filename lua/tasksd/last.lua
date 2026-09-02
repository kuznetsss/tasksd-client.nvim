---The task each daemon most recently started from here: what a repeat, and a
---`task_id=last` argument, resolve to.
---
---Keyed by socket path rather than held as one value, because `daemon.socket`
---can name a daemon per project: a `:cd` between two of them must not repeat
---the other project's command in the other project's directory.
---
---The `task.start` params are kept rather than looked up again through
---`task.list`: the `info` there carries no `subscribe_to_output`, and the
---daemon forgets a task once 100 more have finished after it.
---
---Requires nothing. A client is handed in, so this stays below every layer that
---could want it.
local M = {}

---@type table<string, { client: tasksd.Client, id: integer, params: tasksd.TaskStartParams }>
local by_socket = {}

---@param client tasksd.Client
---@param id integer
---@param params tasksd.TaskStartParams
M.record = function(client, id, params)
  by_socket[client.socket_path] = { client = client, id = id, params = params }
end

---What this client's daemon last started here.
---
---The id comes back only when `client` is still the connection it was recorded
---on: ids come from a counter the daemon starts again at 1, so an id kept
---across a restart names some other task. Params survive that -- they describe
---what to run, not what ran.
---@param client tasksd.Client
---@return tasksd.TaskStartParams|nil params, integer|nil id
M.for_client = function(client)
  local found = by_socket[client.socket_path]
  if not found then
    return nil, nil
  end
  return found.params, found.client == client and found.id or nil
end

---Forget every daemon's. Intended for tests and teardown.
M.reset = function()
  by_socket = {}
end

return M
