local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local form = require("tasksd.form")

local KEYS = {
  next_field = "<Tab>",
  prev_field = "<S-Tab>",
  submit = "<CR>",
  cancel = "<Esc>",
}

---@param on_submit fun(values: table<string, string>)|nil
---@return tasksd.Form
local function open(on_submit)
  return form.open({
    title = "Test",
    keys = KEYS,
    fields = {
      { name = "first", label = "First: ", value = "one" },
      { name = "second", label = "Second: " },
    },
    on_submit = on_submit or function() end,
  })
end

local T = new_set()

T["form"] = new_set({
  hooks = {
    -- A case that fails part-way must not leave a float over every later one.
    post_case = function()
      vim.cmd.stopinsert()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative ~= "" then
          vim.api.nvim_win_close(win, true)
        end
      end
    end,
  },
})

T["form"]["holds values, not labels"] = function()
  local f = open()
  eq(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false), { "one", "" })
  eq(f:values(), { first = "one", second = "" })
end

T["form"]["draws labels as inline virtual text"] = function()
  local f = open()
  local marks = vim.api.nvim_buf_get_extmarks(f.buf, -1, 0, -1, { details = true })
  eq(#marks, 2)
  eq(marks[1][4].virt_text_pos, "inline")
  eq(vim.trim(marks[1][4].virt_text[1][1]), "First:")
end

T["form"]["starts on the first field, at the end of the value"] = function()
  local f = open()
  eq(vim.api.nvim_win_get_cursor(f.win), { 1, 3 })
end

T["form"]["moves between fields and wraps"] = function()
  local f = open()
  f:focus(f:current() + 1)
  eq(f:current(), 2)
  f:focus(f:current() + 1)
  eq(f:current(), 1)
  f:focus(f:current() - 1)
  eq(f:current(), 2)
end

T["form"]["submits the edited values and closes"] = function()
  local submitted
  local f = open(function(values)
    submitted = values
  end)
  vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "edited", "typed" })

  f:submit()

  eq(submitted, { first = "edited", second = "typed" })
  eq(vim.api.nvim_win_is_valid(f.win), false)
end

T["form"]["cancel closes without submitting"] = function()
  local submitted = false
  local f = open(function()
    submitted = true
  end)

  f:close()

  eq(submitted, false)
  eq(vim.api.nvim_win_is_valid(f.win), false)
end

T["form"]["completes the field the cursor is on"] = function()
  local f = form.open({
    title = "Test",
    keys = KEYS,
    fields = {
      { name = "plain", label = "Plain: " },
      {
        name = "fruit",
        label = "Fruit: ",
        value = "app",
        complete = function(before)
          return #before - #before:match("%S*$"), { "apple", "apricot", "banana" }
        end,
      },
    },
    on_submit = function() end,
  })

  -- The field without a `complete` leaves completion mode.
  f:focus(1)
  eq(form.complete(1, ""), -3)
  eq(form.complete(0, ""), {})

  f:focus(2)
  eq(form.complete(1, ""), 0)
  eq(form.complete(0, "ap"), { "apple", "apricot" })
end

T["form"]["sets a completefunc only when a field can complete"] = function()
  local f = open()
  eq(vim.bo[f.buf].completefunc, "")

  local g = form.open({
    title = "Test",
    keys = KEYS,
    fields = {
      {
        name = "only",
        label = "Only: ",
        complete = function()
          return 0, {}
        end,
      },
    },
    on_submit = function() end,
  })
  eq(vim.bo[g.buf].completefunc, "v:lua.require'tasksd.form'.complete")
end

T["form"]["carries the plugin's filetype"] = function()
  local f = open()
  eq(vim.bo[f.buf].filetype, form.FILETYPE)
end

T["form"]["forgets a form when its buffer is wiped"] = function()
  local f = open()
  f:close()
  -- `M.complete` has nothing to dispatch to once the buffer is gone.
  eq(form.complete(1, ""), -3)
end

T["form"]["drops lines added past the last field"] = function()
  local f = open()
  vim.api.nvim_buf_set_lines(f.buf, -1, -1, false, { "stray", "lines" })

  f:normalize()

  eq(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false), { "one", "" })
end

T["form"]["restores a deleted field line"] = function()
  local f = open()
  vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, {})

  f:normalize()

  eq(vim.api.nvim_buf_line_count(f.buf), 2)
  eq(f:values(), { first = "", second = "" })
end

