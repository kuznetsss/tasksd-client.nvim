local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local window = require("tasksd.output.window")

---@type tasksd.output.Placement
local DEFAULT = { position = "bottom", size = "30%" }

---@param opts table|nil
---@return integer win
local function open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  return window.open(buf, vim.tbl_extend("force", { default = DEFAULT }, opts or {}))
end

---Where the window ended up, in screen cells. Read from the screen rather than
---from the layout tree, so a wrong edge cannot agree with the module's own
---mistake about which edge it is.
---@param win integer
---@return {row: integer, col: integer, width: integer, height: integer}
local function place(win)
  local row, col = unpack(vim.api.nvim_win_get_position(win))
  return {
    row = row,
    col = col,
    width = vim.api.nvim_win_get_width(win),
    height = vim.api.nvim_win_get_height(win),
  }
end

local T = new_set({
  hooks = {
    -- The window and the remembered placement are module-level state, and a
    -- case that fails part-way must not hand either to the next one.
    post_case = function()
      window.close()
      window.forget()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if win ~= vim.api.nvim_get_current_win() then
          vim.api.nvim_win_close(win, true)
        end
      end
    end,
  },
})

T["open()"] = new_set()

T["open()"]["puts a split against the configured edge"] = function()
  local win = open()
  local at = place(win)
  eq(at.width, vim.o.columns)
  eq(at.height, math.floor(vim.o.lines * 0.3))
  MiniTest.expect.equality(at.row > 0, true)
end

T["open()"]["reads a size as a count of lines"] = function()
  local win = open({ default = { position = "bottom", size = 5 } })
  eq(place(win).height, 5)
end

T["open()"]["sizes a vertical split by width"] = function()
  local win = open({ default = { position = "right", size = 20 } })
  local at = place(win)
  eq(at.width, 20)
  MiniTest.expect.equality(at.col > 0, true)
end

T["open()"]["centres a float at the configured size"] = function()
  local win = open({
    default = { position = "float", size = { width = "50%", height = 8 } },
  })
  eq(vim.api.nvim_win_get_config(win).relative, "editor")
  local at = place(win)
  eq(at.width, math.floor(vim.o.columns * 0.5))
  eq(at.height, 8)
end

T["open()"]["rejects a position it cannot place"] = function()
  MiniTest.expect.error(function()
    open({ position = "middle" })
  end, "not a position")
end

T["open()"]["moves an already open window instead of opening a second"] = function()
  local first = open()
  local second = open({ position = "right" })
  eq(first, second)
  eq(#vim.api.nvim_list_wins(), 2)
  MiniTest.expect.equality(place(second).col > 0, true)
end

T["remembers"] = new_set()

T["remembers"]["where the user moved the window to"] = function()
  local win = open()
  vim.api.nvim_win_set_config(win, { split = "right", win = -1 })
  vim.api.nvim_win_set_width(win, 33)
  window.close()

  local at = place(open())
  eq(at.width, 33)
  MiniTest.expect.equality(at.col > 0, true)
end

T["remembers"]["the size the user gave a split"] = function()
  local win = open()
  vim.api.nvim_win_set_height(win, 4)
  window.close()

  eq(place(open()).height, 4)
end

T["remembers"]["where a float was dragged to"] = function()
  local win = open({ default = { position = "float", size = 10 } })
  vim.api.nvim_win_set_config(win, { relative = "editor", row = 2, col = 3 })
  window.close()

  local config = vim.api.nvim_win_get_config(open({ default = { position = "float", size = 10 } }))
  eq({ config.row, config.col }, { 2, 3 })
end

T["remembers"]["nothing about a window parked off the editor's edges"] = function()
  local base = vim.api.nvim_get_current_win()
  local win = open()
  vim.api.nvim_win_set_height(win, 4)
  window.close()

  win = open()
  vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { split = "below", win = -1 })
  -- Nested beside `base` rather than against an edge, which is a placement
  -- reopening cannot reproduce, so the last one that could is kept instead.
  vim.api.nvim_win_set_config(win, { split = "right", win = base })
  window.close()

  eq(place(open()).height, 4)
end

T["reset"] = new_set()

T["reset"]["puts the window back where the config says"] = function()
  local win = open()
  vim.api.nvim_win_set_height(win, 4)
  window.close()

  eq(place(open({ reset = true })).height, math.floor(vim.o.lines * 0.3))
end

T["reset"]["forgets the placement, so the next plain open agrees"] = function()
  local win = open()
  vim.api.nvim_win_set_height(win, 4)
  window.close()
  window.close() -- the reset open below is what re-remembers
  open({ reset = true })
  window.close()

  eq(place(open()).height, math.floor(vim.o.lines * 0.3))
end

T["reset"]["an explicit position wins over what is remembered"] = function()
  local win = open()
  vim.api.nvim_win_set_height(win, 4)
  window.close()

  MiniTest.expect.equality(place(open({ position = "left" })).col, 0)
end

T["toggle()"] = new_set()

T["toggle()"]["closes a window that is open"] = function()
  open()
  eq(window.toggle(vim.api.nvim_create_buf(false, true), { default = DEFAULT }), nil)
  eq(window.is_open(), false)
end

T["toggle()"]["opens a window that is not"] = function()
  local win = window.toggle(vim.api.nvim_create_buf(false, true), { default = DEFAULT })
  eq(window.win(), win)
end

T["toggle()"]["moves rather than closes when given a position"] = function()
  local win = open()
  local moved = window.toggle(vim.api.nvim_create_buf(false, true), {
    default = DEFAULT,
    position = "right",
  })
  eq(moved, win)
  MiniTest.expect.equality(place(win).col > 0, true)
end

T["on_close"] = new_set()

T["on_close"]["runs when the window is closed from outside"] = function()
  local closed = 0
  local win = open({
    on_close = function()
      closed = closed + 1
    end,
  })
  vim.api.nvim_win_close(win, true)
  eq(closed, 1)
  eq(window.is_open(), false)
end

T["on_close"]["does not run when the window only moves"] = function()
  local closed = 0
  open({
    on_close = function()
      closed = closed + 1
    end,
  })
  open({ position = "float" })
  eq(closed, 0)
  eq(window.is_open(), true)
end

return T
