-- Edit mode: turns a document buffer into Markdown (Word, ODT, RTF) or CSV (Excel) and
-- rebuilds the original file on :w. Word and ODT files are rebuilt with the original as
-- pandoc's style template, so fonts, heading styles, margins, headers and footers survive.
-- Before the first save of each editing session the original is copied to
-- stdpath("data")/docview/backups.
local M = {}

M.formats = {
  docx = { kind = "pandoc", from = "docx", to = "docx", reference = true, ft = "markdown" },
  odt = { kind = "pandoc", from = "odt", to = "odt", reference = true, ft = "markdown" },
  rtf = { kind = "pandoc", from = "rtf", to = "rtf", standalone = true, ft = "markdown" },
  xlsx = { kind = "csv", ft = "csv" },
}

---@class docview.EditSession
---@field source string
---@field ext string
---@field fmt table
---@field dir string working directory (extracted images, style reference)
---@field backup? string
---@field preview? number preview buffer

---@type table<number, docview.EditSession>
M.sessions = {}

local group = vim.api.nvim_create_augroup("docview.edit", { clear = true })
local sheet_marker = "^### Sheet: (.*)$"

local function notify(msg, level)
  vim.notify("docview: " .. msg, level or vim.log.levels.INFO)
end

local function exec(cmd, cwd)
  local ok, obj = pcall(vim.system, cmd, { text = true, cwd = cwd })
  if not ok then
    return nil, obj
  end
  local r = obj:wait(require("docview").config.timeout)
  if r.code ~= 0 then
    return nil, vim.trim(r.stderr or "") ~= "" and vim.trim(r.stderr) or ("exited with code " .. r.code)
  end
  return r.stdout
end

local function csv_field(v)
  if v:find('[,"\n\r]') or v:match("^%s") or v:match("%s$") then
    return '"' .. v:gsub('"', '""') .. '"'
  end
  return v
end

local function xlsx_to_csv(path)
  local sheets, err = require("docview.ooxml").xlsx_sheets(path, { formulas = true })
  if not sheets then
    return nil, err
  end
  local lines = {}
  for i, sheet in ipairs(sheets) do
    if i > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "### Sheet: " .. sheet.name
    for r = 1, sheet.max_row do
      local cells, last = sheet.rows[r] or {}, 0
      for c in pairs(cells) do
        last = math.max(last, c)
      end
      local fields = {}
      for c = 1, last do
        fields[c] = csv_field(cells[c] or "")
      end
      vim.list_extend(lines, vim.split(table.concat(fields, ","), "\n", { plain = true }))
    end
  end
  return lines
end

