local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local cargo = require("tasksd.install.cargo")
local client = require("tasksd.client")
local github = require("tasksd.install.github")
local install = require("tasksd.install")
local pin = require("tasksd.install.pin")

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

---`bin_path` and `cargo.argv` both call `root()`, so stubbing that one function
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
---@param name string
---@param method tasksd.InstallMethod
local function with_method(name, method, fn)
  install.methods[name] = method
  local ok, err = pcall(fn)
  install.methods[name] = nil
  if not ok then
    error(err)
  end
end

---A method that does nothing but whatever `install` does.
---@param install_fn fun(done: fun(ok: boolean, err: string|nil))
---@return tasksd.InstallMethod
local function method_installing(install_fn)
  return { desc = "test method", install = install_fn }
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
  eq(client.check_server_version(pin.VERSION), nil)
end

-- Short hashes become ambiguous as a repository grows, breaking installs that
-- previously resolved.
T["pin"]["names a full commit hash"] = function()
  eq(#pin.REV, 40)
  MiniTest.expect.no_equality(pin.REV:match("^%x+$"), nil)
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

T["cargo.argv()"] = new_set()

T["cargo.argv()"]["installs the pinned commit into the plugin's own root"] = function()
  local argv = cargo.argv()

  eq(argv[1], "cargo")
  eq(argv[2], "install")
  eq(flag_value(argv, "--root"), install.root())
  eq(flag_value(argv, "--rev"), pin.REV)
  MiniTest.expect.no_equality(flag_value(argv, "--git"), nil)
end

-- Given both, cargo takes the tag and drops the rev silently, so an install
-- carrying both looks hash-pinned while quietly following a movable tag.
T["cargo.argv()"]["never passes --tag alongside --rev"] = function()
  eq(has_flag(cargo.argv(), "--tag"), false)
end

T["cargo.argv()"]["builds reproducibly and overwrites"] = function()
  local argv = cargo.argv()

  eq(has_flag(argv, "--locked"), true)
  eq(has_flag(argv, "--force"), true)
end

--------------------------------------------------------------------------------
-- Release assets
--------------------------------------------------------------------------------

T["release_target()"] = new_set()

T["release_target()"]["names the triple for each published Linux asset"] = function()
  eq(github.release_target({ sysname = "Linux", machine = "x86_64" }), "x86_64-unknown-linux-gnu")
  eq(github.release_target({ sysname = "Linux", machine = "aarch64" }), "aarch64-unknown-linux-gnu")
end

-- The release workflow builds no macOS asset, and a download method must say so
-- rather than 404 on a guessed name.
T["release_target()"]["points an unsupported platform at cargo"] = function()
  local target, err = github.release_target({ sysname = "Darwin", machine = "arm64" })

  eq(target, nil)
  expect_contains(err, "Darwin arm64")
  expect_contains(err, "cargo")
end

T["release_target()"]["resolves this machine or explains why not"] = function()
  local target, err = github.release_target()

  eq(target ~= nil or err ~= nil, true)
end

T["asset_url()"] = new_set()

-- Asset names are `tasksd-<version>-<target>.tar.gz` under the version's tag;
-- a mismatch here is a 404 at install time.
T["asset_url()"]["addresses the pinned version's asset"] = function()
  local target = "x86_64-unknown-linux-gnu"

  eq(github.asset_stem(target), ("tasksd-%s-%s"):format(pin.VERSION, target))
  eq(
    github.asset_url(target),
    ("https://github.com/kuznetsss/tasksd/releases/download/%s/tasksd-%s-%s.tar.gz"):format(
      pin.VERSION,
      pin.VERSION,
      target
    )
  )
end

--------------------------------------------------------------------------------
-- Placing a downloaded binary
--------------------------------------------------------------------------------

T["place()"] = new_set()

---A file standing in for the binary inside an unpacked archive.
---@return string path
local function unpacked_binary(output)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "tasksd")
  write_fake(path, output, 0)
  table.insert(temps, dir)
  return path
end

