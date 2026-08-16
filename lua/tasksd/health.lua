local client = require("tasksd.client")
local config = require("tasksd.config")
local daemon = require("tasksd.daemon")
local socket = require("tasksd.socket")

---What `:checkhealth tasksd` reports.
---
---Neovim finds this by name: `:checkhealth {name}` looks for `lua/{name}/health.lua`
---on the runtimepath and calls its `check()`. There is nothing to register and
---nothing to call from `setup()` -- the file existing at this path *is* the
---registration. Everything runs synchronously into a scratch buffer, so unlike
---`setup()` this is a context where blocking on a subprocess is acceptable.
---
---The job here is to answer "why did tasksd not start?" before the user has to
---ask it: is there a binary, is it new enough, and where would it be talked to.
local M = {}

-- `tasksd --version` is a fast local exec; anything slower than this is broken
-- rather than busy, and :checkhealth should not hang on it.
local VERSION_TIMEOUT_MS = 2000

local REPO_URL = "https://github.com/kuznetsss/tasksd"

---How to obtain a tasksd, given what this machine can use.
---
---Prebuilt archives are published for Linux only, so on every other platform
---offering the releases page would just send the user to a page with nothing
---they can run. `vim.uv.os_uname().sysname` is the libuv view of `uname -s`:
---"Linux", "Darwin", "Windows_NT".
---@return string[]
local function install_advice()
  local advice = {
    ("Build from source: cargo install --git %s --tag %s"):format(
      REPO_URL,
      client.MIN_SERVER_VERSION
    ),
  }
  if vim.uv.os_uname().sysname == "Linux" then
    table.insert(advice, 1, ("Download a prebuilt binary: %s/releases"):format(REPO_URL))
  end
  table.insert(advice, 'Then put it on $PATH, or set daemon.path in require("tasksd").setup()')
  return advice
end

---Locate the binary and report on it.
local function check_executable()
  local exe = daemon.executable()

  -- exepath() answers both questions this needs, in the same way the OS will:
  -- given a bare name it searches $PATH, given a path it checks that the file
  -- is there and executable. Either way "" means "nothing to run".
  local resolved = vim.fn.exepath(exe)
  if resolved == "" then
    local advice = install_advice()

    -- A path typed with a leading ~ is a trap worth naming: the shell expands
    -- it, but `vim.system` does not, so the spawn would fail with a confusing
    -- ENOENT on a filename that visibly exists.
    if exe:sub(1, 1) == "~" then
      table.insert(
        advice,
        1,
        ("daemon.path = %q is not expanded; write the full path, or use vim.fn.expand()"):format(
          exe
        )
      )
    end

    vim.health.error(("tasksd executable not found: %s"):format(exe), advice)
    return nil
  end

  vim.health.ok(("tasksd executable: %s"):format(resolved))
  return resolved
end

---Ask the binary its version and hold it to the same rule the handshake uses.
---@param exe string
local function check_version(exe)
  local ok, out = pcall(function()
    return vim.system({ exe, "--version" }, { text = true }):wait(VERSION_TIMEOUT_MS)
  end)
  if not ok or out.code ~= 0 then
    vim.health.error(("could not run `%s --version`"):format(exe), {
      not ok and tostring(out) or vim.trim(out.stderr or ""),
    })
    return
  end

  -- clap prints "tasksd 0.2.0"; take the first token that starts with a digit
  -- so a future "tasksd 0.3.0 (abcdef)" still parses.
  local version = vim.trim(out.stdout or ""):match("(%d[%w%.%+%-]*)")
  if not version then
    vim.health.warn(("could not parse a version from %q"):format(vim.trim(out.stdout or "")))
    return
  end

  -- Deliberately the client's own check rather than a second comparison here:
  -- the minimum is a property of the protocol this client speaks, and one copy
  -- of that rule means :checkhealth can never disagree with connect().
  local err = client.check_server_version(version)
  if err then
    vim.health.error(err, install_advice())
    return
  end

  vim.health.ok(
    ("tasksd %s (client requires %s or newer)"):format(version, client.MIN_SERVER_VERSION)
  )
end

---Report which daemon this Neovim would address, and whether its socket exists.
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
