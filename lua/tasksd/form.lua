---A floating form: one editable buffer line per field, the field's label drawn
---beside it as inline virtual text. Knows nothing about tasks -- callers
---describe fields and receive a table of values.
local M = {}

local ns = vim.api.nvim_create_namespace("tasksd.form")

---Every form buffer carries it, so a completion plugin can be pointed at forms
---and nothing else.
M.FILETYPE = "tasksd-form"

-- Wide enough that an ordinary path or command line does not wrap on sight.
local MIN_WIDTH = 80

---Live forms, so `M.complete` can find the one it was invoked for. Entries are
---dropped when the buffer is wiped.
---@type table<integer, tasksd.Form>
local by_buf = {}

---@class tasksd.form.Field
---@field name string Key this field's value appears under in the submitted table.
---@field label string Drawn before the value; never part of the buffer text.
---@field value? string Initial value.
---@field complete? fun(before: string): integer, string[] `:h complete-functions` for one field: the text before the cursor in, the byte offset the match starts at and the candidates out.

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
---@field blink? boolean Offer this form's completion through blink.cmp when it is installed.

---@param fields tasksd.form.Field[]
---@return integer
local function label_width(fields)
  local width = 0
  for _, field in ipairs(fields) do
    width = math.max(width, vim.fn.strdisplaywidth(field.label))
  end
  return width
end

---Drawn from scratch each time: deleting a line takes its extmark with it, so
---a repaired buffer has lost some of them.
---@param buf integer
---@param fields tasksd.form.Field[]
local function draw_labels(buf, fields)
  local width = label_width(fields)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, field in ipairs(fields) do
    -- right_gravity=false keeps the label pinned before column 0; the default
    -- would let text typed at the start of the line slide in front of it.
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
      virt_text = { { ("%-" .. width .. "s"):format(field.label), "Title" } },
      virt_text_pos = "inline",
      right_gravity = false,
    })
  end
end

---Obtained from `M.open`.
---@class tasksd.Form
---@field buf integer
---@field win integer
---@field package fields tasksd.form.Field[]
---@field package on_submit fun(values: table<string, string>)
---@field package width integer Width it wants, before the editor's own width caps it.
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

---Put the buffer back into the shape a form expects and fit the window to it.
---Runs after every change: an edit can move the labels' extmarks without
---changing the line count at all (`cc`, `:m`), and only redrawing them
---unconditionally covers that.
function Form:refresh()
  self:normalize()
  draw_labels(self.buf, self.fields)
  self:resize()
end

