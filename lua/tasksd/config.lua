local M = {}

M.default = {}

M.config = vim.deepcopy(M.default)

---@param opts table|nil
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", M.default, opts or {})
end

return M
