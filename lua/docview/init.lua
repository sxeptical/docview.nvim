local M = {}

M.config = {
  -- File extensions rendered as text instead of being opened raw.
  extensions = { "pdf", "docx", "doc", "odt", "rtf", "epub", "pptx", "xlsx" },
  -- Keep the page layout of PDFs (columns, tables) when pdftotext is available.
  pdf_layout = true,
  pandoc_args = { "--to=gfm", "--wrap=auto", "--columns=100" },
  -- Milliseconds before a converter is given up on.
  timeout = 60000,
  -- "pages" shows the real pages as images (kitty, Ghostty or WezTerm with snacks.nvim);
  -- "text" shows the extracted text. Falls back to text when pages are not possible.
  view = "pages",
  pages = {
    -- Resolution pages are rendered at; higher is sharper but slower.
    dpi = 180,
    -- Widest a page is drawn, in columns, before zooming.
    max_width = 100,
    -- Pages rendered per Ghostscript run; each batch appears as soon as it is ready.
    chunk_size = 6,
    -- Ghostscript processes rendering at once.
    jobs = 3,
  },
  -- Previews in snacks.nvim's picker.
  picker = {
    enabled = true,
    -- Show the pages (scrollable) instead of the text.
    pages = true,
  },
  edit = {
    -- Show the real pages in a split while editing, refreshed on every save.
    preview = true,
  },
  -- Buffer-local keymaps; set any to false to disable it.
  keymaps = {
    edit = "i",
    next_page = "]p",
    prev_page = "[p",
    open_external = "gO",
    toggle_view = "<Tab>",
    zoom_in = "+",
    zoom_out = "-",
    zoom_reset = "=",
  },
}

local group = vim.api.nvim_create_augroup("docview", { clear = true })

local function has(bin)
  return vim.fn.executable(bin) == 1
end

local function exec(cmd)
  local ok, obj = pcall(vim.system, cmd, { text = true })
  if not ok then
    return nil, obj
  end
  local r = obj:wait(M.config.timeout)
  if r.code ~= 0 then
    local err = vim.trim(r.stderr or "")
    return nil, err ~= "" and err or ("exited with code " .. r.code)
  end
  return r.stdout
end

local function builtin(name)
  return {
    name = "builtin " .. name .. " reader",
    ft = "markdown",
    available = function()
      return has("unzip")
    end,
    run = function(path)
      return require("docview.ooxml")[name](path)
    end,
  }
end

local function pandoc(from)
  return {
    name = "pandoc",
    ft = "markdown",
    available = function()
      return has("pandoc")
    end,
    argv = function(path)
      return vim.list_extend({ "pandoc", "--from=" .. from, path }, M.config.pandoc_args)
    end,
  }
end

local function command(name, args, ft)
  return {
    name = name,
    ft = ft or "text",
    available = function()
      return has(name)
    end,
    argv = function(path)
      return vim.list_extend({ name }, args(path))
    end,
  }
end

local textutil = command("textutil", function(path)
  return { "-convert", "txt", "-encoding", "UTF-8", "-stdout", path }
end)

-- macOS ships PDFKit, reachable from JavaScript for Automation, so PDFs work with no installs.
local pdfkit_script = [[
ObjC.import('PDFKit');
function run(argv) {
  var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
  if (!doc || doc.isNil()) throw new Error('could not open PDF');
  if (doc.isLocked) throw new Error('PDF is password protected');
  var pages = [];
  for (var i = 0; i < doc.pageCount; i++) {
    var s = doc.pageAtIndex(i).string;
    pages.push(s.isNil() ? '' : s.js);
  }
  return pages.join('\f');
}
]]

local pdfkit = {
  name = "macOS PDFKit",
  ft = "text",
  available = function()
    return vim.fn.has("mac") == 1 and has("osascript")
  end,
  argv = function(path)
    return { "osascript", "-l", "JavaScript", "-e", pdfkit_script, path }
  end,
}

