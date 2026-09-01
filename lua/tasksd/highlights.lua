---The highlight groups this plugin draws with, and what each one falls back to.
---
---Nothing here paints anything: a UI module names a `Tasksd*` group, and this
---is where that name is given a meaning. Keeping every group in one table is
---what makes the set discoverable -- a user theming the plugin has one file to
---read, and one prefix to override.
local M = {}

---Every group is defined with `default = true`: a definition the user or their
---colorscheme made wins over the fallback below, and Neovim keeps a default
---one across the `:highlight clear` a colorscheme starts with.
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
  split = "Normal:TasksdNormal",
}

M.apply = function()
  for name, spec in pairs(M.groups) do
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
  M.apply()
end

return M
