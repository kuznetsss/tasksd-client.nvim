local config = require("tasksd.config")
local install = require("tasksd.install")
local log = require("tasksd.log")
local pin = require("tasksd.install.pin")

---`:Tasksd install [method]` -- obtain a tasksd binary.
---
---Nothing here knows how any method works; `tasksd.install` owns that, and
---owns verifying the result. This is the layer that talks to the user.

---Two installs at once would race: cargo builds into the same `--root`, and the
---github method stages through one fixed path before renaming over the binary.
local running = false

---@type tasksd.Subcommand
return {
  desc = "Install the tasksd daemon",
  impl = function(args)
    -- Not validated here: `install.run` rejects an unknown name and lists the
    -- real ones, so a typo in `install.method` reads the same as one typed at
    -- the command line.
    local name = args[1] or config.current.install.method

    if running then
      log.warn("an install is already running")
      return
    end
    running = true

    log.info(("installing tasksd %s with `%s`..."):format(pin.VERSION, name))

    install.run(name, function(ok, err)
      running = false
      if not ok then
        log.error(("install failed: %s"):format(tostring(err)))
        return
      end
      log.info(("installed tasksd %s to %s"):format(pin.VERSION, install.bin_path()))
    end, log.info)
  end,
  complete = function(arg_lead)
    return vim.tbl_filter(function(name)
      return vim.startswith(name, arg_lead)
    end, install.method_names())
  end,
}
