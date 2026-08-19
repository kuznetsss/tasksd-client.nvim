---Installing tasksd by trying the real methods in turn.
local M = {}

---A download is seconds where a source build is minutes, so the release is
---tried first. `auto` itself is deliberately absent: it is a method only in the
---sense that `M.methods` can look it up, and listing it here would recurse.
---@type tasksd.InstallMethodName[]
M.ORDER = { "github", "cargo" }

---Every method's failure, not just the last: on a machine with no release asset
---*and* no Rust toolchain, either message alone sends the user down a road the
---other has already ruled out.
---@param failures string[]
---@return string
M.combined_error = function(failures)
  return "no install method succeeded:\n" .. table.concat(failures, "\n")
end

---Falls back on a method's own error only. A method that reports success but
---leaves the wrong binary is `install.run`'s verify to catch, and means the pin
---is wrong -- which the next method would reproduce, not repair.
---@param done fun(ok: boolean, err: string|nil) May run in a fast-event context.
---@param report fun(msg: string)
M.install = function(done, report)
  -- Deferred: `tasksd.install` requires this module while it is still loading,
  -- so at file scope there would be no module table to read `methods` from.
  local install = require("tasksd.install")
  local failures = {}

  local function try(index)
    local name = M.ORDER[index]
    if not name then
      done(false, M.combined_error(failures))
      return
    end

    report(("trying `%s`"):format(name))

    install.methods[name].install(function(ok, err)
      if ok then
        done(true, nil)
        return
      end
      table.insert(failures, ("  %s -- %s"):format(name, tostring(err)))

      -- Only when another method follows: the last failure is `combined_error`'s
      -- to carry, and reporting it here would say it twice.
      if M.ORDER[index + 1] then
        report(("`%s` failed: %s"):format(name, tostring(err)))
      end
      try(index + 1)
    end, report)
  end

  try(1)
end

---@type tasksd.InstallMethod
M.method = {
  desc = "Download a release, falling back to building from source",
  install = M.install,
}

return M
