local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local command = require("tasksd.command")
local output_command = require("tasksd.command.output")
local window = require("tasksd.output.window")

local T = new_set()

T["request()"] = new_set()

T["request()"]["with no arguments asks for a toggle"] = function()
  eq(output_command.request({}, false), { task_id = nil, opts = { reset = nil } })
end

T["request()"]["reads a task id"] = function()
  local request = assert(output_command.request({ "task_id=3" }, false))
  eq(request.task_id, 3)
end

T["request()"]["reads a position"] = function()
  local request = assert(output_command.request({ "position=float" }, false))
  eq(request.opts.position, "float")
end

T["request()"]["does not care about argument order"] = function()
  eq(
    output_command.request({ "position=right", "task_id=3" }, false),
    output_command.request({ "task_id=3", "position=right" }, false)
  )
end

-- The bang is the reset, so `:Tasksd! output position=right` means "right, at
-- the configured size" rather than "right, at whatever width it was dragged to".
T["request()"]["turns the bang into a reset"] = function()
  local request = assert(output_command.request({ "position=right" }, true))
  eq({ request.opts.reset, request.opts.position }, { true, "right" })
end

T["request()"]["rejects a position it cannot place"] = function()
  local request, err = output_command.request({ "position=middle" }, false)
  eq(request, nil)
  eq(type(err) == "string" and err:find("unknown position", 1, true) ~= nil, true)
end

T["request()"]["rejects a task id that is not a number"] = function()
  local request, err = output_command.request({ "task_id=abc" }, false)
  eq(request, nil)
  eq(type(err) == "string" and err:find("not a task id", 1, true) ~= nil, true)
end

T["request()"]["rejects a bare word"] = function()
  local request, err = output_command.request({ "3" }, false)
  eq(request, nil)
  eq(type(err) == "string" and err:find("expected key=value", 1, true) ~= nil, true)
end

T["request()"]["rejects an unknown key"] = function()
  local request, err = output_command.request({ "where=right" }, false)
  eq(request, nil)
  eq(type(err) == "string" and err:find("unknown argument", 1, true) ~= nil, true)
end

T["complete()"] = new_set()

T["complete()"]["offers the keys"] = function()
  eq(output_command.complete(""), { "position=", "task_id=" })
end

T["complete()"]["filters the keys by prefix"] = function()
  eq(output_command.complete("pos"), { "position=" })
end

T["complete()"]["offers every position"] = function()
  eq(
    output_command.complete("position="),
    vim.tbl_map(function(name)
      return "position=" .. name
    end, window.POSITIONS)
  )
end

T["complete()"]["filters positions by prefix"] = function()
  eq(output_command.complete("position=r"), { "position=right" })
end

-- Ids are on the far side of a request and completion has to answer now, so the
-- key list must not come back as a fallback.
T["complete()"]["offers nothing for a task id"] = function()
  eq(output_command.complete("task_id="), {})
  eq(output_command.complete("task_id=3"), {})
end

T["registration"] = new_set()

T["registration"]["is a subcommand"] = function()
  eq(command.subcommands.output, output_command)
  eq(vim.tbl_contains(command.names(), "output"), true)
end

T["registration"]["completes through :Tasksd"] = function()
  eq(vim.fn.getcompletion("Tasksd output pos", "cmdline"), { "position=" })
end

-- `nvim_create_user_command` is declared with bang = true, and dispatch hands
-- it on; without that the reset would never reach the subcommand.
T["registration"]["passes the bang through to the subcommand"] = function()
  local original = command.subcommands.output.impl
  local seen
  command.subcommands.output.impl = function(_, bang)
    seen = bang
  end

  local ok, err = pcall(function()
    vim.cmd("Tasksd! output")
  end)

  command.subcommands.output.impl = original
  assert(ok, err)
  eq(seen, true)
end

return T
