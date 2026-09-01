local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local config = require("tasksd.config")
local log = require("tasksd.log")
local task_picker = require("tasksd.task_picker")

---Run `fn` with every user-facing message captured.
---@param fn fun(messages: tests.Message[])
---@return tests.Message[]
local function with_capture(fn)
  local original = log.notify
  ---@type tests.Message[]
  local messages = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  log.notify = function(msg, level)
    table.insert(messages, { msg = msg, level = level })
  end

  local ok, raised = pcall(fn, messages)

  log.notify = original
  if not ok then
    error(raised, 0)
  end
  return messages
end

---Point the plugin at a picker that only records the spec it was handed.
---@return fun(): tasksd.picker.Spec|nil opened
local function capture_picker()
  local opened
  config.setup({
    picker = function(spec)
      opened = spec
    end,
  })
  return function()
    return opened
  end
end

---@param id integer
---@param state tasksd.TaskState
---@return tasksd.TaskEntry
local function entry(id, state)
  return {
    id = id,
    state = state,
    info = { executable = "sleep", args = { "60" }, working_dir = "/tmp" },
  }
end

local T = new_set({
  hooks = {
    post_case = function()
      config.setup({})
    end,
  },
})

--------------------------------------------------------------------------------
-- filters
--------------------------------------------------------------------------------

T["filters()"] = new_set()

T["filters()"]["are the states plus all, sorted"] = function()
  eq(task_picker.filters(), { "all", "finished", "running" })
end

T["filter()"] = new_set()

T["filter()"]["keeps only the state asked for"] = function()
  local entries = { entry(3, "running"), entry(2, "finished"), entry(1, "running") }
  eq(
    vim.tbl_map(function(e)
      return e.id
    end, task_picker.filter(entries, "running")),
    { 3, 1 }
  )
end

T["filter()"]["keeps everything for all"] = function()
  local entries = { entry(3, "running"), entry(2, "finished") }
  eq(#task_picker.filter(entries, "all"), 2)
  eq(#task_picker.filter(entries, nil), 2)
end

--------------------------------------------------------------------------------
-- rows
--------------------------------------------------------------------------------

T["rows()"] = new_set()

T["rows()"]["puts the id, state, command and directory in columns"] = function()
  local rows = task_picker.rows({ entry(3, "running") })
  eq(#rows, 1)
  eq(rows[1].columns, {
    { text = "3", hl = "TasksdTaskId", align = "right" },
    { text = "running", hl = "TasksdTaskRunning" },
    { text = "sleep 60", hl = "TasksdTaskCommand" },
    { text = "/tmp", hl = "TasksdTaskDir" },
  })
end

T["rows()"]["carries the entry as the row's value"] = function()
  local task_entry = entry(3, "running")
  eq(task_picker.rows({ task_entry })[1].value, task_entry)
end

T["rows()"]["shortens a working directory under $HOME"] = function()
  local rows = task_picker.rows({
    {
      id = 1,
      state = "finished",
      info = { executable = "ls", args = {}, working_dir = vim.fn.expand("~/somewhere") },
    },
  })
  eq(rows[1].columns[4].text, "~/somewhere")
end

--------------------------------------------------------------------------------
-- show
--------------------------------------------------------------------------------

T["show()"] = new_set()

T["show()"]["opens the picker with one aligned item per task"] = function()
  local opened = capture_picker()

  task_picker.show({ title = "tasks", empty = "nothing" }, {
    entry(3, "running"),
    entry(12, "finished"),
  })

  local spec = assert(opened())
  eq(spec.title, "tasks")
  eq(spec.items[1].text, " 3  running   sleep 60  /tmp")
  eq(spec.items[2].text, "12  finished  sleep 60  /tmp")
  eq(spec.items[1].value.id, 3)
end

T["show()"]["shows only the tasks the filter keeps"] = function()
  local opened = capture_picker()

  task_picker.show(
    { title = "tasks", empty = "nothing", filter = "running" },
    { entry(3, "running"), entry(2, "finished") }
  )

  local spec = assert(opened())
  eq(#spec.items, 1)
  eq(spec.items[1].value.id, 3)
end

T["show()"]["passes on_choice through"] = function()
  local opened = capture_picker()
  local chosen

  task_picker.show({
    title = "tasks",
    empty = "nothing",
    on_choice = function(value)
      chosen = value
    end,
  }, { entry(3, "running") })

  local spec = assert(opened())
  spec.on_choice(spec.items[1].value)
  eq(chosen.id, 3)
end

-- An empty picker leaves the user to work out which of "no tasks" and "no
-- answer" they are looking at.
T["show()"]["says so instead of opening an empty picker"] = function()
  local opened = capture_picker()

  local messages = with_capture(function()
    task_picker.show({ title = "tasks", empty = "the daemon has no tasks" }, {})
  end)

  eq(opened(), nil)
  eq(messages, { { msg = "the daemon has no tasks", level = vim.log.levels.INFO } })
end

T["show()"]["says so when the filter leaves nothing"] = function()
  local opened = capture_picker()

  local messages = with_capture(function()
    task_picker.show(
      { title = "tasks", empty = "the daemon has no running tasks", filter = "running" },
      { entry(2, "finished") }
    )
  end)

  eq(opened(), nil)
  eq(messages[1].msg, "the daemon has no running tasks")
end

T["show()"]["reports an unusable picker setting"] = function()
  config.setup({ picker = "nonsense" })

  local messages = with_capture(function()
    task_picker.show({ title = "tasks", empty = "nothing" }, { entry(1, "running") })
  end)

  eq(messages[1].level, vim.log.levels.ERROR)
  eq(messages[1].msg:match("^unknown picker `nonsense`") ~= nil, true)
end

return T
