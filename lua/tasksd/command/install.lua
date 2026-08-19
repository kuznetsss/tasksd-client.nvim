local config = require("tasksd.config")
local daemon = require("tasksd.daemon")
local install = require("tasksd.install")
local log = require("tasksd.log")
local pin = require("tasksd.install.pin")

---`:Tasksd install[!] [method]` -- obtain a tasksd binary.
---
---Nothing here knows how any method works; `tasksd.install` owns that, and
---owns verifying the result. This is the layer that talks to the user.

---Two installs at once would race: cargo builds into the same `--root`, and the
---github method stages through one fixed path before renaming over the binary.
local running = false

---@type tasksd.Subcommand
return {
  desc = "Install the tasksd daemon (`:Tasksd! install` to install over a usable one)",
  impl = function(args, bang)
    -- Not validated here: `install.run` rejects an unknown name and lists the
    -- real ones, so a typo in `install.method` reads the same as one typed at
    -- the command line.
    local name = args[1] or config.current.install.method

    if running then
      log.warn("an install is already running")
      return
    end

    -- `daemon.executable` is the same answer a launch would get, so this skips
    -- exactly when installing would change nothing about which binary runs --
    -- including one the user supplied through `daemon.path`.
    if not bang then
      local exe, source = daemon.executable()
      local version = daemon.usable_version(exe, source)
      if version then
        log.info(
          ("tasksd %s already available at %s (%s); `:Tasksd! install` to install anyway"):format(
            version,
            exe,
            daemon.SOURCE_LABEL[source]
          )
        )
        return
      end
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
