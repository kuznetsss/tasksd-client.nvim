local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local buffer = require("tasksd.output.buffer")

---@type tasksd.output.Buffer[]
local opened = {}

---@param max_lines integer|nil
---@return tasksd.output.Buffer
local function new(max_lines)
  local b = buffer.new({ max_lines = max_lines or 100 })
  table.insert(opened, b)
  return b
end

---@param b tasksd.output.Buffer
---@return string[]
local function lines(b)
  return vim.api.nvim_buf_get_lines(b.buf, 0, -1, false)
end

---Output as it comes off the wire, terminator and all.
---@param b tasksd.output.Buffer
---@param from integer
---@param texts string[]
local function output(b, from, texts)
  for i, text in ipairs(texts) do
    b:output({ task_id = 1, line = text .. "\n", line_number = from + i - 1 })
  end
end

---The group each row is drawn in, by 1-based row. Rows carrying no mark -- the
---task's own output -- are absent.
---@param b tasksd.output.Buffer
---@return table<integer, string>
local function marks(b)
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(b.buf, -1, 0, -1, { details = true })) do
    found[mark[2] + 1] = mark[4].hl_group
  end
  return found
end

local T = new_set({
  hooks = {
    post_case = function()
      for _, b in ipairs(opened) do
        b:close()
      end
      opened = {}
    end,
  },
})

T["output()"] = new_set()

T["output()"]["replaces the line a fresh buffer is created with"] = function()
  local b = new()
  output(b, 0, { "one" })
  eq(lines(b), { "one" })
end

T["output()"]["strips the terminator the daemon leaves attached"] = function()
  local b = new()
  b:output({ task_id = 1, line = "one\r\n", line_number = 0 })
  b:output({ task_id = 1, line = "two", line_number = 1 })
  eq(lines(b), { "one", "two" })
end

T["output()"]["keeps a newline out of the buffer text"] = function()
  local b = new()
  b:output({ task_id = 1, line = "one\ntwo\n", line_number = 0 })
  eq(lines(b), { "one two" })
end

T["output()"]["starts from whatever line number it is subscribed at"] = function()
  local b = new()
  output(b, 500, { "one", "two" })
  eq(lines(b), { "one", "two" })
end

T["output()"]["leaves the buffer unmodifiable"] = function()
  local b = new()
  output(b, 0, { "one" })
  eq(vim.bo[b.buf].modifiable, false)
  eq(vim.bo[b.buf].filetype, buffer.FILETYPE)
end

T["ring"] = new_set()

T["ring"]["drops the oldest lines once it is full"] = function()
  local b = new(3)
  output(b, 0, { "one", "two", "three", "four", "five" })
  eq(lines(b), { "three", "four", "five" })
end

T["ring"]["keeps addressing rows by line number after trimming"] = function()
  local b = new(3)
  output(b, 0, { "one", "two", "three", "four" })
  -- Line 3 is the last row; writing it again has to land there and not append.
  output(b, 3, { "four again" })
  eq(lines(b), { "two", "three", "four again" })
end

T["missed_output"] = new_set()

T["missed_output"]["reserves a row per dropped line"] = function()
  local b = new()
  b:missed({ from_line = 0, missed = 2 })
  eq(lines(b), { buffer.LOADING, buffer.LOADING })
end

T["missed_output"]["keeps later output on the rows its numbers say"] = function()
  local b = new()
  output(b, 0, { "one" })
  b:missed({ from_line = 1, missed = 2 })
  output(b, 3, { "four" })
  eq(lines(b), { "one", buffer.LOADING, buffer.LOADING, "four" })
end

T["missed_output"]["fills a hole nothing described, so rows keep their numbers"] = function()
  local b = new()
  output(b, 0, { "one" })
  output(b, 3, { "four" })
  eq(lines(b), { "one", buffer.LOST, buffer.LOST, "four" })
end

T["fill()"] = new_set()

T["fill()"]["puts fetched lines over the placeholders"] = function()
  local b = new()
  local gap = { from_line = 1, missed = 2 }
  b:missed(gap)
  output(b, 3, { "four" })
  b:fill(gap, {
    { line = "two\n", line_number = 1 },
    { line = "three\n", line_number = 2 },
  })
  eq(lines(b), { "two", "three", "four" })
end

T["fill()"]["marks what the daemon could not supply as lost"] = function()
  local b = new()
  local gap = { from_line = 0, missed = 3 }
  b:missed(gap)
  b:fill(gap, { { line = "three\n", line_number = 2 } })
  eq(lines(b), { buffer.LOST, buffer.LOST, "three" })
end

T["fill()"]["marks the whole gap lost when the daemon answers with nothing"] = function()
  local b = new()
  local gap = { from_line = 0, missed = 2 }
  b:missed(gap)
  b:fill(gap, nil)
  eq(lines(b), { buffer.LOST, buffer.LOST })
