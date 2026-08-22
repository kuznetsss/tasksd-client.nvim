---Offering the form's `completefunc` through blink.cmp.
---
---blink never consults `completefunc` on its own -- its sources are its own
---list. It does ship one that wraps a `completefunc`
---(`blink.cmp.sources.complete_func`), but nothing registers it, so this does:
---one provider, enabled for the form's filetype only, added to whatever the
---user already has rather than replacing it.
local M = {}

local SOURCE_ID = "tasksd_form"

-- blink asserts on a duplicate provider id, and its per-filetype list is
-- appended to rather than replaced, so this happens once per session.
local registered = false

---@param filetype string
---@return boolean registered False when blink is absent or too old to ask.
M.register = function(filetype)
  if registered then
    return true
  end

  -- Loads blink when the user has it lazy-loaded. The form enters insert mode
  -- immediately afterwards, which would load it a moment later anyway.
  local ok, blink = pcall(require, "blink.cmp")
  if not ok or type(blink.add_source_provider) ~= "function" then
    return false
  end

  blink.add_source_provider(SOURCE_ID, {
    name = "tasksd",
    module = "blink.cmp.sources.complete_func",
    opts = {
      complete_func = function()
        return vim.bo.completefunc
      end,
    },
  })
  blink.add_filetype_source(filetype, SOURCE_ID)

  registered = true
  return true
end

---Intended for tests.
M.reset = function()
  registered = false
end

return M