---Restore one line per field. The buffer is an ordinary editable buffer, so
---`o`, `dd`, `J` and a linewise paste can all change how many lines it has;
---anything past the last field is dropped and anything missing is added back.
---Text that moved between fields is *not* recovered -- only the shape is.
function Form:normalize()
  local count = vim.api.nvim_buf_line_count(self.buf)
  if count == #self.fields then
    return
  end

  if count > #self.fields then
    vim.api.nvim_buf_set_lines(self.buf, #self.fields, -1, false, {})
  else
    local missing = {}
    for _ = count + 1, #self.fields do
      table.insert(missing, "")
    end
    vim.api.nvim_buf_set_lines(self.buf, count, count, false, missing)
  end

  local row = vim.api.nvim_win_get_cursor(self.win)[1]
  if row > #self.fields then
    self:focus(#self.fields)
  end
end

---Screen rows the fields need at the window's current width: a field wraps
---rather than scrolling out of sight, so a long value costs rows. Measured by
---Neovim, which is the only thing that knows how the labels, wrapping and any
---multi-cell characters actually lay out.
---@return integer
function Form:height()
  local rows =
    vim.api.nvim_win_text_height(self.win, { start_row = 0, end_row = #self.fields - 1 }).all

  -- A value that exactly fills its last row leaves the cursor on the next one,
  -- and measuring the text alone does not count where the cursor goes.
  local row = math.min(vim.api.nvim_win_get_cursor(self.win)[1], #self.fields)
  local line = vim.api.nvim_buf_get_lines(self.buf, row - 1, row, false)[1] or ""
  local filled = label_width(self.fields) + vim.fn.strdisplaywidth(line)
  if filled > 0 and filled % vim.api.nvim_win_get_config(self.win).width == 0 then
    rows = rows + 1
  end

  return rows
end

---Grow or shrink to fit what the fields hold now. Neovim has no self-sizing
---window, so this runs on every change; only the height moves, because a
---window that also shifted sideways as you typed would be unreadable.
function Form:resize()
  local height = math.max(1, math.min(self:height(), vim.o.lines - 6))
  if vim.api.nvim_win_get_config(self.win).height ~= height then
    vim.api.nvim_win_set_config(self.win, { height = height })
  end
end

---Take the editor's new size into account: clamp the width to it, re-centre,
---and refit the height at whatever width survived. Growing as the user types
---deliberately leaves the window where it is; a resized editor is the one time
---moving the whole thing is less jarring than leaving it half off-screen.
function Form:fit()
  local width = math.max(1, math.min(self.width, vim.o.columns - 4))
  if vim.api.nvim_win_get_config(self.win).width ~= width then
    vim.api.nvim_win_set_config(self.win, { width = width })
  end
  self:resize()

  local height = vim.api.nvim_win_get_config(self.win).height
  vim.api.nvim_win_set_config(self.win, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
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

---The buffers' `completefunc`, dispatching to whichever field the cursor is on.
---Reachable as `v:lua.require'tasksd.form'.complete`, which both Neovim's own
---`<C-x><C-u>` and blink's `complete_func` source accept.
---
---Vim calls this twice per completion and forbids moving the cursor in
---between, so recomputing rather than caching the first call's answer is safe.
---@param findstart 1|0
---@param base string
---@return integer|string[]
M.complete = function(findstart, base)
  local form = by_buf[vim.api.nvim_get_current_buf()]
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local field = form and form.fields[row]
  if not field or not field.complete then
    -- -3: leave completion mode without a message.
    return findstart == 1 and -3 or {}
  end

  local start, matches = field.complete(vim.api.nvim_get_current_line():sub(1, col))
  if findstart == 1 then
    return start
  end
  return vim.tbl_filter(function(match)
    return vim.startswith(match, base)
  end, matches)
end

---@param fields tasksd.form.Field[]
---@return boolean
local function completable(fields)
  for _, field in ipairs(fields) do
    if field.complete then
      return true
    end
  end
  return false
end

---@param fields tasksd.form.Field[]
---@return string[] lines, integer width
local function render(fields)
  local labels = label_width(fields)
  local lines, width = {}, 0
  for i, field in ipairs(fields) do
    lines[i] = field.value or ""
    width = math.max(width, labels + vim.fn.strdisplaywidth(lines[i]))
  end
  return lines, width
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

  local lines, content = render(opts.fields)
  local desired = math.max(content + 4, MIN_WIDTH)
  local width = math.max(1, math.min(desired, vim.o.columns - 4))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  draw_labels(buf, opts.fields)

  -- Opened at one row per field and grown by `Form:resize` below, so wrapping
  -- is measured against the width the window actually got.
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = #opts.fields,
    row = math.floor((vim.o.lines - #opts.fields) / 2) - 1,
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
    width = desired,
  }, Form)

  by_buf[buf] = form
  -- TextChangedP as well: with the popup menu open the other two do not fire,
  -- and a completion item can carry a newline.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    buffer = buf,
    callback = function()
      form:refresh()
    end,
  })
  -- Not buffer-local -- VimResized is about the editor -- so it outlives the
  -- form unless it removes itself, which a callback does by returning true.
  vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      if not vim.api.nvim_win_is_valid(form.win) then
        return true
      end
      form:fit()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      by_buf[buf] = nil
    end,
  })

  if completable(opts.fields) then
    vim.bo[buf].completefunc = "v:lua.require'tasksd.form'.complete"
    if opts.blink then
      require("tasksd.blink").register(M.FILETYPE)
    end
  end
  -- After the completefunc, so a FileType autocmd sees a finished buffer.
  vim.bo[buf].filetype = M.FILETYPE

  map(form, opts.keys)
  form:refresh()
  form:focus(1)
  vim.cmd.startinsert({ bang = true })

  return form
end

return M
