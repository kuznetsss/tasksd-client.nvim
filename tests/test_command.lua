local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local command = require("tasksd.command")
local config = require("tasksd.config")
local daemon = require("tasksd.daemon")
local install = require("tasksd.install")

local T = new_set()

---Run `fn` with `install.run` replaced by a stub, so no case here builds or
---downloads anything. The stub records its arguments and hands back the
---callback, letting a case decide when -- or whether -- the install finishes.
---Run `fn` with `install.run` replaced by a stub *and* nothing usable already
---present, so the subcommand always gets as far as installing. Whatever tasksd
---the machine running the suite happens to have must not decide these cases.
---@param fn fun(calls: { name: string, done: fun(ok: boolean, err: string|nil), report: fun(msg: string) }[])
local function with_stubbed_run(fn)
  local original, original_usable = install.run, daemon.usable_version
  local calls = {}

  ---@diagnostic disable-next-line: duplicate-set-field
  install.run = function(name, done, report)
    table.insert(calls, { name = name, done = done, report = report })
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  daemon.usable_version = function()
    return nil, "nothing installed"
  end

  local ok, err = pcall(fn, calls)

  install.run, daemon.usable_version = original, original_usable
  if not ok then
    error(err, 0)
  end
end

---Run `fn` with `install.run` replaced by `impl`, restoring it even when `fn`
---raises: an escaping error would otherwise leave the stub in place for every
---later case in the run, including the ones in other files.
local function with_run(impl, fn)
  local original = install.run
  ---@diagnostic disable-next-line: duplicate-set-field
  install.run = impl

  local ok, err = pcall(fn)

  install.run = original
  if not ok then
    error(err, 0)
  end
end

---Run `fn` with a satisfying tasksd already in place, however it got there.
---@param version string
---@param source tasksd.ExeSource
local function with_usable(version, source, fn)
  local original_exe, original_usable = daemon.executable, daemon.usable_version

  ---@diagnostic disable-next-line: duplicate-set-field
  daemon.executable = function()
    return "/somewhere/tasksd", source
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  daemon.usable_version = function()
    return version, nil
  end

  local ok, err = pcall(fn)

  daemon.executable, daemon.usable_version = original_exe, original_usable
  if not ok then
    error(err, 0)
  end
end

---`log` looks vim.notify up per call, so replacing it here is enough to see
---what the subcommand said.
---@param fn fun(messages: string[])
local function with_notify(fn)
  local original = vim.notify
  local messages = {}

  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, _level)
    table.insert(messages, msg)
  end

  local ok, err = pcall(fn, messages)

  vim.notify = original
  if not ok then
    error(err, 0)
  end
end

T["completion"] = new_set()

-- Against command.names() rather than a hardcoded list, so adding a subcommand
-- does not mean editing this case.
T["completion"]["offers every subcommand"] = function()
  eq(vim.fn.getcompletion("Tasksd ", "cmdline"), command.names())
end

T["completion"]["filters by prefix"] = function()
  eq(vim.fn.getcompletion("Tasksd st", "cmdline"), { "start_task" })
  eq(vim.fn.getcompletion("Tasksd sh", "cmdline"), { "shutdown" })
end

T["completion"]["offers nothing once a subcommand is settled"] = function()
  eq(vim.fn.getcompletion("Tasksd start_task ", "cmdline"), {})
end

T["dispatch"] = new_set()

T["dispatch"]["rejects an unknown subcommand"] = function()
  MiniTest.expect.error(function()
    vim.cmd("Tasksd bogus")
  end, "unknown subcommand")
end

T["dispatch"]["rejects a missing subcommand"] = function()
  MiniTest.expect.error(function()
    vim.cmd("Tasksd")
  end, "expected a subcommand")
end

T["dispatch"]["forwards the remaining arguments"] = function()
  local got
  local original = command.subcommands.start_task.impl
  command.subcommands.start_task.impl = function(args)
    got = args
  end
  vim.cmd("Tasksd start_task foo bar")
  command.subcommands.start_task.impl = original

  eq(got, { "foo", "bar" })
end

T["install"] = new_set()

-- Against install.method_names() rather than a hardcoded list, so adding a
-- method does not mean editing this case.
T["install"]["completes the install methods"] = function()
  eq(vim.fn.getcompletion("Tasksd install ", "cmdline"), install.method_names())
end

T["install"]["filters methods by prefix"] = function()
  eq(vim.fn.getcompletion("Tasksd install g", "cmdline"), { "github" })
end

