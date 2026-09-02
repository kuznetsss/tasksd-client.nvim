local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local last = require("tasksd.last")

---A connection is only ever compared by identity here, so a socket path is all
---one has to have.
---@param socket_path string
---@return tasksd.Client
local function fake_client(socket_path)
  local client = { socket_path = socket_path }
  ---@cast client tasksd.Client
  return client
end

---@param command string
---@return tasksd.TaskStartParams
local function params(command)
  return {
    executable = command,
    args = {},
    working_dir = "/tmp",
    subscribe_to_output = false,
  }
end

-- `require` keeps the module between cases, so the table has to be emptied.
local T = new_set({ hooks = { post_case = last.reset } })

T["for_client()"] = new_set()

T["for_client()"]["has nothing to say about a daemon nothing was started on"] = function()
  local found, id = last.for_client(fake_client("/tmp/a.sock"))
  eq(found, nil)
  eq(id, nil)
end

T["for_client()"]["gives back what was recorded"] = function()
  local c = fake_client("/tmp/a.sock")
  last.record(c, 7, params("ls"))

  local found, id = last.for_client(c)
  eq(found, params("ls"))
  eq(id, 7)
end

T["for_client()"]["keeps only the most recent"] = function()
  local c = fake_client("/tmp/a.sock")
  last.record(c, 7, params("ls"))
  last.record(c, 8, params("true"))

  local found, id = last.for_client(c)
  eq(assert(found).executable, "true")
  eq(id, 8)
end

-- A daemon per project is the default, and its command belongs to its project.
T["for_client()"]["keeps one task per socket"] = function()
  local a, b = fake_client("/tmp/a.sock"), fake_client("/tmp/b.sock")
  last.record(a, 1, params("ls"))
  last.record(b, 1, params("true"))

  eq(assert((last.for_client(a))).executable, "ls")
  eq(assert((last.for_client(b))).executable, "true")
end

-- The id is the daemon's; the params are the user's.
T["for_client()"]["drops the id for a later connection to the same socket"] = function()
  last.record(fake_client("/tmp/a.sock"), 7, params("ls"))

  local found, id = last.for_client(fake_client("/tmp/a.sock"))
  eq(assert(found).executable, "ls")
  eq(id, nil)
end

T["reset()"] = new_set()

T["reset()"]["forgets every daemon"] = function()
  local a, b = fake_client("/tmp/a.sock"), fake_client("/tmp/b.sock")
  last.record(a, 1, params("ls"))
  last.record(b, 1, params("true"))

  last.reset()

  eq(last.for_client(a), nil)
  eq(last.for_client(b), nil)
end

return T
