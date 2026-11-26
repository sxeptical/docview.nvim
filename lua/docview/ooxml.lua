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

function M.xlsx(path)
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

  local lines = {}
  for _, sheet in ipairs(sheets) do
    lines[#lines + 1] = "## " .. sheet.name
    lines[#lines + 1] = ""
    local xml = unzip_read(path, sheet.member) or ""
    local data = (xml:match("<sheetData[^>]*>(.*)</sheetData>") or ""):gsub("<c%s[^>]-/>", "")
    local grid, max_col, last_row = {}, 0, nil
    for row_attrs, row_xml in data:gmatch("<row([^>]*)>(.-)</row>") do
      local r = tonumber(attr(row_attrs, "r") or "")
      if last_row and r and r > last_row + 1 then
        grid[#grid + 1] = { gap = true }
      end
      last_row = r or (last_row or 0) + 1
      local cells, next_col = {}, 1
      for cell_attrs, inner in row_xml:gmatch("<c(%s[^>]*)>(.-)</c>") do
        local letters = (attr(cell_attrs, "r") or ""):match("^(%u+)")
        local col = letters and column_index(letters) or next_col
        local kind, v = attr(cell_attrs, "t"), inner:match("<v>(.-)</v>")
        local value
        if kind == "s" then
          value = shared[(tonumber(v or "") or -1) + 1]
        elseif kind == "inlineStr" then
          value = strings_in(inner)
        elseif kind == "b" then
          value = v == "1" and "TRUE" or "FALSE"
        else
          value = v and M.unescape(v)
        end
        if value and value ~= "" then
          cells[col] = value:gsub("\r?\n", " ↵ ")
          max_col = math.max(max_col, col)
        end
        next_col = col + 1
      end
      grid[#grid + 1] = cells
    end
    if max_col == 0 then
      lines[#lines + 1] = "(empty sheet)"
    else
      vim.list_extend(lines, render_grid(grid, max_col))
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

return M