-- Converters per extension, tried in order until one is available and succeeds.
M.converters = {
  pdf = {
    command("pdftotext", function(path)
      local args = { "-enc", "UTF-8", path, "-" }
      if M.config.pdf_layout then
        table.insert(args, 1, "-layout")
      end
      return args
    end),
    command("mutool", function(path)
      return { "draw", "-q", "-F", "txt", "-o", "-", path }
    end),
    pdfkit,
  },
  docx = { pandoc("docx"), textutil, builtin("docx") },
  doc = {
    textutil,
    command("antiword", function(path)
      return { path }
    end),
    command("catdoc", function(path)
      return { path }
    end),
  },
  odt = { pandoc("odt"), textutil },
  rtf = { pandoc("rtf"), textutil },
  epub = { pandoc("epub") },
  pptx = { builtin("pptx") },
  xlsx = { builtin("xlsx") },
}

local install_hints = {
  pdf = "brew install poppler",
  epub = "brew install pandoc",
  doc = "brew install antiword",
  odt = "brew install pandoc",
  rtf = "brew install pandoc",
  docx = "brew install pandoc",
}

local function paginate(text)
  local pages = vim.split(text, "\f", { plain = true })
  if #pages > 1 and pages[#pages]:match("^%s*$") then
    table.remove(pages)
  end
  if #pages <= 1 then
    return text
  end
  local out = {}
  for i, page in ipairs(pages) do
    out[#out + 1] = ("── Page %d of %d ──"):format(i, #pages)
    out[#out + 1] = (page:gsub("^\n+", ""):gsub("%s+$", ""))
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

function M.convert(path, ext)
  local tried = {}
  for _, conv in ipairs(M.converters[ext] or {}) do
    if conv.available() then
      local ok, text, err = pcall(conv.run or function(p)
        return exec(conv.argv(p))
      end, path)
      if ok and text then
        return text, conv
      end
      tried[#tried + 1] = ("%s: %s"):format(conv.name, ok and (err or "failed") or text)
    end
  end
  return nil, tried
end

--- Like `M.convert`, but runs external converters in the background so the editor never
--- waits on them. Calls `cb(text, converter)` on success or `cb(nil, errors)`.
function M.convert_async(path, ext, cb)
  local list = vim.tbl_filter(function(conv)
    return conv.available()
  end, M.converters[ext] or {})
  local tried = {}
  local function try(i)
    local conv = list[i]
    if not conv then
      return cb(nil, tried)
    end
    local function fail(err)
      tried[#tried + 1] = ("%s: %s"):format(conv.name, err or "failed")
      try(i + 1)
    end
    if not conv.argv then
      -- Built-in readers only unzip a few XML files; they are quick enough to run inline.
      local ok, text, err = pcall(conv.run, path)
      if ok and text then
        return cb(text, conv)
      end
      return fail(ok and err or text)
    end
    local ok, err = pcall(vim.system, conv.argv(path), { text = true, timeout = M.config.timeout }, function(r)
      vim.schedule(function()
        if r.code == 0 then
          return cb(r.stdout, conv)
        end
        local msg = vim.trim(r.stderr or "")
        fail(msg ~= "" and msg or ("exited with code " .. r.code))
      end)
    end)
    if not ok then
      fail(err)
    end
  end
  try(1)
end

--- Turns converter output (or failure) into buffer lines and a filetype.
function M.text_lines(path, ext, text, conv)
  if text then
    text = text:gsub("\r\n?", "\n")
    if ext == "pdf" then
      text = paginate(text)
    end
    local lines = vim.split(vim.trim(text) == "" and "(no text found in document)" or text, "\n", { plain = true })
    while #lines > 1 and lines[#lines]:match("^%s*$") do
      lines[#lines] = nil
    end
    return lines, conv.ft
  end
  local lines = { ("docview: could not convert %s"):format(vim.fn.fnamemodify(path, ":t")), "" }
  if #conv == 0 then
    lines[#lines + 1] = "No converter for ." .. ext .. " is installed."
  else
    for _, err in ipairs(conv) do
      vim.list_extend(lines, vim.split(err, "\n", { plain = true }))
    end
  end
  if install_hints[ext] then
    vim.list_extend(lines, { "", "Try: " .. install_hints[ext] })
  end
  lines[#lines + 1] = "Press gO (or run :DocviewOpen) to open it in its default application."
  return lines, "text"
end

--- Sets the viewer keymaps on `buf`, except the ones named in `skip`.
function M.set_keymaps(buf, skip)
  local km = vim.deepcopy(M.config.keymaps)
  for _, name in ipairs(skip or {}) do
    km[name] = nil
  end
  local function map(lhs, rhs, desc)
    if lhs then
      vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc })
    end
  end
  map(km.edit, function()
    require("docview.edit").start(buf)
  end, "Edit document")
  -- Page headers look the same in both views; in the page view they are centred.
  local page_pattern = [[^\s*── Page \d\+ of \d\+ ──]]
  map(km.next_page, function()
    for _ = 1, vim.v.count1 do
      vim.fn.search(page_pattern, "W")
    end
    vim.cmd("normal! zt")
  end, "Next page")
  map(km.prev_page, function()
    for _ = 1, vim.v.count1 do
      vim.fn.search(page_pattern, "bW")
    end
    vim.cmd("normal! zt")
  end, "Previous page")
  map(km.open_external, M.open_external, "Open in default application")
  map(km.toggle_view, M.toggle, "Switch between pages and text")
  map(km.zoom_in, function()
    require("docview.pages").zoom(buf, 0.2 * vim.v.count1)
  end, "Zoom in")
  map(km.zoom_out, function()
    require("docview.pages").zoom(buf, -0.2 * vim.v.count1)
  end, "Zoom out")
  map(km.zoom_reset, function()
    require("docview.pages").zoom(buf, 0)
  end, "Reset zoom")
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

-- The latest text conversion per buffer; an older one finishing late is ignored.
local text_jobs = {}

local function show_text(buf, path, note, on_done)
  require("docview.pages").stop(buf)
  local ext = vim.fn.fnamemodify(path, ":e"):lower()
  local function finish(lines, ft, conv)
    set_lines(buf, lines)
    vim.bo[buf].filetype = ft
    vim.b[buf].docview = { source = path, view = "text", converter = conv and conv.name or nil, note = note }
    -- After 'filetype': ftplugins map keys too (markdown maps gO to an outline).
    M.set_keymaps(buf)
    if on_done then
      on_done()
    end
  end
  if vim.fn.filereadable(path) == 0 then
    return finish({ "docview: cannot read " .. path }, "text")
  end

  local job = {}
  text_jobs[buf] = job
  set_lines(buf, { "  Loading text…" })
  vim.bo[buf].filetype = "text"
  vim.b[buf].docview = { source = path, view = "text", note = note }
  M.set_keymaps(buf)
  M.convert_async(path, ext, function(text, conv)
    -- Skip if the buffer is gone, switched to pages or editing, or loading again.
    local state = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].docview
    if text_jobs[buf] ~= job or not state or state.view ~= "text" then
      return
    end
    text_jobs[buf] = nil
    local lines, ft = M.text_lines(path, ext, text, conv)
    finish(lines, ft, text and conv or nil)
  end)
end

local function show_pages(buf, path)
  local pages = require("docview.pages")
  local ok, reason = pages.available(path)
  if not ok then
    return false, reason
  end
  local is_pdf = vim.fn.fnamemodify(path, ":e"):lower() == "pdf"
  vim.bo[buf].filetype = "docview"
  M.set_keymaps(buf)
  vim.b[buf].docview = {
    source = path,
    view = "pages",
    converter = is_pdf and "Ghostscript (page images)" or "LibreOffice + Ghostscript (page images)",
  }
  pages.show(buf, path, function(err)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.notify("docview: " .. err .. "; showing text instead", vim.log.levels.WARN)
      show_text(buf, path, err)
    end
  end)
  return true
end

--- Renders `path` into `buf` as pages or text (`view` defaults to `config.view`).
--- `on_done` runs once the text view has its content (right away for pages).
function M.render(buf, path, view, on_done)
  path = vim.fn.fnamemodify(path, ":p")

  -- Never let :w write converted text over the original document. ('modifiable' is off too;
  -- 'readonly' is not used because every redraw would warn about changing a readonly file.)
  if package.loaded["docview.edit"] then
    require("docview.edit").stop(buf)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false

  M.set_keymaps(buf)
  local note
  if (view or M.config.view) == "pages" and vim.fn.filereadable(path) == 1 then
    local ok, reason = show_pages(buf, path)
    if ok then
      return on_done and on_done()
    end
    note = "page view unavailable: " .. reason
    if view == "pages" then
      -- Asked for explicitly (e.g. the toggle key): say why, and keep the current view.
      return vim.notify("docview: " .. note, vim.log.levels.WARN)
    end
  end
  show_text(buf, path, note, on_done)
end

local function current_source()
  local state = vim.b.docview
  return state and state.source or vim.api.nvim_buf_get_name(0)
end

function M.open_external()
  local path = current_source()
  if path == "" then
    return vim.notify("docview: buffer has no file", vim.log.levels.WARN)
  end
  local name = vim.fn.fnamemodify(path, ":t")
  local function failed(msg)
    vim.notify(("docview: could not open %s: %s"):format(name, msg), vim.log.levels.ERROR)
  end
  vim.notify(("docview: opening %s in its default app…"):format(name))
  if vim.fn.has("mac") == 1 then
    -- vim.ui.open drops the opener's errors, so run `open` directly and report them.
    local ok, err = pcall(vim.system, { "open", path }, { text = true }, function(r)
      if r.code ~= 0 then
        vim.schedule(function()
          failed(vim.trim(r.stderr or "") ~= "" and vim.trim(r.stderr) or ("open exited with code " .. r.code))
        end)
      end
    end)
    if not ok then
      failed(err)
    end
  else
    local _, err = vim.ui.open(path)
    if err then
      failed(err)
    end
  end
end

function M.toggle()
  local state = vim.b.docview
  if not state then
    return vim.notify("docview: not a docview buffer", vim.log.levels.WARN)
  end
  M.render(vim.api.nvim_get_current_buf(), state.source, state.view == "pages" and "text" or "pages")
  vim.fn.winrestview({ topline = 1, lnum = 1 })
end

function M.reload()
  local state = vim.b.docview
  if not state then
    return vim.notify("docview: not a docview buffer", vim.log.levels.WARN)
  end
  local view, win = vim.fn.winsaveview(), vim.api.nvim_get_current_win()
  M.render(vim.api.nvim_get_current_buf(), state.source, state.view, function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
    end
  end)
end

function M.info()
  local state = vim.b.docview
  if not state then
    return vim.notify("docview: not a docview buffer", vim.log.levels.WARN)
  end
  local msg = ("docview: %s rendered by %s"):format(state.source, state.converter or "nothing (conversion failed)")
  vim.notify(state.note and (msg .. "\n" .. state.note) or msg)
end

-- The bundled zip plugin also opens .docx/.xlsx/.pptx/.odt with BufReadCmd and would append
-- its archive listing to our buffer, so drop any other handler for the same patterns.
local function claim(patterns)
  local wanted = {}
  for _, p in ipairs(patterns) do
    wanted[p] = true
  end
  for _, au in ipairs(vim.api.nvim_get_autocmds({ event = "BufReadCmd" })) do
    if au.group ~= group and wanted[au.pattern] then
      if au.id then
        pcall(vim.api.nvim_del_autocmd, au.id)
      elseif au.group then
        -- Vimscript autocmds have no id; remove them by group and pattern instead.
        pcall(vim.api.nvim_clear_autocmds, { event = "BufReadCmd", group = au.group, pattern = au.pattern })
      end
    end
  end
end

function M.register()
  vim.api.nvim_clear_autocmds({ group = group })
  require("docview.preview").hook()
  local patterns = {}
  for _, ext in ipairs(M.config.extensions) do
    patterns[#patterns + 1] = "*." .. ext:lower()
    patterns[#patterns + 1] = "*." .. ext:upper()
  end
  if #patterns == 0 then
    return
  end
  claim(patterns)
  vim.api.nvim_create_autocmd("SourcePost", {
    group = group,
    pattern = "*zipPlugin.vim",
    desc = "docview: take documents back from the zip plugin",
    callback = function()
      claim(patterns)
    end,
  })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = patterns,
    desc = "docview: render documents",
    callback = function(ev)
      claim(patterns)
      M.render(ev.buf, ev.match)
    end,
  })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if opts and opts.extensions then
    M.config.extensions = opts.extensions
  end
  for ext, list in pairs(M.config.converters or {}) do
    M.converters[ext] = list
  end
  M.register()
end

return M
