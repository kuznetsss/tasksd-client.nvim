if vim.g.loaded_tasksd then
  return
end
vim.g.loaded_tasksd = true

vim.api.nvim_create_user_command("Tasksd", function(opts)
  require("tasksd.command").run(opts)
end, {
  nargs = "*",
  desc = "Interact with the tasksd daemon",
  complete = function(arg_lead, cmd_line, cursor_pos)
    return require("tasksd.command").complete(arg_lead, cmd_line, cursor_pos)
  end,
})