-- Parses the edit buffer back into sheets; quoted fields may span lines.
local function csv_to_sheets(lines)
  local sheets, sheet = {}, nil
  local row, field, in_quotes = {}, {}, false
  local function finish_field()
    row[#row + 1] = table.concat(field)
    field = {}
  end
  local function finish_row()
    finish_field()
    sheet.rows[#sheet.rows + 1] = row
    row = {}
  end
  for _, line in ipairs(lines) do
    local name = not in_quotes and line:match(sheet_marker)
    if name then
      sheet = { name = name, rows = {} }
      sheets[#sheets + 1] = sheet
    else
      if not sheet then
        sheet = { name = "Sheet1", rows = {} }
        sheets[#sheets + 1] = sheet
      end
      if in_quotes then
        field[#field + 1] = "\n"
      end
      local i = 1
      while i <= #line do
        local ch = line:sub(i, i)
        if in_quotes then
          if ch == '"' and line:sub(i + 1, i + 1) == '"' then
            field[#field + 1] = '"'
            i = i + 1
          elseif ch == '"' then
            in_quotes = false
          else
            field[#field + 1] = ch
          end
        elseif ch == '"' then
          in_quotes = true
        elseif ch == "," then
          finish_field()
        else
          field[#field + 1] = ch
        end
        i = i + 1
      end
      if not in_quotes then
        finish_row()
      end
    end
  end
  if in_quotes then
    finish_row()
  end

  local used = {}
  for _, s in ipairs(sheets) do
    while #s.rows > 0 and table.concat(s.rows[#s.rows]) == "" do
      s.rows[#s.rows] = nil
    end
    -- Excel rejects names over 31 characters, with []:*?/\ or used twice.
    local base = vim.trim(s.name):gsub("[%[%]:*?/\\]", "_"):sub(1, 31)
    base = base ~= "" and base or "Sheet"
    local name, n = base, 2
    while used[name:lower()] do
      local suffix = (" (%d)"):format(n)
      name, n = base:sub(1, 31 - #suffix) .. suffix, n + 1
    end
    used[name:lower()] = true
    s.name = name
  end
  return sheets
end

local function workdir(path)
  local dir = vim.fn.stdpath("cache") .. "/docview/edit/" .. vim.fn.sha256(path):sub(1, 16)
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  return dir
end

local function to_text(s)
  if s.fmt.kind == "csv" then
    return xlsx_to_csv(s.source)
  end
  -- Run inside the working directory so images are referenced as media/… rather than by
  -- long cache paths. Pipe tables are the easiest to edit; grid tables remain for
  -- tables pipes can't express (several paragraphs in a cell).
  local out, err = exec({
    "pandoc",
    "--from=" .. s.fmt.from,
    "--to=markdown-multiline_tables-simple_tables",
    "--wrap=none",
    "--markdown-headings=atx",
    "--extract-media=.",
    s.source,
  }, s.dir)
  if not out then
    return nil, err
  end
  local lines = vim.split(out, "\n", { plain = true })
  while #lines > 1 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines
end

-- Writes the buffer as `ext` to `out`.
local function build(s, lines, ext, out)
  local fmt = M.formats[ext]
  if fmt.kind == "csv" then
    return require("docview.ooxml").write_xlsx(out, csv_to_sheets(lines))
  end
  local md = s.dir .. "/document.md"
  vim.fn.writefile(lines, md)
  local cmd = { "pandoc", "--from=markdown", "--to=" .. fmt.to, "--resource-path=" .. s.dir, "--output=" .. out }
  if fmt.standalone then
    cmd[#cmd + 1] = "--standalone"
  end
  if fmt.reference and ext == s.ext then
    cmd[#cmd + 1] = "--reference-doc=" .. s.dir .. "/reference." .. ext
  end
  cmd[#cmd + 1] = md
  local ok, err = exec(cmd, s.dir)
  return ok ~= nil, err
end

-- pandoc copies every image in the style template into the new file, so a template that
-- still holds the document's own images would duplicate them on each save. Keep only the
-- images headers and footers use.
local function make_reference(s)
  local ref = s.dir .. "/reference." .. s.ext
  vim.uv.fs_copyfile(s.source, ref)
  if s.ext ~= "docx" then
    return
  end
  local function read(member)
    return vim.system({ "unzip", "-p", ref, member }, { text = true }):wait().stdout or ""
  end
  local listing = vim.system({ "unzip", "-Z1", ref }, { text = true }):wait().stdout or ""
  local keep = {}
  for member in listing:gmatch("[^\n]+") do
    if member:match("^word/_rels/header%d*%.xml%.rels$") or member:match("^word/_rels/footer%d*%.xml%.rels$") then
      for target in read(member):gmatch('Target="media/([^"]+)"') do
        keep[target] = true
      end
    end
  end
  local drop = {}
  for target in read("word/_rels/document.xml.rels"):gmatch('Target="media/([^"]+)"') do
    if not keep[target] then
      drop[#drop + 1] = "word/media/" .. target
    end
  end
  if #drop > 0 then
    vim.system(vim.list_extend({ "zip", "-q", "-d", ref }, drop)):wait()
  end
end

local function backup(s)
  local dir = vim.fn.stdpath("data") .. "/docview/backups"
  vim.fn.mkdir(dir, "p")
  local name = ("%s/%s-%s.%s"):format(dir, vim.fn.fnamemodify(s.source, ":t:r"), os.date("%Y%m%d-%H%M%S"), s.ext)
  local ok, err = vim.uv.fs_copyfile(s.source, name)
  if not ok then
    return nil, err
  end
  return name
end

local function refresh_preview(s)
  local pbuf = s.preview
  if not pbuf or not vim.api.nvim_buf_is_valid(pbuf) then
    return
  end
  local pages = require("docview.pages")
  local old = pages.state[pbuf] and pages.state[pbuf].dir
  pages.show(pbuf, s.source, function(err)
    if vim.api.nvim_buf_is_valid(pbuf) then
      vim.bo[pbuf].modifiable = true
      vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "  Preview unavailable: " .. err })
      vim.bo[pbuf].modifiable = false
    end
  end)
  -- Each save makes a new cache entry; drop the one the preview no longer shows.
  if old and pages.state[pbuf] and pages.state[pbuf].dir ~= old then
    vim.fn.delete(old, "rf")
  end
end

local function open_preview(s, buf)
  local pages = require("docview.pages")
  if not require("docview").config.edit.preview or not pages.available(s.source) then
    return
  end
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(pbuf, "docview-preview://" .. s.source)
  vim.bo[pbuf].bufhidden = "wipe"
  vim.bo[pbuf].filetype = "docview"
  vim.b[pbuf].docview = { source = s.source, view = "preview" }
  local edit_win = vim.fn.bufwinid(buf)
  vim.api.nvim_open_win(pbuf, false, { split = "right", win = edit_win ~= -1 and edit_win or 0 })
  require("docview").set_keymaps(pbuf, { "toggle_view", "edit" })
  s.preview = pbuf
  refresh_preview(s)
end

function M.save(buf, target)
  local s = M.sessions[buf]
  if not s then
    return
  end
  target = vim.fn.fnamemodify(target ~= "" and target or s.source, ":p")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ext = vim.fn.fnamemodify(target, ":e"):lower()

  if target ~= s.source and not M.formats[ext] then
    -- `:w notes.md` or `:w data.csv`: write the buffer as it is.
    vim.fn.writefile(lines, target)
    return notify("wrote " .. vim.fn.fnamemodify(target, ":~:."))
  end

  -- Build next to the target so the final rename is atomic.
  local tmp = ("%s/.%s.docview-%d.%s"):format(vim.fn.fnamemodify(target, ":h"), vim.fn.fnamemodify(target, ":t"), vim.uv.os_getpid(), ext)
  local ok, err = build(s, lines, ext, tmp)
  if not ok then
    vim.fn.delete(tmp)
    return notify("not saved: " .. (err or "conversion failed"), vim.log.levels.ERROR)
  end

  if target == s.source and not s.backup then
    local saved, berr = backup(s)
    if not saved then
      vim.fn.delete(tmp)
      return notify("not saved: could not back up the original: " .. berr, vim.log.levels.ERROR)
    end
    s.backup = saved
    notify("original backed up to " .. vim.fn.fnamemodify(saved, ":~"))
  end

  local renamed, rerr = vim.uv.fs_rename(tmp, target)
  if not renamed then
    vim.fn.delete(tmp)
    return notify("not saved: " .. rerr, vim.log.levels.ERROR)
  end
  if target == s.source then
    vim.bo[buf].modified = false
    refresh_preview(s)
  end
  notify("saved " .. vim.fn.fnamemodify(target, ":~:."))
end

--- Leaves edit mode bookkeeping (the caller re-renders the buffer).
function M.stop(buf)
  local s = M.sessions[buf]
  if not s then
    return
  end
  M.sessions[buf] = nil
  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
  if s.preview and vim.api.nvim_buf_is_valid(s.preview) then
    require("docview.pages").stop(s.preview)
    vim.api.nvim_buf_delete(s.preview, { force = true })
  end
end

function M.start(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local state = vim.b[buf].docview
  if not state or state.view == "preview" then
    return notify("not a document buffer", vim.log.levels.WARN)
  end
  if M.sessions[buf] then
    return
  end
  local path = state.source
  local ext = vim.fn.fnamemodify(path, ":e"):lower()
  local fmt = M.formats[ext]
  if not fmt then
    local list = vim.tbl_keys(M.formats)
    table.sort(list)
    return notify(("can't edit .%s files (editable: .%s)"):format(ext, table.concat(list, ", .")), vim.log.levels.WARN)
  end
  if fmt.kind == "pandoc" and vim.fn.executable("pandoc") == 0 then
    return notify("editing needs pandoc (brew install pandoc)", vim.log.levels.WARN)
  end
  if fmt.kind == "csv" and (vim.fn.executable("unzip") == 0 or vim.fn.executable("zip") == 0) then
    return notify("editing spreadsheets needs zip and unzip", vim.log.levels.WARN)
  end

  local s = { source = path, ext = ext, fmt = fmt, dir = workdir(path) }
  if fmt.reference then
    make_reference(s)
  end
  local lines, err = to_text(s)
  if not lines then
    return notify("could not open for editing: " .. err, vim.log.levels.ERROR)
  end

  require("docview.pages").stop(buf)
  for _, lhs in pairs(require("docview").config.keymaps) do
    if lhs then
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end

  -- Start with an empty undo history so `u` can't bring back the viewer's text.
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.bo[buf].buftype = "acwrite"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = fmt.ft
  vim.b[buf].docview = { source = path, view = "edit", converter = fmt.kind == "csv" and "CSV" or "pandoc (Markdown)" }
  M.sessions[buf] = s

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function(ev)
      M.save(buf, ev.file)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.stop(buf)
    end,
  })

  open_preview(s, buf)
  notify(("editing %s as %s. :w saves it (the original is backed up first), :e returns to the viewer"):format(
    vim.fn.fnamemodify(path, ":t"),
    fmt.kind == "csv" and "CSV" or "Markdown"
  ))
end

return M
