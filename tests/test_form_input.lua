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

return T
