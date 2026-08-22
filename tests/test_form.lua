local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local form = require("tasksd.form")
local start_task = require("tasksd.command.start_task")

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

T["split"] = new_set()

T["split"]["separates the executable from its arguments"] = function()
  local exe, args = start_task.split("cargo build --release")
  eq(exe, "cargo")
  eq(args, { "build", "--release" })
end

T["split"]["ignores surrounding and repeated whitespace"] = function()
  local exe, args = start_task.split("  ls   -la  ")
  eq(exe, "ls")
  eq(args, { "-la" })
end

T["split"]["reports an empty command"] = function()
  local exe, args = start_task.split("   ")
  eq(exe, nil)
  eq(args, {})
end

return T
