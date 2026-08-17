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

require("mini.test").setup()