T["place()"]["installs an executable at bin_path"] = function()
  with_root(empty_root(), function()
    local ok, err = github.place(unpacked_binary("tasksd " .. pin.VERSION))

    eq(ok, true)
    eq(err, nil)
    eq(install.is_installed(), true)
    eq(install.version_of(install.bin_path()), pin.VERSION)
  end)
end

-- Reinstalling while a daemon is running is ordinary: tasksd outlives the
-- client that started it.
T["place()"]["replaces a binary that is already there"] = function()
  with_root(fake_root("tasksd 0.0.1"), function()
    local ok = github.place(unpacked_binary("tasksd " .. pin.VERSION))

    eq(ok, true)
    eq(install.version_of(install.bin_path()), pin.VERSION)
  end)
end

T["place()"]["leaves nothing staged behind"] = function()
  with_root(empty_root(), function()
    github.place(unpacked_binary("tasksd " .. pin.VERSION))

    eq(vim.uv.fs_stat(install.bin_path() .. ".new"), nil)
  end)
end

T["place()"]["reports a source that is not there"] = function()
  with_root(empty_root(), function()
    local ok, err = github.place("/nonexistent/tasksd")

    eq(ok, false)
    expect_contains(err, "could not copy")
  end)
end

--------------------------------------------------------------------------------
-- github.install
--------------------------------------------------------------------------------

T["github.install()"] = new_set()

---Run `fn` with `release_target` reporting no asset for this platform.
local function with_unsupported_platform(fn)
  local original = github.release_target
  ---@diagnostic disable-next-line: duplicate-set-field
  github.release_target = function()
    return nil, "publishes no binary for Plan9 pdp11"
  end

  local ok, err = pcall(fn)
  github.release_target = original
  if not ok then
    error(err)
  end
end

-- Nothing may reach the network, so this asserts the refusal happens first.
T["github.install()"]["refuses an unsupported platform without downloading"] = function()
  with_unsupported_platform(function()
    local called, ok, err = false, nil, nil
    github.install(function(o, e)
      called, ok, err = true, o, e
    end)

    eq(called, true)
    eq(ok, false)
    expect_contains(err, "Plan9 pdp11")
  end)
end

--------------------------------------------------------------------------------
-- Checksums
--------------------------------------------------------------------------------

T["sha256"] = new_set()

-- `printf 'tasksd\n' | shasum -a 256`
local KNOWN_CONTENT = "tasksd"
local KNOWN_DIGEST = "212c4c3fa4670794c6f609db3b4c907da86800ea1ed272b584e1af88f0d975a3"

