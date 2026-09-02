local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local config = require("tasksd.config")
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

T["shade()"] = new_set({
  hooks = {
    pre_case = function()
      vim.api.nvim_set_hl(0, "Normal", { bg = "#204080" })
    end,
    post_case = function()
      config.current.output.shade = config.default.output.shade
    end,
  },
})

T["shade()"]["is nothing when off"] = function()
  config.current.output.shade = false
  eq(highlights.shade(), nil)
end

T["shade()"]["darkens Normal's background by a percentage"] = function()
  config.current.output.shade = "50%"
  eq(highlights.shade(), tonumber("102040", 16))
end

T["shade()"]["takes an amount of its own from true"] = function()
  config.current.output.shade = true
  local bg = highlights.shade()
  eq(type(bg), "number")
  eq(bg < tonumber("204080", 16), true)
end

T["shade()"]["rejects anything that is not a percentage"] = function()
  config.current.output.shade = "30"
  MiniTest.expect.error(highlights.shade, "not a shade")
end

T["shade()"]["is nothing when Normal is transparent"] = function()
  vim.api.nvim_set_hl(0, "Normal", {})
  config.current.output.shade = true
  eq(highlights.shade(), nil)
end

T["shade()"]["gives TasksdNormal a background instead of its link"] = function()
  config.current.output.shade = "50%"
  highlights.apply()
  eq(hl("TasksdNormal").link, nil)
  eq(hl("TasksdNormal").bg, tonumber("102040", 16))
end

T["shade()"]["follows the colorscheme"] = function()
  local before = vim.g.colors_name
  vim.cmd.colorscheme("habamax")
  highlights.ensure()
  local shaded = hl("TasksdNormal").bg
  eq(shaded, highlights.shade())

  vim.cmd.colorscheme("desert")
  eq(hl("TasksdNormal").bg, highlights.shade())
  eq(hl("TasksdNormal").bg ~= shaded, true)
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
