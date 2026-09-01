local highlights = require("tasksd.highlights")

---The one output window: where it opens, how big it is, and where the user
---moved it to since. It is handed a buffer and shows it; what is in that
---buffer, and which task it belongs to, is `tasksd.output`'s business.
---
---Config is not read here -- the caller passes `default`, the way
---`tasksd.form` is handed its keys -- so the window can be opened from anywhere
---the placement is already known.
local M = {}

---@alias tasksd.output.Position "left"|"right"|"top"|"bottom"|"float"

---A count of lines/columns, or a percentage of the editor. The table form gives
---the two dimensions separately, which only a float uses both of.
---@alias tasksd.output.Size number|string|{width: number|string, height: number|string}

---@class tasksd.output.Placement
---@field position tasksd.output.Position
---@field size tasksd.output.Size

---Where the window is, in cells. Only the dimensions the position leaves to the
---user are kept: a split's other dimension is the editor's, and reopening
---somewhere else should not inherit it.
---@class tasksd.output.Geometry
---@field position tasksd.output.Position
---@field width? integer
---@field height? integer
---@field row? integer Float only.
---@field col? integer Float only.

---@class tasksd.output.window.Opts
---@field default tasksd.output.Placement Falls back to this for whatever is not remembered.
---@field position? tasksd.output.Position Put the window here, whatever is remembered.
---@field reset? boolean Ignore the remembered placement.
---@field enter? boolean Focus the window. Defaults to true.
---@field on_close? fun() Runs when the window goes, however it goes.

---Position names, sorted so completion order is stable.
---@type tasksd.output.Position[]
M.POSITIONS = { "bottom", "float", "left", "right", "top" }

local TITLE = " tasksd output "

---@type table<tasksd.output.Position, string>
local SPLIT = { left = "left", right = "right", top = "above", bottom = "below" }

---@type integer|nil
local current = nil

---Where the window was when it last closed; nil until it has been open once.
---@type tasksd.output.Geometry|nil
local remembered = nil

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

---@param spec number|string A count, or a percentage of `total` such as "30%".
---@param total integer
---@return integer
local function measure(spec, total)
  if type(spec) == "number" then
    return math.max(1, math.floor(spec))
  end
  local percent = tonumber(tostring(spec):match("^(%d+%.?%d*)%%$"))
  assert(percent, ("`%s` is not a size: expected a count or a percentage"):format(spec))
  return math.max(1, math.floor(total * percent / 100))
end

---@param size tasksd.output.Size
---@param key "width"|"height"
---@param total integer
---@return integer
local function dimension(size, key, total)
  if type(size) == "table" then
    return measure(size[key], total)
  end
  return measure(size, total)
end

