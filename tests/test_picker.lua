local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local config = require("tasksd.config")
local picker = require("tasksd.picker")

---@param text string
---@param hl? string
---@param align? "left"|"right"
---@return tasksd.picker.Column
local function column(text, hl, align)
  return { text = text, hl = hl, align = align }
end

local T = new_set({
  hooks = {
    post_case = function()
      config.setup({})
    end,
  },
})

--------------------------------------------------------------------------------
-- align
--------------------------------------------------------------------------------

T["align()"] = new_set()

T["align()"]["pads every column to its widest cell"] = function()
  local items = picker.align({
    { value = "a", columns = { column("1"), column("running"), column("sleep") } },
    { value = "b", columns = { column("12"), column("finished"), column("ls") } },
  })
  eq(items[1].text, "1   running   sleep")
  eq(items[2].text, "12  finished  ls")
end

T["align()"]["right-aligns a column that asks for it"] = function()
  local items = picker.align({
    { value = "a", columns = { column("1", nil, "right"), column("running") } },
    { value = "b", columns = { column("12", nil, "right"), column("finished") } },
  })
  eq(items[1].text, " 1  running")
  eq(items[2].text, "12  finished")
end

-- Otherwise every line ends in a run of spaces the user can see when they
-- select it.
T["align()"]["does not pad the last column"] = function()
  local items = picker.align({
    { value = "a", columns = { column("1"), column("short") } },
    { value = "b", columns = { column("2"), column("much longer") } },
  })
  eq(items[1].text, "1  short")
end

T["align()"]["measures display cells, not bytes"] = function()
  local items = picker.align({
    -- Six bytes, but four display cells: two per character.
    { value = "a", columns = { column("日本"), column("x") } },
    { value = "b", columns = { column("abcde"), column("y") } },
  })
  eq(items[1].text, "日本   x")
  eq(items[2].text, "abcde  y")
end

T["align()"]["keeps highlights on the text and off the gap"] = function()
  local items = picker.align({
    { value = "a", columns = { column("1", "Number"), column("running", "DiagnosticOk") } },
  })
  eq(items[1].chunks, {
    { text = "1", hl = "Number" },
    { text = "  " },
    { text = "running", hl = "DiagnosticOk" },
  })
end

T["align()"]["carries each row's value through"] = function()
  local value = { id = 7 }
  local items = picker.align({ { value = value, columns = { column("7") } } })
  eq(items[1].value, value)
end

T["align()"]["is empty for no rows"] = function()
  eq(picker.align({}), {})
end

--------------------------------------------------------------------------------
-- resolve
--------------------------------------------------------------------------------

T["resolve()"] = new_set()

-- Nothing but this plugin and mini.nvim is on the runtimepath here, so snacks
-- is never available in the test suite.
T["resolve()"]["falls back to select when snacks is absent"] = function()
  local backend = assert(picker.resolve("auto"))
  eq(backend, picker.backends.select)
end

T["resolve()"]["reports a backend that is not installed"] = function()
  local backend, err = picker.resolve("snacks")
  eq(backend, nil)
  eq(err, "picker `snacks` is not installed")
end

T["resolve()"]["reports a name that is not a backend"] = function()
  local backend, err = picker.resolve("telescope")
  eq(backend, nil)
  eq(tostring(err):match("^unknown picker `telescope`") ~= nil, true)
  eq(tostring(err):match("select, snacks$") ~= nil, true)
end

T["resolve()"]["takes a function as a backend of its own"] = function()
  local opened
  local backend = assert(picker.resolve(function(spec)
    opened = spec
  end))
  eq(backend.is_available(), true)
  backend.pick({ title = "t", items = {} })
  eq(opened, { title = "t", items = {} })
end

--------------------------------------------------------------------------------
-- pick
--------------------------------------------------------------------------------

T["pick()"] = new_set()

T["pick()"]["opens the configured picker"] = function()
  local opened
  config.setup({
    picker = function(spec)
      opened = spec
    end,
  })

  local ok, err = picker.pick({ title = "tasks", items = {} })
  eq(ok, true)
  eq(err, nil)
  eq(opened.title, "tasks")
end

T["pick()"]["reports an unusable setting instead of opening anything"] = function()
  config.setup({ picker = "nonsense" })

  local ok, err = picker.pick({ title = "tasks", items = {} })
  eq(ok, false)
  eq(tostring(err):match("^unknown picker `nonsense`") ~= nil, true)
end

return T
