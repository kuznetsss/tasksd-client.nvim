---Obtaining a tasksd binary.
---
---Installing is always an explicit user action, never something `setup()` does:
---it writes to the filesystem, needs the network, and can take minutes. This
---module only knows how to put a binary in one well-known place and report on
---it -- deciding *whether* to is `tasksd.command.install`'s job, and reporting
---the outcome to the user is the caller's.
---
---Nothing here reads `tasksd.config`. Which binary gets *launched* is
---`tasksd.daemon`'s question; this module only answers "where would an
---installed one live, and how do I put one there".
local M = {}

---The tasksd release this client is built against.
---
---Pinned rather than tracking the latest release, because "latest" is a moving
---target that will eventually be *newer* than this client understands -- the
---handshake would then reject a daemon the plugin itself installed. Bump this
---together with `client.MIN_SERVER_VERSION`; the test suite asserts it is never
---older than that floor.
M.PINNED_VERSION = "0.2.0"

---The commit `PINNED_VERSION` was tagged at, and what a source build actually
---builds.
---
---A tag is a movable pointer: whoever can push to the repo can retag 0.2.0 at
---different code, and every later install would silently get it. A commit hash
---cannot be moved, so this is the pin that means anything.
---
---These are *not* both passed to cargo. Given `--tag` and `--rev` together,
---cargo takes the tag and ignores the rev without warning -- the install would
---look hash-pinned while following the tag. `cargo_argv` therefore passes only
---`--rev`, and `PINNED_VERSION` is what the result is verified against.
M.PINNED_REV = "322c09dde5fea179e7e40750f1be2ed8e7e37db2"

local REPO_URL = "https://github.com/kuznetsss/tasksd"

--------------------------------------------------------------------------------
-- Where an installed binary lives
--------------------------------------------------------------------------------

---Root of the plugin-managed installation.
---
---`stdpath("data")` (~/.local/share/nvim) is for things a plugin installs and
---expects to keep; contrast `tasksd.socket`, which uses `stdpath("state")` for
---runtime files that may be thrown away between sessions. Deliberately *not*
---inside this plugin's own directory: a plugin manager updating the plugin
---would wipe it.
---@return string
M.root = function()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "tasksd")
end

---Where an installed tasksd ends up. `cargo install --root` appends `bin/`,
---and the release archives are laid out to match.
---No .exe branch: tasksd speaks unix sockets, so Windows is out regardless.
---@return string
M.bin_path = function()
  return vim.fs.joinpath(M.root(), "bin", "tasksd")
end

---Whether this plugin has already installed a binary.
---@return boolean
M.is_installed = function()
  return vim.fn.executable(M.bin_path()) == 1
end

-- `tasksd --version` is a fast local exec; anything slower than this is broken
-- rather than busy.
local VERSION_TIMEOUT_MS = 2000

---Ask a tasksd binary which version it is.
---
---Here rather than in `tasksd.daemon`, where process control otherwise lives,
---only to keep the dependency one-way: `daemon` already requires this module
---for `bin_path`, and a `daemon` -> `install` -> `daemon` cycle would hand one
---of them a half-initialised module table.
---
---Synchronous. Both callers -- verifying a finished install, and
---`:checkhealth` -- are already in a context where a few milliseconds do not
---matter, and neither wants the callback plumbing.
---@param exe string
---@return string|nil version nil when it could not be determined.
---@return string|nil err
M.version_of = function(exe)
  -- vim.system raises rather than returns when the program cannot be spawned.
  local ok, out = pcall(function()
    return vim.system({ exe, "--version" }, { text = true }):wait(VERSION_TIMEOUT_MS)
  end)
  if not ok then
    return nil, tostring(out)
  end

  local stderr = vim.trim(out.stderr or "")
  if out.code ~= 0 then
    return nil, stderr ~= "" and stderr or ("exit code " .. out.code)
  end

  -- clap prints "tasksd 0.2.0"; take the first token that starts with a digit
  -- so a future "tasksd 0.3.0 (abcdef)" still parses.
  local stdout = vim.trim(out.stdout or "")
  local version = stdout:match("(%d[%w%.%+%-]*)")
  if not version then
    return nil, ("could not parse a version from %q"):format(stdout)
  end
  return version, nil
end

--------------------------------------------------------------------------------
-- Methods
--------------------------------------------------------------------------------

---@alias tasksd.InstallMethod "cargo"

