local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local client = require("tasksd.client")
local install = require("tasksd.install")

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Nothing here reaches the network or builds anything: every case is a pure
-- argv question, or runs a shell script standing in for tasksd.
local temps = {}

---Write an executable stand-in for tasksd that prints `output` and exits `code`.
---A failing run writes to stderr, as clap and cargo do -- that is the stream
---`version_of` quotes back, so a fake using stdout would test nothing.
local function write_fake(path, output, code)
  local redirect = (code or 0) ~= 0 and " >&2" or ""
  vim.fn.writefile({
    "#!/bin/sh",
    ("printf '%%s\\n' %s%s"):format(vim.fn.shellescape(output), redirect),
    ("exit %d"):format(code or 0),
  }, path)
  vim.fn.setfperm(path, "rwx------")
end

---A lone fake binary, for the cases that only probe a version.
---@return string path
local function fake_bin(output, code)
  local path = vim.fn.tempname()
  write_fake(path, output, code)
  table.insert(temps, path)
  return path
end

---A directory shaped like a finished install: <root>/bin/tasksd.
---@return string root
local function fake_root(output, code)
  local root = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(root, "bin"), "p")
  write_fake(vim.fs.joinpath(root, "bin", "tasksd"), output, code)
  table.insert(temps, root)
  return root
end

---A root with nothing installed in it.
---@return string root
local function empty_root()
  local root = vim.fn.tempname()
  table.insert(temps, root)
  return root
end

---`bin_path` and `cargo_argv` both call `root()`, so stubbing that one function
---redirects the whole module away from the real ~/.local/share/nvim without any
---test-only option in the code.
local function with_root(root, fn)
  local original = install.root
  ---@diagnostic disable-next-line: duplicate-set-field
  install.root = function()
    return root
  end

  local ok, err = pcall(fn)
  install.root = original
  if not ok then
    error(err)
  end
end

---Run `fn` with `method` temporarily registered.
local function with_method(method, spec, fn)
  install.methods[method] = spec
  local ok, err = pcall(fn)
  install.methods[method] = nil
  if not ok then
    error(err)
  end
end

---@return boolean ok, string|nil err
local function run_sync(method)
  local done, ok, err = false, false, nil
  install.run(method, function(o, e)
    done, ok, err = true, o, e
  end)

  local finished = vim.wait(5000, function()
    return done
  end, 10)
  if not finished then
    error("install.run never invoked its callback")
  end
  return ok, err
end

---@return string|nil
local function flag_value(argv, flag)
  for i, value in ipairs(argv) do
    if value == flag then
      return argv[i + 1]
    end
  end
  return nil
end

local function has_flag(argv, flag)
  return vim.tbl_contains(argv, flag)
end

---tostring() rather than indexing directly, so a nil error message fails the
---assertion instead of raising a nil-index inside the test.
local function expect_contains(text, pattern)
  MiniTest.expect.no_equality(tostring(text):find(pattern), nil)
end

--------------------------------------------------------------------------------

local T = new_set({
  hooks = {
    post_once = function()
      for _, path in ipairs(temps) do
        vim.fn.delete(path, "rf")
      end
    end,
  },
})

--------------------------------------------------------------------------------
-- The pin
--------------------------------------------------------------------------------

T["pin"] = new_set()

-- Bumping MIN_SERVER_VERSION past the pin would ship a plugin whose own
-- installer yields a daemon it then refuses to talk to.
T["pin"]["satisfies the version the client requires"] = function()
  eq(client.check_server_version(install.PINNED_VERSION), nil)
end

