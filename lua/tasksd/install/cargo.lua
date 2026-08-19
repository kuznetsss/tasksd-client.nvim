---Installing tasksd by building it from source.
local pin = require("tasksd.install.pin")

local M = {}

---`--root` keeps the binary out of ~/.cargo/bin, so it never shadows a tasksd
---the user manages themselves. `--rev` rather than `--tag`; see `pin.REV`.
---@return string[]
M.argv = function()
  -- Deferred: `tasksd.install` requires this module while it is still loading,
  -- so at file scope there would be no module table to read `root` from.
  local install = require("tasksd.install")

  return {
    "cargo",
    "install",
    "--root",
    install.root(),
    "--git",
    pin.REPO_URL,
    "--rev",
    pin.REV,
    "--locked",
    "--force",
  }
end

---@type tasksd.InstallMethod
M.method = {
  desc = "Build from source with cargo",
  install = function(done, report)
    local install = require("tasksd.install")

    local ok, err =
      install.require_programs({ "cargo" }, "install a Rust toolchain: https://rustup.rs")
    if not ok then
      done(false, err)
      return
    end

    report(("building tasksd %s from source; this takes a few minutes"):format(pin.VERSION))
    install.spawn(M.argv(), done)
  end,
}

return M
