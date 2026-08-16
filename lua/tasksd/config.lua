local M = {}

M.default = {
  daemon = {
    path = "", -- path to tasksd executable
    thread_number = 2,
    task_buffer_size = 10000, -- lines
    graceful_period = 5, -- seconds
    log_file = nil, -- logging disabled by default
    -- Which daemon to talk to; see `tasksd.socket`.
    --   'global'        -- one daemon for every Neovim instance
    --   'nvim_instance' -- one daemon per Neovim instance
    --   'pwd'           -- one daemon per working directory
    --   'project'       -- one daemon per version control root above it
    --   function() -> string -- a path of your own
    socket = "global",
    detached = true,
  },
}

M.current = vim.deepcopy(M.default)

---@param opts table|nil
M.setup = function(opts)
  M.current = vim.tbl_deep_extend("force", M.default, opts or {})
end

return M
