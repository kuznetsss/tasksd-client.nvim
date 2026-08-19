---Obtaining a tasksd binary. Which binary gets *launched* is `tasksd.daemon`'s
---question; this module only knows where an installed one lives, and delegates
---putting one there to the method modules beside it.
local pin = require("tasksd.install.pin")

local M = {}

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

---Semver orders a pre-release *below* its release, so "0.3.0-rc1" does not
---satisfy a 0.3.0 minimum. The one place the floor is compared, so a daemon
---rejected before launch and one rejected at the handshake can never disagree.
---@param version string
---@return boolean
M.satisfies_min = function(version)
  local parsed = vim.version.parse(version)
  return parsed ~= nil and not vim.version.lt(parsed, pin.MIN_VERSION)
end

---@alias tasksd.InstallMethodName "auto"|"cargo"|"github"

---@class tasksd.InstallMethod
---@field desc string One-line description, listed when a method is named that does not exist.
---@field install fun(done: fun(ok: boolean, err: string|nil), report: fun(msg: string)) Checks its own preconditions first. `done` may arrive in a fast-event context, and `report` is safe to call from one.

---Programs a method needs, in one message shape so every method reports a
---missing dependency the same way.
---@param programs string[]
---@param hint string
---@return boolean ok
---@return string|nil err
M.require_programs = function(programs, hint)
  for _, program in ipairs(programs) do
    if vim.fn.executable(program) == 0 then
      return false, ("%s is not on $PATH; %s"):format(program, hint)
    end
  end
  return true, nil
end

---@param argv string[]
---@param done fun(ok: boolean, err: string|nil) May run in a fast-event context.
M.spawn = function(argv, done)
  -- vim.system raises rather than returns when the program cannot be spawned.
  local ok, err = pcall(function()
    vim.system(argv, { text = true }, function(out)
      if out.code ~= 0 then
        local stderr = vim.trim(out.stderr or "")
        done(false, stderr ~= "" and stderr or ("exit code " .. out.code))
        return
      end
      done(true, nil)
    end)
  end)
  if not ok then
    done(false, tostring(err))
  end
end

---Keyed by plain string, not `tasksd.InstallMethodName`: the name arrives from
---a command line, so `M.run` has to be able to look up a non-method.
---@type table<string, tasksd.InstallMethod>
M.methods = {
  auto = require("tasksd.install.auto").method,
  cargo = require("tasksd.install.cargo").method,
  github = require("tasksd.install.github").method,
}

---Sorted, so completion order is stable.
---@return string[]
M.method_names = function()
  local names = vim.tbl_keys(M.methods)
  table.sort(names)
  return names
end

---@return string
local function method_lines()
  local lines = {}
  for _, name in ipairs(M.method_names()) do
    table.insert(lines, ("  %s -- %s"):format(name, M.methods[name].desc))
  end
  return table.concat(lines, "\n")
end

---A method reporting success has only proved that *it* is happy, so `verify`
---runs here rather than inside one: no method can skip it.
---@param name string A `tasksd.InstallMethodName`, or whatever the user typed.
---@param on_done fun(ok: boolean, err: string|nil) Runs on the main loop.
---@param on_report? fun(msg: string) Progress narration. Runs on the main loop.
M.run = function(name, on_done, on_report)
  local function finish(ok, err)
    vim.schedule(function()
      on_done(ok, err)
    end)
  end

  -- Scheduled like `finish`, so a method may narrate from the fast-event
  -- context its own callbacks arrive in, and so what it says stays ordered
  -- against the result.
  local function report(msg)
    if not on_report then
      return
    end
    vim.schedule(function()
      on_report(msg)
    end)
  end

  local method = M.methods[name]
  if not method then
    finish(
      false,
      ("unknown install method `%s`; available methods:\n%s"):format(tostring(name), method_lines())
    )
    return
  end

  method.install(function(ok, err)
    if not ok then
      finish(false, err)
      return
    end
    -- Not `finish(M.verify())`: `done` may arrive in a fast-event context, and
    -- verify() execs a process and waits on it.
    vim.schedule(function()
      on_done(M.verify())
    end)
  end, report)
end

---Catches `pin.REV` being updated without `pin.VERSION` beside it.
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
  if version ~= pin.VERSION then
    return false,
      ("installed tasksd %s, expected %s -- pin.REV and pin.VERSION disagree"):format(
        version,
        pin.VERSION
      )
  end
  return true, nil
end

return M
