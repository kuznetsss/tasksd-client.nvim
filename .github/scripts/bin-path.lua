---Prints where the plugin installs its binary, for the ci workflow to cache
---and to hand the test suite as `TASKSD_BIN`. Asking the plugin keeps the path
---in one place: `install.root` decides it, and the workflow never spells it.

-- `require` resolves against the runtimepath; `nvim -l` starts with only the
-- Neovim runtime on it.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- `io.write`, not `print`: under `nvim -l` print goes through the message
-- system and lands on stderr, where the caller cannot read it.
io.write(require("tasksd.install").bin_path() .. "\n")