T["form"]["redraws the labels a deleted line took with it"] = function()
  local f = open()
  vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, {})

  f:refresh()

  local marks = vim.api.nvim_buf_get_extmarks(f.buf, -1, 0, -1, { details = true })
  eq(#marks, 2)
  eq(vim.trim(marks[1][4].virt_text[1][1]), "First:")
  eq(vim.trim(marks[2][4].virt_text[1][1]), "Second:")
end

-- Driven by the event rather than by `:normal! o`, because TextChanged does not
-- fire while there is typeahead -- which a `:normal!` command always has.
T["form"]["repairs the shape when the text changes"] = function()
  local f = open()

  for _, event in ipairs({ "TextChanged", "TextChangedI", "TextChangedP" }) do
    vim.api.nvim_buf_set_lines(f.buf, -1, -1, false, { "stray" })
    vim.api.nvim_exec_autocmds(event, { buffer = f.buf })

    eq(vim.api.nvim_buf_line_count(f.buf), 2)
  end
end

T["form"]["keeps the cursor on a field after a repair"] = function()
  local f = open()
  vim.api.nvim_buf_set_lines(f.buf, -1, -1, false, { "stray" })
  vim.api.nvim_win_set_cursor(f.win, { 3, 0 })

  f:normalize()

  eq(vim.api.nvim_win_get_cursor(f.win)[1], 2)
end

---Replace a field's text the way typing does. `nvim_buf_set_lines` would take
---the line's label extmark with it, which changes what the layout measures.
---@param f tasksd.Form
---@param row integer
---@param text string
local function set_value(f, row, text)
  local line = vim.api.nvim_buf_get_lines(f.buf, row - 1, row, false)[1] or ""
  vim.api.nvim_buf_set_text(f.buf, row - 1, 0, row - 1, #line, { text })
end

T["form"]["opens at one row per field when nothing wraps"] = function()
  local f = open()
  eq(vim.api.nvim_win_get_config(f.win).height, 2)
end

-- Every label is padded to the widest, so both fields start 8 cells in.
local LABELS = #"Second: "

T["form"]["grows to fit a value that wraps"] = function()
  local f = open()
  local width = vim.api.nvim_win_get_config(f.win).width

  -- Wraps once: the label pushes it past a single row, not as far as three.
  set_value(f, 1, ("x"):rep(width))
  f:resize()

  eq(vim.api.nvim_win_get_config(f.win).height, 3)
end

T["form"]["leaves a row for the cursor when a value exactly fills one"] = function()
  local f = open()
  local width = vim.api.nvim_win_get_config(f.win).width

  set_value(f, 1, ("x"):rep(width - LABELS))
  f:focus(1)
  f:resize()

  eq(vim.api.nvim_win_get_config(f.win).height, 3)
end

T["form"]["fits itself into a narrower editor"] = function()
  local f = open()
  local columns = vim.o.columns

  vim.o.columns = 40
  f:fit()
  local narrow = vim.api.nvim_win_get_config(f.win)

  vim.o.columns = columns
  f:fit()
  local restored = vim.api.nvim_win_get_config(f.win)

  eq(narrow.width <= 36, true)
  eq(narrow.col <= 40 - narrow.width, true)
  -- Back to the width it wanted, once there is room for it again.
  eq(restored.width, math.min(80, columns - 4))
end

T["form"]["shrinks again when the value does"] = function()
  local f = open()
  local width = vim.api.nvim_win_get_config(f.win).width

  set_value(f, 1, ("x"):rep(2 * width))
  f:resize()
  set_value(f, 1, "one")
  f:resize()

  eq(vim.api.nvim_win_get_config(f.win).height, 2)
end

T["form"]["resizes as the text changes"] = function()
  local f = open()
  local width = vim.api.nvim_win_get_config(f.win).width

  set_value(f, 1, ("x"):rep(width))
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = f.buf })

  eq(vim.api.nvim_win_get_config(f.win).height > 2, true)
end

T["form"]["maps the configured keys buffer-locally"] = function()
  local f = open()
  local lhs = {}
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(f.buf, "i")) do
    lhs[keymap.lhs] = true
  end
  eq(lhs["<Tab>"], true)
  eq(lhs["<S-Tab>"], true)
  eq(lhs["<CR>"], true)
end

T["form"]["leaves an empty key unmapped"] = function()
  local f = form.open({
    title = "Test",
    keys = { next_field = "", submit = "<CR>" },
    fields = { { name = "only", label = "Only: " } },
    on_submit = function() end,
  })
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(f.buf, "i")) do
    eq(keymap.lhs, "<CR>")
  end
end

return T
