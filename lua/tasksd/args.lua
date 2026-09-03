---`key=value` subcommand arguments: how a subcommand that asks more than one
---question takes its answers. Order never matters, and any one question can be
---answered on the command line without answering the rest -- leaving a question
---out is what opens a picker for it.
local M = {}

---@param argv string[] The subcommand's own arguments, without its name.
---@param keys string[] Accepted keys, each written with its `=`, sorted.
---@param greedy? string A key that takes the rest of the line, so its value can hold spaces.
---@return table<string, string>|nil values, string|nil err
M.parse = function(argv, keys, greedy)
  local values = {}
  for i, arg in ipairs(argv) do
    local key, value = arg:match("^([%w_]+)=(.*)$")
    if not key then
      return nil, ("expected key=value, got `%s`"):format(arg)
    end
    if not vim.tbl_contains(keys, key .. "=") then
      return nil,
        ("unknown argument `%s`, expected one of: %s"):format(key, table.concat(keys, ", "))
    end
    -- The command line arrives already split on whitespace, so a greedy key
    -- takes everything after it or it could never carry a space. Runs of
    -- whitespace collapse to one; anything more exact belongs in Lua.
    if key == greedy then
      values[key] = table.concat(vim.list_extend({ value }, vim.list_slice(argv, i + 1)), " ")
      break
    end
    values[key] = value
  end
  return values, nil
end

---@type string[]
M.BOOLEANS = { "false", "true" }

---@param value string
---@return boolean|nil, string|nil err
M.boolean = function(value)
  if value == "true" then
    return true, nil
  end
  if value == "false" then
    return false, nil
  end
  return nil, ("expected true or false, got `%s`"):format(value)
end

---The keys until one has been typed, then that key's own candidates.
---
---A key with nothing in `values` completes to nothing rather than falling back
---to the key list, which would offer `task_id=signal=`.
---@param arg_lead string
---@param keys string[]
---@param values table<string, fun(lead: string): string[]> Candidates per key, without the `key=`.
---@return string[]
M.complete = function(arg_lead, keys, values)
  local key, lead = arg_lead:match("^([%w_]+)=(.*)$")
  if key then
    local candidates = values[key]
    if not candidates then
      return {}
    end
    return vim.tbl_map(function(match)
      return key .. "=" .. match
    end, candidates(lead))
  end

  return vim.tbl_filter(function(name)
    return vim.startswith(name, arg_lead)
  end, keys)
end

---@param lead string
---@param candidates string[]
---@return string[]
M.starting_with = function(lead, candidates)
  return vim.tbl_filter(function(candidate)
    return vim.startswith(candidate, lead)
  end, candidates)
end

return M
