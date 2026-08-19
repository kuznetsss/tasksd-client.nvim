local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local config = require("tasksd.config")
local health = require("tasksd.health")
local install = require("tasksd.install")

-- There is no automated tasksd installation yet, so the integration tests run
-- against a local build. Override with TASKSD_BIN=/path/to/tasksd.
local TASKSD = os.getenv("TASKSD_BIN")
  or vim.fn.expand("~/Documents/rust/tasksd/target/debug/tasksd")

local function needs_tasksd()
  if vim.fn.executable(TASKSD) == 0 then
    MiniTest.skip(("no tasksd binary at %s (set TASKSD_BIN)"):format(TASKSD))
  end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

---Run `health.check()` with `vim.health` swapped for a recorder.
---
---`health.lua` looks the functions up on `vim.health` at call time rather than
---capturing them at load, so replacing the table intercepts every report -- no
---dependency injection and no child Neovim needed. Restored even when the check
---raises, since a leftover stub would break `:checkhealth` for the whole run.
---@return { level: string, msg: string, advice: string[] }[]
local function run_check()
  local original = vim.health
  local entries = {}
  local function record(level)
    return function(msg, advice)
      table.insert(entries, { level = level, msg = tostring(msg), advice = advice or {} })
    end
  end

  vim.health = {
    start = record("start"),
    ok = record("ok"),
    info = record("info"),
    warn = record("warn"),
    error = record("error"),
  }
  local ok, err = pcall(health.check)
  vim.health = original

  if not ok then
    error(err)
  end
  return entries
end

local function find(entries, level, pattern)
  for _, entry in ipairs(entries) do
    if entry.level == level and entry.msg:find(pattern) then
      return entry
    end
  end
  return nil
end

local function mentions(entries, pattern)
  for _, entry in ipairs(entries) do
    if entry.msg:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function advises(entry, pattern)
  for _, line in ipairs(entry and entry.advice or {}) do
    if line:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

---Run `fn` with both of the fallbacks behind `daemon.path` taken away, so a
---case about an unusable path reports the same on a machine that has run
---`:Tasksd install` as on one that has not.
local function with_no_tasksd(fn)
  local is_installed, path = install.is_installed, assert(vim.uv.os_getenv("PATH"))
  ---@diagnostic disable-next-line: duplicate-set-field
  install.is_installed = function()
    return false
  end
  vim.uv.os_setenv("PATH", "/nonexistent")

  local ok, err = pcall(fn)

  install.is_installed = is_installed
  vim.uv.os_setenv("PATH", path)
  if not ok then
    error(err)
  end
end

-- Stand-ins for tasksd, so the version cases can cover versions no real daemon
-- would report.
local fakes = {}

---@param output string What the fake prints for `--version`.
---@param code integer|nil Exit status, default 0.
---@return string path
local function fake_tasksd(output, code)
  local path = vim.fn.tempname()
  -- A failing run writes to stderr, as clap does: that is the stream the health
  -- check quotes back to the user.
  local redirect = (code or 0) ~= 0 and " >&2" or ""
  vim.fn.writefile({
    "#!/bin/sh",
    ("printf '%%s\\n' %s%s"):format(vim.fn.shellescape(output), redirect),
    ("exit %d"):format(code or 0),
  }, path)
  vim.fn.setfperm(path, "rwx------")
  table.insert(fakes, path)
  return path
end

--------------------------------------------------------------------------------

local T = new_set({
  hooks = {
    pre_case = function()
      config.current = vim.deepcopy(config.default)
    end,
    post_once = function()
      for _, path in ipairs(fakes) do
        vim.fn.delete(path)
      end
    end,
  },
})

--------------------------------------------------------------------------------
-- The executable
--------------------------------------------------------------------------------

T["check()"] = new_set()

