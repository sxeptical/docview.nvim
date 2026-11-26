-- Page view: renders each page of a document to a PNG and shows it with snacks.nvim's
-- image support (kitty graphics protocol), the way a PDF viewer would.
--
-- Office files go through LibreOffice to become a PDF, Ghostscript turns PDF pages into
-- PNGs, and everything is cached by file path, size and mtime so reopening is instant.
-- Each page is laid over as many blank buffer lines as it is tall, so it scrolls line by line.
local M = {}

---@class docview.PageState
---@field source string
---@field dir string cache directory
---@field pdf? string
---@field count? number
---@field rendered table<number, boolean>
---@field layout table<number, {header:number, first:number, last:number, width:number, offset:number}>
---@field placed table<number, snacks.image.Placement>
---@field zoom number
---@field status? string
---@field closed? boolean

---@type table<number, docview.PageState>
M.state = {}

local group = vim.api.nvim_create_augroup("docview.pages", { clear = true })
local header_fmt = "── Page %d of %d ──"

local function config()
  return require("docview").config.pages
end

local function soffice()
  for _, bin in ipairs({ "soffice", "/Applications/LibreOffice.app/Contents/MacOS/soffice" }) do
    if vim.fn.executable(bin) == 1 then
      return bin
    end
  end
end

--- Whether pages can be shown for this file; the second value explains why not.
function M.available(path)
  local ok = pcall(require, "snacks")
  if not ok or not Snacks.image then
    return false, "snacks.nvim is not installed"
  end
  if not Snacks.image.supports_terminal() or not Snacks.image.terminal.env().placeholders then
    return false, "this terminal cannot show images (needs kitty, Ghostty or WezTerm)"
  end
  if vim.fn.executable("gs") == 0 then
    return false, "Ghostscript is not installed (brew install ghostscript)"
  end
  if vim.fn.fnamemodify(path, ":e"):lower() ~= "pdf" and not soffice() then
    return false, "LibreOffice is not installed (brew install --cask libreoffice)"
  end
  return true
end

local function run(cmd, cb)
  local ok, err = pcall(vim.system, cmd, { text = true }, function(r)
    vim.schedule(function()
      cb(r.code == 0, vim.trim(r.stderr or ""))
    end)
  end)
  if not ok then
    cb(false, err)
  end
end

local function exists(file)
  return vim.uv.fs_stat(file) ~= nil
end

local function page_png(st, i)
  return ("%s/page-%04d.png"):format(st.dir, i)
end

local function cache_dir(path)
  local stat = assert(vim.uv.fs_stat(path))
  local key = table.concat({ path, stat.size, stat.mtime.sec, stat.mtime.nsec, config().dpi }, ":")
  local dir = vim.fn.stdpath("cache") .. "/docview/" .. vim.fn.sha256(key):sub(1, 16)
  vim.fn.mkdir(dir, "p")
  return dir
end

-- LibreOffice cannot run twice on one profile, so conversions wait their turn.
local office_queue, office_busy = {}, false

local function next_conversion()
  if office_busy or #office_queue == 0 then
    return
  end
  office_busy = true
  local job = table.remove(office_queue, 1)
  -- A private profile lets this run while the LibreOffice app is open.
  local profile = vim.uri_from_fname(vim.fn.stdpath("cache") .. "/docview/libreoffice-profile")
  local cmd = { soffice(), "-env:UserInstallation=" .. profile, "--headless", "--norestore" }
  vim.list_extend(cmd, { "--convert-to", "pdf", "--outdir", job.dir, job.source })
  local produced = job.dir .. "/" .. vim.fn.fnamemodify(job.source, ":t:r") .. ".pdf"
  local function attempt(tries)
    run(cmd, function(_, err)
      -- soffice exits 0 even when the conversion fails, and a fresh profile occasionally
      -- exits before converting, so check for the file and retry once.
      if not exists(produced) and tries < 2 then
        return attempt(tries + 1)
      end
      office_busy = false
      if exists(produced) then
        vim.uv.fs_rename(produced, job.out)
        job.cb(job.out)
      else
        local lines = vim.tbl_filter(function(l)
          return not l:find("^Fontconfig")
        end, vim.split(err, "\n"))
        local detail = vim.trim(table.concat(lines, " "))
        job.cb(nil, "LibreOffice could not convert the file" .. (detail ~= "" and (": " .. detail) or ""))
      end
      next_conversion()
    end)
  end
  attempt(1)
end

local function to_pdf(st, cb)
  if vim.fn.fnamemodify(st.source, ":e"):lower() == "pdf" then
    return cb(st.source)
  end
  local out = st.dir .. "/document.pdf"
  if exists(out) then
    return cb(out)
  end
  table.insert(office_queue, { source = st.source, dir = st.dir, out = out, cb = cb })
  next_conversion()