---@return string path
local function file_with(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  table.insert(temps, path)
  return path
end

T["sha256"]["every published target carries a pinned digest"] = function()
  for _, machine in ipairs({ "x86_64", "aarch64" }) do
    local target = github.release_target({ sysname = "Linux", machine = machine })
    local digest = pin.SHA256[target]

    MiniTest.expect.no_equality(digest, nil)
    eq(#digest, 64)
    MiniTest.expect.no_equality(digest:match("^%x+$"), nil)
  end
end

T["sha256"]["hashes a file"] = function()
  eq(github.sha256_of(file_with({ KNOWN_CONTENT })), KNOWN_DIGEST)
end

T["sha256"]["reports a file it cannot hash"] = function()
  local digest, err = github.sha256_of("/nonexistent/archive.tar.gz")

  eq(digest, nil)
  MiniTest.expect.no_equality(err, nil)
end

-- A replaced release asset is exactly what the pin exists to catch, so a
-- mismatch has to name both digests rather than just fail.
T["sha256"]["rejects an archive that is not the pinned one"] = function()
  local ok, err = github.check_sha256(file_with({ "not tasksd" }), "x86_64-unknown-linux-gnu")

  eq(ok, false)
  expect_contains(err, "expected " .. pin.SHA256["x86_64-unknown-linux-gnu"])
end

T["sha256"]["rejects a target with no pinned digest"] = function()
  local ok, err = github.check_sha256(file_with({ KNOWN_CONTENT }), "sparc-unknown-none")

  eq(ok, false)
  expect_contains(err, "no pinned digest")
end

T["sha256"]["accepts an archive matching its pin"] = function()
  local target = "x86_64-unknown-linux-gnu"
  local original = pin.SHA256[target]
  pin.SHA256[target] = KNOWN_DIGEST

  local ok, err = github.check_sha256(file_with({ KNOWN_CONTENT }), target)
  pin.SHA256[target] = original

  eq(ok, true)
  eq(err, nil)
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
  with_root(fake_root("tasksd " .. pin.VERSION), function()
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

T["run()"]["passes a method's own error through"] = function()
  with_method(
    "__test",
    method_installing(function(done)
      done(false, "build broke")
    end),
    function()
      local ok, err = run_sync("__test")

      eq(ok, false)
      eq(err, "build broke")
    end
  )
end

-- A method reporting success has only proved that *it* is happy.
T["run()"]["verifies what a method claims to have installed"] = function()
  with_root(empty_root(), function()
    with_method(
      "__test",
      method_installing(function(done)
        done(true, nil)
      end),
      function()
        local ok, err = run_sync("__test")

        eq(ok, false)
        expect_contains(err, "nothing installed at")
      end
    )
  end)
end

T["run()"]["succeeds when a method leaves a matching binary"] = function()
  with_root(fake_root("tasksd " .. pin.VERSION), function()
    with_method(
      "__test",
      method_installing(function(done)
        done(true, nil)
      end),
      function()
        local ok, err = run_sync("__test")

        eq(ok, true)
        eq(err, nil)
      end
    )
  end)
end

-- vim.system calls back in a fast-event context, where verify() -- which execs
-- and waits -- is not allowed to run.
T["run()"]["verifies on the main loop after a spawning method"] = function()
  with_root(fake_root("tasksd " .. pin.VERSION), function()
    with_method(
      "__test",
      method_installing(function(done)
        install.spawn({ "sh", "-c", "exit 0" }, done)
      end),
      function()
        local ok, err = run_sync("__test")

        eq(ok, true)
        eq(err, nil)
      end
    )
  end)
end

--------------------------------------------------------------------------------
-- Method building blocks
--------------------------------------------------------------------------------

T["require_programs()"] = new_set()

-- A missing toolchain has to read as "install Rust", not as whatever a failed
-- spawn happens to say.
T["require_programs()"]["names the missing program and what to do about it"] = function()
  local ok, err = install.require_programs({ "sh", "tasksd-no-such-program" }, "do the thing first")

  eq(ok, false)
  expect_contains(err, "tasksd%-no%-such%-program")
  expect_contains(err, "not on %$PATH")
  expect_contains(err, "do the thing first")
end

T["require_programs()"]["passes when every program is present"] = function()
  local ok, err = install.require_programs({ "sh" }, "n/a")

  eq(ok, true)
  eq(err, nil)
end

T["spawn()"] = new_set()

---@return boolean ok, string|nil err
local function spawn_sync(argv)
  local done, ok, err = false, false, nil
  install.spawn(argv, function(o, e)
    done, ok, err = true, o, e
  end)

  local finished = vim.wait(5000, function()
    return done
  end, 10)
  if not finished then
    error("install.spawn never invoked its callback")
  end
  return ok, err
end

T["spawn()"]["reports the command's stderr"] = function()
  local ok, err = spawn_sync({ "sh", "-c", "echo 'build broke' >&2; exit 1" })

  eq(ok, false)
  eq(err, "build broke")
end

T["spawn()"]["falls back to the exit code when nothing was written"] = function()
  local ok, err = spawn_sync({ "sh", "-c", "exit 3" })

  eq(ok, false)
  expect_contains(err, "exit code 3")
end

-- vim.system raises rather than returning when the program does not exist.
T["spawn()"]["reports a command that cannot be spawned"] = function()
  local ok, err = spawn_sync({ "tasksd-no-such-program" })

  eq(ok, false)
  MiniTest.expect.no_equality(err, nil)
end

T["spawn()"]["succeeds on exit 0"] = function()
  local ok, err = spawn_sync({ "sh", "-c", "exit 0" })

  eq(ok, true)
  eq(err, nil)
end

return T
