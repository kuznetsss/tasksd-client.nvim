---The highlight groups this plugin draws with, and what each one falls back to.
---
---Nothing here paints anything: a UI module names a `Tasksd*` group, and this
---is where that name is given a meaning. Keeping every group in one table is
---what makes the set discoverable -- a user theming the plugin has one file to
---read, and one prefix to override.
local config = require("tasksd.config")

local M = {}

---Every group is defined with `default = true`: a definition the user or their
---colorscheme made wins over the fallback below, and Neovim restores a default
---*link* across the `:highlight clear` a colorscheme starts with. A default
---colour it does not restore -- see `M.ensure`.
---@type table<string, vim.api.keyset.highlight>
M.groups = {
  -- Window chrome, through 'winhighlight'.
  TasksdNormal = { link = "Normal" },
  TasksdNormalFloat = { link = "NormalFloat" },
  TasksdBorder = { link = "FloatBorder" },
  TasksdTitle = { link = "FloatTitle" },

  TasksdFormLabel = { link = "Title" },
  TasksdFormToggleOn = { link = "DiagnosticOk" },
  TasksdFormToggleOff = { link = "Comment" },

  -- Lines the plugin puts in an output buffer itself, rather than lines the
  -- task wrote. Output is left alone: it is the task's, and a group over it
  -- would fight whatever the user has colouring the buffer.
  TasksdOutputNote = { link = "Comment" },
  TasksdOutputExit = { link = "DiagnosticOk" },
  TasksdOutputExitFailed = { link = "DiagnosticError" },
  TasksdOutputLoading = { link = "Comment" },
  TasksdOutputLost = { link = "DiagnosticWarn" },

  TasksdTaskId = { link = "Number" },
  TasksdTaskRunning = { link = "DiagnosticOk" },
  TasksdTaskFinished = { link = "Comment" },
  -- Empty rather than linked to `Normal`: the command is the row's own text and
  -- should read as text. `Normal` would paint its background over a float's.
  TasksdTaskCommand = {},
  TasksdTaskDir = { link = "Directory" },
}

---'winhighlight' for a window this plugin owns, by what kind of window it is.
---Neovim draws a window with its own groups, so this is the only way to give
---the user a `Tasksd*` handle on the background, the border and the title.
---@type table<"float"|"split", string>
M.WINHIGHLIGHT = {
  float = "NormalFloat:TasksdNormalFloat,FloatBorder:TasksdBorder,FloatTitle:TasksdTitle",
  -- `NormalNC` as well: Neovim paints an unfocused window with it, so a
  -- colorscheme that defines it would take the panel's background back the
  -- moment the focus left.
  split = "Normal:TasksdNormal,NormalNC:TasksdNormal",
}

---How much darker than `Normal` a shaded background is: `true` for the usual
---amount, `false` for none, or a percentage of your own such as "50%".
---@alias tasksd.Shade boolean|string

---Enough to read as a panel without looking like a different colorscheme.
---toggleterm.nvim's `shading_factor`, which this is taken from, settled on it.
local DEFAULT_SHADE = 30

---@param spec tasksd.Shade|nil
---@return number|nil percent
local function percentage(spec)
  if spec == nil or spec == false then
    return nil
  end
  if spec == true then
    return DEFAULT_SHADE
  end
  local percent = tonumber(tostring(spec):match("^(%d+%.?%d*)%%$"))
  assert(
    percent,
    ("`%s` is not a shade: expected true, false, or a percentage"):format(tostring(spec))
  )
  return percent
end

---@param rgb integer
---@param percent number
---@return integer
local function darken(rgb, percent)
  local factor = math.max(0, 100 - percent) / 100
  local red = math.floor(rgb / 0x10000) % 0x100
  local green = math.floor(rgb / 0x100) % 0x100
  local blue = rgb % 0x100
  return math.floor(red * factor) * 0x10000
    + math.floor(green * factor) * 0x100
    + math.floor(blue * factor)
end

---The background `TasksdNormal` takes instead of its link.
---@return integer|nil rgb nil when nothing was asked for, or `Normal` has no
---background to darken -- a transparent colorscheme, where a shade would paint
---over what the user wanted to see through.
M.shade = function()
  local percent = percentage(config.current.output.shade)
  if not percent then
    return nil
  end
  local bg = vim.api.nvim_get_hl(0, { name = "Normal" }).bg
  return bg and darken(bg, percent) or nil
end

M.apply = function()
  local groups = M.groups
  local bg = M.shade()
  if bg then
    groups = vim.tbl_extend("force", groups, { TasksdNormal = { bg = bg } })
  end
  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end

local applied = false

---Define the groups, on the way to drawing something with them.
M.ensure = function()
  if applied then
    return
  end
  applied = true
  -- A shade is a colour rather than a link, and `:highlight clear` -- which
  -- every colorscheme starts with -- drops a default colour where it restores a
  -- default link. Recomputing is what makes a shade follow the colorscheme, and
  -- it lands because that same clear left the group empty for a `default` one.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("tasksd.highlights", { clear = true }),
    callback = M.apply,
  })
  M.apply()
end

return M
