local daemon = require("tasksd.daemon")

---The JSON-RPC connection to tasksd: the `Client` object, the handshake, and
---the one-connection-per-Neovim cache. Getting a daemon to talk to is
---`tasksd.daemon`'s job.
local M = {}

local CLIENT_NAME = "tasksd-client.nvim"
local CLIENT_VERSION = "0.1.0"

-- A live daemon answers `hello` immediately; this only has to cover a very
-- slow machine, not a missing daemon (daemon.ensure rules that out first).
local HELLO_TIMEOUT_MS = 5000

--------------------------------------------------------------------------------
-- Client object
--------------------------------------------------------------------------------

---A connected tasksd client. Obtained from `M.connect`; never constructed
---directly, and never handed to a caller in a disconnected state.
---@class tasksd.Client
---@field socket_path string Socket this client is connected to.
---@field server_version string Version reported by the daemon during the handshake.
---@field package rpc vim.lsp.rpc.PublicClient
---@field package handlers table<string, fun(params: table)>
---@field package closed boolean
local Client = {}
-- Client is both the metatable of every instance and, via __index, the table
-- those instances fall back to for method lookup. One shared method table, no
-- per-instance copies.
Client.__index = Client

---Create an instance with every field present.
---`rpc` is the one exception: the RPC dispatchers need to close over `self`, so
---it cannot exist before the instance does and is assigned by `handshake`
---immediately after. Nothing hands a client out before that has happened.
---@param socket_path string
---@return tasksd.Client
function Client.new(socket_path)
  return setmetatable({
    socket_path = socket_path,
    server_version = "",
    handlers = {},
    closed = false,
  }, Client)
end

---Is the connection still usable?
---@return boolean
function Client:is_connected()
  return not self.closed and not self.rpc.is_closing()
end

---Send a JSON-RPC request and receive the response asynchronously.
---@param method string tasksd method name, e.g. "task.start".
---@param params table|nil
---@param on_result fun(err: lsp.ResponseError|nil, result: any)
---@return boolean sent
function Client:request(method, params, on_result)
  if not self:is_connected() then
    return false
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  return self.rpc.request(method, params, on_result)
end

---Send a JSON-RPC notification (no response expected).
---@param method string
---@param params table|nil
---@return boolean sent
function Client:notify(method, params)
  if not self:is_connected() then
    return false
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  return self.rpc.notify(method, params)
end

---Register a handler for a notification the daemon pushes, e.g. "task.output".
---Passing nil removes the handler. Handlers run on the main loop.
---@param method string
---@param handler fun(params: table)|nil
function Client:on(method, handler)
  self.handlers[method] = handler
end

---Close the connection. Safe to call more than once.
function Client:disconnect()
  if self.closed then
    return
  end
  self.closed = true
  self.rpc.terminate()
end

--------------------------------------------------------------------------------
-- Connecting
--------------------------------------------------------------------------------

---Open the JSON-RPC connection and complete the `hello` handshake.
---@param socket_path string
---@param on_done fun(client: tasksd.Client|nil, err: string|nil)
local function handshake(socket_path, on_done)
  local self = Client.new(socket_path)

  -- Dispatchers close over `self`, so they can be built before rpc exists.
  local dispatchers = {
    -- Everything tasksd pushes at us (task.output, task.exit, ...) arrives
    -- here. Unhandled methods are dropped rather than erroring: the daemon may
    -- legitimately send notifications this client version does not know about.
    notification = function(method, params)
      local handler = self.handlers[method]
      if handler then
        handler(params)
      end
    end,
    on_exit = function()
      self.closed = true
    end,
  }

  self.rpc = vim.lsp.rpc.connect(socket_path)(dispatchers)

  local settled = false
  local function finish(client, err)
    if settled then
      return
    end
    settled = true
    on_done(client, err)
  end

  self:request("hello", {
    client_name = CLIENT_NAME,
    client_version = CLIENT_VERSION,
  }, function(err, result)
    if err then
      self:disconnect()
      finish(nil, ("tasksd rejected the handshake: %s"):format(vim.inspect(err)))
      return
    end
    self.server_version = result and result.server_version or "unknown"
    finish(self, nil)
  end)

  -- vim.lsp.rpc silently buffers writes when the socket is not connected, so a
  -- lost handshake would otherwise hang forever with no callback.
  vim.defer_fn(function()
    if not settled then
      self:disconnect()
      finish(nil, "timed out waiting for the tasksd handshake")
    end
  end, HELLO_TIMEOUT_MS)
