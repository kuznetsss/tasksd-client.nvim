local config = require("tasksd.config")
local M = {}

M.setup = function(opts)
  config.setup(opts)
end

return M
