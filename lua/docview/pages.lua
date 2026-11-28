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
---@field placed_at table<number, table> the layout each placement was drawn with
---@field dirty_from? number first buffer line replaced since the last sync
---@field sharpening table<string, boolean> sharper renders started, as "page@dpi"
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

-- Pages are rendered at `config.dpi`; zooming in re-renders the visible ones sharper.
local function page_png(st, i, dpi)
  return ("%s/page-%04d-%d.png"):format(st.dir, i, dpi or config().dpi)
end

-- The resolution snacks.nvim believes a PNG has. It reads ImageMagick's density, which
-- for PNGs is pixels per centimetre, and uses it as DPI; mirror that to know how large
-- snacks will draw a page, since it never scales an image beyond that size.
local function snacks_dpi(png)
  local fd = io.open(png, "rb")
  if not fd then
    return 72
  end
  local head = fd:read(512) or ""
  fd:close()
  local at = head:find("pHYs", 1, true)
  if not at then
    return 72
  end
  local x = head:byte(at + 4) * 16777216 + head:byte(at + 5) * 65536 + head:byte(at + 6) * 256 + head:byte(at + 7)
  local unit = head:byte(at + 12)
  if unit ~= 1 or x == 0 then
    return 72
  end
  return x / 100
end

local function cache_dir(path)
  local stat = assert(vim.uv.fs_stat(path))
  local key = table.concat({ path, stat.size, stat.mtime.sec, stat.mtime.nsec }, ":")
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

local function to_pdf(st, cb, preview)
  if vim.fn.fnamemodify(st.source, ":e"):lower() == "pdf" then
    return cb(st.source)
  end
  local out = st.dir .. "/document.pdf"
  if exists(out) then
    return cb(out)
  end
  if preview then
    -- Scrolling through a picker shouldn't queue a conversion per file: a newer preview
    -- replaces older ones that haven't started yet.
    for i = #office_queue, 1, -1 do
      if office_queue[i].preview then
        table.remove(office_queue, i)
      end
    end
  end
  table.insert(office_queue, { source = st.source, dir = st.dir, out = out, cb = cb, preview = preview })
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

