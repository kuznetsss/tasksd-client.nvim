local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local highlights = require("tasksd.highlights")

---@param name string
---@return table
local function hl(name)
  return vim.api.nvim_get_hl(0, { name = name })
end

local T = new_set({
  hooks = {
    -- Cases below define groups by hand; `:highlight clear {group}` puts one
    -- back to the default this module gave it.
    post_case = function()
      for name in pairs(highlights.groups) do
        vim.cmd.highlight({ "clear", name })
      end
    end,
  },
})

T["apply()"] = new_set()

T["apply()"]["defines every group"] = function()
  highlights.apply()
  for name in pairs(highlights.groups) do
    eq(type(hl(name)), "table")
  end
end

T["apply()"]["links a group to its fallback"] = function()
  highlights.apply()
  eq(hl("TasksdTaskId").link, "Number")
  eq(hl("TasksdBorder").link, "FloatBorder")
end

T["apply()"]["leaves a group the user has already defined alone"] = function()
  vim.api.nvim_set_hl(0, "TasksdTaskId", { fg = "#ff0000" })
  highlights.apply()
  eq(hl("TasksdTaskId").link, nil)
  eq(hl("TasksdTaskId").fg, tonumber("ff0000", 16))
end

T["apply()"]["survives a colorscheme, links and all"] = function()
  highlights.apply()
  local before = vim.g.colors_name
  vim.cmd.colorscheme("habamax")
  eq(hl("TasksdTaskId").link, "Number")
  if before then
    vim.cmd.colorscheme(before)
  end
end

T["WINHIGHLIGHT"] = new_set()

T["WINHIGHLIGHT"]["only names groups this module defines"] = function()
  local unknown = {}
  for _, value in pairs(highlights.WINHIGHLIGHT) do
    for _, pair in ipairs(vim.split(value, ",")) do
      local target = vim.split(pair, ":")[2]
      if not highlights.groups[target] then
        table.insert(unknown, target)
      end
    end
  end
  eq(unknown, {})
end

return T
