local M = {}

M.default = {
  daemon = {
    path = "", -- path to tasksd executable
    thread_number = 2,
    task_buffer_size = 10000, -- lines
    graceful_period = 5, -- seconds
    log_file = nil, -- logging disabled by default
    socket = "global", -- 'session' or function()->string
    detached = true,
  },
}

M.current = vim.deepcopy(M.default)

---@param opts table|nil
M.setup = function(opts)
  M.current = vim.tbl_deep_extend("force", M.default, opts or {})
end

return M
