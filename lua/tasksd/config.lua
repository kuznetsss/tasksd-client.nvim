local M = {}

M.default = {
  daemon = {
    path = "",
    thread_number = 2,
    task_buffer_size = 10000, -- lines
    graceful_period = 5, -- seconds
    log_file = nil,
    -- Which daemon to talk to; see `tasksd.socket`.
    --   'global'        -- one daemon for every Neovim instance
    --   'nvim_instance' -- one daemon per Neovim instance
    --   'pwd'           -- one daemon per working directory
    --   'project'       -- one daemon per version control root above it
    --   function() -> string -- a path of your own
    socket = "project",
    detached = true,
  },
  form = {
    -- Register a blink.cmp source for the form's completion when blink is
    -- installed; see `tasksd.blink`. `<C-x><C-u>` works either way.
    blink = true,
    -- Keys inside the floating input form; see `tasksd.form`. An empty string
    -- leaves that action unmapped.
    keys = {
      next_field = "<Tab>",
      prev_field = "<S-Tab>",
      toggle = "<Space>",
      submit = "<CR>",
      cancel = "<Esc>",
    },
  },
  output = {
    -- Where the output window opens; see `tasksd.output.window`.
    --   'left' | 'right' | 'top' | 'bottom' | 'float'
    position = "bottom",
    -- A count of lines/columns or a percentage of the editor. A split uses
    -- only the dimension its position implies; a float uses both, and can be
    -- given them separately as `{ width = ..., height = ... }`.
    size = "30%",
    max_lines = 10000, -- lines
    -- Whether new output moves the cursor to the last line when it was
    -- already there. Off leaves the view wherever you put it.
    autoscroll = true,
    -- Whether the start-task form's "Show output" box starts ticked.
    show_on_start = true,
  },
  -- Which picker shows a list; see `tasksd.picker`.
  --   'auto'   -- snacks.nvim when it is there, else 'select'
  --   'snacks' -- snacks.nvim's picker
  --   'select' -- vim.ui.select
  --   function(spec) -- open one of your own
  picker = "auto",
  install = {
    -- Which method `:Tasksd install` uses when given no argument; see
    -- `tasksd.install`.
    --   'auto'   -- download a release, else build from source
    --   'github' -- download a prebuilt release binary
    --   'cargo'  -- build from source
    method = "auto",
  },
}

M.current = vim.deepcopy(M.default)

---@param opts table|nil
M.setup = function(opts)
  M.current = vim.tbl_deep_extend("force", M.default, opts or {})
end

return M
