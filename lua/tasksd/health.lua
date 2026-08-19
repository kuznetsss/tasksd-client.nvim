local client = require("tasksd.client")
local config = require("tasksd.config")
local daemon = require("tasksd.daemon")
local install = require("tasksd.install")
local pin = require("tasksd.install.pin")
local socket = require("tasksd.socket")

---What `:checkhealth tasksd` reports: is there a binary, is it new enough, and
---which daemon would this Neovim address.
---
---Nothing registers this. `:checkhealth {name}` looks for `lua/{name}/health.lua`
---on the runtimepath and calls its `check()` -- the file existing at this path
---*is* the registration.
local M = {}

local REPO_URL = "https://github.com/kuznetsss/tasksd"

---`:Tasksd install` already picks between a prebuilt release and a source
---build per platform, so pointing at either by hand would only duplicate --
---and eventually contradict -- what `tasksd.install.auto` decides.
---@return string[]
local function install_advice()
  return {
    ("Run `:Tasksd install` to fetch or build tasksd %s"):format(pin.VERSION),
    'Or supply your own and set daemon.path in require("tasksd").setup()',
    ("Source: %s"):format(REPO_URL),
  }
end

local function check_executable()
  local exe, source = daemon.executable()

  -- Falling back is quiet at launch time, so a path the user believes is in
  -- effect but is not has to surface somewhere.
  local configured = config.current.daemon.path
  if configured ~= nil and configured ~= "" and source ~= "config" then
    vim.health.warn(("daemon.path = %q is not executable, so it was ignored"):format(configured), {
      "Point it at a tasksd binary, or unset it to use whichever one this plugin finds",
    })
  end

  -- exepath() resolves the same way the OS will: a bare name is searched on
  -- $PATH, a path is checked for existence and the executable bit. Either way
  -- "" means nothing to run.
  local resolved = vim.fn.exepath(exe)
  if resolved == "" then
    vim.health.error(("tasksd executable not found: %s"):format(exe), install_advice())
    return nil
  end

  vim.health.ok(("tasksd executable: %s (%s)"):format(resolved, daemon.SOURCE_LABEL[source]))
  return resolved
end

---@param exe string
local function check_version(exe)
  -- An error rather than a warning: a binary that will not say what it is
  -- cannot be checked against the minimum at all.
  local version, err = install.version_of(exe)
  if not version then
    vim.health.error(("could not determine the version of %s"):format(exe), { tostring(err) })
    return
  end

  -- The client's own check rather than a second comparison here, so
  -- :checkhealth can never disagree with connect().
  local unsupported = client.check_server_version(version)
  if unsupported then
    vim.health.error(unsupported, install_advice())
    return
  end

  vim.health.ok(("tasksd %s (client requires %s or newer)"):format(version, pin.MIN_VERSION))
end

local function check_socket()
  local scheme = config.current.daemon.socket
  vim.health.info(
    ("daemon.socket = %s"):format(
      type(scheme) == "function" and "<function>" or vim.inspect(scheme)
    )
  )

  -- socket.path() raises on an unknown scheme or an over-long path, which is a
  -- misconfiguration report in its own right rather than a crash in checkhealth.
  local ok, path = pcall(socket.path)
  if not ok then
    vim.health.error(("could not resolve the socket path: %s"):format(tostring(path)))
    return
  end

  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "socket" then
    -- Existence is not liveness: tasksd does not unlink on a hard kill, so this
    -- file may be a leftover. `daemon.ensure` probes it and removes it if dead.
    vim.health.ok(("socket present: %s"):format(path))
  else
    vim.health.info(("socket not created yet: %s"):format(path))
  end
end

M.check = function()
  vim.health.start("tasksd-client.nvim")

  local exe = check_executable()
  if exe then
    check_version(exe)
  end

  check_socket()
end

return M
