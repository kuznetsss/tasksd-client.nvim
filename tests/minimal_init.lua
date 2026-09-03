-- The runtimepath gets this plugin and mini.nvim and nothing else, so a test
-- failure is always about this code rather than an interaction with some other
-- plugin.

vim.opt.runtimepath:append(vim.uv.cwd())

local mini = os.getenv("MINI_NVIM")
if not mini or mini == "" then
  vim.notify(
    "MINI_NVIM is unset. Enter the nix devshell first (direnv allow, or nix develop).",
    vim.log.levels.ERROR
  )
  vim.cmd("cquit 1")
end
vim.opt.runtimepath:append(mini)

-- Fail here rather than letting the integration cases skip themselves: a run
-- that quietly tests nothing still reports green.
local tasksd = os.getenv("TASKSD_BIN")
if tasksd == nil or tasksd == "" then
  -- Only when nothing was asked for: an explicit TASKSD_BIN that will not run
  -- is an error, not something to silently replace. Published back to the
  -- environment because the test files resolve the binary by reading it.
  tasksd = require("tasksd.install").bin_path()
  vim.env.TASKSD_BIN = tasksd
end

if vim.fn.executable(tasksd) == 0 then
  vim.notify(
    ("no runnable tasksd at %s -- set TASKSD_BIN or run :Tasksd install"):format(tasksd),
    vim.log.levels.ERROR
  )
  vim.cmd("cquit 1")
end

require("mini.test").setup()