-- Short hashes become ambiguous as a repository grows, breaking installs that
-- previously resolved.
T["pin"]["names a full commit hash"] = function()
  eq(#install.PINNED_REV, 40)
  MiniTest.expect.no_equality(install.PINNED_REV:match("^%x+$"), nil)
end

--------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------

T["bin_path()"] = new_set()

-- Not the plugin's own directory: a plugin manager updating the plugin must not
-- delete the binary.
T["bin_path()"]["lives under stdpath('data')"] = function()
  eq(vim.startswith(install.bin_path(), vim.fn.stdpath("data")), true)
end

-- `cargo install --root X` writes X/bin/tasksd, so bin_path has to agree.
T["bin_path()"]["is bin/tasksd inside the install root"] = function()
  eq(install.bin_path(), vim.fs.joinpath(install.root(), "bin", "tasksd"))
end

T["bin_path()"]["reports nothing installed when the file is absent"] = function()
  with_root(empty_root(), function()
    eq(install.is_installed(), false)
  end)
end

T["bin_path()"]["reports an installed binary"] = function()
  with_root(fake_root("tasksd 0.2.0"), function()
    eq(install.is_installed(), true)
  end)
end

--------------------------------------------------------------------------------
-- cargo
--------------------------------------------------------------------------------

T["cargo_argv()"] = new_set()

T["cargo_argv()"]["installs the pinned commit into the plugin's own root"] = function()
  local argv = install.cargo_argv()

  eq(argv[1], "cargo")
  eq(argv[2], "install")
  eq(flag_value(argv, "--root"), install.root())
  eq(flag_value(argv, "--rev"), install.PINNED_REV)
  MiniTest.expect.no_equality(flag_value(argv, "--git"), nil)
end

-- Given both, cargo takes the tag and drops the rev silently, so an install
-- carrying both looks hash-pinned while quietly following a movable tag.
T["cargo_argv()"]["never passes --tag alongside --rev"] = function()
  eq(has_flag(install.cargo_argv(), "--tag"), false)
end

T["cargo_argv()"]["builds reproducibly and overwrites"] = function()
  local argv = install.cargo_argv()

  eq(has_flag(argv, "--locked"), true)
  eq(has_flag(argv, "--force"), true)
end

--------------------------------------------------------------------------------
-- version_of
--------------------------------------------------------------------------------

T["version_of()"] = new_set()

T["version_of()"]["reads the version clap prints"] = function()
  eq(install.version_of(fake_bin("tasksd 0.2.0")), "0.2.0")
end

T["version_of()"]["ignores anything after the version"] = function()
  eq(install.version_of(fake_bin("tasksd 9.9.9 (abcdef)")), "9.9.9")
end

T["version_of()"]["reports a binary that fails"] = function()
  local version, err = install.version_of(fake_bin("boom", 3))

  eq(version, nil)
  expect_contains(err, "boom")
end

T["version_of()"]["reports output with no version in it"] = function()
  local version, err = install.version_of(fake_bin("not a version"))

  eq(version, nil)
  expect_contains(err, "could not parse a version")
end

-- vim.system raises rather than returning when the program does not exist.
T["version_of()"]["reports a binary that cannot be spawned"] = function()
  local version, err = install.version_of("/nonexistent/tasksd")

  eq(version, nil)
  MiniTest.expect.no_equality(err, nil)
end

--------------------------------------------------------------------------------
-- verify
--------------------------------------------------------------------------------

T["verify()"] = new_set()

T["verify()"]["fails when nothing was installed"] = function()
  with_root(empty_root(), function()
    local ok, err = install.verify()

    eq(ok, false)
    expect_contains(err, "nothing installed at")
  end)
end

-- A commit that builds a different version than this client expects is a
-- mistake in the pin, and must not pass silently.
T["verify()"]["fails when the built version is not the pinned one"] = function()
  with_root(fake_root("tasksd 0.0.1"), function()
    local ok, err = install.verify()

    eq(ok, false)
    expect_contains(err, "disagree")
  end)
end

T["verify()"]["passes on an install reporting the pinned version"] = function()
  with_root(fake_root("tasksd " .. install.PINNED_VERSION), function()
    local ok, err = install.verify()

    eq(ok, true)
    eq(err, nil)
  end)
end

--------------------------------------------------------------------------------
-- run
--------------------------------------------------------------------------------

T["run()"] = new_set()

T["run()"]["rejects an unknown method and lists the real ones"] = function()
  local ok, err = run_sync("homebrew")

  eq(ok, false)
  expect_contains(err, "unknown install method")
  expect_contains(err, "cargo")
end

-- A missing toolchain has to read as "install Rust", not as whatever a failed
-- spawn happens to say.
T["run()"]["explains a missing toolchain before spawning anything"] = function()
  with_method("__test", {
    desc = "test method",
    requires = "tasksd-no-such-program",
    hint = "do the thing first",
    argv = function()
      error("argv must not be reached when the requirement is missing")
    end,
  }, function()
    local ok, err = run_sync("__test")

    eq(ok, false)
    expect_contains(err, "not on %$PATH")
    expect_contains(err, "do the thing first")
  end)
end

T["run()"]["passes an installer's own error through"] = function()
  with_method("__test", {
    desc = "test method",
    requires = "sh",
    hint = "n/a",
    argv = function()
      return { "sh", "-c", "echo 'build broke' >&2; exit 1" }
    end,
  }, function()
    local ok, err = run_sync("__test")

    eq(ok, false)
    eq(err, "build broke")
  end)
end

-- An installer exiting 0 has only proved that *it* is happy.
T["run()"]["succeeds when the installer leaves a matching binary"] = function()
  with_root(fake_root("tasksd " .. install.PINNED_VERSION), function()
    with_method("__test", {
      desc = "test method",
      requires = "sh",
      hint = "n/a",
      argv = function()
        return { "sh", "-c", "exit 0" }
      end,
    }, function()
      local ok, err = run_sync("__test")

      eq(ok, true)
      eq(err, nil)
    end)
  end)
end

T["run()"]["fails when the installer exits 0 but installs nothing"] = function()
  with_root(empty_root(), function()
    with_method("__test", {
      desc = "test method",
      requires = "sh",
      hint = "n/a",
      argv = function()
        return { "sh", "-c", "exit 0" }
      end,
    }, function()
      local ok, err = run_sync("__test")

      eq(ok, false)
      expect_contains(err, "nothing installed at")
    end)
  end)
end

return T
