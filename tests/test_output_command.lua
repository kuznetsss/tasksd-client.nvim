local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local command = require("tasksd.command")
local output = require("tasksd.output")
local output_command = require("tasksd.command.output")
local window = require("tasksd.output.window")

local T = new_set()

T["from_argv()"] = new_set()

T["from_argv()"]["with no arguments asks for a toggle"] = function()
  eq(output_command.from_argv({}, false), {})
end

T["from_argv()"]["reads a task id"] = function()
  local opts = assert(output_command.from_argv({ "task_id=3" }, false))
  eq(opts.task_id, 3)
end

T["from_argv()"]["reads a position"] = function()
  local opts = assert(output_command.from_argv({ "position=float" }, false))
  eq(opts.position, "float")
end

T["from_argv()"]["does not care about argument order"] = function()
  eq(
    output_command.from_argv({ "position=right", "task_id=3" }, false),
    output_command.from_argv({ "task_id=3", "position=right" }, false)
  )
end

-- The bang is the force, so `:Tasksd! output position=right` means "right, at
-- the configured size" rather than "right, at whatever width it was dragged to".
T["from_argv()"]["turns the bang into a force"] = function()
  local opts = assert(output_command.from_argv({ "position=right" }, true))
  eq({ opts.force, opts.position }, { true, "right" })
end

T["from_argv()"]["rejects a task id that is not a number"] = function()
  local opts, err = output_command.from_argv({ "task_id=abc" }, false)
  eq(opts, nil)
  eq(type(err) == "string" and err:find("not a task id", 1, true) ~= nil, true)
end

T["from_argv()"]["rejects a bare word"] = function()
  local opts, err = output_command.from_argv({ "3" }, false)
  eq(opts, nil)
  eq(type(err) == "string" and err:find("expected key=value", 1, true) ~= nil, true)
end

T["from_argv()"]["rejects an unknown key"] = function()
  local opts, err = output_command.from_argv({ "where=right" }, false)
  eq(opts, nil)
  eq(type(err) == "string" and err:find("unknown argument", 1, true) ~= nil, true)
end

T["validate()"] = new_set()

T["validate()"]["turns force into a reset"] = function()
  eq(output_command.validate({ position = "right", force = true }), {
    position = "right",
    reset = true,
  })
end

-- The task id is not part of what `tasksd.output` is told: it decides between
-- `show` and `toggle` instead.
T["validate()"]["leaves the task id behind"] = function()
  eq(output_command.validate({ task_id = 3 }), {})
end

-- Reachable from Lua as well as from the command line, so the check has to sit
-- past the argv parser rather than inside it.
T["validate()"]["rejects a position it cannot place"] = function()
  ---@diagnostic disable-next-line: assign-type-mismatch
  local show_opts, err = output_command.validate({ position = "middle" })
  eq(show_opts, nil)
  eq(type(err) == "string" and err:find("unknown position", 1, true) ~= nil, true)
end

T["validate()"]["rejects a task id that is not a number"] = function()
  ---@diagnostic disable-next-line: assign-type-mismatch
  local show_opts, err = output_command.validate({ task_id = "3" })
  eq(show_opts, nil)
  eq(type(err) == "string" and err:find("not a task id", 1, true) ~= nil, true)
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

T["run()"] = new_set()

---Run `fn` with `output.show` and `output.toggle` replaced by recorders, so no
---case here opens a window or reaches for a daemon.
---@param fn fun(calls: { what: string, task_id: integer|nil, opts: table }[])
local function with_stubbed_output(fn)
  local original_show, original_toggle = output.show, output.toggle
  local calls = {}

  ---@diagnostic disable-next-line: duplicate-set-field
  output.show = function(task_id, opts)
    table.insert(calls, { what = "show", task_id = task_id, opts = opts })
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  output.toggle = function(opts)
    table.insert(calls, { what = "toggle", opts = opts })
  end

  local ok, err = pcall(fn, calls)

  output.show, output.toggle = original_show, original_toggle
  if not ok then
    error(err, 0)
  end
end

T["run()"]["shows the task it was given"] = function()
  with_stubbed_output(function(calls)
    output_command.run({ task_id = 3, position = "right" })
    eq(#calls, 1)
    eq({ calls[1].what, calls[1].task_id }, { "show", 3 })
    eq(calls[1].opts, { position = "right" })
  end)
end

T["run()"]["toggles without a task id"] = function()
  with_stubbed_output(function(calls)
    output_command.run()
    eq(#calls, 1)
    eq({ calls[1].what, calls[1].opts }, { "toggle", {} })
  end)
end

T["run()"]["reports a bad position rather than acting"] = function()
  with_stubbed_output(function(calls)
    local messages = {}
    local original = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg)
      table.insert(messages, msg)
    end
    ---@diagnostic disable-next-line: assign-type-mismatch
    local ok, err = pcall(output_command.run, { position = "middle" })
    vim.notify = original
    assert(ok, err)

    eq(#calls, 0)
    eq(messages[#messages]:find("unknown position", 1, true) ~= nil, true)
  end)
end

T["lua api"] = new_set()

-- The command line and the Lua call are the same request written two ways.
T["lua api"]["matches the command line"] = function()
  with_stubbed_output(function(calls)
    vim.cmd("Tasksd! output task_id=3 position=right")
    require("tasksd").output({ task_id = 3, position = "right", force = true })

    eq(#calls, 2)
    eq(calls[1], calls[2])
  end)
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
