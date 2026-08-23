local config = require("tasksd.config")

---Choosing one thing out of a list, without caring which picker plugin does it.
---
---A backend is an adapter and nothing more: layout, alignment and highlighting
---happen here, once, so a second picker costs an adapter rather than a
---reimplementation. Nothing in this directory knows what a task is.
local M = {}

---A piece of a line as its caller describes it.
---@class tasksd.picker.Column
---@field text string
---@field hl? string A highlight group; backends that cannot colour ignore it.
---@field align? "left"|"right" Within its column. Defaults to left.

---A piece of a line after alignment: padded, and no longer free to move.
---@class tasksd.picker.Chunk
---@field text string
---@field hl? string

---@class tasksd.picker.Row
---@field value any Handed back to `on_choice` when this row is picked.
---@field columns tasksd.picker.Column[]

---`text` and `chunks` are two views of the same laid-out line, so a backend
---that cannot colour still shows the same columns.
---@class tasksd.picker.Item
---@field value any
---@field text string Also what the fuzzy matcher sees.
---@field chunks tasksd.picker.Chunk[]

---@class tasksd.picker.Spec
---@field title string
---@field items tasksd.picker.Item[]
---@field on_choice? fun(value: any) Not called when the user cancels.

---`is_available` is separate so `picker = "auto"` can probe a backend without
---opening one.
---@class tasksd.picker.Backend
---@field is_available fun(): boolean
---@field pick fun(spec: tasksd.picker.Spec)

local GAP = "  "

---Pad each column to the widest cell in it, and render every row twice: as
---chunks and as one string.
---
---Widths are in display cells rather than bytes, so a working directory with
---non-ASCII in it still lines up.
---@param rows tasksd.picker.Row[]
---@return tasksd.picker.Item[]
M.align = function(rows)
  local widths = {}
  for _, row in ipairs(rows) do
    for i, column in ipairs(row.columns) do
      widths[i] = math.max(widths[i] or 0, vim.fn.strdisplaywidth(column.text))
    end
  end

  local items = {}
  for _, row in ipairs(rows) do
    local chunks = {}
    for i, column in ipairs(row.columns) do
      local last = i == #row.columns
      local padding = string.rep(" ", widths[i] - vim.fn.strdisplaywidth(column.text))
      local text = column.text
      if column.align == "right" then
        text = padding .. text
      elseif not last then
        text = text .. padding
      end
      -- Padding between columns is its own chunk so that a highlight covers
      -- the text and not the gap after it.
      table.insert(chunks, { text = text, hl = column.hl })
      if not last then
        table.insert(chunks, { text = GAP })
      end
    end

    local texts = vim.tbl_map(function(chunk)
      return chunk.text
    end, chunks)
    table.insert(items, { value = row.value, text = table.concat(texts), chunks = chunks })
  end
  return items
end

---@type table<string, tasksd.picker.Backend>
M.backends = {
  select = require("tasksd.picker.select"),
  snacks = require("tasksd.picker.snacks"),
}

-- What `auto` tries, in order. `select` is always available, so this never
-- runs out.
local AUTO = { "snacks", "select" }

---Sorted, so error messages are stable.
---@return string[]
M.names = function()
  local names = vim.tbl_keys(M.backends)
  table.sort(names)
  return names
end

---@param setting any The `picker` config value.
---@return tasksd.picker.Backend|nil backend, string|nil err
M.resolve = function(setting)
  if type(setting) == "function" then
    return {
      is_available = function()
        return true
      end,
      pick = setting,
    },
      nil
  end

  if setting == "auto" then
    for _, name in ipairs(AUTO) do
      local backend = M.backends[name]
      if backend.is_available() then
        return backend, nil
      end
    end
    return nil, "no picker is available"
  end

  local backend = M.backends[setting]
  if not backend then
    return nil,
      ('unknown picker `%s`, expected a function, "auto", or one of: %s'):format(
        tostring(setting),
        table.concat(M.names(), ", ")
      )
  end
  if not backend.is_available() then
    return nil, ("picker `%s` is not installed"):format(setting)
  end
  return backend, nil
end

---Open the configured picker. Reports rather than notifying, like the other
---non-edge modules: what to say about an unusable `picker` setting belongs to
---the command that asked.
---@param spec tasksd.picker.Spec
---@return boolean ok, string|nil err
M.pick = function(spec)
  local backend, err = M.resolve(config.current.picker)
  if not backend then
    return false, err
  end
  backend.pick(spec)
  return true, nil
end

return M
