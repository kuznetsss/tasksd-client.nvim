---[snacks.nvim](https://github.com/folke/snacks.nvim)'s picker.
local M = {}

---Requiring `snacks` rather than `snacks.picker` directly: the picker's modules
---reach for the `Snacks` global, which only the top-level module installs.
---Loads snacks when the user has it lazy-loaded, which opening a picker would
---do a moment later anyway.
---@return table|nil
local function module()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return nil
  end
  local reached, picker = pcall(function()
    -- `enabled` is only ever false when the user turned the picker off in
    -- `Snacks.setup`; it is nil when they never mentioned it.
    if snacks.config.picker.enabled == false then
      return nil
    end
    return snacks.picker
  end)
  if not reached or type(picker) ~= "table" or type(picker.pick) ~= "function" then
    return nil
  end
  return picker
end

M.is_available = function()
  return module() ~= nil
end

---@param spec tasksd.picker.Spec
M.pick = function(spec)
  local picker = module()
  if not picker then
    return
  end

  picker.pick({
    title = spec.title,
    items = spec.items,
    -- No `source`: it is snacks' key for a *registered* picker's config, and
    -- this list is built here rather than found by one of theirs.
    layout = { preset = "select" },
    format = function(item)
      return vim.tbl_map(function(chunk)
        return { chunk.text, chunk.hl }
      end, item.chunks)
    end,
    confirm = function(self, item)
      self:close()
      if item and spec.on_choice then
        spec.on_choice(item.value)
      end
    end,
  })
end

return M
