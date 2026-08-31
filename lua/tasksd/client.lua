local daemon = require("tasksd.daemon")
local install = require("tasksd.install")
local pin = require("tasksd.install.pin")
local socket = require("tasksd.socket")

---The JSON-RPC connection to tasksd: the `Client` object, the handshake, and
---the one-connection-per-Neovim cache. Getting a daemon to talk to at all is
---`tasksd.daemon`'s job.
local M = {}

local CLIENT_NAME = "tasksd-client.nvim"
local CLIENT_VERSION = "0.1.0"

-- Only has to cover a very slow machine: `daemon.ensure` has already ruled out
-- a missing daemon, and a live one answers `hello` immediately.
local HELLO_TIMEOUT_MS = 5000

---Rejecting here as well as before launch is not redundant: this is the only
---check that covers a daemon somebody else started on the socket.
---@param server_version any Whatever the daemon put in the `hello` result.
---@return string|nil err nil when the version is acceptable.
M.check_server_version = function(server_version)
  if type(server_version) ~= "string" then
    return "tasksd did not report its version in the handshake"
  end
  local parsed = vim.version.parse(server_version)
  if not parsed then
    return ("tasksd reported an unrecognisable version %q; %s or newer is required"):format(
      server_version,
      pin.MIN_VERSION
    )
  end
  if not install.satisfies_min(server_version) then
    return ("tasksd %s is too old; this client requires %s or newer"):format(
      server_version,
      pin.MIN_VERSION
    )
  end
  return nil
end

---@param err lsp.ResponseError|nil
---@return string
M.describe_error = function(err)
  if type(err) ~= "table" or type(err.message) ~= "string" then
    return vim.inspect(err)
  end
  -- tasksd puts the failing path, spawn error, and so on in `data`; the
  -- `message` alone is only the error class.
  if err.data == nil then
    return err.message
  end
  return ("%s: %s"):format(err.message, tostring(err.data))
end

--------------------------------------------------------------------------------
-- Client object
--------------------------------------------------------------------------------

---Obtained from `M.connect`; never constructed directly, and never handed to a
---caller in a disconnected state.
---@class tasksd.Client
---@field socket_path string Socket this client is connected to.
---@field server_version string Reported during the handshake; never older than `pin.MIN_VERSION`.
---@field close_reason string|nil Why the connection ended; nil while it is open.
---@field package rpc vim.lsp.rpc.PublicClient
---@field package listeners table<string, (fun(params: table))[]>
---@field package on_close fun(client: tasksd.Client, reason: string)|nil
local Client = {}
Client.__index = Client

---`rpc` is left unset: the dispatchers close over `self`, so it cannot exist
---before the instance does. `handshake` assigns it immediately after.
---@param socket_path string
---@param on_close fun(client: tasksd.Client, reason: string)|nil Runs once, when the connection ends.
---@return tasksd.Client
function Client.new(socket_path, on_close)
  return setmetatable({
    socket_path = socket_path,
    server_version = "",
    listeners = {},
    on_close = on_close,
  }, Client)
end

---The transport is the single source of truth: it flips to closing both when we
---terminate it and when the socket reaches EOF, so a flag kept here could only
---ever disagree with it.
---@return boolean
function Client:is_connected()
  return not self.rpc.is_closing()
end

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

---Listen for a notification the daemon pushes, e.g. "task.output". Listeners
---run on the main loop, in the order they were added, and a method can have any
---number of them: one connection is shared by everything in this Neovim, so
---`task.exit` has both the notifier and whatever is showing that task's output
---waiting on it.
---@param method string
---@param handler fun(params: table)
---@return fun() detach Removes this listener. Safe to call more than once.
function Client:on(method, handler)
  vim.validate("handler", handler, "callable")

  local listeners = self.listeners[method] or {}
  self.listeners[method] = listeners
  table.insert(listeners, handler)

  return function()
    for i, listener in ipairs(listeners) do
      if listener == handler then
        table.remove(listeners, i)
        return
      end
    end
  end
end

---Safe to call more than once: `terminate` returns early once it is already
---closing. Only labels the close; the bookkeeping happens in the `on_exit`
---dispatcher, which `terminate` calls on its way out.
function Client:disconnect()
  self.close_reason = self.close_reason or "closed locally"
  self.rpc.terminate()
end

--------------------------------------------------------------------------------
-- Connecting
--------------------------------------------------------------------------------

