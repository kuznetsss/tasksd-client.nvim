local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local config = require("tasksd.config")
local log = require("tasksd.log")
local save = require("tasksd.save")

local dir = vim.fn.tempname()

---A file on disk holding `contents`, opened in a buffer that is not current.
---@param name string
---@param contents string
---@return integer buf, string path
local function file(name, contents)
  local path = ("%s/%s"):format(dir, name)
  vim.fn.writefile({ contents }, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf, path
end

---@param buf integer
---@param line string
local function edit(buf, line)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
end

---@param path string
---@return string
local function on_disk(path)
  return (vim.fn.readfile(path) or {})[1]
end

local T = new_set({
  hooks = {
    pre_case = function()
      config.current = vim.deepcopy(config.default)
      vim.fn.mkdir(dir, "p")
    end,
    post_case = function()
      -- `bwipeout!` rather than `bdelete`: a buffer left modified would make
      -- the next case's `:wall` write a file this one created.
      vim.cmd("silent! %bwipeout!")
      vim.fn.delete(dir, "rf")
    end,
  },
})

T["all()"] = new_set()

T["all()"]["writes nothing while auto_save is off"] = function()
  local buf, path = file("off.txt", "original")
  edit(buf, "changed")

  save.all()

  eq(on_disk(path), "original")
  eq(vim.bo[buf].modified, true)
end

T["all()"]["writes every modified buffer, not just the current one"] = function()
  local a, a_path = file("a.txt", "original")
  local b, b_path = file("b.txt", "original")
  edit(a, "changed-a")
  edit(b, "changed-b")
  config.current.auto_save = true

  -- No window shows either file: the start-task form is a scratch buffer, so
  -- this is the situation `auto_save` actually runs in.
  save.all()

  eq(on_disk(a_path), "changed-a")
  eq(on_disk(b_path), "changed-b")
  eq(vim.bo[a].modified, false)
  eq(vim.bo[b].modified, false)
end

T["all()"]["leaves an unmodified buffer alone"] = function()
  local _, path = file("untouched.txt", "original")
  config.current.auto_save = true
  local before = vim.fn.getftime(path)

  save.all()

  eq(vim.fn.getftime(path), before)
end

-- E141: `:wall` raises on this, and a stray `:enew` must not be able to stop a
-- task from ever starting.
T["all()"]["warns but keeps going when a modified buffer has no name"] = function()
  local buf, path = file("named.txt", "original")
  edit(buf, "changed")
  local unnamed = vim.api.nvim_create_buf(true, false)
  edit(unnamed, "scratch")
  config.current.auto_save = true

  local original = log.notify
  local messages = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  log.notify = function(msg, level)
    table.insert(messages, { msg = msg, level = level })
  end
  local ok = pcall(save.all)
  log.notify = original

  eq(ok, true)
  eq(on_disk(path), "changed")
  eq(#messages, 1)
  eq(messages[1].level, vim.log.levels.WARN)
  eq(messages[1].msg:match("E141") ~= nil, true)
end

return T