T["check()"]["reports a missing executable and how to get one"] = function()
  config.setup({ daemon = { path = "/nonexistent/tasksd" } })
  local entries
  with_no_tasksd(function()
    entries = run_check()
  end)

  local err = find(entries, "error", "executable not found")
  MiniTest.expect.no_equality(err, nil)
  eq(advises(err, "cargo install"), true)

  -- Nothing to run means nothing to ask for a version: the check must stop
  -- rather than report a second, confusing failure about the same cause.
  eq(mentions(entries, "client requires"), false)
end

-- Falling back to another binary is silent at launch time, so :checkhealth is
-- the only place the user learns their setting is not in effect.
T["check()"]["warns that an unusable daemon.path was ignored"] = function()
  config.setup({ daemon = { path = "/nonexistent/tasksd" } })
  local warning = find(run_check(), "warn", "/nonexistent/tasksd.*was ignored")

  MiniTest.expect.no_equality(warning, nil)
end

T["check()"]["names which of the three sources won"] = function()
  config.setup({ daemon = { path = fake_tasksd("tasksd 9.9.9") } })
  MiniTest.expect.no_equality(find(run_check(), "ok", "%(daemon%.path%)"), nil)

  config.setup({ daemon = { path = "" } })
  with_no_tasksd(function()
    eq(find(run_check(), "warn", "was ignored"), nil)
  end)
end

--------------------------------------------------------------------------------
-- The version
--------------------------------------------------------------------------------

T["check()"]["accepts a real tasksd"] = function()
  needs_tasksd()
  config.setup({ daemon = { path = TASKSD } })
  local entries = run_check()

  MiniTest.expect.no_equality(find(entries, "ok", "tasksd executable:"), nil)
  MiniTest.expect.no_equality(find(entries, "ok", "^tasksd %d"), nil)
  eq(find(entries, "error", "."), nil)
end

T["check()"]["parses the version out of the --version line"] = function()
  config.setup({ daemon = { path = fake_tasksd("tasksd 9.9.9 (abcdef)") } })
  local ok = find(run_check(), "ok", "^tasksd 9%.9%.9 ")

  MiniTest.expect.no_equality(ok, nil)
end

-- Reached through client.check_server_version, so :checkhealth and the
-- handshake can never disagree about what is too old.
T["check()"]["rejects a daemon older than the client requires"] = function()
  config.setup({ daemon = { path = fake_tasksd("tasksd 0.0.1") } })
  local err = find(run_check(), "error", "too old")

  MiniTest.expect.no_equality(err, nil)
  eq(advises(err, "cargo install"), true)
end

-- Errors, not warnings: a binary that will not say what it is cannot be held to
-- the minimum at all.
T["check()"]["reports output that is not version-shaped"] = function()
  config.setup({ daemon = { path = fake_tasksd("not a version") } })
  local err = find(run_check(), "error", "could not determine the version")

  MiniTest.expect.no_equality(err, nil)
  eq(advises(err, "could not parse a version"), true)
end

T["check()"]["reports a --version that fails"] = function()
  config.setup({ daemon = { path = fake_tasksd("boom", 3) } })
  local err = find(run_check(), "error", "could not determine the version")

  MiniTest.expect.no_equality(err, nil)
  eq(advises(err, "boom"), true)
end

--------------------------------------------------------------------------------
-- The socket
--------------------------------------------------------------------------------

T["check()"]["reports the socket it would use"] = function()
  config.setup({ daemon = { path = fake_tasksd("tasksd 9.9.9"), socket = "global" } })

  -- Either level is correct here: whether the file exists depends on whether a
  -- daemon has ever run, which this case deliberately does not control.
  eq(mentions(run_check(), "global.sock"), true)
end

-- socket.path() raises on an unknown scheme, which must not blow up
-- :checkhealth mid-render.
T["check()"]["reports an unresolvable socket scheme"] = function()
  config.setup({ daemon = { path = fake_tasksd("tasksd 9.9.9"), socket = "session" } })

  MiniTest.expect.no_equality(find(run_check(), "error", "could not resolve the socket path"), nil)
end

return T
