---Installs tasksd for the ci workflow, through the entry point `:Tasksd
---install` uses. The configured default method, `auto`, downloads a release
---where one is published and builds from source where it is not, so one call
---covers every runner -- and it declines to install over a usable tasksd,
---which is what makes the macOS cache a saving rather than a rebuild.

-- `require` resolves against the runtimepath; `nvim -l` starts with only the
-- Neovim runtime on it.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

---Narration, not data: nothing reads this script's stdout, and selene's lua51
---standard library does not model `io.stderr`.
local function say(msg)
  io.write(msg .. "\n")
end

---Generous because a runner with no release asset builds from source.
local TIMEOUT_MS = 20 * 60 * 1000

local result

require("tasksd").install({
  on_done = function(ok, err)
    result = { ok = ok, err = err }
  end,
})

-- Nothing else drives the event loop under `nvim -l`, so the install's
-- callbacks only run while this waits.
if not vim.wait(TIMEOUT_MS, function()
  return result ~= nil
end, 500) then
  say(("install did not finish within %d minutes"):format(TIMEOUT_MS / 60000))
  os.exit(1)
end

if not result.ok then
  say(("install failed: %s"):format(tostring(result.err)))
  os.exit(1)
end