end

T["fill()"]["writes only the part of the gap the ring still holds"] = function()
  local b = new(5)
  local gap = { from_line = 0, missed = 2 }
  b:missed(gap)
  output(b, 2, { "three", "four", "five", "six" })
  -- Six rows into a ring of five: the first placeholder has gone over the top.
  eq(lines(b), { buffer.LOADING, "three", "four", "five", "six" })

  b:fill(gap, {
    { line = "one\n", line_number = 0 },
    { line = "two\n", line_number = 1 },
  })
  eq(lines(b), { "two", "three", "four", "five", "six" })
end

T["fill()"]["does nothing when the gap has scrolled away entirely"] = function()
  local b = new(2)
  local gap = { from_line = 0, missed = 2 }
  b:missed(gap)
  output(b, 2, { "three", "four" })
  b:fill(gap, { { line = "one\n", line_number = 0 } })
  eq(lines(b), { "three", "four" })
end

T["finish()"] = new_set()

T["finish()"]["writes how the task ended after its last line"] = function()
  local b = new()
  output(b, 0, { "one" })
  b:finish({ task_id = 7, exit_code = 2, signal = vim.NIL })
  eq(lines(b), { "one", "[task 7 exited with code 2]" })
end

T["finish()"]["writes into a buffer that never saw any output"] = function()
  local b = new()
  b:finish({ task_id = 7, exit_code = 0, signal = vim.NIL })
  eq(lines(b), { "[task 7 finished]" })
end

T["finish()"]["reports a signal rather than a code"] = function()
  local b = new()
  b:finish({ task_id = 7, exit_code = vim.NIL, signal = 9 })
  eq(lines(b), { "[task 7 was killed by signal 9]" })
end

T["finish()"]["writes the line once, however often it is told"] = function()
  local b = new()
  b:finish({ task_id = 7, exit_code = 0, signal = vim.NIL })
  b:finish({ task_id = 7, exit_code = 0, signal = vim.NIL })
  eq(lines(b), { "[task 7 finished]" })
end

T["finish()"]["leaves room for a gap filled after the task ended"] = function()
  local b = new()
  local gap = { from_line = 0, missed = 1 }
  b:missed(gap)
  output(b, 1, { "two" })
  b:finish({ task_id = 7, exit_code = 0, signal = vim.NIL })
  b:fill(gap, { { line = "one\n", line_number = 0 } })
  eq(lines(b), { "one", "two", "[task 7 finished]" })
end

T["highlights"] = new_set()

T["highlights"]["colours a placeholder and leaves output alone"] = function()
  local b = new()
  output(b, 0, { "one" })
  b:missed({ from_line = 1, missed = 2 })
  eq(marks(b), { [2] = "TasksdOutputLoading", [3] = "TasksdOutputLoading" })
end

T["highlights"]["colours a line the daemon could not supply"] = function()
  local b = new()
  local gap = { from_line = 0, missed = 2 }
  b:missed(gap)
  b:fill(gap, { { line = "one\n", line_number = 0 } })
  eq(marks(b), { [2] = "TasksdOutputLost" })
end

T["highlights"]["takes the mark off a placeholder that was filled"] = function()
  local b = new()
  local gap = { from_line = 0, missed = 1 }
  b:missed(gap)
  b:fill(gap, { { line = "one\n", line_number = 0 } })
  eq(marks(b), {})
end

-- A mark left on a trimmed row would collapse onto the row that took its place,
-- colouring output the task wrote.
T["highlights"]["drops the marks of rows the ring trimmed away"] = function()
  local b = new(2)
  b:missed({ from_line = 0, missed = 2 })
  output(b, 2, { "three", "four" })
  eq(lines(b), { "three", "four" })
  eq(marks(b), {})
end

T["highlights"]["tells a clean exit from a failed one"] = function()
  local ok, failed, signalled = new(), new(), new()
  ok:finish({ task_id = 1, exit_code = 0, signal = vim.NIL })
  failed:finish({ task_id = 2, exit_code = 1, signal = vim.NIL })
  signalled:finish({ task_id = 3, exit_code = vim.NIL, signal = 9 })

  eq(marks(ok), { [1] = "TasksdOutputExit" })
  eq(marks(failed), { [1] = "TasksdOutputExitFailed" })
  eq(marks(signalled), { [1] = "TasksdOutputExitFailed" })
end

T["highlights"]["colours a note that is not about an exit"] = function()
  local b = new()
  b:note("task 7 has already finished")
  eq(marks(b), { [1] = "TasksdOutputNote" })
end

T["close()"] = new_set()

T["close()"]["deletes the buffer"] = function()
  local b = new()
  output(b, 0, { "one" })
  b:close()
  eq(vim.api.nvim_buf_is_valid(b.buf), false)
end

return T
