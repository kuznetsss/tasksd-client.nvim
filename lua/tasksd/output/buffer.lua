local task = require("tasksd.task")

---A bounded view of one task's output, held in a scratch buffer.
---
---Rows are addressed by the line number the daemon gave the line, never by
---where the text happens to sit: the ring drops lines off the top as it fills,
---so a gap fetched later still lands on the rows it reserved even though
---everything has shifted underneath it in the meantime.
---
---Nothing here opens a window or talks to the daemon. `tasksd.output` feeds it
---notifications and hands it whatever `task.get_output` came back with.
local M = {}

---Every output buffer carries it, so highlights and user autocommands can be
---pointed at task output and nothing else.
M.FILETYPE = "tasksd-output"

---Stands in for a line the daemon said was dropped, until it is fetched.
M.LOADING = "<loading output>"

---Stands in for a dropped line the daemon could no longer supply: its own
---buffer is bounded too, so a gap reported late may already be past recall.
M.LOST = "<output lost>"

---@param line string
---@return string
local function strip(line)
  -- The daemon reads with `read_line`, so the terminator is still attached, and
  -- `nvim_buf_set_lines` raises on any string holding a newline.
  return (line:gsub("\r?\n$", ""):gsub("[\r\n]", " "))
end

---One `task.output` notification, and one entry of a `task.get_output` result;
---see `docs/API.md` in tasksd.
---@class tasksd.output.Line
---@field line string
---@field line_number integer

---One `task.missed_output` notification.
---@class tasksd.output.Missed
---@field from_line integer
---@field missed integer

--------------------------------------------------------------------------------
-- Buffer object
--------------------------------------------------------------------------------

---Obtained from `M.new`.
---@class tasksd.output.Buffer
---@field buf integer
---@field max_lines integer
---@field package first integer|nil Line number sitting at row 0; nil until the first write.
---@field package rows integer Output rows held, which excludes the exit line.
---@field package blank boolean The buffer still holds only the line it was created with.
---@field package finished boolean The exit line has been written.
local Buffer = {}
Buffer.__index = Buffer

---@param from integer
---@param to integer
---@param lines string[]
function Buffer:replace(from, to, lines)
  -- A Neovim buffer cannot be empty: a fresh one holds a single empty line, and
  -- the first write has to replace it rather than push it down.
  if self.blank then
    from, to, self.blank = 0, -1, false
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, from, to, false, lines)
  vim.bo[self.buf].modifiable = false
end

---Drop the oldest rows once the ring is over its size.
function Buffer:trim()
  local extra = self.rows - self.max_lines
  if extra <= 0 then
    return
  end
  self:replace(0, extra, {})
  self.rows = self.rows - extra
  self.first = self.first + extra
end

---Put `lines` at output line numbers `[from_line, from_line + #lines)`.
---@param from_line integer
---@param lines string[]
function Buffer:write(from_line, lines)
  if #lines == 0 then
    return
  end
  self.first = self.first or from_line

  local row = from_line - self.first
  if row < 0 then
    -- The head of this batch has already been trimmed away; only its tail is
    -- still inside the ring.
    lines = vim.list_slice(lines, 1 - row)
    row = 0
    if #lines == 0 then
      return
    end
  end

  -- A hole can only open when a line goes missing with no `task.missed_output`
  -- to describe it. Filling it keeps every later line on the row its number
  -- says, which is the whole point of addressing rows this way.
  if row > self.rows then
    local padded = {}
    for _ = self.rows + 1, row do
      table.insert(padded, M.LOST)
    end
    lines, row = vim.list_extend(padded, lines), self.rows
  end

  self:replace(row, math.min(row + #lines, self.rows), lines)
  self.rows = math.max(self.rows, row + #lines)
  self:trim()
end

---@param params tasksd.output.Line
function Buffer:output(params)
  self:write(params.line_number, { strip(params.line) })
end

---Reserve a row per dropped line, so the output behind the gap still lands
---where its line number says. `Buffer:fill` puts the real text over them.
---@param params tasksd.output.Missed
function Buffer:missed(params)
  local lines = {}
  for _ = 1, params.missed do
    table.insert(lines, M.LOADING)
  end
  self:write(params.from_line, lines)
end

---Put fetched lines over the rows `Buffer:missed` reserved. The daemon answers
---with whatever part of the range it still holds, so anything it left out is
---marked lost rather than left loading for good.
---@param params tasksd.output.Missed The gap this was fetched for.
---@param lines tasksd.output.Line[]|nil A `task.get_output` result's `lines`.
function Buffer:fill(params, lines)
  local text = {}
  for _, entry in ipairs(lines or {}) do
    text[entry.line_number] = strip(entry.line)
  end

  local filled = {}
  for number = params.from_line, params.from_line + params.missed - 1 do
    table.insert(filled, text[number] or M.LOST)
  end
  self:write(params.from_line, filled)
end

---Write a line that is about the task rather than from it, after whatever
---output is held. It takes no row of its own, so output still lands in front of
---it.
---@param text string
function Buffer:note(text)
  self:replace(self.rows, self.rows, { ("[%s]"):format(text) })
end

---Write how the task ended, after its last line of output. Ignored the second
---time: the daemon sends one `task.exit`, but a resubscribe must not be able to
---append another.
---@param params tasksd.TaskExit
function Buffer:finish(params)
  if self.finished then
    return
  end
  self.finished = true
  self:note(task.exit_message(params))
end

function Buffer:close()
  if vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
end

--------------------------------------------------------------------------------
-- Creating
--------------------------------------------------------------------------------

---@class tasksd.output.buffer.Opts
---@field max_lines integer Rows kept before the oldest are dropped.
---@field name? string Buffer name, which is what a statusline shows.

---@param opts tasksd.output.buffer.Opts
---@return tasksd.output.Buffer
M.new = function(opts)
  vim.validate("max_lines", opts.max_lines, "number")
  vim.validate("name", opts.name, "string", true)
  assert(opts.max_lines >= 1, "max_lines must be at least 1")

  local buf = vim.api.nvim_create_buf(false, true)
  if opts.name then
    vim.api.nvim_buf_set_name(buf, opts.name)
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = M.FILETYPE

  return setmetatable({
    buf = buf,
    max_lines = math.floor(opts.max_lines),
    rows = 0,
    blank = true,
    finished = false,
  }, Buffer)
end

return M
