local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local command = require("tasksd.command")

local T = new_set()

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

return T
