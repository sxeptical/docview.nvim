-- Dependency-free readers for Office Open XML files (.docx, .pptx, .xlsx).
-- They only need `unzip`, so they work anywhere pandoc and friends are missing.
local M = {}

local function unzip_list(path)
  local r = vim.system({ "unzip", "-Z1", path }, { text = true }):wait()
  if r.code ~= 0 then
    return nil
  end
  return vim.split(r.stdout, "\n", { trimempty = true })
end

local function unzip_read(path, member)
  local r = vim.system({ "unzip", "-p", path, member }, { text = true }):wait()
  if r.code ~= 0 or r.stdout == "" then
    return nil
  end
  return r.stdout
end

local named = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

function M.unescape(s)
  return (s:gsub("&(#?)([xX]?)(%w+);", function(hash, x, v)
    if hash == "" then
      return named[x .. v] or ("&" .. x .. v .. ";")
    end
    local n = tonumber(v, x ~= "" and 16 or 10)
    return n and vim.fn.nr2char(n) or ""
  end))
end

-- Iterates over (closing, tag name, attributes, following text) for each XML tag.
local function tokens(xml)
  return xml:gmatch("<(/?)([%w:]+)([^>]*)>([^<]*)")
end

local function attr(attrs, name)
  return attrs:match("%s" .. name .. '="([^"]*)"')
end

-- Maps relationship ids to the part paths they point to, relative to `base`.
local function relationships(path, rels_member, base)
  local map = {}
  for tag in (unzip_read(path, rels_member) or ""):gmatch("<Relationship%s[^>]*>") do
    local id, target = attr(tag, "Id"), attr(tag, "Target")
    if id and target then
      map[id] = target:sub(1, 1) == "/" and target:sub(2) or base .. target
    end
  end
  return map
end

