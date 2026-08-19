---Installing tasksd by downloading a binary from its GitHub releases.
local pin = require("tasksd.install.pin")

local M = {}

local HASH_TIMEOUT_MS = 10000

---Release assets are named for the Rust target triple they were built for.
---Only what tasksd's release workflow actually publishes is listed, keyed by
---the `sysname` and `machine` libuv reports.
local RELEASE_TARGETS = {
  Linux = {
    x86_64 = "x86_64-unknown-linux-gnu",
    aarch64 = "aarch64-unknown-linux-gnu",
  },
}

---@param uname? { sysname: string, machine: string } Defaults to this machine's.
---@return string|nil target nil when the release carries no asset for it.
---@return string|nil err
M.release_target = function(uname)
  uname = uname or vim.uv.os_uname()

  local target = (RELEASE_TARGETS[uname.sysname] or {})[uname.machine]
  if not target then
    return nil,
      ("tasksd %s publishes no binary for %s %s; build from source with the cargo method instead"):format(
        pin.VERSION,
        uname.sysname,
        uname.machine
      )
  end
  return target, nil
end

---The archive unpacks to a directory of this same name, so the binary inside
---it is `<stem>/tasksd`.
---@param target string
---@return string
M.asset_stem = function(target)
  return ("tasksd-%s-%s"):format(pin.VERSION, target)
end

---@param target string
---@return string
M.asset_url = function(target)
  return ("%s/releases/download/%s/%s.tar.gz"):format(
    pin.REPO_URL,
    pin.VERSION,
    M.asset_stem(target)
  )
end

---coreutils ships the first, macOS the second; both print `<digest>  <path>`.
---An either-or, so it stays out of `tasksd.InstallMethodSpec.requires`.
local HASHERS = {
  { "sha256sum" },
  { "shasum", "-a", "256" },
}

---@return string[]|nil argv
---@return string|nil err
M.hasher = function()
  for _, argv in ipairs(HASHERS) do
    if vim.fn.executable(argv[1]) == 1 then
      return argv, nil
    end
  end
  return nil, "no SHA-256 tool on $PATH; expected one of sha256sum, shasum"
end

---`vim.fn.sha256` cannot stand in: it takes a Vim string, and neither that nor
---`readfile` can carry the NUL bytes an archive is full of.
---@param path string
---@return string|nil digest
---@return string|nil err
M.sha256_of = function(path)
  local hasher, hasher_err = M.hasher()
  if not hasher then
    return nil, hasher_err
  end

  local argv = vim.list_extend(vim.list_slice(hasher), { path })
  -- vim.system raises rather than returns when the program cannot be spawned.
  local ok, out = pcall(function()
    return vim.system(argv, { text = true }):wait(HASH_TIMEOUT_MS)
  end)
  if not ok then
    return nil, tostring(out)
  end

  local stdout = vim.trim(out.stdout or "")
  if out.code ~= 0 then
    local stderr = vim.trim(out.stderr or "")
    return nil, stderr ~= "" and stderr or ("exit code " .. out.code)
  end

  local digest = stdout:match("^(%x+)")
  if not digest or #digest ~= 64 then
    return nil, ("could not parse a digest from %q"):format(stdout)
  end
  return digest, nil
end

---Copy beside the destination and rename over it: copying straight onto the
---binary of a running daemon fails with ETXTBSY, while a rename within one
---directory replaces it atomically.
---@param src string
---@return boolean ok
---@return string|nil err
M.place = function(src)
  local dest = require("tasksd.install").bin_path()
  local staged = dest .. ".new"

  vim.fn.mkdir(vim.fs.dirname(dest), "p")

  local ok, err = vim.uv.fs_copyfile(src, staged)
  if not ok then
    return false, ("could not copy %s to %s: %s"):format(src, staged, tostring(err))
  end

  ok, err = vim.uv.fs_chmod(staged, tonumber("755", 8))
  if not ok then
    return false, ("could not make %s executable: %s"):format(staged, tostring(err))
  end

  ok, err = vim.uv.fs_rename(staged, dest)
  if not ok then
    return false, ("could not move %s to %s: %s"):format(staged, dest, tostring(err))
  end
  return true, nil
end

---@param path string
---@param target string
---@return boolean ok
---@return string|nil err
M.check_sha256 = function(path, target)
  local expected = pin.SHA256[target]
  if not expected then
    return false, ("no pinned digest for %s"):format(target)
  end

  local digest, err = M.sha256_of(path)
  if not digest then
    return false, ("could not hash %s: %s"):format(path, tostring(err))
  end
  if digest ~= expected then
    return false, ("%s has digest %s, expected %s"):format(path, digest, expected)
  end
  return true, nil
end

---@param done fun(ok: boolean, err: string|nil)
M.install = function(done)
  local install = require("tasksd.install")

  local target, target_err = M.release_target()
  if not target then
    done(false, target_err)
    return
  end

  -- `vim.net.request` shells out to curl, so nothing here spawns it directly.
  local ok, err =
    install.require_programs({ "curl", "tar" }, "both are needed to unpack a release archive")
  if not ok then
    done(false, err)
    return
  end

  -- Before the download rather than after: a machine that cannot check the
  -- digest must not spend the bytes.
  local _, hasher_err = M.hasher()
  if hasher_err then
    done(false, hasher_err)
    return
  end

  local archive = vim.fn.tempname() .. ".tar.gz"
  local unpacked = vim.fn.tempname()

  local function finish(finished, finish_err)
    vim.fn.delete(archive)
    vim.fn.delete(unpacked, "rf")
    done(finished, finish_err)
  end

  vim.net.request(M.asset_url(target), { outpath = archive }, function(request_err)
    -- Both callbacks below arrive in a fast-event context, where the rest of
    -- this -- hashing, unpacking, vim.fn -- may not run.
    vim.schedule(function()
      if request_err then
        finish(false, request_err)
        return
      end

      local checked, check_err = M.check_sha256(archive, target)
      if not checked then
        finish(false, check_err)
        return
      end

      vim.fn.mkdir(unpacked, "p")
      install.spawn({ "tar", "-xzf", archive, "-C", unpacked }, function(extracted, tar_err)
        vim.schedule(function()
          if not extracted then
            finish(false, tar_err)
            return
          end
          finish(M.place(vim.fs.joinpath(unpacked, M.asset_stem(target), "tasksd")))
        end)
      end)
    end)
  end)
end

---@type tasksd.InstallMethod
M.method = {
  desc = "Download a prebuilt binary from GitHub releases",
  install = M.install,
}

return M
