local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local config = require("tasksd.config")
local socket = require("tasksd.socket")

local SCHEMES = { "global", "nvim_instance", "pwd", "project" }

---:cd, with the path escaped -- a temporary directory may hold anything.
---@param dir string
local function cd(dir)
  vim.cmd.cd(vim.fn.fnameescape(dir))
end

-- Every case here is pure path arithmetic: no daemon is started, so no cleanup
-- is needed. `config.current` and the working directory are the two pieces of
-- global state a case can leave behind, so both are restored.
local original_cwd = vim.fn.getcwd(-1)

local T = new_set({
  hooks = {
    pre_case = function()
      config.current = vim.deepcopy(config.default)
    end,
    post_case = function()
      cd(original_cwd)
    end,
  },
})

T["path()"] = new_set()

T["path()"]["defaults to the global socket"] = function()
  eq(vim.fs.basename(socket.path()), "global.sock")
end

T["path()"]["puts every built-in scheme under stdpath('state')"] = function()
  local dir = vim.fs.joinpath(vim.fn.stdpath("state"), "tasksd")
  for _, scheme in ipairs(SCHEMES) do
    config.setup({ daemon = { socket = scheme } })
    eq(vim.fs.dirname(socket.path()), dir)
  end
end

T["path()"]["gives the same answer on every call"] = function()
  for _, scheme in ipairs(SCHEMES) do
    config.setup({ daemon = { socket = scheme } })
    eq(socket.path(), socket.path())
  end
end

T["path()"]["names the nvim_instance socket after this process"] = function()
  config.setup({ daemon = { socket = "nvim_instance" } })
  eq(vim.fs.basename(socket.path()), ("nvim-%d.sock"):format(vim.uv.os_getpid()))
end

-- The whole point of the scheme: :cd somewhere else and you address a different
-- daemon. The hash makes that true without putting slashes in a file name.
T["path()"]["follows the global working directory"] = function()
  config.setup({ daemon = { socket = "pwd" } })

  local original = vim.fn.getcwd(-1)
  local first = socket.path()

  cd(vim.fs.dirname(original))
  local second = socket.path()

  cd(original)
  eq(socket.path(), first)

  MiniTest.expect.no_equality(first, second)
end

-- ...and the other half of the point: a window-local directory must not.
-- `client.get` drops the live connection whenever this answer changes, so a
-- scheme that moved with the cursor would kill subscriptions on a window hop.
T["path()"]["ignores a window-local directory"] = function()
  config.setup({ daemon = { socket = "pwd" } })

  local expected = socket.path()
  vim.cmd.vsplit()
  vim.cmd.lcd(vim.fn.fnameescape(vim.fs.dirname(vim.fn.getcwd(-1))))

  local ok, actual = pcall(socket.path)
  vim.cmd.close() -- leave the layout as the next case expects it

  eq(ok, true)
  eq(actual, expected)
end

-- Sandboxes, not the real repo: tempname() sits under Neovim's own temp
-- directory, so nothing above it holds a marker that could sway the result.
---@return string root, string deep
local function project_tree()
  local root = vim.fn.tempname()
  local deep = vim.fs.joinpath(root, "src", "nested")
  vim.fn.mkdir(deep, "p")
  return root, deep
end

-- The difference from `pwd`, and the reason the scheme exists: where you
-- happened to start Neovim inside the tree must not matter.
T["path()"]["shares one socket across a project tree"] = function()
  config.setup({ daemon = { socket = "project" } })
  local root, deep = project_tree()
  vim.fn.mkdir(vim.fs.joinpath(root, ".git"), "p")

  cd(root)
  local at_root = socket.path()
  cd(deep)
  eq(socket.path(), at_root)
end

T["path()"]["falls back to the directory when nothing marks a root"] = function()
  config.setup({ daemon = { socket = "project" } })
  local root, deep = project_tree()

  cd(deep)
  local unmarked = socket.path()

  -- Same directory, but now there is a root above it: the answer must move.
  vim.fn.mkdir(vim.fs.joinpath(root, ".jj"), "p")
  local marked = socket.path()
  MiniTest.expect.no_equality(unmarked, marked)

  cd(root)
  eq(socket.path(), marked)
end

T["path()"]["takes a path from a function"] = function()
  config.setup({
    daemon = {
      socket = function()
        return "/tmp/tasksd-custom.sock"
      end,
    },
  })
  eq(socket.path(), "/tmp/tasksd-custom.sock")
end

T["path()"]["rejects an unknown scheme"] = function()
  config.setup({ daemon = { socket = "session" } })
  MiniTest.expect.error(socket.path, "daemon.socket must be one of")
end

T["path()"]["rejects a function that returns no path"] = function()
  config.setup({ daemon = { socket = function() end } })
  MiniTest.expect.error(socket.path, "expected a path")
end

-- A path the kernel would truncate binds to the wrong name instead of failing,
-- which is far harder to diagnose than an error here.
T["path()"]["rejects a path longer than sun_path"] = function()
  config.setup({
    daemon = {
      socket = function()
        return "/tmp/" .. string.rep("x", 120) .. ".sock"
      end,
    },
  })
  MiniTest.expect.error(socket.path, "the limit is 103")
end

return T