local function squeeze_blank_lines(lines)
  local out = {}
  for _, line in ipairs(lines) do
    line = line:gsub("%s+$", "")
    if line ~= "" or (out[#out] and out[#out] ~= "") then
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

function M.docx(path)
  local xml = unzip_read(path, "word/document.xml")
  if not xml then
    return nil, "word/document.xml not found (is this a valid .docx?)"
  end

  local lines, para, prefix = {}, {}, ""
  local in_text, cell_depth, row = false, 0, {}

  local function end_paragraph()
    local text = M.unescape(table.concat(para))
    para, prefix = {}, ""
    return text
  end

  for close, name, attrs, text in tokens(xml) do
    local selfclose = attrs:sub(-1) == "/"
    if name == "w:t" then
      in_text = close == "" and not selfclose
    elseif name == "w:pStyle" then
      local style = (attr(attrs, "w:val") or ""):lower()
      local level = style:match("^heading(%d)")
      if level then
        prefix = string.rep("#", tonumber(level)) .. " "
      elseif style == "title" then
        prefix = "# "
      end
    elseif name == "w:numPr" and close == "" and prefix == "" then
      prefix = "- "
    elseif name == "w:tab" and attrs == "/" then
      para[#para + 1] = "\t"
    elseif (name == "w:br" or name == "w:cr") and close == "" then
      para[#para + 1] = cell_depth > 0 and " " or "\n"
    elseif name == "w:p" and (close == "/" or selfclose) then
      if cell_depth > 0 then
        para[#para + 1] = " "
      else
        local p = prefix
        lines[#lines + 1] = p .. end_paragraph()
        lines[#lines + 1] = ""
      end
    elseif name == "w:tc" then
      if close == "/" then
        row[#row + 1] = vim.trim(end_paragraph())
      end
      cell_depth = cell_depth + (close == "/" and -1 or 1)
    elseif name == "w:tr" and close == "/" then
      lines[#lines + 1] = "| " .. table.concat(row, " | ") .. " |"
      row = {}
    elseif name == "w:tbl" and close == "/" then
      lines[#lines + 1] = ""
    end
    if in_text and name == "w:t" then
      para[#para + 1] = text
    end
  end
  return squeeze_blank_lines(lines)
end

local function paragraphs_text(xml)
  local lines, para = {}, {}
  for close, name, attrs, text in tokens(xml) do
    if name == "a:t" and close == "" and attrs:sub(-1) ~= "/" then
      para[#para + 1] = text
    elseif name == "a:br" then
      para[#para + 1] = "\n"
    elseif name == "a:p" and (close == "/" or attrs:sub(-1) == "/") then
      lines[#lines + 1] = M.unescape(table.concat(para))
      para = {}
    end
  end
  return lines
end

function M.pptx(path)
  local slides = {}
  local presentation = unzip_read(path, "ppt/presentation.xml")
  if presentation then
    local rels = relationships(path, "ppt/_rels/presentation.xml.rels", "ppt/")
    for tag in presentation:gmatch("<p:sldId%s[^>]*>") do
      local rid = tag:match('%s[%w]+:id="([^"]*)"')
      if rid and rels[rid] then
        slides[#slides + 1] = rels[rid]
      end
    end
  end
  if #slides == 0 then
    local numbered = {}
    for _, member in ipairs(unzip_list(path) or {}) do
      local n = member:match("^ppt/slides/slide(%d+)%.xml$")
      if n then
        numbered[#numbered + 1] = { tonumber(n), member }
      end
    end
    table.sort(numbered, function(a, b)
      return a[1] < b[1]
    end)
    for _, s in ipairs(numbered) do
      slides[#slides + 1] = s[2]
    end
  end
  if #slides == 0 then
    return nil, "no slides found (is this a valid .pptx?)"
  end

  local lines = {}
  for i, member in ipairs(slides) do
    lines[#lines + 1] = ("## Slide %d"):format(i)
    lines[#lines + 1] = ""
    for _, line in ipairs(paragraphs_text(unzip_read(path, member) or "")) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = ""
  end
  return squeeze_blank_lines(lines)
end

local function column_index(letters)
  local n = 0
  for i = 1, #letters do
    n = n * 26 + (letters:byte(i) - 64)
  end
  return n
end

local function strings_in(xml)
  local parts = {}
  for t in xml:gsub("<rPh.-</rPh>", ""):gmatch("<t[^>/]*>(.-)</t>") do
    parts[#parts + 1] = t
  end
  return M.unescape(table.concat(parts))
end

local function render_grid(grid, max_col)
  local widths = {}
  for _, cells in ipairs(grid) do
    for c = 1, max_col do
      local w = vim.fn.strdisplaywidth(cells[c] or "")
      widths[c] = math.min(math.max(widths[c] or 0, w), 40)
    end
  end
  local lines = {}
  for _, cells in ipairs(grid) do
    if cells.gap then
      lines[#lines + 1] = ""
    else
      local out = {}
      for c = 1, max_col do
        local v = cells[c] or ""
        out[c] = v .. string.rep(" ", widths[c] - vim.fn.strdisplaywidth(v))
      end
      lines[#lines + 1] = table.concat(out, " │ ")
    end
  end
  return lines
end

--- Reads every sheet as { name, rows = { [row] = { [col] = value } }, max_row, max_col }.
--- With `opts.formulas`, cells holding a formula read as "=FORMULA" instead of its result.
function M.xlsx_sheets(path, opts)
  opts = opts or {}
  local shared = {}
  local sst = unzip_read(path, "xl/sharedStrings.xml")
  if sst then
    for si in sst:gmatch("<si>(.-)</si>") do
      shared[#shared + 1] = strings_in(si)
    end
  end

  local sheets = {}
  local rels = relationships(path, "xl/_rels/workbook.xml.rels", "xl/")
  for tag in (unzip_read(path, "xl/workbook.xml") or ""):gmatch("<sheet%s[^>]*>") do
    local rid = tag:match('%s[%w]+:id="([^"]*)"')
    if rid and rels[rid] then
      sheets[#sheets + 1] = { name = M.unescape(attr(tag, "name") or rid), member = rels[rid] }
    end
  end
  if #sheets == 0 then
    return nil, "no worksheets found (is this a valid .xlsx?)"
  end

  for _, sheet in ipairs(sheets) do
    local xml = unzip_read(path, sheet.member) or ""
    local data = (xml:match("<sheetData[^>]*>(.*)</sheetData>") or "")
    data = data:gsub("<row[^>]-/>", ""):gsub("<c%s[^>]-/>", "")
    local rows, max_row, max_col = {}, 0, 0
    for row_attrs, row_xml in data:gmatch("<row([^>]*)>(.-)</row>") do
      local r = tonumber(attr(row_attrs, "r") or "") or max_row + 1
      local cells, next_col = {}, 1
      for cell_attrs, inner in row_xml:gmatch("<c(%s[^>]*)>(.-)</c>") do
        local letters = (attr(cell_attrs, "r") or ""):match("^(%u+)")
        local col = letters and column_index(letters) or next_col
        local kind, v = attr(cell_attrs, "t"), inner:match("<v>(.-)</v>")
        local value
        -- Shared formulas (<f t="shared" si="0"/>) have no text of their own; those keep their result.
        local formula = opts.formulas and inner:match("<f[^>/]*>(.-)</f>")
        if formula and formula ~= "" then
          value = "=" .. M.unescape(formula)
        elseif kind == "s" then
          value = shared[(tonumber(v or "") or -1) + 1]
        elseif kind == "inlineStr" then
          value = strings_in(inner)
        elseif kind == "b" then
          value = v == "1" and "TRUE" or "FALSE"
        else
          value = v and M.unescape(v)
        end
        if value and value ~= "" then
          cells[col] = value
          max_col = math.max(max_col, col)
        end
        next_col = col + 1
      end
      if next(cells) then
        rows[r] = cells
        max_row = math.max(max_row, r)
      end
    end
    sheet.rows, sheet.max_row, sheet.max_col = rows, max_row, max_col
  end
  return sheets
end

function M.xlsx(path)
  local sheets, err = M.xlsx_sheets(path)
  if not sheets then
    return nil, err
  end
  local lines = {}
  for _, sheet in ipairs(sheets) do
    lines[#lines + 1] = "## " .. sheet.name
    lines[#lines + 1] = ""
    local numbers = vim.tbl_keys(sheet.rows)
    table.sort(numbers)
    local grid, last = {}, nil
    for _, r in ipairs(numbers) do
      if last and r > last + 1 then
        grid[#grid + 1] = { gap = true }
      end
      last = r
      local cells = {}
      for c, v in pairs(sheet.rows[r]) do
        cells[c] = v:gsub("\r?\n", " ↵ ")
      end
      grid[#grid + 1] = cells
    end
    if sheet.max_col == 0 then
      lines[#lines + 1] = "(empty sheet)"
    else
      vim.list_extend(lines, render_grid(grid, sheet.max_col))
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

local function xml_escape(s)
  return (s:gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

local function column_letters(n)
  local s = ""
  while n > 0 do
    local r = (n - 1) % 26
    s = string.char(65 + r) .. s
    n = math.floor((n - 1) / 26)
  end
  return s
end

--- Writes a minimal .xlsx with the given sheets ({ name, rows = { { values... } } }).
--- Numbers and TRUE/FALSE become typed cells; everything else is text.
function M.write_xlsx(out, sheets)
  local dir = vim.fn.tempname()
  local function write(name, content)
    local file = dir .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
    local fd = assert(io.open(file, "wb"))
    fd:write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n', content)
    fd:close()
  end

  local ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
  local rel_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  local overrides, entries, rels = {}, {}, {}
  for i, sheet in ipairs(sheets) do
    local rows = {}
    for r, values in ipairs(sheet.rows) do
      local cells = {}
      for c, v in ipairs(values) do
        if v ~= "" then
          local ref = column_letters(c) .. r
          local numeric = v:match("^%-?%d+%.?%d*$") or v:match("^%-?%d*%.%d+$") or v:match("^%-?%d+%.?%d*[eE][%+%-]?%d+$")
          -- Leading zeros (postcodes, phone numbers, IDs) stay text so they aren't lost.
          if #v > 1 and v:sub(1, 1) == "=" then
            cells[#cells + 1] = ('<c r="%s"><f>%s</f></c>'):format(ref, xml_escape(v:sub(2)))
          elseif numeric and not v:match("^%-?0%d") then
            cells[#cells + 1] = ('<c r="%s"><v>%s</v></c>'):format(ref, v)
          elseif v == "TRUE" or v == "FALSE" then
            cells[#cells + 1] = ('<c r="%s" t="b"><v>%d</v></c>'):format(ref, v == "TRUE" and 1 or 0)
          else
            cells[#cells + 1] = ('<c r="%s" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>'):format(ref, xml_escape(v))
          end
        end
      end
      if #cells > 0 then
        rows[#rows + 1] = ('<row r="%d">%s</row>'):format(r, table.concat(cells))
      end
    end
    write(("xl/worksheets/sheet%d.xml"):format(i), ("<worksheet %s><sheetData>%s</sheetData></worksheet>"):format(ns, table.concat(rows)))
    overrides[#overrides + 1] = ('<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'):format(i)
    entries[#entries + 1] = ('<sheet name="%s" sheetId="%d" r:id="rId%d"/>'):format(xml_escape(sheet.name), i, i)
    rels[#rels + 1] = ('<Relationship Id="rId%d" Type="%s/worksheet" Target="worksheets/sheet%d.xml"/>'):format(i, rel_ns, i)
  end
  rels[#rels + 1] = ('<Relationship Id="rId%d" Type="%s/styles" Target="styles.xml"/>'):format(#sheets + 1, rel_ns)

  write("[Content_Types].xml", table.concat({
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>',
    table.concat(overrides),
    "</Types>",
  }))
  write("_rels/.rels", ('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/></Relationships>'):format(rel_ns))
  -- Formulas are written without cached results, so ask the app to calculate on open.
  write("xl/workbook.xml", ('<workbook %s xmlns:r="%s"><sheets>%s</sheets><calcPr fullCalcOnLoad="1"/></workbook>'):format(ns, rel_ns, table.concat(entries)))
  write("xl/_rels/workbook.xml.rels", ('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">%s</Relationships>'):format(table.concat(rels)))
  write("xl/styles.xml", ("<styleSheet %s><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs></styleSheet>"):format(ns))

  vim.fn.delete(out)
  local r = vim.system({ "zip", "-q", "-X", "-r", out, "[Content_Types].xml", "_rels", "xl" }, { cwd = dir }):wait()
  vim.fn.delete(dir, "rf")
  if r.code ~= 0 then
    return nil, "zip failed: " .. (r.stderr or "")
  end
  return true
end

return M