end

---Connect to tasksd on `socket_path`, launching the daemon if none is running.
---
---The callback receives a connected `tasksd.Client`, or nil plus an error
---message. It never receives a client that is not ready to use, and it always
---runs on the main loop.
---@param socket_path string
---@param on_done fun(client: tasksd.Client|nil, err: string|nil)
M.connect = function(socket_path, on_done)
  vim.validate("socket_path", socket_path, "string")
  vim.validate("on_done", on_done, "callable")

  daemon.ensure(socket_path, function(ok, err)
    if not ok then
      on_done(nil, err)
      return
    end
    handshake(socket_path, on_done)
  end)
end

--------------------------------------------------------------------------------
-- The connection
--------------------------------------------------------------------------------

-- One client per Neovim instance. Which daemon it talks to is the socket
-- provider's decision (one global tasksd, one per project, ...); by the time a
-- path reaches here that choice has already been made.
---@type tasksd.Client|nil
local current = nil

-- Callbacks waiting on a connection that is already being established, and the
-- socket that attempt is for.
---@type (fun(client: tasksd.Client|nil, err: string|nil))[]|nil
local waiting = nil
---@type string|nil
local waiting_socket = nil

---Get this instance's client, connecting only if there isn't a live one.
---
---This is what callers should use; `M.connect` is the unconditional primitive
---underneath it. Concurrent calls share a single connection attempt rather than
---racing to launch competing daemons.
---
---`on_done` is always called asynchronously, even when the connection is
---already open, so callers never have to handle two different orderings.
---@param socket_path string
---@param on_done fun(client: tasksd.Client|nil, err: string|nil)
M.get = function(socket_path, on_done)
  vim.validate("socket_path", socket_path, "string")
  vim.validate("on_done", on_done, "callable")

  -- is_connected(), not a nil check: the client goes stale when the daemon
  -- dies, and the RPC transport flips it to closed. Handing that back would
  -- wedge the plugin until Neovim restarted.
  --
  -- The socket_path comparison covers the provider changing its mind mid
  -- session (a per-project provider after :cd, say): the old connection is
  -- dropped rather than silently kept.
  local existing = current
  if existing and existing:is_connected() and existing.socket_path == socket_path then
    vim.schedule(function()
      on_done(existing, nil)
    end)
    return
  end

  if existing then
    existing:disconnect()
    current = nil
  end

  if waiting then
    -- An in-flight attempt cannot be retargeted, and handing back a client for
    -- a different daemon would be worse than refusing. Rare enough to be worth
    -- an honest error rather than a queue-and-hope.
    if waiting_socket ~= socket_path then
      vim.schedule(function()
        on_done(
          nil,
          ("already connecting to %s; retry once that settles"):format(tostring(waiting_socket))
        )
      end)
      return
    end
    table.insert(waiting, on_done)
    return
  end
  waiting = { on_done }
  waiting_socket = socket_path

  M.connect(socket_path, function(client, err)
    local queued = waiting or {}
    waiting = nil
    waiting_socket = nil
    -- Only a success is kept; a failure must be retried on the next call.
    current = client
    for _, callback in ipairs(queued) do
      callback(client, err)
    end
  end)
end

---Drop the connection, disconnecting it. Intended for tests and teardown.
M.reset = function()
  if current then
    current:disconnect()
    current = nil
  end
end

return M