end

local function ps_string(s)
  return "(" .. s:gsub("[\\()]", "\\%0") .. ")"
end

local function page_count(pdf, cb)
  local cmd = { "gs", "-q", "-dNODISPLAY", "-dNOSAFER", "-dBATCH", "-dNOPAUSE" }
  vim.list_extend(cmd, { "-c", ps_string(pdf) .. " (r) file runpdfbegin pdfpagecount = quit" })
  vim.system(cmd, { text = true }, function(r)
    vim.schedule(function()
      cb(tonumber(vim.trim(r.stdout or "")))
    end)
  end)
end

local function render_range(st, first, last, cb)
  local pattern = ("%s/chunk-%d-%%d.png"):format(st.dir, first)
  local cmd = { "gs", "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=png16m", "-r" .. config().dpi }
  vim.list_extend(cmd, { "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4" })
  vim.list_extend(cmd, { "-dFirstPage=" .. first, "-dLastPage=" .. last, "-o", pattern, st.pdf })
  run(cmd, function(ok, err)
    for i = first, last do
      local chunk = pattern:format(i - first + 1)
      if exists(chunk) then
        vim.uv.fs_rename(chunk, page_png(st, i))
      end
    end
    cb(ok, err)
  end)
end

local function win_for(buf)
  local win = vim.fn.bufwinid(buf)
  return win ~= -1 and win or nil
end

-- Window options that would push the page off-centre or draw over it.
local plain_window = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  cursorline = false,
  colorcolumn = "",
  list = false,
  wrap = false,
  spell = false,
}

local function set_window_options(win, plain)
  for name, value in pairs(plain_window) do
    if not plain then
      value = vim.go[name]
    end
    pcall(vim.api.nvim_set_option_value, name, value, { scope = "local", win = win })
  end
end

local function close_placements(st)
  for i, p in pairs(st.placed) do
    pcall(p.close, p)
    st.placed[i] = nil
  end
end

-- Only pages near the viewport get an image, so long documents stay light.
function M.sync(buf)
  local st, win = M.state[buf], win_for(buf)
  if not st or st.closed or not win or not st.count then
    return
  end
  local top, bot = vim.fn.line("w0", win), vim.fn.line("w$", win)
  local margin = vim.api.nvim_win_get_height(win)
  for i, l in pairs(st.layout) do
    local near = l.last >= top - margin and l.first <= bot + margin
    if near and not st.placed[i] then
      st.placed[i] = Snacks.image.placement.new(buf, page_png(st, i), {
        pos = { l.first, l.offset },
        range = { l.first, l.offset, l.last, l.offset },
        inline = true,
        conceal = true,
        width = l.width,
        height = l.last - l.first + 1,
        type = "image",
      })
    elseif not near and st.placed[i] then
      pcall(st.placed[i].close, st.placed[i])
      st.placed[i] = nil
    end
  end
end

local function current_position(buf, st)
  local win = win_for(buf)
  if not win then
    return
  end
  local function locate(lnum)
    local best
    for i, l in pairs(st.layout) do
      if l.header <= lnum and (not best or l.header > st.layout[best].header) then
        best = i
      end
    end
    if not best then
      return { page = 1, frac = 0 }
    end
    local l = st.layout[best]
    return { page = best, frac = (lnum - l.header) / math.max(1, l.last - l.header + 1) }
  end
  return { cursor = locate(vim.fn.line(".", win)), top = locate(vim.fn.line("w0", win)) }
end

local function restore_position(buf, st, pos)
  local win = win_for(buf)
  if not win or not pos then
    return
  end
  local function lnum(loc)
    local l = st.layout[loc.page]
    if not l then
      return 1
    end
    return l.header + math.floor(loc.frac * (l.last - l.header + 1) + 0.5)
  end
  local count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({
      topline = math.min(count, lnum(pos.top)),
      lnum = math.min(count, lnum(pos.cursor)),
      col = 0,
    })
  end)
end

