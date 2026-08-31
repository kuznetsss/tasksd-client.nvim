local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---The form's repair and resize hang off TextChanged, which does not fire while
---there is typeahead -- and `feedkeys` and `:normal!` are nothing but
---typeahead. Only keys delivered to a real UI behave like a user typing, so
---these cases run in a child Neovim; `tests/test_form.lua` covers the rest
---in-process.
local child = MiniTest.new_child_neovim()

local OPEN = [[
  _G.form = require("tasksd.form").open({
    title = "Test",
    keys = { next_field = "<Tab>", prev_field = "<S-Tab>", submit = "<CR>", cancel = "<Esc>" },
    fields = {
      { name = "first", label = "First: " },
      { name = "second", label = "Second: " },
    },
    on_submit = function() end,
  })
]]

local OPEN_TOGGLE = [[
  _G.form = require("tasksd.form").open({
    title = "Test",
    keys = { next_field = "<Tab>", toggle = "<Space>", submit = "<CR>", cancel = "<Esc>" },
    fields = {
      { name = "text", label = "Text: " },
      { name = "flag", label = "Flag: ", type = "toggle" },
    },
    on_submit = function() end,
  })
]]

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.lua(OPEN)
    end,
    post_once = child.stop,
  },
})

T["grows while a value is typed"] = function()
  local width = child.lua_get("vim.api.nvim_win_get_config(_G.form.win).width")
  eq(child.lua_get("vim.api.nvim_win_get_config(_G.form.win).height"), 2)

  child.type_keys(("x"):rep(width))

  eq(child.lua_get("vim.api.nvim_win_get_config(_G.form.win).height") > 2, true)
end

T["shrinks again when the value is deleted"] = function()
  local width = child.lua_get("vim.api.nvim_win_get_config(_G.form.win).width")
  child.type_keys(("x"):rep(width))

  child.type_keys("<Esc>", "0d$")

  eq(child.lua_get("vim.api.nvim_win_get_config(_G.form.win).height"), 2)
end

T["follows the editor being resized"] = function()
  child.o.columns = 40

  eq(child.lua_get("vim.api.nvim_win_get_config(_G.form.win).width") <= 36, true)
end

T["stops listening for resizes once it is closed"] = function()
  child.lua("_G.form:close()")

  child.o.columns = 40

  -- A dead window would raise from the autocommand rather than deleting it.
  eq(child.lua_get("#vim.api.nvim_get_autocmds({ event = 'VimResized' })"), 0)
end

T["repairs a line opened with o"] = function()
  child.type_keys("<Esc>", "o", "foo")

  eq(child.lua_get("vim.api.nvim_buf_line_count(_G.form.buf)"), 2)
end

T["repairs a field line deleted with dd"] = function()
  child.type_keys("<Esc>", "dd")

  eq(child.lua_get("vim.api.nvim_buf_line_count(_G.form.buf)"), 2)
  eq(child.lua_get("#vim.api.nvim_buf_get_extmarks(_G.form.buf, -1, 0, -1, {})"), 2)
end

T["opens in insert mode"] = function()
  eq(child.lua_get("vim.api.nvim_get_mode().mode"), "i")
end

T["leaves insert mode when submitted from it"] = function()
  child.type_keys("<CR>")

  eq(child.lua_get("vim.api.nvim_get_mode().mode"), "n")
end

T["leaves insert mode when closed from it"] = function()
  child.lua("_G.form:close()")

  eq(child.lua_get("vim.api.nvim_get_mode().mode"), "n")
end

T["toggle"] = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.lua(OPEN_TOGGLE)
    end,
  },
})

---@return boolean
local function flag()
  return child.lua_get("_G.form:values().flag")
end

-- The form opens in insert mode, so a normal-mode-only tick would mean leaving
-- insert to answer a yes-or-no question.
T["toggle"]["ticks the box from insert mode"] = function()
  child.type_keys("<Tab>")
  eq(child.lua_get("vim.api.nvim_get_mode().mode"), "i")

  child.type_keys("<Space>")

  eq(flag(), true)
  eq(child.lua_get("vim.api.nvim_buf_get_lines(_G.form.buf, 1, 2, false)"), { "[x]" })
end

T["toggle"]["ticks the box from normal mode"] = function()
  child.type_keys("<Esc>", "<Tab>", "<Space>")

  eq(flag(), true)
end

T["toggle"]["unticks it again"] = function()
  child.type_keys("<Tab>", "<Space>", "<Space>")

  eq(flag(), false)
  eq(child.lua_get("vim.api.nvim_buf_get_lines(_G.form.buf, 1, 2, false)"), { "[ ]" })
end

-- On a text field the key has to keep its ordinary meaning, which is why the
-- mapping feeds it back rather than swallowing it.
T["toggle"]["types a space on a text field"] = function()
  child.type_keys("a", "<Space>", "b")

  eq(child.lua_get("vim.api.nvim_buf_get_lines(_G.form.buf, 0, 1, false)"), { "a b" })
  eq(flag(), false)
end

T["toggle"]["steps right on a text field in normal mode"] = function()
  child.type_keys("abc", "<Esc>", "0")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(_G.form.win)"), { 1, 0 })

  child.type_keys("<Space>")

  eq(child.lua_get("vim.api.nvim_win_get_cursor(_G.form.win)"), { 1, 1 })
end

return T
