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

---The oldest tasksd this client knows how to talk to. Bump it whenever this
---client starts relying on a daemon feature that did not exist before, so the
---failure lands once at connect time with an actionable message instead of
---later, as an unexplained error from whichever request needed the feature.
---
---This is a property of the code, not a user preference, so it is a constant
---here rather than an option in `tasksd.config` -- and it has to be, since
---`client.lua` deliberately never reads config.
M.MIN_SERVER_VERSION = "0.2.0"

---Compare a version reported by the daemon against `M.MIN_SERVER_VERSION`.
---
---`vim.version` is Neovim's built-in semver implementation: `parse` turns a
---string into a comparable object (permissive by default -- "v0.2", "0.3.0-rc1"
---and build metadata are all accepted), and returns nil rather than raising
---when the string is not a version at all. Note that semver orders a
---pre-release *below* its release, so "0.3.0-rc1" does not satisfy a 0.3.0
---minimum.
---
---Exposed so the version policy can be tested without a daemon:
---`:lua =require("tasksd.client").check_server_version("0.1.0")`
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
      M.MIN_SERVER_VERSION
    )
  end
  if vim.version.lt(parsed, M.MIN_SERVER_VERSION) then
    return ("tasksd %s is too old; this client requires %s or newer"):format(
      server_version,
      M.MIN_SERVER_VERSION
    )
  end
  return nil
end

--------------------------------------------------------------------------------
-- Client object
--------------------------------------------------------------------------------

---A connected tasksd client. Obtained from `M.connect`; never constructed
---directly, and never handed to a caller in a disconnected state.
---@class tasksd.Client
---@field socket_path string Socket this client is connected to.
---@field server_version string Version reported by the daemon during the handshake; never older than `M.MIN_SERVER_VERSION`.
---@field close_reason string|nil Why the connection ended; nil while it is open.
---@field package rpc vim.lsp.rpc.PublicClient
---@field package handlers table<string, fun(params: table)>
---@field package on_close fun(client: tasksd.Client, reason: string)|nil
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
---@param on_close fun(client: tasksd.Client, reason: string)|nil Runs once, when the connection ends.
---@return tasksd.Client
function Client.new(socket_path, on_close)
  return setmetatable({
    socket_path = socket_path,
    server_version = "",
    handlers = {},
    on_close = on_close,
  }, Client)
end

---Is the connection still usable?
---
---The transport is the single source of truth. It flips to closing both when we
---terminate it and when the socket reaches EOF, so a second flag kept here
---could only ever disagree with it.
---@return boolean
function Client:is_connected()
  return not self.rpc.is_closing()
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

---Close the connection. Safe to call more than once: the transport's terminate
---returns early once it is already closing.
---
---This only labels the close; the bookkeeping happens in the `on_exit`
---dispatcher, which terminate calls on its way out.
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

  -- Dispatchers close over `self`, so they can be built before rpc exists.
  local dispatchers = {
    -- Everything tasksd pushes at us (task.output, task.exit, ...) arrives
    -- here. Unhandled methods are dropped rather than erroring: the daemon may
    -- legitimately send notifications this client version does not know about.
    notification = function(method, params)
      -- `shutting_down` is not the disconnect signal -- the EOF right behind it
      -- is. The daemon may never get to send it (a crash, or a shutdown it has
      -- to force through), so it only ever explains a close that is already
      -- coming. Recorded here, then dispatched on like any other notification
      -- so a caller's own handler still runs.
      if method == "shutting_down" then
        self.close_reason = "daemon shut down"
      end
      local handler = self.handlers[method]
      if handler then
        handler(params)
      end
    end,
    -- The one place a client is declared dead. vim.lsp.rpc routes every ending
    -- through the transport's terminate -- our own disconnect, the socket
    -- reaching EOF, an unparseable message -- and terminate calls this last.
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
    -- A daemon that is too old is a failed connection, not a usable client with
    -- a caveat: the caller gets nil plus an explanation, exactly as it would for
    -- a daemon that never answered. Nothing downstream has to re-check.
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
---The callback receives a connected `tasksd.Client`, or nil plus an error
---message. It never receives a client that is not ready to use, and it always
---runs on the main loop.
---
---`on_close` runs once when the connection ends, for any reason, with a short
---human-readable explanation. It is taken here rather than set on the returned
---client so that there is no window in which a connection could end before its
---owner has registered interest.
---@param socket_path string
---@param on_done fun(client: tasksd.Client|nil, err: string|nil)
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

-- One client per Neovim instance. Which daemon it talks to is the socket
-- provider's decision (one global tasksd, one per project, ...); by the time a
-- path reaches here that choice has already been made.
--
-- Invariant: this holds a live client or nothing. The on_close hook installed
-- in M.get clears it the instant the connection ends, so a dead client is never
-- reachable from here and nothing downstream has to re-validate it.
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

  -- A plain nil check is enough: `current` cannot hold a dead client (see the
  -- invariant above), so there is nothing to re-validate.
  --
  -- The socket_path comparison covers the provider changing its mind mid
  -- session (a per-project provider after :cd, say): the old connection is
  -- dropped rather than silently kept.
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
    -- This runs synchronously from the handshake result, so the hook below
    -- cannot have fired for this client yet -- no dead client can land here.
    current = client
    for _, callback in ipairs(queued) do
      callback(client, err)
    end
  end, function(client)
    -- The connection ended, however it ended. Drop it unless something newer
    -- has already taken its place.
    if current == client then
      current = nil
    end
  end)
end

---Drop the connection, disconnecting it. Intended for tests and teardown.
M.reset = function()
  if current then
    -- disconnect() clears `current` through the on_close hook.
    current:disconnect()
  end
end

return M