--- Lays out the buffer: a header per page and enough blank lines for each page image.
function M.draw(buf)
  local st, win = M.state[buf], win_for(buf)
  if not st or st.closed then
    return
  end
  local pos = st.count and next(st.layout) and current_position(buf, st)
  close_placements(st)
  st.layout = {}

  local lines = {}
  if not st.count then
    lines = { "  " .. (st.status or "Rendering pages…") }
  else
    local info = win and vim.fn.getwininfo(win)[1]
    local avail = info and (info.width - info.textoff - 1) or vim.o.columns
    local cells = Snacks.image.terminal.size()
    -- Zoom scales the fitted width; pages can't grow past the window (no horizontal scroll).
    local fit = math.min(avail, config().max_width)
    st.zoom = math.min(st.zoom, avail / fit)
    local width = math.max(20, math.min(avail, math.floor(fit * st.zoom)))
    for i = 1, st.count do
      local png = page_png(st, i)
      local w, h = width, nil
      if st.rendered[i] then
        local dim = Snacks.image.util.dim(png)
        -- Never wider than the image's natural size, or snacks would draw it smaller.
        local natural = math.floor(dim.width / config().dpi * 96 * cells.scale / cells.cell_width)
        w = math.min(w, natural)
        h = math.ceil(w * dim.height / dim.width * cells.cell_width / cells.cell_height)
      end
      local offset = math.max(0, math.floor((avail - w) / 2))
      local pad = string.rep(" ", offset)
      local title = header_fmt:format(i, st.count)
      local header = #lines + 1
      lines[#lines + 1] = string.rep(" ", math.max(0, math.floor((avail - vim.fn.strdisplaywidth(title)) / 2))) .. title
      if h then
        for _ = 1, h do
          lines[#lines + 1] = pad
        end
        st.layout[i] = { header = header, first = header + 1, last = header + h, width = w, offset = offset }
      else
        lines[#lines + 1] = pad .. "rendering…"
      end
      lines[#lines + 1] = ""
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  if win then
    set_window_options(win, true)
  end
  restore_position(buf, st, pos)
  M.sync(buf)
end

local function render_all(buf, st)
  local chunk, total = config().chunk_size, st.count
  local function step(first)
    if st.closed or first > total then
      return
    end
    local last = math.min(total, first + chunk - 1)
    local cached = true
    for i = first, last do
      cached = cached and exists(page_png(st, i))
    end
    local function done()
      for i = first, last do
        st.rendered[i] = exists(page_png(st, i))
      end
      M.draw(buf)
      step(last + 1)
    end
    if cached then
      done()
    else
      render_range(st, first, last, function(ok, err)
        if not ok then
          vim.notify("docview: Ghostscript failed: " .. err, vim.log.levels.WARN)
        end
        done()
      end)
    end
  end
  step(1)
end

--- Shows `path` as page images in `buf`. `on_fail(reason)` is called if that is not possible.
function M.show(buf, path, on_fail)
  M.stop(buf)
  local st = {
    source = path,
    dir = cache_dir(path),
    rendered = {},
    layout = {},
    placed = {},
    zoom = 1,
    status = vim.fn.fnamemodify(path, ":e"):lower() == "pdf" and "Rendering pages…"
      or "Converting with LibreOffice…",
  }
  M.state[buf] = st
  M.draw(buf)

  to_pdf(st, function(pdf, err)
    if st.closed then
      return
    end
    if not pdf then
      return on_fail(err)
    end
    st.pdf = pdf
    page_count(pdf, function(count)
      if st.closed then
        return
      end
      if not count or count < 1 then
        return on_fail("Ghostscript could not read the PDF")
      end
      st.count = count
      render_all(buf, st)
    end)
  end)

  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.stop(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      M.draw(buf)
    end,
  })
end

local pending = {}
local function schedule(buf, fn)
  if pending[buf] then
    return
  end
  pending[buf] = true
  vim.schedule(function()
    pending[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      fn(buf)
    end
  end)
end

vim.api.nvim_create_autocmd("WinScrolled", {
  group = vim.api.nvim_create_augroup("docview.pages.scroll", { clear = true }),
  callback = function()
    for buf in pairs(M.state) do
      if win_for(buf) then
        schedule(buf, M.sync)
      end
    end
  end,
})

vim.api.nvim_create_autocmd("WinResized", {
  group = vim.api.nvim_create_augroup("docview.pages.resize", { clear = true }),
  callback = function()
    for _, win in ipairs(vim.v.event.windows or {}) do
      local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
      if buf and M.state[buf] then
        schedule(buf, M.draw)
      end
    end
  end,
})

--- Stops rendering and removes the page images; the buffer keeps its lines.
function M.stop(buf)
  local st = M.state[buf]
  if not st then
    return
  end
  st.closed = true
  close_placements(st)
  M.state[buf] = nil
  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
  local win = win_for(buf)
  if win then
    set_window_options(win, false)
  end
end

function M.zoom(buf, delta)
  local st = M.state[buf]
  if not st then
    return
  end
  st.zoom = delta == 0 and 1 or math.max(0.3, math.min(3, st.zoom + delta))
  M.draw(buf)
end

return M