T["install"]["passes the method through"] = function()
  with_stubbed_run(function(calls)
    with_notify(function()
      vim.cmd("Tasksd install github")
      calls[1].done(true, nil)
    end)
    eq(#calls, 1)
    eq(calls[1].name, "github")
  end)
end

-- An unknown method is install.run's to reject, not the subcommand's: it is the
-- side that knows what the methods are.
T["install"]["hands an unknown method to install.run"] = function()
  with_stubbed_run(function(calls)
    with_notify(function()
      vim.cmd("Tasksd install bogus")
      calls[1].done(false, "unknown install method `bogus`")
    end)
    eq(calls[1].name, "bogus")
  end)
end

T["install"]["falls back to the configured method"] = function()
  local original = config.current.install.method
  config.current.install.method = "cargo"

  with_stubbed_run(function(calls)
    with_notify(function()
      vim.cmd("Tasksd install")
      calls[1].done(true, nil)
    end)
    eq(calls[1].name, "cargo")
  end)

  config.current.install.method = original
end

T["install"]["defaults to auto"] = function()
  eq(config.default.install.method, "auto")
end

-- The point of the whole check: a binary the user supplied through daemon.path
-- is as good a reason not to install as one this plugin put there.
T["install"]["skips when a satisfying tasksd is already there"] = function()
  local ran = false

  with_run(function()
    ran = true
  end, function()
    with_usable("0.2.0", "config", function()
      with_notify(function(messages)
        vim.cmd("Tasksd install")

        eq(ran, false)
        eq(messages[#messages]:find("already available", 1, true) ~= nil, true)
        eq(messages[#messages]:find("daemon.path", 1, true) ~= nil, true)
      end)
    end)
  end)
end

T["install"]["says how to install anyway"] = function()
  with_run(function() end, function()
    with_usable("0.2.0", "installed", function()
      with_notify(function(messages)
        vim.cmd("Tasksd install")
        eq(messages[#messages]:find("`:Tasksd! install`", 1, true) ~= nil, true)
      end)
    end)
  end)
end

-- Vim attaches a bang to the command name, never to an argument, so the force
-- spelling is `:Tasksd! install` and not `:Tasksd install!`.
T["install"]["installs anyway when banged"] = function()
  local calls = {}

  with_run(function(name, done)
    table.insert(calls, { name = name, done = done })
  end, function()
    with_usable("0.2.0", "installed", function()
      with_notify(function()
        vim.cmd("Tasksd! install cargo")
        eq(#calls, 1)
        eq(calls[1].name, "cargo")
        calls[1].done(true, nil)
      end)
    end)
  end)
end

T["install"]["announces the method before it starts"] = function()
  with_stubbed_run(function(calls)
    with_notify(function(messages)
      vim.cmd("Tasksd install cargo")
      eq(#messages, 1)
      eq(messages[1]:find("cargo", 1, true) ~= nil, true)
      calls[1].done(true, nil)
    end)
  end)
end

T["install"]["reports where it installed to"] = function()
  with_stubbed_run(function(calls)
    with_notify(function(messages)
      vim.cmd("Tasksd install cargo")
      calls[1].done(true, nil)
      eq(messages[#messages]:find(install.bin_path(), 1, true) ~= nil, true)
    end)
  end)
end

-- The channel the install methods narrate through: without it a source build is
-- minutes of silence.
T["install"]["shows progress while an install is running"] = function()
  with_stubbed_run(function(calls)
    with_notify(function(messages)
      vim.cmd("Tasksd install auto")
      calls[1].report("trying `github`")
      eq(messages[#messages]:find("trying `github`", 1, true) ~= nil, true)
      calls[1].done(true, nil)
    end)
  end)
end

T["install"]["reports the failure a method returned"] = function()
  with_stubbed_run(function(calls)
    with_notify(function(messages)
      vim.cmd("Tasksd install cargo")
      calls[1].done(false, "cargo is not on $PATH")
      eq(messages[#messages]:find("cargo is not on $PATH", 1, true) ~= nil, true)
    end)
  end)
end

-- Two at once would race: cargo builds into one --root, and the github method
-- stages through one fixed path.
T["install"]["refuses a second install while one is running"] = function()
  with_stubbed_run(function(calls)
    with_notify(function(messages)
      vim.cmd("Tasksd install cargo")
      vim.cmd("Tasksd install github")
      eq(#calls, 1)
      eq(messages[#messages]:find("already running", 1, true) ~= nil, true)

      -- Leaving it unfinished would make every later case see a busy install.
      calls[1].done(true, nil)
    end)
  end)
end

T["install"]["accepts another install once the first finished"] = function()
  with_stubbed_run(function(calls)
    with_notify(function()
      vim.cmd("Tasksd install cargo")
      calls[1].done(false, "boom")
      vim.cmd("Tasksd install github")
      eq(#calls, 2)
      calls[2].done(true, nil)
    end)
  end)
end

return T