local function render_range(st, first, last, cb, dpi)
  dpi = dpi or config().dpi
  local pattern = ("%s/chunk-%d-%d-%%d.png"):format(st.dir, dpi, first)
  local cmd = { "gs", "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=png16m", "-r" .. dpi }
  vim.list_extend(cmd, { "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4" })
  vim.list_extend(cmd, { "-dFirstPage=" .. first, "-dLastPage=" .. last, "-o", pattern, st.pdf })
  run(cmd, function(ok, err)
    for i = first, last do
      local chunk = pattern:format(i - first + 1)
      if exists(chunk) then
        vim.uv.fs_rename(chunk, page_png(st, i, dpi))
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

-- Closes a page's placement. Once an image has no placements left it is freed in the
-- terminal too: kitty keeps at most 320 MB of images and silently drops old unused ones
-- when that fills up (which zooming does quickly), while snacks would assume they are
-- still there and later draw an empty page.
local function release(p)
  pcall(p.close, p)
  local img = p.img
  if img and img.sent and not next(img.placements or {}) then
    pcall(Snacks.image.terminal.request, { a = "d", d = "I", i = img.id })
    img.sent = false
  end
end

local function place(buf, png, opts)
  -- An image left over from earlier may have been dropped by the terminal; send it again.
  local ok, img = pcall(Snacks.image.image.new, png)
  if ok and img.sent and not next(img.placements or {}) then
    img.sent = false
  end
  return Snacks.image.placement.new(buf, png, opts)
end

local function close_placements(st)
  for i, p in pairs(st.placed) do
    release(p)
    st.placed[i] = nil
  end
  st.placed_at = {}
end

local function same_layout(a, b)
  return a and b and a.first == b.first and a.last == b.last and a.width == b.width and a.offset == b.offset
end

-- Only pages near the viewport get an image, so long documents stay light. A page that is
-- already shown keeps its image in the terminal: if it moved or was resized, its placement
-- is redrawn in place, which costs nothing, instead of sending the image again.
function M.sync(buf)
  local st, win = M.state[buf], win_for(buf)
  if not st or st.closed or not win or not st.count then
    return
  end
  local dirty = st.dirty_from or math.huge
  st.dirty_from = nil
  local top, bot = vim.fn.line("w0", win), vim.fn.line("w$", win)
  local margin = vim.api.nvim_win_get_height(win)
  for i, p in pairs(st.placed) do
    if not st.layout[i] then
      release(p)
      st.placed[i], st.placed_at[i] = nil, nil
    end
  end
  for i, l in pairs(st.layout) do
    local near = l.last >= top - margin and l.first <= bot + margin
    if near then
      local png = page_png(st, i)
      if l.dpi > config().dpi then
        if exists(page_png(st, i, l.dpi)) then
          png = page_png(st, i, l.dpi)
        elseif not st.sharpening[i .. "@" .. l.dpi] then
          -- Show the page now and swap in a sharper render once it is ready.
          st.sharpening[i .. "@" .. l.dpi] = true
          render_range(st, i, i, function()
            local current = st.layout[i]
            if not st.closed and current and current.dpi == l.dpi and exists(page_png(st, i, l.dpi)) then
              M.sync(buf)
            end
          end, l.dpi)
        end
      end
      local p = st.placed[i]
      if p and p.img.src ~= png then
        release(p)
        st.placed[i], p = nil, nil
      end
      local opts = {
        pos = { l.first, l.offset },
        range = { l.first, l.offset, l.last, l.offset },
        inline = true,
        conceal = true,
        width = l.width,
        height = l.last - l.first + 1,
        type = "image",
      }
      if not p then
        st.placed[i] = place(buf, png, opts)
      elseif not same_layout(st.placed_at[i], l) or l.last >= dirty then
        p.opts = vim.tbl_extend("force", p.opts, opts)
        p._state = nil
        p:update()
      end
      st.placed_at[i] = vim.deepcopy(l)
    elseif st.placed[i] then
      release(st.placed[i])
      st.placed[i], st.placed_at[i] = nil, nil
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
      local w, h, dpi = width, nil, config().dpi
      if st.rendered[i] then
        local dim = Snacks.image.util.dim(png)
        -- Never wider than snacks' idea of the image's natural size, or it would draw it smaller.
        local natural = math.floor(dim.width / snacks_dpi(png) * 96 * cells.scale / cells.cell_width)
        w = math.min(w, natural)
        h = math.ceil(w * dim.height / dim.width * cells.cell_width / cells.cell_height)
        -- Resolution that gives about one image pixel per screen pixel at this width.
        local needed = w * cells.cell_width / (dim.width / config().dpi)
        if needed > dpi * 1.15 then
          -- Capped: a page at 480 DPI already takes ~85 MB of the terminal's image memory.
          dpi = math.min(480, math.ceil(needed / 60) * 60)
        end
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
        st.layout[i] = { header = header, first = header + 1, last = header + h, width = w, offset = offset, dpi = dpi }
      else
        lines[#lines + 1] = pad .. "rendering…"
      end
      lines[#lines + 1] = ""
    end
  end

  -- Only replace from the first changed line, so pages above keep their place untouched.
  local old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local from = 1
  while from <= #lines and from <= #old and lines[from] == old[from] do
    from = from + 1
  end
  if from <= #lines or #old > #lines then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, from - 1, -1, false, vim.list_slice(lines, from))
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    st.dirty_from = math.min(st.dirty_from or math.huge, from)
  end
  if win then
    set_window_options(win, true)
  end
  restore_position(buf, st, pos)
  M.sync(buf)
end

-- Coalesces redraws: several renders finishing together cause one redraw.
local function request_draw(buf, st)
  if st.draw_pending then
    return
  end
  st.draw_pending = true
  vim.schedule(function()
    st.draw_pending = false
    if not st.closed and vim.api.nvim_buf_is_valid(buf) then
      M.draw(buf)
    end
  end)
end

local function render_all(buf, st)
  local todo = {}
  for i = 1, st.count do
    if exists(page_png(st, i)) then
      st.rendered[i] = true
    else
      todo[#todo + 1] = i
    end
  end
  -- The first pages missing (the ones in view) get a job each so they appear as soon as
  -- possible; the rest are batched. Jobs run on several Ghostscript processes at once.
  local jobs, k = {}, 1
  while k <= #todo do
    local size = #jobs < 2 and 1 or config().chunk_size
    local first, last = todo[k], todo[k]
    while k < #todo and todo[k + 1] == last + 1 and last - first + 1 < size do
      k = k + 1
      last = todo[k]
    end
    jobs[#jobs + 1] = { first, last }
    k = k + 1
  end

  M.draw(buf)
  local next_job, running = 1, 0
  local function start()
    while not st.closed and running < math.max(1, config().jobs) and next_job <= #jobs do
      local job = jobs[next_job]
      next_job, running = next_job + 1, running + 1
      render_range(st, job[1], job[2], function(ok, err)
        running = running - 1
        if not ok and not st.warned then
          st.warned = true
          vim.notify("docview: Ghostscript failed: " .. err, vim.log.levels.WARN)
        end
        for i = job[1], job[2] do
          st.rendered[i] = exists(page_png(st, i))
        end
        request_draw(buf, st)
        start()
      end)
    end
  end
  start()
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
    placed_at = {},
    sharpening = {},
    zoom = 1,
    status = "Rendering pages…",
  }
  if vim.fn.fnamemodify(path, ":e"):lower() ~= "pdf" and not exists(st.dir .. "/document.pdf") then
    st.status = "Converting with LibreOffice…"
  end
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

--- Converts `path` to PDF if needed, then calls `cb(ready)`; `ready` is true when it was
--- already converted (or is a PDF), so `M.show` can draw pages without waiting.
--- Used by picker previews, whose conversions replace each other while queued.
function M.prepare(path, cb)
  local st = { source = path, dir = cache_dir(path) }
  local cached = vim.fn.fnamemodify(path, ":e"):lower() == "pdf" or exists(st.dir .. "/document.pdf")
  if cached then
    return cb(true)
  end
  to_pdf(st, function(pdf)
    if pdf then
      cb(false)
    end
  end, true)
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

--- Zooms by `delta` (0.2 = 20%); 0 fits the page to the window again.
function M.zoom(buf, delta)
  local st = M.state[buf]
  if not st or not st.count then
    return
  end
  local before = st.zoom
  st.zoom = delta == 0 and 1 or math.max(0.3, st.zoom + delta)
  M.draw(buf)
  local msg = ("docview: zoom %d%%"):format(math.floor(st.zoom * 100 + 0.5))
  if delta > 0 and st.zoom <= before + 1e-6 then
    msg = msg .. " (page already fills the window)"
  end
  vim.api.nvim_echo({ { msg } }, false, {})
end

return M
