-- Keeps the page cache and the edit backups from growing forever. Runs shortly after
-- startup (config.cache.auto_clean) or with :DocviewCleanCache, a few entries per event
-- loop tick so the editor never waits on it.
--
-- Cache layout (stdpath("cache")/docview):
--   <path hash>-<version hash>/  one version of one document: page-NNNN-DPI.png,
--                                document.pdf (Office files), source (the document's path)
--   edit/<path hash>/            working files of an editing session
-- Backups live in stdpath("data")/docview/backups as <name>-YYYYMMDD-HHMMSS.<ext>.
local M = {}

local DAY = 86400

function M.root()
  return vim.fn.stdpath("cache") .. "/docview"
end

local function config()
  return require("docview").config.cache
end

local function stat(path)
  return vim.uv.fs_stat(path)
end

local function size_of(dir)
  local total = 0
  for name, kind in vim.fs.dir(dir, { depth = 20 }) do
    if kind == "file" then
      local st = stat(dir .. "/" .. name)
      total = total + (st and st.size or 0)
    end
  end
  return total
end

-- The version a cache folder was made for, as cache_dir() in pages.lua names it.
local function current_name(path)
  local st = stat(path)
  if not st then
    return nil
  end
  local key = table.concat({ path, st.size, st.mtime.sec, st.mtime.nsec }, ":")
  return vim.fn.sha256(path):sub(1, 12) .. "-" .. vim.fn.sha256(key):sub(1, 12)
end

local function in_use(dir)
  return package.loaded["docview.pages"] ~= nil and require("docview.pages").in_use(dir)
end

local function editing(dir)
  for _, s in pairs(package.loaded["docview.edit"] and require("docview.edit").sessions or {}) do
    if s.dir == dir then
      return true
    end
  end
  return false
end

---@class docview.CleanReport
---@field freed number bytes
---@field documents number cache folders removed
---@field files number single files removed (zoom renders, backups)

--- Cleans up now. `on_done(report)` is called when finished.
---@param on_done? fun(report: docview.CleanReport)
function M.prune(on_done)
  local cfg, now = config(), os.time()
  local report = { freed = 0, documents = 0, files = 0 }
  local root = M.root()

  local function remove_dir(dir)
    report.freed = report.freed + size_of(dir)
    report.documents = report.documents + 1
    vim.fn.delete(dir, "rf")
  end
  local function remove_file(file, st)
    report.freed = report.freed + (st and st.size or 0)
    report.files = report.files + 1
    vim.fn.delete(file)
  end

  local ticks = 0
  local function pause()
    ticks = ticks + 1
    if ticks % 10 == 0 then
      coroutine.yield()
    end
  end

  local function run()
    local entries = {}
    if vim.fn.isdirectory(root) == 1 then
      for name, kind in vim.fs.dir(root) do
        local dir = root .. "/" .. name
        if kind ~= "directory" or in_use(dir) then
          -- leave files and folders being shown alone
        elseif name == "libreoffice-profile" or name:match("^%x+$") then
          -- Left over from older versions of docview (the profile now lives in stdpath("data")).
          remove_dir(dir)
        elseif name == "edit" then
          for sub in vim.fs.dir(dir) do
            local work = dir .. "/" .. sub
            local st = stat(work)
            if not editing(work) and st and now - st.mtime.sec > DAY then
              remove_dir(work)
            end
          end
        elseif name:match("^%x+%-%x+$") then
          local st = stat(dir)
          local source = (vim.fn.filereadable(dir .. "/source") == 1 and vim.fn.readfile(dir .. "/source")[1]) or nil
          if not st or not source or current_name(source) ~= name then
            -- The document was deleted or has changed since: this version is never shown again.
            remove_dir(dir)
          elseif now - st.mtime.sec > cfg.max_age_days * DAY then
            remove_dir(dir)
          else
            local base = require("docview").config.pages.dpi
            for file in vim.fs.dir(dir) do
              local dpi = tonumber(file:match("^page%-%d+%-(%d+)%.png$") or "")
              local fst = dpi and dpi ~= base and stat(dir .. "/" .. file)
              if fst and now - fst.mtime.sec > cfg.zoom_age_days * DAY then
                remove_file(dir .. "/" .. file, fst)
              end
            end
            -- Deleting files touches the folder; keep its time as "last used".
            vim.uv.fs_utime(dir, st.atime.sec, st.mtime.sec)
            entries[#entries + 1] = { dir = dir, used = st.mtime.sec, size = size_of(dir) }
          end
        end
        pause()
      end
    end

    -- Over the size limit: least recently used documents go first.
    local total, limit = 0, cfg.max_size_mb * 1024 * 1024
    for _, e in ipairs(entries) do
      total = total + e.size
    end
    table.sort(entries, function(a, b)
      return a.used < b.used
    end)
    for _, e in ipairs(entries) do
      if total <= limit then
        break
      end
      if not in_use(e.dir) then
        total = total - e.size
        remove_dir(e.dir)
      end
    end

    -- Backups: the newest few per document, and none older than the age limit.
    local backups = vim.fn.stdpath("data") .. "/docview/backups"
    if vim.fn.isdirectory(backups) == 1 then
      local groups = {}
      for name, kind in vim.fs.dir(backups) do
        local doc, y, mo, d, h, mi, sec, ext =
          name:match("^(.*)%-(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)%.([^.]+)$")
        if kind == "file" and doc then
          local key = doc .. "." .. ext
          groups[key] = groups[key] or {}
          table.insert(groups[key], {
            file = backups .. "/" .. name,
            st = stat(backups .. "/" .. name),
            -- From the name: a copied file may keep the original document's modification time.
            made = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec }),
          })
        end
      end
      for _, list in pairs(groups) do
        table.sort(list, function(a, b)
          return a.file > b.file -- the timestamp in the name sorts newest first
        end)
        for i, b in ipairs(list) do
          if i > cfg.backups_keep or now - b.made > cfg.backups_max_age_days * DAY then
            remove_file(b.file, b.st)
          end
        end
        pause()
      end
    end
  end

  local co = coroutine.create(run)
  local function step()
    local ok, err = coroutine.resume(co)
    if not ok then
      return vim.notify("docview: cache cleanup failed: " .. tostring(err), vim.log.levels.WARN)
    end
    if coroutine.status(co) == "dead" then
      if on_done then
        on_done(report)
      end
    else
      vim.schedule(step)
    end
  end
  step()
end

function M.describe(report)
  local parts = { ("freed %.1f MB"):format(report.freed / 1024 / 1024) }
  if report.documents > 0 then
    parts[#parts + 1] = ("%d cached document%s"):format(report.documents, report.documents == 1 and "" or "s")
  end
  if report.files > 0 then
    parts[#parts + 1] = ("%d file%s"):format(report.files, report.files == 1 and "" or "s")
  end
  return table.concat(parts, ", ")
end

return M
