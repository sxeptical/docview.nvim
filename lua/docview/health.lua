local M = {}

local function check_pages()
  vim.health.start("docview: page view")
  local ok = pcall(require, "snacks")
  if not ok or not Snacks.image then
    vim.health.warn("snacks.nvim not found; documents open as text")
  elseif not Snacks.image.supports_terminal() then
    vim.health.warn("terminal does not support the kitty graphics protocol (kitty, Ghostty, WezTerm); documents open as text")
  else
    vim.health.ok("snacks.nvim image support in " .. Snacks.image.terminal.env().name)
  end
  if vim.fn.executable("gs") == 1 then
    vim.health.ok("Ghostscript renders pages")
  else
    vim.health.warn("Ghostscript not found (brew install ghostscript)")
  end
  local soffice = vim.fn.executable("soffice") == 1
    or vim.fn.executable("/Applications/LibreOffice.app/Contents/MacOS/soffice") == 1
  if soffice then
    vim.health.ok("LibreOffice converts Word, PowerPoint and Excel files to pages")
  else
    vim.health.warn("LibreOffice not found; only PDFs get a page view (brew install --cask libreoffice)")
  end
end

function M.check()
  local docview = require("docview")
  if docview.config.view == "pages" then
    check_pages()
  end
  vim.health.start("docview: text view")
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
