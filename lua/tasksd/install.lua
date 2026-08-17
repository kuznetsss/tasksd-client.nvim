---Obtaining a tasksd binary. Which binary gets *launched* is `tasksd.daemon`'s
---question; this module only knows where an installed one lives and how to put
---one there.
local M = {}

---Bump together with `client.MIN_SERVER_VERSION`; the test suite asserts this
---is never older.
M.PINNED_VERSION = "0.2.0"

---The commit `PINNED_VERSION` was tagged at. Given `--tag` and `--rev`
---together cargo silently ignores the rev, so `cargo_argv` passes only `--rev`
---and `M.verify` checks the result against `PINNED_VERSION`.
M.PINNED_REV = "322c09dde5fea179e7e40750f1be2ed8e7e37db2"

local REPO_URL = "https://github.com/kuznetsss/tasksd"

local VERSION_TIMEOUT_MS = 2000

---Deliberately not inside the plugin's own directory: a plugin manager
---updating the plugin would wipe it.
---@return string
M.root = function()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "tasksd")
end

---@return string
M.bin_path = function()
  return vim.fs.joinpath(M.root(), "bin", "tasksd")
end

---@return boolean
M.is_installed = function()
  return vim.fn.executable(M.bin_path()) == 1
end

---Here rather than in `tasksd.daemon` to keep the dependency one-way: `daemon`
---already requires this module, and a cycle would hand one of them a
---half-initialised module table.
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

  -- clap prints "tasksd 0.2.0"; the first digit-led token, so a future
  -- "tasksd 0.3.0 (abcdef)" still parses.
  local stdout = vim.trim(out.stdout or "")
  local version = stdout:match("(%d[%w%.%+%-]*)")
  if not version then
    return nil, ("could not parse a version from %q"):format(stdout)
  end
  return version, nil
end

---@alias tasksd.InstallMethod "cargo"

---`--root` keeps the binary out of ~/.cargo/bin, so it never shadows a tasksd
---the user manages themselves. `--rev` rather than `--tag`; see `M.PINNED_REV`.
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

---Keyed by plain string, not `tasksd.InstallMethod`: the name arrives from a
---command line, so `M.run` has to be able to look up a non-method.
---@type table<string, tasksd.InstallMethodSpec>
M.methods = {
  cargo = {
    desc = "Build from source with cargo",
    requires = "cargo",
    hint = "install a Rust toolchain: https://rustup.rs",
    argv = M.cargo_argv,
  },
}

---Sorted, so completion order is stable.
---@return string[]
M.method_names = function()
  local names = vim.tbl_keys(M.methods)
  table.sort(names)
  return names
end

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

  -- vim.system raises rather than returns when the program cannot be spawned.
  local ok, err = pcall(function()
    vim.system(spec.argv(), { text = true }, function(out)
      if out.code ~= 0 then
        finish(
          false,
          vim.trim(out.stderr or "") ~= "" and vim.trim(out.stderr) or ("exit code " .. out.code)
        )
        return
      end
      -- Not `finish(M.verify())`: this callback runs in a fast-event context,
      -- and verify() execs a process and waits on it.
      vim.schedule(function()
        on_done(M.verify())
      end)
    end)
  end)
  if not ok then
    finish(false, tostring(err))
  end
end

---Catches `PINNED_REV` being updated without `PINNED_VERSION` beside it.
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