---Which edge of the editor `win` sits against, or nil when it is not on one.
---
---Neovim has no "which side is this split on" query, so the layout tree answers
---it instead: a window against an edge is the first or last child of the root
---row/col. Anything nested deeper is a placement reopening could not reproduce.
---@param win integer
---@return tasksd.output.Position|nil
local function edge(win)
  local tab = vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(win))
  local kind, children = unpack(vim.fn.winlayout(tab))
  if kind ~= "row" and kind ~= "col" then
    return nil
  end

  ---@param node table
  ---@return boolean
  local function is_win(node)
    return node[1] == "leaf" and node[2] == win
  end
  local first, last = children[1], children[#children]

  if kind == "col" then
    return (is_win(first) and "top") or (is_win(last) and "bottom") or nil
  end
  return (is_win(first) and "left") or (is_win(last) and "right") or nil
end

---@param win integer
---@return tasksd.output.Geometry|nil geometry nil when reopening could not put the window back.
local function geometry_of(win)
  local win_config = vim.api.nvim_win_get_config(win)
  if win_config.relative ~= "" then
    return {
      position = "float",
      width = win_config.width,
      height = win_config.height,
      -- `row`/`col` come back as floats even when they were given as integers.
      row = math.floor(win_config.row),
      col = math.floor(win_config.col),
    }
  end

  local position = edge(win)
  if not position then
    return nil
  end
  if position == "top" or position == "bottom" then
    return { position = position, height = vim.api.nvim_win_get_height(win) }
  end
  return { position = position, width = vim.api.nvim_win_get_width(win) }
end

---Take down where `win` is now, keeping the last placement that could be
---reproduced when this one cannot.
---@param win integer
local function remember(win)
  remembered = geometry_of(win) or remembered
end

---@param opts tasksd.output.window.Opts
---@return tasksd.output.Geometry
local function resolve(opts)
  local from = not opts.reset and remembered or nil
  local position = opts.position or (from and from.position) or opts.default.position
  assert(
    vim.tbl_contains(M.POSITIONS, position),
    ("`%s` is not a position, expected one of: %s"):format(
      tostring(position),
      table.concat(M.POSITIONS, ", ")
    )
  )

  local size = opts.default.size
  local geometry = {
    position = position,
    width = (from and from.width) or dimension(size, "width", vim.o.columns),
    height = (from and from.height) or dimension(size, "height", vim.o.lines),
  }
  if position == "float" then
    geometry.row = (from and from.row) or math.floor((vim.o.lines - geometry.height) / 2)
    geometry.col = (from and from.col) or math.floor((vim.o.columns - geometry.width) / 2)
  end
  return geometry
end

---@param geometry tasksd.output.Geometry
---@return vim.api.keyset.win_config
local function win_config(geometry)
  if geometry.position == "float" then
    return {
      relative = "editor",
      width = geometry.width,
      height = geometry.height,
      row = geometry.row,
      col = geometry.col,
      border = "rounded",
      title = TITLE,
      title_pos = "center",
    }
  end

  -- `win = -1` splits the editor rather than the current window, which is what
  -- puts the split against an edge instead of beside whatever had the focus.
  local config = { split = SPLIT[geometry.position], win = -1 }
  if geometry.position == "top" or geometry.position == "bottom" then
    config.height = geometry.height
  else
    config.width = geometry.width
  end
  return config
end

---@param win integer
---@param geometry tasksd.output.Geometry
local function decorate(win, geometry)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = geometry.position == "float" and highlights.WINHIGHLIGHT.float
    or highlights.WINHIGHLIGHT.split
  -- Without these a panel is resized every time a split opens or closes beside
  -- it, because 'equalalways' redistributes the room among all the windows.
  vim.wo[win].winfixheight = geometry.position == "top" or geometry.position == "bottom"
  vim.wo[win].winfixwidth = geometry.position == "left" or geometry.position == "right"
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

---@return integer|nil
M.win = function()
  if current and vim.api.nvim_win_is_valid(current) then
    return current
  end
  return nil
end

---@return boolean
M.is_open = function()
  return M.win() ~= nil
end

---@param win integer
---@param on_close fun()|nil
local function watch_close(win, on_close)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      -- WinClosed runs while the window is still there, which is the last
      -- moment its placement can be read at all.
      remember(win)
      current = nil
      if on_close then
        on_close()
      end
    end,
  })
end

---Show `buf` in the output window, opening it if it is not open and moving it
---if it is.
---@param buf integer
---@param opts tasksd.output.window.Opts
---@return integer win
M.open = function(buf, opts)
  highlights.ensure()

  local win = M.win()
  -- An open window has been resized and moved since it opened; where it is now
  -- is the placement to keep, not the one it was last closed at.
  if win then
    remember(win)
  end

  local geometry = resolve(opts)
  if win then
    -- Reconfigured rather than reopened: closing would fire `on_close`, which
    -- to this window's owner means the output is no longer wanted.
    vim.api.nvim_win_set_config(win, win_config(geometry))
    vim.api.nvim_win_set_buf(win, buf)
  else
    win = vim.api.nvim_open_win(buf, opts.enter ~= false, win_config(geometry))
    current = win
    watch_close(win, opts.on_close)
  end

  decorate(win, geometry)
  return win
end

---@return boolean closed false when there was nothing open.
M.close = function()
  local win = M.win()
  if not win then
    return false
  end
  vim.api.nvim_win_close(win, true)
  return true
end

---@param buf integer
---@param opts tasksd.output.window.Opts
---@return integer|nil win nil when the call closed the window.
M.toggle = function(buf, opts)
  -- A position or a reset is an instruction about where the window goes, so it
  -- moves an open window rather than closing it.
  if M.is_open() and not opts.position and not opts.reset then
    M.close()
    return nil
  end
  return M.open(buf, opts)
end

---Forget where the window last was, so the next open uses `default` again.
M.forget = function()
  remembered = nil
end

return M
