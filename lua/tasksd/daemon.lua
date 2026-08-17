local config = require("tasksd.config")
local install = require("tasksd.install")

---Process control for the tasksd daemon: building its argv, launching it, and
---answering "is one listening on this socket?". Nothing here knows about
---JSON-RPC; `tasksd.client` layers that on top. Nor does it decide *which*
---socket to use -- that is `tasksd.socket`; here a path is an argument.
local M = {}

-- Binding the socket is fast, but not instant, so a fresh daemon is polled.
local RETRY_DELAY_MS = 50
local RETRY_ATTEMPTS = 40 -- 40 * 50ms = 2s

--------------------------------------------------------------------------------
-- Command line
--------------------------------------------------------------------------------

---Without this, a misspelled or missing key reaches the daemon as the literal
---string "nil" and tasksd dies with an unhelpful clap parse error.
---@param value any
---@param key string
---@return string
local function number_arg(value, key)
  if type(value) ~= "number" then
    error(("daemon.%s must be a number, got %s"):format(key, vim.inspect(value)), 0)
  end
  return tostring(value)
end

---A configured `daemon.path`, else one this plugin installed, else the bare
---name for `vim.system` to resolve on $PATH.
---
---Split out of `M.argv` so `tasksd.health` can report on the same binary that
---would actually be launched.
---@return string
M.executable = function()
  local path = config.current.daemon.path
  if path ~= nil and path ~= "" then
    return path
  end
  if install.is_installed() then
    return install.bin_path()
  end
  return "tasksd"
end

---@param socket_path string
---@return string[]
M.argv = function(socket_path)
  local daemon = config.current.daemon

  local argv = {
    M.executable(),
    "--unix-socket-path",
    socket_path,
    "--thread-number",
    number_arg(daemon.thread_number, "thread_number"),
    "--process-buffer-size",
    number_arg(daemon.task_buffer_size, "task_buffer_size"),
    "--graceful-period",
    number_arg(daemon.graceful_period, "graceful_period"),
    -- A detached daemon has no console to write to; `log_file` below is the
    -- channel that actually works.
    "--quiet",
  }

  if daemon.log_file then
    table.insert(argv, "--log-file")
    table.insert(argv, tostring(daemon.log_file))
  end

  return argv
end

--------------------------------------------------------------------------------
-- Launching
--------------------------------------------------------------------------------

---A throwaway connection, because vim.lsp.rpc.connect cannot report a failed
---one: it warns and hands back a client that silently buffers writes. A raw uv
---connect answers definitively and immediately.
---@param socket_path string
---@param on_done fun(ok: boolean, err: string|nil) Runs on the libuv loop.
local function probe(socket_path, on_done)
  local pipe = vim.uv.new_pipe(false)
  if not pipe then
    on_done(false, "could not allocate a pipe")
    return
  end

  pipe:connect(socket_path, function(err)
    pipe:close()
    on_done(err == nil, err)
  end)
end

---@param socket_path string
---@param attempts integer
---@param on_done fun(ok: boolean, err: string|nil)
local function probe_with_retry(socket_path, attempts, on_done)
  probe(socket_path, function(ok, err)
    if ok or attempts <= 1 then
      on_done(ok, err)
      return
    end
    -- vim.defer_fn resumes on the main loop, so the next attempt is made from a
    -- context where calling into vim.* is legal.
    vim.defer_fn(function()
      probe_with_retry(socket_path, attempts - 1, on_done)
    end, RETRY_DELAY_MS)
  end)
end

---tasksd binds without unlinking first, so a file left by a daemon that was
---killed rather than shut down makes the next bind fail with EADDRINUSE.
---@param socket_path string
local function remove_stale_socket(socket_path)
  local stat = vim.uv.fs_stat(socket_path)
  if stat and stat.type == "socket" then
    vim.uv.fs_unlink(socket_path)
  end
end

---stdout/stderr are captured so a daemon that starts and then dies reports its
---own error instead of surfacing as a generic connection timeout. The tradeoff:
---the detached daemon holds pipes owned by this Neovim. `--quiet` keeps it from
---writing to them, so dropping that flag would mean revisiting this.
---@param socket_path string
---@param on_early_exit fun(out: vim.SystemCompleted) Called if tasksd exits non-zero.
---@return boolean ok
---@return string|nil err
local function spawn(socket_path, on_early_exit)
  -- Both M.argv (invalid config) and vim.system (executable not found) raise
  -- rather than return, so this needs a pcall, not an exit-code check.
  local ok, err = pcall(function()
    local argv = M.argv(socket_path)
    vim.system(argv, { detach = config.current.daemon.detached, text = true }, function(out)
      if out.code ~= 0 then
        on_early_exit(out)
      end
    end)
  end)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

---Make sure a daemon is listening on `socket_path`, launching one if not.
---@param socket_path string
---@param on_done fun(ok: boolean, err: string|nil) Runs on the main loop.
M.ensure = function(socket_path, on_done)
  probe(socket_path, function(alive)
    if alive then
      vim.schedule(function()
        on_done(true, nil)
      end)
      return
    end

    -- Nothing answered: either no socket, or a stale file. Both mean no live
    -- daemon.
    vim.schedule(function()
      remove_stale_socket(socket_path)

      -- The daemon exiting and the probe succeeding are a race; `settled` is
      -- assigned synchronously so it is decided here rather than in whichever
      -- scheduled callback runs first.
      --
      -- The hop to the main loop belongs here rather than at each call site:
      -- one of them is vim.system's on_exit, which runs in a fast-event context
      -- where vim.fn and vim.wait are illegal -- and this function promises its
      -- caller the opposite.
      local settled = false
      local function finish(ok, err)
        if settled then
          return
        end
        settled = true
        vim.schedule(function()
          on_done(ok, err)
        end)
      end

      local spawned, spawn_err = spawn(socket_path, function(out)
        finish(
          false,
          ("tasksd exited with code %d: %s"):format(out.code, vim.trim(out.stderr or ""))
        )
      end)
      if not spawned then
        finish(false, ("could not launch tasksd: %s"):format(spawn_err))
        return
      end

      probe_with_retry(socket_path, RETRY_ATTEMPTS, function(ok, err)
        if ok then
          finish(true, nil)
        else
          finish(false, ("launched tasksd but could not connect: %s"):format(tostring(err)))
        end
      end)
    end)
  end)
end

return M