---Build the argv for a `cargo` install.
---
---`--root` puts the binary under a directory we control instead of
---~/.cargo/bin, so uninstalling means deleting one directory and a
---cargo-installed tasksd never shadows one the user manages themselves.
---`--locked` builds with the committed Cargo.lock, exactly as tasksd's own CI
---does. `--force` makes a repeated install mean "reinstall the pinned version"
---rather than "refuse, something is already here". `--rev` rather than `--tag`;
---see `M.PINNED_REV`.
---Exposed for debugging: `:lua =require("tasksd.install").cargo_argv()`
---@return string[]
M.cargo_argv = function()
  return {
    "cargo",
    "install",
    "--root",
    M.root(),
    "--git",
    REPO_URL,
    "--rev",
    M.PINNED_REV,
    "--locked",
    "--force",
  }
end

---@class tasksd.InstallMethodSpec
---@field desc string One-line description, for `:Tasksd install` completion.
---@field requires string A program that must exist before this can run.
---@field hint string What to tell the user when `requires` is missing.
---@field argv fun(): string[]

---Keyed by plain string, not by `tasksd.InstallMethod`: the name arrives from a
---command line, so `M.run` has to be able to look up something that turns out
---not to be a method at all.
---@type table<string, tasksd.InstallMethodSpec>
M.methods = {
  cargo = {
    desc = "Build from source with cargo",
    requires = "cargo",
    hint = "install a Rust toolchain: https://rustup.rs",
    argv = M.cargo_argv,
  },
}

---Method names, sorted so completion order is stable.
---@return string[]
M.method_names = function()
  local names = vim.tbl_keys(M.methods)
  table.sort(names)
  return names
end

--------------------------------------------------------------------------------
-- Running an install
--------------------------------------------------------------------------------

---Install the pinned tasksd.
---
---Asynchronous because a source build takes minutes and blocking Neovim for
---that long is not an option. `on_done` is handed back on the main loop, so it
---is free to call `vim.*`.
---@param method string A `tasksd.InstallMethod`, or whatever the user typed.
---@param on_done fun(ok: boolean, err: string|nil) Runs on the main loop.
M.run = function(method, on_done)
  local function finish(ok, err)
    vim.schedule(function()
      on_done(ok, err)
    end)
  end

  local spec = M.methods[method]
  if not spec then
    finish(
      false,
      ("unknown install method `%s`, expected one of: %s"):format(
        tostring(method),
        table.concat(M.method_names(), ", ")
      )
    )
    return
  end

  if vim.fn.executable(spec.requires) == 0 then
    finish(false, ("%s is not on $PATH; %s"):format(spec.requires, spec.hint))
    return
  end

  -- vim.system raises when the program cannot be spawned at all, which the
  -- check above makes unlikely but not impossible (a race, or a $PATH entry
  -- that is not really executable).
  local ok, err = pcall(function()
    vim.system(spec.argv(), { text = true }, function(out)
      if out.code ~= 0 then
        -- cargo reports build failures on stderr; passing it through is the
        -- difference between "install failed" and an actionable message.
        finish(
          false,
          vim.trim(out.stderr or "") ~= "" and vim.trim(out.stderr) or ("exit code " .. out.code)
        )
        return
      end
      -- Not `finish(M.verify())`: this callback runs in a fast-event context,
      -- and verify() both execs a process and waits on it. Hop to the main loop
      -- first, then check what the installer actually left behind.
      vim.schedule(function()
        on_done(M.verify())
      end)
    end)
  end)
  if not ok then
    finish(false, tostring(err))
  end
end

---Check that an install actually produced the daemon it promised.
---
---An installer that exits 0 has only proved that *it* is happy. This is what
---makes `PINNED_REV` and `PINNED_VERSION` agree in practice rather than by
---assertion: the commit is what gets built, and the version it reports is
---compared against the one this client was written for. They disagree if the
---rev is ever updated without the version beside it.
---@return boolean ok
---@return string|nil err
M.verify = function()
  local bin = M.bin_path()
  if vim.fn.executable(bin) == 0 then
    return false, ("nothing installed at %s"):format(bin)
  end

  local version, err = M.version_of(bin)
  if not version then
    return false, ("installed %s but could not read its version: %s"):format(bin, tostring(err))
  end
  if version ~= M.PINNED_VERSION then
    return false,
      ("installed tasksd %s, expected %s -- PINNED_REV and PINNED_VERSION disagree"):format(
        version,
        M.PINNED_VERSION
      )
  end
  return true, nil
end

return M
