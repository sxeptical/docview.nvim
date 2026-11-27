-- Previews documents in snacks.nvim's picker, which would otherwise call them binary files.
-- The text shows at once; the first page replaces it when it has been rendered (cached,
-- so the next time a document is previewed its page shows immediately).
local M = {}

---@type table<string, {key:string, lines:string[], ft:string}>
local text_cache = {}

local function document_text(path, ext)
  local stat = vim.uv.fs_stat(path)
  local key = stat and (stat.size .. ":" .. stat.mtime.sec .. ":" .. stat.mtime.nsec) or ""
  local hit = text_cache[path]
  if hit and hit.key == key then
    return hit.lines, hit.ft
  end
  local text, conv = require("docview").convert(path, ext)
  local lines, ft
  if text then
    lines = vim.split(vim.trim(text:gsub("\r\n?", "\n")), "\n", { plain = true })
    ft = conv.ft
    if #lines == 1 and lines[1] == "" then
      lines = { "(no text found in document)" }
    end
  else
    lines, ft = { "No text preview: no converter for ." .. ext .. " is installed." }, "text"
  end
  text_cache[path] = { key = key, lines = lines, ft = ft }
  return lines, ft
end

local function show_page(ctx, path, png)
  local buf = ctx.preview:scratch()
  ctx.preview:set_title(vim.fn.fnamemodify(path, ":t"))
  Snacks.image.buf.attach(buf, { src = png })
end

--- Previews `ctx.item` if it is a document; returns false to leave it to snacks.
---@param ctx snacks.picker.preview.ctx
function M.file(ctx)
  local docview = require("docview")
  if not docview.config.picker.enabled then
    return false
  end
  local item = ctx.item
  if item.buf and vim.api.nvim_buf_is_loaded(item.buf) then
    return false
  end
  local path = Snacks.picker.util.path(item)
  if not path or vim.fn.isdirectory(path) == 1 or not vim.uv.fs_stat(path) then
    return false
  end
  local ext = vim.fn.fnamemodify(path, ":e"):lower()
  if not vim.tbl_contains(docview.config.extensions, ext) then
    return false
  end
  -- snacks draws PDFs (page 1) itself when its image support is on.
  if Snacks.image.supports_file(path) and Snacks.image.config.enabled ~= false then
    return false
  end

  local pages = require("docview.pages")
  if docview.config.picker.pages and pages.available(path) then
    local shown = false
    pages.first_page(path, function(png)
      -- Already cached: show the page straight away instead of the text.
      if not shown then
        shown = true
        return show_page(ctx, path, png)
      end
      -- Rendered later: only if the picker still shows this item.
      if ctx.preview.item == item and ctx.preview.win:valid() then
        show_page(ctx, path, png)
      end
    end)
    if shown then
      return true
    end
    shown = true
  end

  local lines, ft = document_text(path, ext)
  ctx.preview:reset()
  ctx.preview:set_title(vim.fn.fnamemodify(path, ":t"))
  ctx.preview:set_lines(lines)
  ctx.preview:highlight({ ft = ft })
  return true
end

--- Makes snacks' file previewer hand documents to `M.file`.
function M.hook()
  local ok, previewers = pcall(require, "snacks.picker.preview")
  if not ok or type(previewers) ~= "table" or previewers._docview then
    return
  end
  local file = previewers.file
  previewers.file = function(ctx)
    local handled, res = pcall(M.file, ctx)
    if handled and res then
      return
    end
    return file(ctx)
  end
  previewers._docview = true
end

return M
