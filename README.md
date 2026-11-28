# docview.nvim

Open PDFs, Word documents, spreadsheets and slides in Neovim. In kitty, Ghostty or
WezTerm you see the real pages, with their fonts, layout and images, the way a PDF viewer shows them.
Press `<Tab>` for the text version to search, yank or read anywhere else.

`:e report.docx` (or picking the file from any explorer or picker) just works. Viewing
never modifies the file (`:w` is refused); press `i` to edit Word, ODT, RTF and Excel files.

## Page view

Each page is rendered to an image and drawn with [snacks.nvim](https://github.com/folke/snacks.nvim)'s
image support, scrolling line by line like any buffer.

- PDFs need [Ghostscript](https://ghostscript.com): `brew install ghostscript`
- Word, PowerPoint, Excel, OpenDocument and RTF files are first converted to PDF by
  LibreOffice, which runs invisibly in the background: `brew install --cask libreoffice`

Converted PDFs and page images are cached (by path, size and modification time), so a
document is only converted once; reopening it is instant. The first pages appear while
the rest are still rendering.

When page images aren't possible (another terminal, missing tools), documents open as text
and `:DocviewInfo` says why.

## Picker previews

In [snacks.nvim](https://github.com/folke/snacks.nvim)'s pickers (LazyVim's `<leader>ff`
and friends) documents preview as their real pages, which you can scroll through with the
picker's preview keys (`<C-f>` / `<C-b>`). Only the pages near what's visible are kept in
the terminal, and rendering stops as soon as you move to another file.

The first time an Office file is previewed, its text shows for the few seconds LibreOffice
takes to convert it; after that it is cached and its pages show at once.

## Editing

Press `i` (or `:DocviewEdit`) in a Word, ODT, RTF or Excel document to edit it. `:w`
saves back to the original file, with the real pages in a split on the right that refresh
on every save. `:e` returns to the viewer.

| Format                   | Edited as | Kept on save                                                                 | Lost on save                                                                                   |
| ------------------------ | --------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `.docx` `.odt`           | Markdown  | Text, headings, lists, bold/italic, links, tables, images, footnotes; fonts, heading styles, margins, headers and footers (the original is the style template) | Comments, tracked changes, text boxes, columns, formatting applied by hand to single words |
| `.rtf`                   | Markdown  | Text and basic formatting                                                    | Fonts and page layout                                                                          |
| `.xlsx`                  | CSV       | Values, formulas (shown as `=SUM(A1:A3)`), sheets (`### Sheet: Name` lines)  | Cell formatting, number formats (dates become numbers), column widths, charts                  |

Before the first save of each editing session the original is copied to
`~/.local/share/nvim/docview/backups/`, so nothing is ever lost. `:w notes.md` or
`:w data.csv` writes the Markdown/CSV itself; `:w copy.docx` saves a converted copy.

Editing Word, ODT and RTF needs [pandoc](https://pandoc.org): `brew install pandoc`.

## Cache

Page images and converted PDFs are kept in `~/.cache/nvim/docview` and cleaned up
automatically a few seconds after Neovim starts:

- a document's old versions are deleted as soon as it is rendered again after a change,
  and versions of deleted or changed documents at the next cleanup;
- documents not opened or previewed for 30 days are deleted;
- sharper renders made while zoomed in are deleted after a day;
- above 1 GB in total, the least recently used documents go first;
- edit backups: the newest 5 per document are kept, none older than 90 days.

Documents on screen are never touched. `:DocviewCleanCache` runs the cleanup now and
reports what it freed; `:DocviewClearCache` deletes the whole cache.

## Text view

| Format              | Converters, in order of preference                  |
| ------------------- | --------------------------------------------------- |
| `.pdf`              | `pdftotext` → `mutool` → macOS PDFKit (built in)    |
| `.docx`             | `pandoc` → `textutil` (macOS) → built-in reader     |
| `.doc`              | `textutil` → `antiword` → `catdoc`                  |
| `.odt` `.rtf`       | `pandoc` → `textutil`                               |
| `.epub`             | `pandoc`                                            |
| `.pptx` `.xlsx`     | built-in reader (needs only `unzip`)                |

On macOS everything except `.epub` works with no installs; `brew install pandoc poppler`
gives Markdown output for Word documents and layout-preserving PDF text.

## Install

lazy.nvim (keep it un-lazy; it only registers autocmds at startup):

```lua
{ "sxeptical/docview.nvim", lazy = false, dependencies = { "folke/snacks.nvim" }, opts = {} }
```

Without a plugin manager: `vim.opt.rtp:prepend("~/path/to/docview.nvim")`.

## Usage

| Key / command          | Action                                             |
| ---------------------- | -------------------------------------------------- |
| `i`                    | Edit the document (`:DocviewEdit`)                 |
| `<Tab>`                | Switch between pages and text (`:DocviewToggle`)   |
| `]p` / `[p`            | Next / previous page (takes a count)               |
| `+` / `-` / `=`        | Zoom in / out / fit to window (page view)          |
| `gO`                   | Open the file in its default app (`:DocviewOpen`)  |
| `:DocviewReload`       | Re-convert (e.g. after the file changed)           |
| `:DocviewInfo`         | Show which converter was used                      |
| `:DocviewCleanCache`   | Clean up old cached pages and backups now          |
| `:DocviewClearCache`   | Delete cached page images and PDFs                 |
| `:checkhealth docview` | See what is installed                              |

## Options

```lua
require("docview").setup({
  extensions = { "pdf", "docx", "doc", "odt", "rtf", "epub", "pptx", "xlsx" },
  view = "pages", -- or "text" to open documents as text by default
  pages = {
    dpi = 180, -- render resolution; higher is sharper but slower
    max_width = 100, -- widest a page is drawn, in columns, at zoom 1
    chunk_size = 6, -- pages rendered per batch
    jobs = 3, -- Ghostscript processes rendering at once
  },
  picker = {
    enabled = true, -- preview documents in snacks.nvim's picker
    pages = true, -- show pages instead of text in previews
  },
  cache = {
    auto_clean = true, -- clean up shortly after startup
    max_age_days = 30, -- documents not opened for this long
    max_size_mb = 1024, -- beyond this, least recently used documents go first
    zoom_age_days = 1, -- sharper renders made while zoomed in
    backups_keep = 5, -- edit backups kept per document
    backups_max_age_days = 90,
  },
  edit = {
    preview = true, -- real pages in a split while editing, refreshed on save
  },
  pdf_layout = true, -- pdftotext -layout keeps columns and tables aligned (text view)
  pandoc_args = { "--to=gfm", "--wrap=auto", "--columns=100" },
  timeout = 60000,
  keymaps = { -- false disables one
    edit = "i",
    next_page = "]p",
    prev_page = "[p",
    open_external = "gO",
    toggle_view = "<Tab>",
    zoom_in = "+",
    zoom_out = "-",
    zoom_reset = "=",
  },
})
```
