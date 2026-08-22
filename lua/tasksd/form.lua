---A floating form: one editable buffer line per field, the field's label drawn
---beside it as inline virtual text. Knows nothing about tasks -- callers
---describe fields and receive a table of values.
local M = {}

local ns = vim.api.nvim_create_namespace("tasksd.form")

---@class tasksd.form.Field
---@field name string Key this field's value appears under in the submitted table.
---@field label string Drawn before the value; never part of the buffer text.
---@field value? string Initial value.

---Each entry is a `{lhs}`; nil leaves that action unmapped.
---@class tasksd.form.Keys
---@field next_field? string
---@field prev_field? string
---@field submit? string
---@field cancel? string

---@class tasksd.form.Opts
---@field title string
---@field fields tasksd.form.Field[]
---@field keys tasksd.form.Keys
---@field on_submit fun(values: table<string, string>)

---Obtained from `M.open`.
---@class tasksd.Form
---@field buf integer
---@field win integer
---@field package fields tasksd.form.Field[]
---@field package on_submit fun(values: table<string, string>)
local Form = {}
Form.__index = Form

---@return table<string, string>
function Form:values()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, #self.fields, false)
  local values = {}
  for i, field in ipairs(self.fields) do
    values[field.name] = vim.trim(lines[i] or "")
  end
  return values
end

---1-based index of the field the cursor is on.
---@return integer
function Form:current()
  return vim.api.nvim_win_get_cursor(self.win)[1]
end

---Put the cursor at the end of field `index`, wrapping around both ends.
---@param index integer
function Form:focus(index)
  local count = #self.fields
  index = (index - 1) % count + 1
  local line = vim.api.nvim_buf_get_lines(self.buf, index - 1, index, false)[1] or ""
  vim.api.nvim_win_set_cursor(self.win, { index, #line })
end

function Form:close()
  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
end

---Closes first, so `on_submit` is free to open windows or prompt without the
---form still holding focus.
function Form:submit()
  local values = self:values()
  self:close()
  self.on_submit(values)
end

---@param fields tasksd.form.Field[]
---@return string[] lines, integer label_width, integer width
local function render(fields)
  local label_width = 0
  for _, field in ipairs(fields) do
    label_width = math.max(label_width, vim.fn.strdisplaywidth(field.label))
  end

  local lines, width = {}, 0
  for i, field in ipairs(fields) do
    lines[i] = field.value or ""
    width = math.max(width, label_width + vim.fn.strdisplaywidth(lines[i]))
  end
  return lines, label_width, width
end

---@param form tasksd.Form
---@param keys tasksd.form.Keys
local function map(form, keys)
  ---@param modes string[]
  ---@param lhs string|nil
  ---@param rhs function
  local function set(modes, lhs, rhs)
    if lhs and lhs ~= "" then
      vim.keymap.set(modes, lhs, rhs, { buffer = form.buf, nowait = true })
    end
  end

  set({ "n", "i" }, keys.next_field, function()
    form:focus(form:current() + 1)
  end)
  set({ "n", "i" }, keys.prev_field, function()
    form:focus(form:current() - 1)
  end)
  set({ "n", "i" }, keys.submit, function()
    form:submit()
  end)
  -- Normal mode only: in insert mode <Esc> has to keep meaning <Esc>.
  set({ "n" }, keys.cancel, function()
    form:close()
  end)
end

---@param opts tasksd.form.Opts
---@return tasksd.Form
M.open = function(opts)
  vim.validate("title", opts.title, "string")
  vim.validate("fields", opts.fields, "table")
  vim.validate("keys", opts.keys, "table")
  vim.validate("on_submit", opts.on_submit, "callable")
  assert(#opts.fields > 0, "a form needs at least one field")

  local lines, label_width, width = render(opts.fields)
  width = math.min(math.max(width + 4, 50), vim.o.columns - 4)
  local height = #opts.fields

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for i, field in ipairs(opts.fields) do
    -- right_gravity=false keeps the label pinned before column 0; the default
    -- would let text typed at the start of the line slide in front of it.
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
      virt_text = { { ("%-" .. label_width .. "s"):format(field.label), "Title" } },
      virt_text_pos = "inline",
      right_gravity = false,
    })
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true

  local form = setmetatable({
    buf = buf,
    win = win,
    fields = opts.fields,
    on_submit = opts.on_submit,
  }, Form)

  map(form, opts.keys)
  form:focus(1)
  vim.cmd.startinsert({ bang = true })

  return form
end

return M