---Open the JSON-RPC connection and complete the `hello` handshake.
---@param socket_path string
---@param on_close fun(client: tasksd.Client, reason: string)|nil
---@param on_done fun(client: tasksd.Client|nil, err: string|nil)
local function handshake(socket_path, on_close, on_done)
  local self = Client.new(socket_path, on_close)

  local dispatchers = {
    -- Unknown methods are dropped rather than erroring: the daemon may
    -- legitimately send notifications this client version does not know about.
    notification = function(method, params)
      -- `shutting_down` is not the disconnect signal -- the EOF right behind it
      -- is. The daemon may never get to send it (a crash, or a shutdown it has
      -- to force through), so it only ever explains a close that is already
      -- coming.
      if method == "shutting_down" then
        self.close_reason = "daemon shut down"
      end
      -- Over a copy: a listener is free to detach itself, or anything else,
      -- while it runs.
      for _, listener in ipairs(vim.list_slice(self.listeners[method] or {})) do
        listener(params)
      end
    end,
    -- The one place a client is declared dead. vim.lsp.rpc routes every ending
    -- through the transport's `terminate` -- our own disconnect, the socket
    -- reaching EOF, an unparseable message -- and `terminate` calls this last.
    on_exit = function()
      self.close_reason = self.close_reason or "connection lost"
      if self.on_close then
        self.on_close(self, self.close_reason)
      end
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
    local server_version = result and result.server_version
    local version_err = M.check_server_version(server_version)
    if version_err then
      self:disconnect()
      finish(nil, version_err)
      return
    end
    self.server_version = server_version
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
---`on_close` is taken here rather than set on the returned client so there is
---no window in which a connection could end before its owner has registered
---interest.
---@param socket_path string
---@param on_done fun(client: tasksd.Client|nil, err: string|nil) Always on the main loop.
---@param on_close fun(client: tasksd.Client, reason: string)|nil
M.connect = function(socket_path, on_done, on_close)
  vim.validate("socket_path", socket_path, "string")
  vim.validate("on_done", on_done, "callable")
  vim.validate("on_close", on_close, "callable", true)

  daemon.ensure(socket_path, function(ok, err)
    if not ok then
      on_done(nil, err)
      return
    end
    handshake(socket_path, on_close, on_done)
  end)
end

--------------------------------------------------------------------------------
-- The connection
--------------------------------------------------------------------------------

-- Invariant: a live client or nothing. The on_close hook installed in `M.get`
-- clears this the instant the connection ends, so nothing downstream has to
-- re-validate what it gets from here.
---@type tasksd.Client|nil
local current = nil

-- Callbacks waiting on a connection that is already being established, and the
-- socket that attempt is for.
---@type (fun(client: tasksd.Client|nil, err: string|nil))[]|nil
local waiting = nil
---@type string|nil
local waiting_socket = nil

---Get this instance's client, connecting only if there isn't a live one. This
---is what callers should use; `M.connect` is the unconditional primitive
---underneath it.
---
---Concurrent calls share a single connection attempt rather than racing to
---launch competing daemons.
---@param socket_path string|fun(client: tasksd.Client|nil, err: string|nil)|nil Which daemon, or the callback alone to use `socket.path()`.
---@param on_done? fun(client: tasksd.Client|nil, err: string|nil) Always asynchronous, cache hit or not.
M.get = function(socket_path, on_done)
  if type(socket_path) == "function" then
    on_done = socket_path
    socket_path = nil
  end
  vim.validate("socket_path", socket_path, "string", true)
  vim.validate("on_done", on_done, "callable")
  ---@cast socket_path string|nil
  ---@cast on_done -nil

  if not socket_path then
    -- Resolved before `current` is read, so a `daemon.socket` that cannot be
    -- resolved does not cost a live connection its subscriptions. `socket.path`
    -- raises rather than returning an error, and a user-supplied provider
    -- function can raise anything at all.
    local ok, resolved = pcall(socket.path)
    if not ok then
      vim.schedule(function()
        on_done(nil, tostring(resolved))
      end)
      return
    end
    socket_path = resolved
  end

  -- Comparing socket_path covers the provider changing its mind mid-session (a
  -- per-project provider after :cd, say).
  local existing = current
  if existing and existing.socket_path == socket_path then
    vim.schedule(function()
      on_done(existing, nil)
    end)
    return
  end

  if existing then
    -- Clears `current` on the way through, via on_close.
    existing:disconnect()
  end

  if waiting then
    -- An in-flight attempt cannot be retargeted, and handing back a client for
    -- a different daemon would be worse than refusing.
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
    -- nil on failure, so the next call retries. Runs synchronously from the
    -- handshake result, so the hook below cannot have fired for this client
    -- yet.
    current = client
    for _, callback in ipairs(queued) do
      callback(client, err)
    end
  end, function(client)
    if current == client then
      current = nil
    end
  end)
end

---Drop the connection, disconnecting it. Intended for tests and teardown.
M.reset = function()
  if current then
    current:disconnect()
  end
end

return M
