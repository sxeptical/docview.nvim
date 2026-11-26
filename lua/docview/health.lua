local M = {}

function M.check()
  local docview = require("docview")
  vim.health.start("docview")
  for _, ext in ipairs(docview.config.extensions) do
    local available, missing = {}, {}
    for _, conv in ipairs(docview.converters[ext] or {}) do
      table.insert(conv.available() and available or missing, conv.name)
    end
    if #available > 0 then
      local msg = ("." .. ext .. ": using %s"):format(available[1])
      if #missing > 0 then
        msg = msg .. (" (not installed: %s)"):format(table.concat(missing, ", "))
      end
      vim.health.ok(msg)
    else
      vim.health.warn(("." .. ext .. ": no converter available (install one of: %s)"):format(table.concat(missing, ", ")))
    end
  end
end

return M
