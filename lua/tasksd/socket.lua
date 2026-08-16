local config = require("tasksd.config")

---Deciding *which* daemon a command talks to.
---
---A unix socket is just a file, so "one daemon per X" is entirely a question of
---how X maps to a path: two Neovims that compute the same path share a daemon,
---two that compute different paths each get their own. That mapping lives here
---and nowhere else, so every caller asking for "the" socket gets the same
---answer.
local M = {}

-- The kernel copies a unix socket path into a fixed `sun_path` buffer: 104
-- bytes on macOS, 108 on Linux, NUL included -- far shorter than PATH_MAX. Use
-- the smaller of the two, since a path that works here should work everywhere.
local MAX_PATH_BYTES = 104

---Fail loudly on a path the kernel would truncate, rather than letting tasksd
---bind to a silently shortened name.
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

---Directory holding every socket this plugin creates.
---
---`stdpath("state")` is Neovim's directory for data that should outlive a
---restart but is not user-authored config -- the right shelf for a runtime
---socket. The directory has to exist before tasksd can bind inside it, hence
---the mkdir; "p" makes it a no-op when it is already there.
---@return string
local function socket_dir()
  local dir = vim.fs.joinpath(vim.fn.stdpath("state"), "tasksd")
  vim.fn.mkdir(dir, "p")
  return dir
end

-- What makes a directory a project root, nearest ancestor first. Only version
-- control roots: build files like Cargo.toml or package.json also sit in every
-- workspace member, so they would resolve to a crate or a package rather than
-- to the tree you think of as the project.
local PROJECT_MARKERS = { ".git", ".jj", ".hg", ".svn" }

---The directory both directory-based schemes start from.
---
---getcwd(-1) is the *global* directory, deliberately not the window's: a plain
---getcwd() follows :lcd, so hopping between splits would change the answer, and
---`client.get` drops the old connection -- with its subscriptions -- whenever
---the answer changes. One Neovim means one project here, and it only moves when
---you type :cd. fs_realpath keeps /tmp/x and its symlinked /private/tmp/x on
---macOS from becoming two daemons.
---@return string
local function cwd()
  local dir = vim.fn.getcwd(-1)
  return vim.uv.fs_realpath(dir) or dir
end

---Name a socket after a directory.
---
---The directory itself cannot go into the name -- slashes, and the length cap
---above -- so it is hashed. The basename is prepended purely so that `ls` on
---the socket directory is readable; the hash is what actually identifies it.
---@param prefix string Scheme name, so two schemes never collide on one file.
---@param dir string
---@return string
local function name_for(prefix, dir)
  local label = vim.fs.basename(dir):gsub("[^%w._-]", "_"):sub(1, 20)
  return ("%s-%s-%s.sock"):format(prefix, label, vim.fn.sha256(dir):sub(1, 12))
end

---@alias tasksd.SocketScheme "global"|"nvim_instance"|"pwd"|"project"

---How each named scheme turns into a file name inside `socket_dir()`.
---
---Names only: the schemes cannot pick their own directory, which keeps every
---socket this plugin owns in one place and keeps the paths short.
---@type table<tasksd.SocketScheme, fun(): string>
local schemes = {
  -- One daemon for this user: every Neovim, every project, the same file.
  global = function()
    return "global.sock"
  end,

  -- One daemon per Neovim process. The pid is unique for as long as the
  -- process lives, which is exactly as long as this socket is wanted -- note
  -- that this gives up the main reason tasksd detaches its tasks, since the
  -- next Neovim will address a different daemon and never see them again.
  nvim_instance = function()
    return ("nvim-%d.sock"):format(vim.uv.os_getpid())
  end,

  -- One daemon per working directory, taken literally: `nvim` started in
  -- ~/project/src/foo addresses a different daemon than one started in
  -- ~/project. Use `project` if that is not what you want.
  pwd = function()
    return name_for("pwd", cwd())
  end,

  -- One daemon per project: the same daemon however deep in the tree Neovim
  -- was started. vim.fs.root walks upward from the working directory to the
  -- nearest ancestor holding a marker, and returns nil if there is none -- in
  -- which case there is no project to speak of and the directory itself is the
  -- best answer left, making this degrade into `pwd`.
  --
  -- The search starts from the working directory rather than from the current
  -- buffer on purpose: opening a file outside the tree must not silently
  -- repoint the whole plugin at another daemon.
  project = function()
    local dir = cwd()
    return name_for("project", vim.fs.root(dir, PROJECT_MARKERS) or dir)
  end,
}

---The scheme names, sorted, for error messages.
---@return string
local function scheme_names()
  local names = vim.tbl_keys(schemes)
  table.sort(names)
  return '"' .. table.concat(names, '", "') .. '"'
end

---Resolve the `daemon.socket` option into an actual filesystem path.
---Exposed for debugging: `:lua =require("tasksd.socket").path()`
---@return string
M.path = function()
  local socket = config.current.daemon.socket

  -- A function gets the final say: it is the escape hatch for the schemes this
  -- module does not ship -- one daemon per git worktree, per tmux session,
  -- whatever. It owns its path completely, including creating the directory.
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
