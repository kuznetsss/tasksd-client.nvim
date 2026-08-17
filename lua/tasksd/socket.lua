local config = require("tasksd.config")

---Deciding *which* daemon a command talks to.
---
---A unix socket is just a file, so "one daemon per X" is entirely a question of
---how X maps to a path: two Neovims that compute the same path share a daemon,
---two that compute different paths each get their own. That mapping lives here
---and nowhere else.
local M = {}

-- The kernel copies the path into a fixed `sun_path` buffer: 104 bytes on
-- macOS, 108 on Linux, NUL included. Use the smaller, so a path that works here
-- works everywhere.
local MAX_PATH_BYTES = 104

---A path over the limit binds to a silently truncated name instead of failing.
---@param path string
---@return string
local function checked(path)
  if #path >= MAX_PATH_BYTES then
    error(
      ("socket path is %d bytes, the limit is %d: %s"):format(#path, MAX_PATH_BYTES - 1, path),
      0
    )
  end
  return path
end

---`stdpath("state")` rather than `stdpath("data")`: a socket is runtime scratch
---that may be thrown away between sessions.
---@return string
local function socket_dir()
  local dir = vim.fs.joinpath(vim.fn.stdpath("state"), "tasksd")
  vim.fn.mkdir(dir, "p")
  return dir
end

-- Nearest ancestor first. Version control roots only: build files like
-- Cargo.toml or package.json also sit in every workspace member, so they would
-- resolve to a crate rather than to the tree you think of as the project.
local PROJECT_MARKERS = { ".git", ".jj", ".hg", ".svn" }

---getcwd(-1) is the *global* directory, deliberately not the window's: a plain
---getcwd() follows :lcd, and `client.get` drops the live connection -- with its
---subscriptions -- whenever this answer changes. fs_realpath keeps /tmp/x and
---its symlinked /private/tmp/x on macOS from becoming two daemons.
---@return string
local function cwd()
  local dir = vim.fn.getcwd(-1)
  return vim.uv.fs_realpath(dir) or dir
end

---The directory cannot go into the name -- slashes, and the length cap above --
---so it is hashed. The basename is prepended only so `ls` is readable.
---@param prefix string Scheme name, so two schemes never collide on one file.
---@param dir string
---@return string
local function name_for(prefix, dir)
  local label = vim.fs.basename(dir):gsub("[^%w._-]", "_"):sub(1, 20)
  return ("%s-%s-%s.sock"):format(prefix, label, vim.fn.sha256(dir):sub(1, 12))
end

---@alias tasksd.SocketScheme "global"|"nvim_instance"|"pwd"|"project"

---File names only: a scheme cannot pick its own directory, which keeps every
---socket this plugin owns in one place and keeps the paths short.
---@type table<tasksd.SocketScheme, fun(): string>
local schemes = {
  global = function()
    return "global.sock"
  end,

  -- Gives up the main reason tasksd detaches its tasks: the next Neovim
  -- addresses a different daemon and never sees them again.
  nvim_instance = function()
    return ("nvim-%d.sock"):format(vim.uv.os_getpid())
  end,

  -- Literally the directory: `nvim` started in ~/project/src/foo addresses a
  -- different daemon than one started in ~/project.
  pwd = function()
    return name_for("pwd", cwd())
  end,

  -- vim.fs.root returns nil when no ancestor holds a marker, in which case
  -- there is no project to speak of and this degrades into `pwd`.
  project = function()
    local dir = cwd()
    return name_for("project", vim.fs.root(dir, PROJECT_MARKERS) or dir)
  end,
}

---Sorted, for error messages.
---@return string
local function scheme_names()
  local names = vim.tbl_keys(schemes)
  table.sort(names)
  return '"' .. table.concat(names, '", "') .. '"'
end

---Resolve the `daemon.socket` option into an actual filesystem path.
---@return string
M.path = function()
  local socket = config.current.daemon.socket

  -- The escape hatch for schemes this module does not ship -- per git worktree,
  -- per tmux session, whatever. It owns its path completely, including creating
  -- the directory.
  if type(socket) == "function" then
    local path = socket()
    if type(path) ~= "string" or path == "" then
      error(("daemon.socket returned %s, expected a path"):format(vim.inspect(path)), 0)
    end
    return checked(path)
  end

  local scheme = type(socket) == "string" and schemes[socket] or nil
  if not scheme then
    error(
      ("daemon.socket must be one of %s or a function, got %s"):format(
        scheme_names(),
        vim.inspect(socket)
      ),
      0
    )
  end

  return checked(vim.fs.joinpath(socket_dir(), scheme()))
end

return M
