---`vim.ui.select`: the backend with no dependency, and the one `auto` falls
---back to. Plain text only, so `chunks` go unused.
---@type tasksd.picker.Backend
return {
  is_available = function()
    return true
  end,

  pick = function(spec)
    vim.ui.select(spec.items, {
      prompt = spec.title,
      ---@param item tasksd.picker.Item
      format_item = function(item)
        return item.text
      end,
    }, function(item)
      if item and spec.on_choice then
        spec.on_choice(item.value)
      end
    end)
  end,
}
