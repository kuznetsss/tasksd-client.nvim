local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local config = require("tasksd.config")

-- `config.current` is module-level mutable state and `require` caches modules,
-- so without a reset every test would inherit the previous test's setup() call.
local T = new_set({
  hooks = {
    pre_case = function()
      config.current = vim.deepcopy(config.default)
    end,
  },
})

T["setup()"] = new_set()

T["setup()"]["accepts no arguments"] = function()
  config.setup()
  eq(config.current, config.default)
end

T["setup()"]["lets user options win over defaults"] = function()
  config.setup({ daemon = { threads_number = 8 } })
  eq(config.current.daemon.threads_number, 8)
end

T["setup()"]["merges deeply, keeping untouched defaults"] = function()
  config.setup({ daemon = { threads_number = 8 } })
  eq(config.current.daemon.task_buffer_size, config.default.daemon.task_buffer_size)
  eq(config.current.daemon.detached, true)
end

T["setup()"]["does not mutate the defaults table"] = function()
  local before = config.default.daemon.threads_number
  config.setup({ daemon = { threads_number = 99 } })
  eq(config.default.daemon.threads_number, before)
end

return T
