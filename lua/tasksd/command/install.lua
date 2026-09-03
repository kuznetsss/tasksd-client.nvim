local arguments = require("tasksd.args")
local config = require("tasksd.config")
local daemon = require("tasksd.daemon")
local install = require("tasksd.install")
local log = require("tasksd.log")
local pin = require("tasksd.install.pin")

---`:Tasksd[!] install [method=<name>]`, or `require("tasksd").install(opts)` --
---obtain a tasksd binary.
---
---Nothing here knows how any method works; `tasksd.install` owns that, and
---owns verifying the result. This is the layer that talks to the user.
---@class tasksd.command.Install : tasksd.Subcommand
local M = {}

M.desc = "Install the tasksd daemon: [method=<name>], ! to install over a usable one"

local KEYS = { "method=" }

---@class tasksd.command.install.Opts
---@field method? string Defaults to `install.method` from the config.
---@field force? boolean Install even when a usable tasksd is already there.

---Two installs at once would race: cargo builds into the same `--root`, and the
---github method stages through one fixed path before renaming over the binary.
local running = false

---@param args string[]
---@param force boolean
---@return tasksd.command.install.Opts|nil opts, string|nil err
M.from_argv = function(args, force)
  local values, err = arguments.parse(args, KEYS)
  if not values then
    return nil, err
  end
  ---@type tasksd.command.install.Opts
  local opts = { method = values.method, force = force or nil }
  return opts, nil
end

---@param opts tasksd.command.install.Opts|nil
M.run = function(opts)
  vim.validate("opts", opts, "table", true)
  opts = opts or {}

  -- Not validated here: `install.run` rejects an unknown name and lists the
  -- real ones, so a typo in `install.method` reads the same as one typed at
  -- the command line.
  local name = opts.method or config.current.install.method

  if running then
    log.warn("an install is already running")
    return
  end

  -- `daemon.executable` is the same answer a launch would get, so this skips
  -- exactly when installing would change nothing about which binary runs --
  -- including one the user supplied through `daemon.path`.
  if not opts.force then
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
end

M.impl = function(args, bang)
  local opts, err = M.from_argv(args, bang)
  if not opts then
    log.error(tostring(err))
    return
  end
  M.run(opts)
end

---@param arg_lead string
---@return string[]
M.complete = function(arg_lead)
  return arguments.complete(arg_lead, KEYS, {
    method = function(lead)
      return arguments.starting_with(lead, install.method_names())
    end,
  })
end

return M
