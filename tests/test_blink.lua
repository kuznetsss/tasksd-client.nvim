local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local blink = require("tasksd.blink")

---Run `fn` with a stand-in for blink.cmp on `package.loaded`, so this suite
---never needs the real plugin on the runtimepath.
---@param stub table|nil nil makes `require("blink.cmp")` fail, as when it is not installed.
---@param fn fun(stub: table|nil)
local function with_blink(stub, fn)
  local original = package.loaded["blink.cmp"]
  package.loaded["blink.cmp"] = stub
  blink.reset()

  local ok, err = pcall(fn, stub)

  package.loaded["blink.cmp"] = original
  blink.reset()
  if not ok then
    error(err, 0)
  end
end

---@return table stub, table calls
local function stub_blink()
  local calls = { providers = {}, filetypes = {} }
  return {
    add_source_provider = function(id, config)
      table.insert(calls.providers, { id = id, config = config })
    end,
    add_filetype_source = function(filetype, id)
      table.insert(calls.filetypes, { filetype = filetype, id = id })
    end,
  },
    calls
end

local T = new_set()

T["register()"] = new_set()

T["register()"]["registers a provider for the form filetype"] = function()
  local stub, calls = stub_blink()
  with_blink(stub, function()
    eq(blink.register("tasksd-form"), true)

    eq(#calls.providers, 1)
    eq(calls.providers[1].config.module, "blink.cmp.sources.complete_func")
    eq(calls.filetypes, { { filetype = "tasksd-form", id = calls.providers[1].id } })
  end)
end

T["register()"]["points the provider at the buffer's completefunc"] = function()
  local stub, calls = stub_blink()
  with_blink(stub, function()
    blink.register("tasksd-form")

    vim.bo.completefunc = "v:lua.require'tasksd.form'.complete"
    eq(calls.providers[1].config.opts.complete_func(), "v:lua.require'tasksd.form'.complete")
    vim.bo.completefunc = ""
  end)
end

T["register()"]["registers once, because blink rejects a duplicate id"] = function()
  local stub, calls = stub_blink()
  with_blink(stub, function()
    blink.register("tasksd-form")
    blink.register("tasksd-form")

    eq(#calls.providers, 1)
    eq(#calls.filetypes, 1)
  end)
end

T["register()"]["reports blink missing rather than failing"] = function()
  with_blink(nil, function()
    eq(blink.register("tasksd-form"), false)
  end)
end

T["register()"]["reports a blink without the runtime API"] = function()
  with_blink({}, function()
    eq(blink.register("tasksd-form"), false)
  end)
end

return T
